//! The optional GPU backend: the 24 blend modes in a wgpu compute shader.
//!
//! The CPU compositor stays the default and the reference: this module is an accelerator for one step of
//! it - compositing two straight-alpha RGBA8 surfaces in a blend mode at an opacity - and every result is
//! checked against the CPU in the tests. Nothing here panics when the machine has no adapter: every entry
//! point reports `None` and the caller falls back, because a machine without a GPU is not an error.
//!
//! The shader (`blend.wgsl`) mirrors `blend::composite_texel_mode` step for step, including the way the
//! CPU stores a premultiplied byte and unpremultiplies it again, so a GPU composite and a CPU one agree to
//! within the rounding of the two float implementations.

use std::sync::OnceLock;

use comp_core::{Bitmap8, BlendMode, Document, Layer};

use crate::pixel::Surface;

/// The compute shader, kept beside the code that binds it.
const SHADER: &str = include_str!("blend.wgsl");

/// How many pixels one workgroup covers, matching the shader's `@workgroup_size`.
const WORKGROUP: u32 = 64;

/// The most workgroups one dispatch dimension takes; WebGPU fixes it at 65535. A 4000 x 4000 canvas needs
/// a quarter of a million workgroups, so the dispatch spreads them over two dimensions.
const MAX_WORKGROUPS_PER_DIMENSION: u32 = 65_535;

/// The GPU the blend shader runs on.
///
/// Built once per process by `backend()`; a machine with no usable adapter simply has none.
pub struct GpuBackend {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::ComputePipeline,
    bind_group_layout: wgpu::BindGroupLayout,
    /// The adjustment layer pass: its own entry point and its own bindings.
    adjust_pipeline: wgpu::ComputePipeline,
    adjust_layout: wgpu::BindGroupLayout,
    /// The layer effect passes, in the order effects.rs runs them.
    fx_layout: wgpu::BindGroupLayout,
    fx_prepare: wgpu::ComputePipeline,
    fx_shape: wgpu::ComputePipeline,
    fx_shift: wgpu::ComputePipeline,
    fx_blur_h: wgpu::ComputePipeline,
    fx_blur_v: wgpu::ComputePipeline,
    fx_extreme: wgpu::ComputePipeline,
    fx_combine: wgpu::ComputePipeline,
    fx_fill: wgpu::ComputePipeline,
    fx_over: wgpu::ComputePipeline,
    fx_straighten: wgpu::ComputePipeline,
    fx_vignette: wgpu::ComputePipeline,
    fx_lens: wgpu::ComputePipeline,
    fx_blur: wgpu::ComputePipeline,
    fx_bloom_highlights: wgpu::ComputePipeline,
    fx_bloom_add: wgpu::ComputePipeline,
    fx_tonal: wgpu::ComputePipeline,
    fx_dither_ordered: wgpu::ComputePipeline,
    fx_dither_marks: wgpu::ComputePipeline,
    fx_scanlines: wgpu::ComputePipeline,
    /// The passes a blur adjustment runs: premultiply, the blur itself, and the shared tail.
    prepare_pipeline: wgpu::ComputePipeline,
    blur_pipeline: wgpu::ComputePipeline,
    motion_pipeline: wgpu::ComputePipeline,
    finish_pipeline: wgpu::ComputePipeline,
    adapter_name: String,
    backend_name: String,
    /// The last validation error a composite hit, so a caller that saw a fallback can report why.
    last_error: std::sync::Mutex<Option<String>>,
}

impl GpuBackend {
    /// Opens the best adapter this machine offers, or `None` when there is none.
    ///
    /// Every failure path - no instance, no adapter, no device, a shader this driver will not take - is
    /// `None` rather than a panic: a machine without a discrete GPU, a headless session or a driver that
    /// refuses the request all mean "use the CPU", not "the program is broken". `unavailability` says
    /// which one it was, so a test can insist that a rejected shader is a failure while a missing GPU is a
    /// skip.
    pub fn new() -> Option<GpuBackend> {
        GpuBackend::open().ok()
    }

    fn open() -> Result<GpuBackend, String> {
        let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
        descriptor.backends = wgpu::Backends::from_env().unwrap_or_else(wgpu::Backends::all);
        let instance = wgpu::Instance::new(descriptor);
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
            apply_limit_buckets: false,
        }))
        .map_err(|error| format!("no adapter: {error}"))?;
        let info = adapter.get_info();
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("comp-render"),
            required_features: wgpu::Features::empty(),
            required_limits: adapter.limits(),
            ..Default::default()
        }))
        .map_err(|error| format!("no device: {error}"))?;
        // wgpu turns a validation error into a panic unless a scope catches it, so the shader and the
        // pipeline are created inside one: a shader this driver will not take is a reported failure, not a
        // crash in the middle of a composite.
        let error_scope = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("comp-render blend"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("comp-render blend"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(PARAMS_BYTES),
                    },
                    count: None,
                },
                storage_entry(1, true),
                storage_entry(2, true),
                storage_entry(3, false),
                storage_entry(4, true),
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("comp-render blend"),
            bind_group_layouts: &[Some(&bind_group_layout)],
            immediate_size: 0,
        });
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("comp-render blend"),
            layout: Some(&layout),
            module: &shader,
            entry_point: Some("composite"),
            compilation_options: Default::default(),
            cache: None,
        });
        let adjust_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("comp-render adjust"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(PARAMS_BYTES),
                    },
                    count: None,
                },
                storage_entry(3, false),
                storage_entry(4, true),
                storage_entry(5, true),
                storage_entry(6, true),
                storage_entry(7, true),
            ],
        });
        let adjust_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("comp-render adjust"),
            bind_group_layouts: &[Some(&adjust_layout)],
            immediate_size: 0,
        });
        let adjust_pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("comp-render adjust"),
            layout: Some(&adjust_pipeline_layout),
            module: &shader,
            entry_point: Some("adjust"),
            compilation_options: Default::default(),
            cache: None,
        });
        // The blur adjustments share the adjust pass's bindings; each is one entry point of its own.
        let pass_pipeline = |entry: &str| {
            device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(&adjust_pipeline_layout),
                module: &shader,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        // Effects need one more binding than the adjustment passes: a buffer of f32 values, because the
        // CPU's effects blur rounds only once, after both axes.
        let fx_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("comp-render effects"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(PARAMS_BYTES),
                    },
                    count: None,
                },
                storage_entry(3, false),
                storage_entry(4, true),
                storage_entry(5, true),
                storage_entry(6, true),
                storage_entry(7, true),
                storage_entry(8, false),
            ],
        });
        let fx_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("comp-render effects"),
            bind_group_layouts: &[Some(&fx_layout)],
            immediate_size: 0,
        });
        let fx_pipeline = |entry: &str| {
            device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(&fx_pipeline_layout),
                module: &shader,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        let fx_prepare = fx_pipeline("fx_prepare");
        let fx_shape = fx_pipeline("fx_shape");
        let fx_shift = fx_pipeline("fx_shift");
        let fx_blur_h = fx_pipeline("fx_blur_h");
        let fx_blur_v = fx_pipeline("fx_blur_v");
        let fx_extreme = fx_pipeline("fx_extreme");
        let fx_combine = fx_pipeline("fx_combine");
        let fx_fill = fx_pipeline("fx_fill");
        let fx_over = fx_pipeline("fx_over");
        let fx_straighten = fx_pipeline("fx_straighten");
        // The filter kernels are per pixel and run on the premultiplied surface the CPU's filters use.
        let fx_vignette = fx_pipeline("fx_vignette");
        let fx_lens = fx_pipeline("fx_lens");
        // The filters' blur is adjustment::gaussian_blur - the blur entry point already built for the blur
        // adjustment: the same kernel, the same transparent edges, the same rounding between the axes.
        let fx_blur = fx_pipeline("blur");
        let fx_bloom_highlights = fx_pipeline("fx_bloom_highlights");
        let fx_bloom_add = fx_pipeline("fx_bloom_add");
        let fx_tonal = fx_pipeline("fx_tonal");
        let fx_dither_ordered = fx_pipeline("fx_dither_ordered");
        let fx_dither_marks = fx_pipeline("fx_dither_marks");
        let fx_scanlines = fx_pipeline("fx_scanlines");
        let prepare_pipeline = pass_pipeline("prepare");
        let blur_pipeline = pass_pipeline("blur");
        let motion_pipeline = pass_pipeline("motion");
        let finish_pipeline = pass_pipeline("finish");
        if let Some(error) = pollster::block_on(error_scope.pop()) {
            return Err(format!("the blend shader was rejected: {error}"));
        }
        Ok(GpuBackend {
            device,
            queue,
            pipeline,
            bind_group_layout,
            adjust_pipeline,
            adjust_layout,
            fx_layout,
            fx_prepare,
            fx_shape,
            fx_shift,
            fx_blur_h,
            fx_blur_v,
            fx_extreme,
            fx_combine,
            fx_fill,
            fx_over,
            fx_straighten,
            fx_vignette,
            fx_lens,
            fx_blur,
            fx_bloom_highlights,
            fx_bloom_add,
            fx_tonal,
            fx_dither_ordered,
            fx_dither_marks,
            fx_scanlines,
            prepare_pipeline,
            blur_pipeline,
            motion_pipeline,
            finish_pipeline,
            adapter_name: info.name.clone(),
            backend_name: format!("{:?}", info.backend),
            last_error: std::sync::Mutex::new(None),
        })
    }

    /// The adapter and backend this backend runs on, for a status line or a test.
    pub fn describe(&self) -> String {
        format!("{} ({})", self.adapter_name, self.backend_name)
    }

    pub fn adapter_name(&self) -> &str {
        &self.adapter_name
    }

    pub fn backend_name(&self) -> &str {
        &self.backend_name
    }

    /// The last validation error this backend's composite hit, if the most recent one fell back.
    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().ok().and_then(|slot| slot.clone())
    }

    /// Composites `source` over `backdrop` in `mode` at `opacity`, straight alpha in and out.
    ///
    /// `None` when the surfaces do not match, are empty, or the device refused the work; the caller then
    /// composites on the CPU. A partially GPU-made image is never returned.
    pub fn composite(
        &self,
        backdrop: &Bitmap8,
        source: &Bitmap8,
        mode: BlendMode,
        opacity: f64,
    ) -> Option<Bitmap8> {
        self.composite_covered(backdrop, source, &[], mode, opacity)
    }

    /// The same, with coverage planes the shader multiplies into the source's alpha before it blends:
    /// a layer's own mask, its clipping coverage, and its folders' masks, in the order the CPU applies
    /// them. Each plane is canvas-sized, one byte per pixel.
    pub fn composite_covered(
        &self,
        backdrop: &Bitmap8,
        source: &Bitmap8,
        planes: &[Vec<u8>],
        mode: BlendMode,
        opacity: f64,
    ) -> Option<Bitmap8> {
        if backdrop.width() != source.width() || backdrop.height() != source.height() {
            return None;
        }
        self.composite_placed(backdrop, source, None, planes, mode, opacity)
    }

    /// The same, with the layer's pixels placed through a transform instead of filling the canvas.
    ///
    /// The source is then the layer's own image, at its own size, and the shader samples it: place.rs's
    /// inverse mapping, its filter and its coverage, so a moved, scaled, turned or mirrored layer lands on
    /// the CPU's own pixels.
    pub fn composite_placed(
        &self,
        backdrop: &Bitmap8,
        source: &Bitmap8,
        placement: Option<&crate::place::Placement>,
        planes: &[Vec<u8>],
        mode: BlendMode,
        opacity: f64,
    ) -> Option<Bitmap8> {
        if placement.is_none() && (backdrop.width() != source.width() || backdrop.height() != source.height()) {
            return None;
        }
        if backdrop.is_empty() || source.is_empty() {
            return None;
        }
        // Any validation error inside the composite - a driver limit, an unmappable buffer - is caught here
        // and reported as None, which the caller answers by compositing on the CPU.
        let error_scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let count = backdrop.pixel_count();
        if planes.len() > MAX_COVERAGE_PLANES {
            return None;
        }
        if planes.iter().any(|plane| plane.len() != count) {
            return None;
        }
        let mode_index = BlendMode::ALL.iter().position(|candidate| *candidate == mode)? as u32;
        let bytes = (count * 4) as u64;
        let storage = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST;
        let backdrop_buffer = self.upload("backdrop", backdrop.pixels(), bytes, storage);
        // The layer's own rectangle, which the coverage measures against even when the buffer below holds a
        // reduced copy of it.
        let cover_size = (source.width(), source.height());
        // A reduced placement samples the layer's halved chain, not the layer: the reduction happens here,
        // with the CPU's own DownsampleCache, so the shader reads the same levels it would have.
        let reduced;
        let source = match placement.as_ref().filter(|placement| placement.level > 0) {
            Some(placement) => {
                reduced = crate::place::reduced_for_gpu(source, placement.level)?;
                &reduced.0
            }
            None => source,
        };
        let source_bytes = (source.pixel_count() * 4) as u64;
        let source_buffer = self.upload("source", source.pixels(), source_bytes, storage);
        // The buffer's own size, which the shader needs to index it: the layer's size only when it was not
        // reduced. The coverage keeps measuring against the layer's full rectangle.
        let sample_size = (source.width(), source.height());
        let output_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("output"),
            size: bytes,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        // A buffer a shader writes cannot be mapped for reading, so the result is copied into one that
        // can: the usual two-buffer readback.
        let readback_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: bytes,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        // A dispatch may only have 65535 workgroups on a dimension, and a large canvas needs far more
        // than that: spread them over two dimensions and tell the shader how many the first one took.
        let groups = (count as u32).div_ceil(WORKGROUP);
        let groups_x = groups.min(MAX_WORKGROUPS_PER_DIMENSION);
        let groups_y = groups.div_ceil(groups_x.max(1));
        let mut params_bytes = [0u8; PARAMS_BYTES as usize];
        params_bytes[0..4].copy_from_slice(&(count as u32).to_le_bytes());
        params_bytes[4..8].copy_from_slice(&mode_index.to_le_bytes());
        params_bytes[8..12].copy_from_slice(&(opacity.clamp(0.0, 1.0) as f32).to_le_bytes());
        params_bytes[12..16].copy_from_slice(&groups_x.to_le_bytes());
        // The placement: where the layer's own image goes, how it is sampled and through which matrix.
        let placement = placement.cloned();
        params_bytes[24..28].copy_from_slice(&cover_size.0.to_le_bytes());
        params_bytes[28..32].copy_from_slice(&cover_size.1.to_le_bytes());
        params_bytes[32..36].copy_from_slice(&backdrop.width().to_le_bytes());
        if let Some(placement) = &placement {
            params_bytes[36..40].copy_from_slice(&placement.filter.to_le_bytes());
            params_bytes[40..44].copy_from_slice(&1u32.to_le_bytes());
            params_bytes[44..48].copy_from_slice(&(placement.axis_aligned as u32).to_le_bytes());
            params_bytes[48..52].copy_from_slice(&(placement.box_.0 as i32).to_le_bytes());
            params_bytes[52..56].copy_from_slice(&(placement.box_.1 as i32).to_le_bytes());
            params_bytes[56..60].copy_from_slice(&placement.box_.2.to_le_bytes());
            params_bytes[60..64].copy_from_slice(&placement.box_.3.to_le_bytes());
            let inverse = placement.inverse;
            for (slot, value) in [
                (64usize, inverse.a),
                (68, inverse.b),
                (72, inverse.c),
                (76, inverse.d),
                (80, inverse.tx),
                (84, inverse.ty),
                (88, placement.affine.a),
                (92, placement.affine.d),
                (96, placement.affine.tx),
                (100, placement.affine.ty),
            ] {
                params_bytes[slot..slot + 4].copy_from_slice(&(value as f32).to_le_bytes());
            }
            // A reduced layer is sampled at its own scale, as the CPU's placements do. The offsets follow
            // the shader's struct: after the affine comes coord_scale, then the buffer's own size.
            params_bytes[104..108].copy_from_slice(&placement.coord_scale.to_le_bytes());
            params_bytes[108..112].copy_from_slice(&sample_size.0.to_le_bytes());
            params_bytes[112..116].copy_from_slice(&sample_size.1.to_le_bytes());
        } else {
            // Without a placement the source is the canvas itself, one texel per pixel.
            params_bytes[24..28].copy_from_slice(&backdrop.width().to_le_bytes());
            params_bytes[28..32].copy_from_slice(&backdrop.height().to_le_bytes());
        }
        // Four coverage bytes to a word, one plane after another, and at least one word so the binding is
        // never empty: the shader reads nothing from it when there are no planes.
        let plane_words = (count as u32).div_ceil(4).max(1);
        let packed = pack_planes(planes, plane_words);
        params_bytes[16..20].copy_from_slice(&(planes.len() as u32).to_le_bytes());
        params_bytes[20..24].copy_from_slice(&plane_words.to_le_bytes());
        let coverage_buffer = self.upload(
            "coverage",
            &packed,
            packed.len() as u64,
            wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        );
        let params_buffer = self.upload("params", &params_bytes, PARAMS_BYTES, wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST);
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("comp-render blend"),
            layout: &self.bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: backdrop_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: source_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: output_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 4, resource: coverage_buffer.as_entire_binding() },
            ],
        });
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("comp-render blend") });
        {
            let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("comp-render blend"),
                timestamp_writes: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &bind_group, &[]);
            pass.dispatch_workgroups(groups_x, groups_y, 1);
        }
        encoder.copy_buffer_to_buffer(&output_buffer, 0, &readback_buffer, 0, bytes);
        self.queue.submit(Some(encoder.finish()));

        // Read the result back. This is the part that costs on a small image: the round trip to the GPU and
        // back dwarfs the arithmetic.
        let slice = readback_buffer.slice(..);
        let (sender, receiver) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.device.poll(wgpu::PollType::wait_indefinitely()).ok()?;
        receiver.recv().ok()?.ok()?;
        let pixels = {
            let view = slice.get_mapped_range().ok()?;
            view.to_vec()
        };
        readback_buffer.unmap();
        if let Some(error) = pollster::block_on(error_scope.pop()) {
            if let Ok(mut slot) = self.last_error.lock() {
                *slot = Some(error.to_string());
            }
            return None;
        }
        Bitmap8::from_raw(backdrop.width(), backdrop.height(), pixels).ok()
    }

    /// One adjustment layer's pass over the canvas, with the CPU's own semantics: the kernel, then - when
    /// the layer has a blend mode - the adjusted colors blended with what was under them at full coverage
    /// and shown only where the canvas had coverage, then the layer's coverage mixed back in.
    ///
    /// The coverage plane already carries the layer's mask, its folders' masks and its opacity, exactly as
    /// the composite path's planes do. No planes means the adjustment applies everywhere.
    pub fn adjust(
        &self,
        canvas: &Bitmap8,
        program: &crate::adjustment::GpuAdjustment,
        planes: &[Vec<u8>],
        blend: Option<BlendMode>,
        opacity: f64,
    ) -> Option<Bitmap8> {
        if canvas.is_empty() || program.words().is_empty() {
            return None;
        }
        let error_scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let count = canvas.pixel_count();
        if planes.len() > MAX_COVERAGE_PLANES || planes.iter().any(|plane| plane.len() != count) {
            return None;
        }
        if planes.is_empty() && opacity >= 1.0 && blend.is_none() {
            // Nothing to mix and no blend: the pass still runs, because the kernel changes the pixels.
        }
        let bytes = (count * 4) as u64;
        let storage = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST;
        let canvas_buffer = self.upload("canvas", canvas.pixels(), bytes, storage);
        let below_buffer = self.upload("beneath", canvas.pixels(), bytes, storage);
        let output_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("adjusted"),
            size: bytes,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let readback_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: bytes,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let groups = (count as u32).div_ceil(WORKGROUP);
        let groups_x = groups.min(MAX_WORKGROUPS_PER_DIMENSION);
        let groups_y = groups.div_ceil(groups_x.max(1));
        let mut params_bytes = [0u8; PARAMS_BYTES as usize];
        params_bytes[0..4].copy_from_slice(&(count as u32).to_le_bytes());
        // A blend mode travels as its index plus one, so zero can mean "no blend".
        let mode_word = match blend {
            Some(mode) => BlendMode::ALL.iter().position(|candidate| *candidate == mode)? as u32 + 1,
            None => 0,
        };
        params_bytes[4..8].copy_from_slice(&mode_word.to_le_bytes());
        params_bytes[8..12].copy_from_slice(&(opacity.clamp(0.0, 1.0) as f32).to_le_bytes());
        params_bytes[12..16].copy_from_slice(&groups_x.to_le_bytes());
        let plane_words = (count as u32).div_ceil(4).max(1);
        let packed = pack_planes(planes, plane_words);
        params_bytes[16..20].copy_from_slice(&(planes.len() as u32).to_le_bytes());
        params_bytes[20..24].copy_from_slice(&plane_words.to_le_bytes());
        params_bytes[24..28].copy_from_slice(&canvas.width().to_le_bytes());
        params_bytes[28..32].copy_from_slice(&canvas.height().to_le_bytes());
        params_bytes[32..36].copy_from_slice(&canvas.width().to_le_bytes());
        let params_buffer = self.upload("params", &params_bytes, PARAMS_BYTES, wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST);
        let coverage_buffer = self.upload("coverage", &packed, packed.len() as u64, storage);
        let words = program.words();
        let program_bytes: Vec<u8> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
        let program_buffer = self.upload("program", &program_bytes, program_bytes.len() as u64, storage);
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("comp-render adjust"),
            layout: &self.adjust_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: output_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 4, resource: coverage_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 5, resource: program_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 6, resource: canvas_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 7, resource: below_buffer.as_entire_binding() },
            ],
        });
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("comp-render adjust") });
        {
            let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("comp-render adjust"),
                timestamp_writes: None,
            });
            pass.set_pipeline(&self.adjust_pipeline);
            pass.set_bind_group(0, &bind_group, &[]);
            pass.dispatch_workgroups(groups_x, groups_y, 1);
        }
        encoder.copy_buffer_to_buffer(&output_buffer, 0, &readback_buffer, 0, bytes);
        self.queue.submit(Some(encoder.finish()));
        let slice = readback_buffer.slice(..);
        let (sender, receiver) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.device.poll(wgpu::PollType::wait_indefinitely()).ok()?;
        receiver.recv().ok()?.ok()?;
        let pixels = {
            let view = slice.get_mapped_range().ok()?;
            view.to_vec()
        };
        readback_buffer.unmap();
        if let Some(error) = pollster::block_on(error_scope.pop()) {
            if let Ok(mut slot) = self.last_error.lock() {
                *slot = Some(error.to_string());
            }
            return None;
        }
        Bitmap8::from_raw(canvas.width(), canvas.height(), pixels).ok()
    }

    /// One blur adjustment layer: premultiply the canvas, run the blur, then the same tail every other
    /// adjustment ends with. Gaussian runs a separable pass per axis; motion runs its streak in one.
    ///
    /// The kernel comes from the program: the CPU built the Gaussian's normalized weights, and the motion
    /// blur's step count and direction are its own rounded values, so neither is recomputed here.
    pub fn blur_adjustment(
        &self,
        canvas: &Bitmap8,
        program: &crate::adjustment::GpuAdjustment,
        planes: &[Vec<u8>],
        blend: Option<BlendMode>,
        gaussian: bool,
    ) -> Option<Bitmap8> {
        if canvas.is_empty() {
            return None;
        }
        let count = canvas.pixel_count();
        if planes.len() > MAX_COVERAGE_PLANES || planes.iter().any(|plane| plane.len() != count) {
            return None;
        }
        let mode_word = match blend {
            Some(mode) => BlendMode::ALL.iter().position(|candidate| *candidate == mode)? as u32 + 1,
            None => 0,
        };
        let words = program.words();
        // Premultiply once: the CPU's blurs read a surface, whose bytes are premultiplied. Every pass needs
        // the canvas width to know where a row ends.
        let width = Some(canvas.width());
        let premultiplied = self.run_pass(Pass::Prepare, canvas.pixels(), canvas.pixels(), &words, 0, None, width)?;
        // The CPU's kernels open with a guard - a radius of zero, a distance of one pixel - and leave the
        // canvas alone; the layer's blend and coverage steps still run afterwards.
        let blurred = if !program.apply {
            premultiplied.clone()
        } else if gaussian {
            let horizontal = self.run_pass(Pass::Blur, &premultiplied, &premultiplied, &words, 0, None, width)?;
            self.run_pass(Pass::Blur, &horizontal, &horizontal, &words, 1, None, width)?
        } else {
            self.run_pass(Pass::Motion, &premultiplied, &premultiplied, &words, 0, None, width)?
        };
        let pixels = self.run_pass(
            Pass::Finish,
            &blurred,
            &premultiplied,
            &words,
            mode_word,
            Some((planes, count)),
            Some(canvas.width()),
        )?;
        Bitmap8::from_raw(canvas.width(), canvas.height(), pixels).ok()
    }

    /// One compute pass of the adjustment family: the canvas it reads, the copy beneath it, the program,
    /// the mode word, and the coverage planes when the pass mixes them in.
    #[allow(clippy::too_many_arguments)]
    fn run_pass(
        &self,
        pass: Pass,
        canvas: &[u8],
        beneath: &[u8],
        words: &[u32],
        mode_word: u32,
        planes: Option<(&[Vec<u8>], usize)>,
        width: Option<u32>,
    ) -> Option<Vec<u8>> {
        let bytes = canvas.len() as u64;
        let count = (bytes / 4) as u32;
        let width = width.unwrap_or(count);
        let error_scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let storage = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST;
        let canvas_buffer = self.upload("pass-canvas", canvas, bytes, storage);
        let beneath_buffer = self.upload("pass-beneath", beneath, bytes, storage);
        let output_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("pass-output"),
            size: bytes,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let readback = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("pass-readback"),
            size: bytes,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let groups = count.div_ceil(WORKGROUP);
        let groups_x = groups.min(MAX_WORKGROUPS_PER_DIMENSION);
        let groups_y = groups.div_ceil(groups_x.max(1));
        let (plane_count, plane_words, packed) = match planes {
            Some((planes, count)) => {
                let plane_words = (count as u32).div_ceil(4).max(1);
                (planes.len() as u32, plane_words, pack_planes(planes, plane_words))
            }
            None => (0, 1, vec![0u8; 4]),
        };
        let mut params_bytes = [0u8; PARAMS_BYTES as usize];
        params_bytes[0..4].copy_from_slice(&count.to_le_bytes());
        params_bytes[4..8].copy_from_slice(&mode_word.to_le_bytes());
        params_bytes[12..16].copy_from_slice(&groups_x.to_le_bytes());
        params_bytes[16..20].copy_from_slice(&plane_count.to_le_bytes());
        params_bytes[20..24].copy_from_slice(&plane_words.to_le_bytes());
        params_bytes[32..36].copy_from_slice(&width.to_le_bytes());
        params_bytes[116..120].copy_from_slice(&(count / width.max(1)).to_le_bytes());
        // The blur pass reads its axis from the flag the caller passed in mode_word.
        params_bytes[40..44].copy_from_slice(&mode_word.to_le_bytes());
        let params_buffer = self.upload("pass-params", &params_bytes, PARAMS_BYTES, wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST);
        let coverage_buffer = self.upload("pass-coverage", &packed, packed.len() as u64, storage);
        let program_bytes: Vec<u8> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
        let program_buffer = self.upload("pass-program", &program_bytes, program_bytes.len() as u64, storage);
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("comp-render pass"),
            layout: &self.adjust_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: output_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 4, resource: coverage_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 5, resource: program_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 6, resource: canvas_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 7, resource: beneath_buffer.as_entire_binding() },
            ],
        });
        let pipeline = match pass {
            Pass::Prepare => &self.prepare_pipeline,
            Pass::Blur => &self.blur_pipeline,
            Pass::Motion => &self.motion_pipeline,
            Pass::Finish => &self.finish_pipeline,
        };
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("comp-render pass") });
        {
            let mut compute = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("comp-render pass"),
                timestamp_writes: None,
            });
            compute.set_pipeline(pipeline);
            compute.set_bind_group(0, &bind_group, &[]);
            compute.dispatch_workgroups(groups_x, groups_y, 1);
        }
        encoder.copy_buffer_to_buffer(&output_buffer, 0, &readback, 0, bytes);
        self.queue.submit(Some(encoder.finish()));
        let slice = readback.slice(..);
        let (sender, receiver) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.device.poll(wgpu::PollType::wait_indefinitely()).ok()?;
        receiver.recv().ok()?.ok()?;
        let pixels = {
            let view = slice.get_mapped_range().ok()?;
            view.to_vec()
        };
        readback.unmap();
        if let Some(error) = pollster::block_on(error_scope.pop()) {
            if let Ok(mut slot) = self.last_error.lock() {
                *slot = Some(error.to_string());
            }
            return None;
        }
        Some(pixels)
    }

    /// One pass of the effects pipeline. Every pass is a pure function of its buffers: the canvas it
    /// reads, the second buffer beside it, the coverage plane, the f32 scratch, and a small program.
    #[allow(clippy::too_many_arguments)]
    fn fx_run(
        &self,
        entry: Fx,
        canvas: &[u8],
        beneath: &[u8],
        coverage: &[u8],
        scratch: &[u8],
        program: &[u32],
        params: &FxParams,
    ) -> Option<Vec<u8>> {
        let bytes = (params.count * 4) as u64;
        let error_scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let storage = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST;
        let canvas_buffer = self.upload("fx-canvas", canvas, bytes, storage);
        let beneath_buffer = self.upload("fx-beneath", beneath, bytes, storage);
        let coverage_buffer = self.upload("fx-coverage", coverage, coverage.len() as u64, storage);
        let scratch_buffer = self.upload("fx-scratch", scratch, bytes, storage);
        let output_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("fx-output"),
            size: bytes,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let readback = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("fx-readback"),
            size: bytes,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let groups = params.count.div_ceil(WORKGROUP);
        let groups_x = groups.min(MAX_WORKGROUPS_PER_DIMENSION);
        let groups_y = groups.div_ceil(groups_x.max(1));
        let mut params_bytes = [0u8; PARAMS_BYTES as usize];
        params_bytes[0..4].copy_from_slice(&params.count.to_le_bytes());
        params_bytes[12..16].copy_from_slice(&groups_x.to_le_bytes());
        params_bytes[16..20].copy_from_slice(&params.coverage_planes.to_le_bytes());
        params_bytes[20..24].copy_from_slice(&params.plane_words.to_le_bytes());
        params_bytes[32..36].copy_from_slice(&params.width.to_le_bytes());
        params_bytes[36..40].copy_from_slice(&params.mode.to_le_bytes());
        params_bytes[40..44].copy_from_slice(&params.axis.to_le_bytes());
        params_bytes[48..52].copy_from_slice(&(params.inset as i32).to_le_bytes());
        params_bytes[56..60].copy_from_slice(&params.width.to_le_bytes());
        params_bytes[60..64].copy_from_slice(&params.height.to_le_bytes());
        params_bytes[108..112].copy_from_slice(&params.layer_width.to_le_bytes());
        params_bytes[112..116].copy_from_slice(&params.layer_height.to_le_bytes());
        params_bytes[116..120].copy_from_slice(&params.height.to_le_bytes());
        let params_buffer = self.upload("fx-params", &params_bytes, PARAMS_BYTES, wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST);
        let program_bytes: Vec<u8> = program.iter().flat_map(|word| word.to_le_bytes()).collect();
        let program_buffer = self.upload("fx-program", &program_bytes, program_bytes.len() as u64, storage);
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("comp-render effects"),
            layout: &self.fx_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: output_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 4, resource: coverage_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 5, resource: program_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 6, resource: canvas_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 7, resource: beneath_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 8, resource: scratch_buffer.as_entire_binding() },
            ],
        });
        let pipeline = match entry {
            Fx::Prepare => &self.fx_prepare,
            Fx::Shape => &self.fx_shape,
            Fx::Shift => &self.fx_shift,
            Fx::BlurH => &self.fx_blur_h,
            Fx::BlurV => &self.fx_blur_v,
            Fx::Extreme => &self.fx_extreme,
            Fx::Combine => &self.fx_combine,
            Fx::Fill => &self.fx_fill,
            Fx::Over => &self.fx_over,
            Fx::Straighten => &self.fx_straighten,
            Fx::Vignette => &self.fx_vignette,
            Fx::Lens => &self.fx_lens,
            Fx::Blur => &self.fx_blur,
            Fx::BloomHighlights => &self.fx_bloom_highlights,
            Fx::BloomAdd => &self.fx_bloom_add,
            Fx::Tonal => &self.fx_tonal,
            Fx::DitherOrdered => &self.fx_dither_ordered,
            Fx::DitherMarks => &self.fx_dither_marks,
            Fx::Scanlines => &self.fx_scanlines,
        };
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("comp-render effects") });
        {
            let mut compute = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("comp-render effects"),
                timestamp_writes: None,
            });
            compute.set_pipeline(pipeline);
            compute.set_bind_group(0, &bind_group, &[]);
            compute.dispatch_workgroups(groups_x, groups_y, 1);
        }
        encoder.copy_buffer_to_buffer(&output_buffer, 0, &readback, 0, bytes);
        self.queue.submit(Some(encoder.finish()));
        let slice = readback.slice(..);
        let (sender, receiver) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.device.poll(wgpu::PollType::wait_indefinitely()).ok()?;
        receiver.recv().ok()?.ok()?;
        let pixels = {
            let view = slice.get_mapped_range().ok()?;
            view.to_vec()
        };
        readback.unmap();
        if let Some(error) = pollster::block_on(error_scope.pop()) {
            if let Ok(mut slot) = self.last_error.lock() {
                *slot = Some(error.to_string());
            }
            return None;
        }
        Some(pixels)
    }

    /// A layer's effects, rendered on the GPU in the layer's own grid and grown by their margin, exactly
    /// as effects::render lays them out: what sits behind the layer, then the layer, then what sits on top.
    ///
    /// Returns the grown image as straight alpha and the margin it was grown by, which is what the caller
    /// needs to place it with grown_transform.
    pub fn effects_image(
        &self,
        image: &Bitmap8,
        mask: Option<&crate::pixel::Plane>,
        effects: &comp_core::effects::LayerEffects,
    ) -> Option<(Bitmap8, u32)> {
        let effects = crate::effects::visible(effects);
        if effects.is_empty() || image.is_empty() {
            return Some((image.clone(), 0));
        }
        let inset = crate::effects::margin(&effects);
        let (width, height) = (image.width() + inset * 2, image.height() + inset * 2);
        let count = width * height;
        let plane_words = count.div_ceil(4).max(1);
        let packed_mask = match mask {
            Some(plane) => pack_planes(&[plane.values().to_vec()], plane_words),
            None => vec![0u8; (plane_words * 4) as usize],
        };
        let params = FxParams {
            count,
            width,
            height,
            layer_width: image.width(),
            layer_height: image.height(),
            inset,
            mode: 0,
            axis: 0,
            coverage_planes: u32::from(mask.is_some()),
            plane_words,
        };
        let blank = vec![0u8; (count * 4) as usize];
        // The grown canvas: the layer's pixels at the inset, premultiplied and masked.
        let canvas = self.fx_run(Fx::Prepare, image.pixels(), &blank, &packed_mask, &blank, &program(&[]), &params)?;
        // The shape: the coverage every effect measures from, kept while the fills paint the canvas.
        let shape = self.fx_run(Fx::Shape, &canvas, &blank, &packed_mask, &blank, &program(&[]), &params)?;
        // The layer's own placed pixels, kept aside: the effects are painted into the canvas, and the layer
        // is composited over them afterwards.
        let placed = canvas.clone();
        let mut canvas = canvas;

        // The effects that sit behind the layer, in the order effects.rs paints them.
        if let Some(shadow) = effects.shadow.filter(|shadow| shadow.opacity > 0.0) {
            let (dx, dy) = crate::effects::shadow_offset(shadow.angle, shadow.distance);
            let coverage = self.softened(&canvas, &shape, &packed_mask, &params, dx, dy, (shadow.blur / 2.0) as f32)?;
            canvas = self.fx_fill(&canvas, &coverage, shadow.color().to_rgba8(), shadow.opacity as f32, &params, &packed_mask)?;
        }
        if let Some(glow) = effects.outer_glow.filter(|glow| glow.opacity > 0.0) {
            let coverage = self.glow_coverage(&canvas, &shape, &packed_mask, &params, (glow.size / 2.0) as f32)?;
            canvas = self.fx_fill(&canvas, &coverage, glow.color().to_rgba8(), glow.opacity as f32, &params, &packed_mask)?;
        }
        let stroke = effects.stroke.filter(|stroke| stroke.size > 0.0 && stroke.opacity > 0.0);
        if let Some(stroke) = stroke.filter(|stroke| !stroke.inside) {
            let coverage = self.ring_coverage(&canvas, &shape, &packed_mask, &params, stroke.size, false)?;
            canvas = self.fx_fill(&canvas, &coverage, stroke.color().to_rgba8(), stroke.opacity as f32, &params, &packed_mask)?;
        }
        // The layer's own pixels over the effects behind it.
        canvas = self.fx_run(Fx::Over, &canvas, &placed, &packed_mask, &vec![0u8; (count * 4) as usize], &program(&[]), &params)?;
        if let Some(overlay) = effects.color_overlay.filter(|overlay| overlay.opacity > 0.0) {
            canvas = self.fx_fill(&canvas, &shape, overlay.color().to_rgba8(), overlay.opacity as f32, &params, &packed_mask)?;
        }
        if let Some(glow) = effects.inner_glow.filter(|glow| glow.size > 0.0 && glow.opacity > 0.0) {
            let coverage = self.softened(&canvas, &shape, &packed_mask, &params, 0.0, 0.0, (glow.size / 2.0) as f32)?;
            let inside = with_mode(&params, 1);
            let coverage = self.fx_run(Fx::Combine, &coverage, &shape, &packed_mask, &vec![0u8; (count * 4) as usize], &program(&[]), &inside)?;
            canvas = self.fx_fill(&canvas, &coverage, glow.color().to_rgba8(), glow.opacity as f32, &params, &packed_mask)?;
        }
        if let Some(inner) = effects.inner_shadow.filter(|inner| inner.opacity > 0.0) {
            let (dx, dy) = crate::effects::shadow_offset(inner.angle, inner.distance);
            let coverage = self.softened(&canvas, &shape, &packed_mask, &params, dx, dy, (inner.blur / 2.0) as f32)?;
            let inside = with_mode(&params, 1);
            let coverage = self.fx_run(Fx::Combine, &coverage, &shape, &packed_mask, &vec![0u8; (count * 4) as usize], &program(&[]), &inside)?;
            canvas = self.fx_fill(&canvas, &coverage, inner.color().to_rgba8(), inner.opacity as f32, &params, &packed_mask)?;
        }
        if let Some(stroke) = stroke.filter(|stroke| stroke.inside) {
            let coverage = self.ring_coverage(&canvas, &shape, &packed_mask, &params, stroke.size, true)?;
            canvas = self.fx_fill(&canvas, &coverage, stroke.color().to_rgba8(), stroke.opacity as f32, &params, &packed_mask)?;
        }
        // Straight alpha, which is what the placement machinery samples.
        let straight = self.fx_run(Fx::Straighten, &canvas, &shape, &packed_mask, &vec![0u8; (count * 4) as usize], &program(&[]), &params)?;
        let bitmap = Bitmap8::from_raw(width, height, straight).ok()?;
        Some((bitmap, inset))
    }

    /// A shape moved by its offset and softened: the coverage a shadow is cast through.
    #[allow(clippy::too_many_arguments)]
    fn softened(
        &self,
        _canvas: &[u8],
        shape: &[u8],
        mask: &[u8],
        params: &FxParams,
        dx: f64,
        dy: f64,
        sigma: f32,
    ) -> Option<Vec<u8>> {
        // The CPU lays the offset shape down on whole pixels, rounding half to even: the offsets are
        // resolved here so the shader only has to walk to them.
        let offset_x = dx.round_ties_even() as f32;
        let offset_y = dy.round_ties_even() as f32;
        let moved = self.fx_run(Fx::Shift, shape, shape, mask, shape, &program(&[offset_x, offset_y]), params)?;
        self.blur_plane(&moved, mask, params, sigma)
    }

    /// The CPU's effects blur: a Gaussian with its border carried outwards, rounded once, after both axes.
    fn blur_plane(&self, plane: &[u8], mask: &[u8], params: &FxParams, sigma: f32) -> Option<Vec<u8>> {
        if !sigma.is_finite() || sigma <= 0.0 {
            return Some(plane.to_vec());
        }
        let (taps, kernel) = crate::adjustment::gaussian_kernel_for(sigma);
        let mut words = vec![0u32; 32 + 1200];
        words[2] = (taps as f32).to_bits();
        for (index, weight) in kernel.iter().enumerate() {
            words[32 + index] = weight.to_bits();
        }
        let horizontal = self.fx_run(Fx::BlurH, plane, plane, mask, plane, &words, params)?;
        self.fx_run(Fx::BlurV, plane, plane, mask, &horizontal, &words, params)
    }

    /// An outer glow's coverage: the softened shape less the shape itself.
    fn glow_coverage(
        &self,
        _canvas: &[u8],
        shape: &[u8],
        mask: &[u8],
        params: &FxParams,
        sigma: f32,
    ) -> Option<Vec<u8>> {
        let soft = self.blur_plane(shape, mask, params, sigma)?;
        self.fx_run(Fx::Combine, &soft, shape, mask, &vec![0u8; (params.count * 4) as usize], &program(&[0.0]), params)
    }

    /// A stroke's ring: the shape grown (or shrunk) by the reach, less the shape.
    fn ring_coverage(
        &self,
        _canvas: &[u8],
        shape: &[u8],
        mask: &[u8],
        params: &FxParams,
        size: f64,
        inside: bool,
    ) -> Option<Vec<u8>> {
        let reach = size.round_ties_even().max(1.0) as u32;
        let mut words = vec![0u32; 32 + 1200];
        words[2] = (reach as f32).to_bits();
        words[3] = f32::from(inside).to_bits();
        let across = with_axis(params, |p| p.axis = 0);
        let down = with_axis(params, |p| p.axis = 1);
        let horizontal = self.fx_run(Fx::Extreme, shape, shape, mask, shape, &words, &across)?;
        let vertical = self.fx_run(Fx::Extreme, &horizontal, shape, mask, shape, &words, &down)?;
        let ring = with_mode(params, if inside { 3 } else { 2 });
        self.fx_run(
            Fx::Combine,
            &vertical,
            shape,
            mask,
            &vec![0u8; (params.count * 4) as usize],
            &program(&[]),
            &ring,
        )
    }

    /// Paints a color through a coverage onto the effects canvas, source over, at the effect's opacity.
    fn fx_fill(
        &self,
        canvas: &[u8],
        coverage: &[u8],
        color: [u8; 4],
        opacity: f32,
        params: &FxParams,
        mask: &[u8],
    ) -> Option<Vec<u8>> {
        let mut words = vec![0u32; 32 + 1200];
        for (index, channel) in color[..3].iter().enumerate() {
            words[2 + index] = (*channel as f32 / 255.0).to_bits();
        }
        words[5] = opacity.to_bits();
        self.fx_run(Fx::Fill, canvas, coverage, mask, canvas, &words, params)
    }

    /// Which filters the GPU can run: the ones that are a function of one pixel, or of a pixel and its
    /// neighbours through the blur pass, with the CPU's own formulas.
    ///
    /// The dither is refused: its error-diffusion styles are a serial raster scan whose every pixel depends
    /// on the one before it, and its ASCII styles need a glyph atlas built from a font.
    pub fn filter_accepts(kind: crate::filters::FilterKind) -> Result<(), String> {
        match kind {
            crate::filters::FilterKind::LensCorrection => Ok(()),
            // The vignette's colour write used to land a level away where the alpha was low. That was the
            // shader's round being half to even while the CPU's is half away from zero, which the rounding
            // audit fixed; it is measured against the CPU now.
            crate::filters::FilterKind::Vignette => Ok(()),
            crate::filters::FilterKind::Dither => Err(
                "dither: which styles run depends on the settings; see GpuBackend::dither_accepts".into(),
            ),
            crate::filters::FilterKind::BloomGlow | crate::filters::FilterKind::TonalContrast => Ok(()),
            _ => Ok(()),
        }
    }

    /// One filter over a whole image, the way filters::apply_filter runs it: the surface is premultiplied,
    /// the kernel runs, and the result is straight again.
    pub fn filter_image(
        &self,
        image: &Bitmap8,
        kind: crate::filters::FilterKind,
        settings: &crate::filters::FilterSettings,
    ) -> Option<Bitmap8> {
        let settings = settings.normalized();
        // The dither is judged on its settings before anything else: its kind alone cannot say whether the
        // style in hand is one the GPU runs.
        if matches!(kind, crate::filters::FilterKind::Dither) {
            GpuBackend::dither_accepts(&settings.dither).ok()?;
            return self.dither_ordered(image, &settings.dither);
        }
        GpuBackend::filter_accepts(kind).ok()?;
        let entry = match kind {
            crate::filters::FilterKind::LensCorrection => Fx::Lens,
            crate::filters::FilterKind::Vignette => Fx::Vignette,
            crate::filters::FilterKind::BloomGlow => Fx::BloomAdd,
            crate::filters::FilterKind::TonalContrast => Fx::Tonal,
            _ => return None,
        };
        let count = image.pixel_count() as u32;
        if count == 0 {
            return Some(image.clone());
        }
        let bytes = (count * 4) as u64;
        let params = FxParams {
            count,
            width: image.width(),
            height: image.height(),
            layer_width: image.width(),
            layer_height: image.height(),
            inset: 0,
            mode: 0,
            axis: 0,
            coverage_planes: 0,
            plane_words: 1,
        };
        let blank = vec![0u8; bytes as usize];
        // The premultiplied surface, exactly as Surface::from_bitmap leaves it.
        let canvas = self.fx_run(Fx::Prepare, image.pixels(), &blank, &blank, &blank, &program(&[]), &params)?;
        let mut words = vec![0u32; 32 + 1200];
        // Bloom and tonal contrast blur the surface with adjustment::gaussian_blur before their own pass.
        if matches!(kind, crate::filters::FilterKind::BloomGlow | crate::filters::FilterKind::TonalContrast) {
            let sigma = if matches!(kind, crate::filters::FilterKind::BloomGlow) {
                (settings.bloom_radius / 2.0) as f32
            } else {
                settings.tonal_radius as f32
            };
            let source = if matches!(kind, crate::filters::FilterKind::BloomGlow) {
                let mut highlights = vec![0u32; 32 + 1200];
                highlights[2] = crate::filters::BLOOM_KNEE.to_bits();
                self.fx_run(Fx::BloomHighlights, &canvas, &blank, &blank, &blank, &highlights, &params)?
            } else {
                canvas.clone()
            };
            let blurred = if sigma > 0.0 && sigma.is_finite() {
                let (taps, kernel) = crate::adjustment::gaussian_kernel_for(sigma);
                let mut blur_words = vec![0u32; 32 + 1200];
                blur_words[2] = (taps as f32).to_bits();
                for (index, weight) in kernel.iter().enumerate() {
                    blur_words[32 + index] = weight.to_bits();
                }
                let across = with_axis(&params, |copy| copy.axis = 0);
                let down = with_axis(&params, |copy| copy.axis = 1);
                let horizontal = self.fx_run(Fx::Blur, &source, &source, &blank, &blank, &blur_words, &across)?;
                self.fx_run(Fx::Blur, &horizontal, &horizontal, &blank, &blank, &blur_words, &down)?
            } else {
                source
            };
            if matches!(kind, crate::filters::FilterKind::BloomGlow) {
                words[2] = ((settings.bloom_amount / 50.0) as f32).to_bits();
            } else {
                // The strength and the three weights, which the CPU folds into its delta.
                words[2] = ((settings.tonal_amount / 50.0) as f32).to_bits();
                words[3] = (settings.tonal_shadows as f32).to_bits();
                words[4] = (settings.tonal_midtones as f32).to_bits();
                words[5] = (settings.tonal_highlights as f32).to_bits();
            }
            let finished = self.fx_run(entry, &canvas, &blurred, &blank, &blank, &words, &params)?;
            let straight = self.fx_run(Fx::Straighten, &finished, &blank, &blank, &blank, &program(&[]), &params)?;
            return Bitmap8::from_raw(image.width(), image.height(), straight).ok();
        }
        let scalars: Vec<f32> = match entry {
            Fx::Lens => {
                // The CPU takes its strength as distortion / 100 * LENS_STRENGTH.
                vec![(settings.distortion / 100.0 * crate::filters::LENS_STRENGTH) as f32]
            }
            _ => vec![
                0.0,
                0.0,
                (settings.vignette_amount / 100.0).clamp(0.0, 1.0) as f32,
                settings.vignette_midpoint as f32,
                settings.vignette_roundness as f32,
                settings.vignette_feather as f32,
                settings.vignette_highlights as f32,
                0.0,
                0.0,
                0.0,
                image.width() as f32,
                image.height() as f32,
                settings.vignette_color.red.clamp(0.0, 1.0) as f32,
                settings.vignette_color.green.clamp(0.0, 1.0) as f32,
                settings.vignette_color.blue.clamp(0.0, 1.0) as f32,
            ],
        };
        for (index, value) in scalars.iter().enumerate() {
            words[2 + index] = value.to_bits();
        }
        // The vignette's mask is a scalar per pixel, built here in f64 and handed over as f32.
        let scratch: Vec<u8> = match entry {
            Fx::Vignette => {
                let frame = (0.0f64, 0.0f64, image.width() as f64, image.height() as f64);
                let mut values = Vec::with_capacity(count as usize * 4);
                for y in 0..image.height() {
                    for x in 0..image.width() {
                        let mask = crate::filters::vignette_mask_at(
                            x as f64 + 0.5 - frame.0,
                            y as f64 + 0.5 - frame.1,
                            frame.2,
                            frame.3,
                            settings.vignette_midpoint,
                            settings.vignette_roundness,
                            settings.vignette_feather,
                        );
                        values.extend_from_slice(&(mask as f32).to_le_bytes());
                    }
                }
                values
            }
            _ => blank.clone(),
        };
        let filtered = self.fx_run(entry, &canvas, &blank, &blank, &scratch, &words, &params)?;
        let straight = self.fx_run(Fx::Straighten, &filtered, &blank, &blank, &blank, &program(&[]), &params)?;
        Bitmap8::from_raw(image.width(), image.height(), straight).ok()
    }

    /// Which dither styles the GPU can run, and why the rest cannot. The ordered screens are a threshold
    /// matrix and a quantization, pixel by pixel; the halftone marks, the glyphs and the error diffusion are
    /// not, and each says so on its own.
    pub fn dither_accepts(settings: &crate::filters::DitherSettings) -> Result<(), String> {
        use crate::filters::{DitherPixelShape, DitherStyle};
        let normalized = settings.normalized();
        let style = normalized.style;
        match style {
            DitherStyle::Bayer2 | DitherStyle::Bayer4 | DitherStyle::Bayer8 => {}
            DitherStyle::Atkinson | DitherStyle::FloydSteinberg => {
                return Err(format!(
                    "dither/{style:?}: error diffusion is a serial raster scan, one pixel depending on the last"
                ))
            }
            DitherStyle::Ascii => return Err("dither/Ascii: needs a glyph atlas built from a font".into()),
            DitherStyle::Scanlines => {
                // The pass is built and runs; it is one pixel away from the CPU at the simplest setting, so
                // it stays refused until that is settled. A glow is a second reason.
                if normalized.glow > 0.0 {
                    return Err(format!(
                        "dither/Scanlines: a glow of {} blurs the result after the lines are drawn",
                        normalized.glow
                    ));
                }
                // The beam pass is built and measured; a glow is the only thing left it cannot do.
            }
            DitherStyle::Dots | DitherStyle::Lines | DitherStyle::Diamonds | DitherStyle::Patterns => {}
        }
        if normalized.pixel_size as usize > 1 {
            return Err(format!(
                "dither/{style:?} at pixel size {}: the block average is a pass of its own",
                normalized.pixel_size
            ));
        }
        // The dot shape only matters where the chunky pixel path runs, which ASCII and Scanlines skip.
        if normalized.pixel_shape == DitherPixelShape::Dot
            && !matches!(normalized.style, DitherStyle::Ascii | DitherStyle::Scanlines)
        {
            return Err(format!(
                "dither/{style:?} with the dot shape: rounding whole cells into dots is a pass of its own"
            ));
        }
        Ok(())
    }

    /// dither_apply for the ordered screens: premultiplied bytes in, the threshold matrix and the
    /// quantization over them, premultiplied bytes out.
    fn dither_ordered(&self, image: &Bitmap8, settings: &crate::filters::DitherSettings) -> Option<Bitmap8> {
        use crate::filters::DitherStyle;
        let settings = settings.normalized();
        let count = image.pixel_count() as u32;
        if count == 0 {
            return Some(image.clone());
        }
        let bytes = (count * 4) as u64;
        let params = FxParams {
            count,
            width: image.width(),
            height: image.height(),
            layer_width: image.width(),
            layer_height: image.height(),
            inset: 0,
            // Which screen this is. The threshold screens read it as their matrix size and the marks pass
            // as its style, and each pass only ever sees its own four.
            mode: match settings.style {
                DitherStyle::Bayer2 | DitherStyle::Patterns => 0,
                DitherStyle::Bayer4 | DitherStyle::Dots => 1,
                DitherStyle::Bayer8 | DitherStyle::Lines => 2,
                _ => 3,
            },
            axis: u32::from(settings.colors == crate::filters::DitherColors::Original),
            coverage_planes: 0,
            plane_words: 1,
        };
        let blank = vec![0u8; bytes as usize];
        let canvas = self.fx_run(Fx::Prepare, image.pixels(), &blank, &blank, &blank, &program(&[]), &params)?;
        // The tone curve the CPU builds from the density and the contrast, and the ramp it paints.
        let gamma = 2f32.powf((settings.density / 100.0) as f32 * 1.5);
        let contrast_setting = (settings.contrast / 100.0) as f32;
        let contrast = if contrast_setting >= 0.0 {
            1.0 / (1.0 - 0.95 * contrast_setting)
        } else {
            1.0 + contrast_setting
        };
        let dark = crate::filters::byte_color_for_gpu(settings.dark);
        let light = crate::filters::byte_color_for_gpu(settings.light);
        let levels = (settings.levels as i32).clamp(2, 16) as f32;
        let mut words = vec![0u32; 32 + 1200];
        // The tone curve, then the marks' own settings: the dot, line and diamond screens are the ramp's
        // ink and paper painted through a cell of this size and angle.
        for (index, value) in [
            gamma,
            contrast,
            levels,
            dark[0],
            dark[1],
            dark[2],
            light[0],
            light[1],
            light[2],
            // The program's scalar slots, so a third pass never collides with the first two:
            //   0 gamma, 1 contrast, 2 levels        read by the threshold screens, the marks and the lines
            //   3..5 dark, 6..8 light                read by the threshold screens, the marks and the lines
            //   9, 10, 11                            marks: light_on_dark, cell size, angle (radians)
            //                                        scanlines: line spacing, bead strength, wobble
            //   12                                   the probe flag, 0 in every shipped build
            // Slots 9 through 11 are the ones two styles share, and they are written by the branch below.
            if settings.style == DitherStyle::Scanlines {
                (settings.line_spacing as f32).max(2.0)
            } else if settings.light_on_dark {
                1.0
            } else {
                0.0
            },
            if settings.style == DitherStyle::Scanlines {
                (settings.dots / 100.0) as f32
            } else {
                (settings.cell_size as f32).max(2.0)
            },
            if settings.style == DitherStyle::Scanlines {
                settings.wobble as f32
            } else {
                (settings.angle as f32).to_radians()
            },
            // A probe build sets this to have the pass report what it worked out rather than the pixel (see
            // the ignored probe tests).
            0.0,
        ]
        .iter()
        .enumerate()
        {
            words[2 + index] = value.to_bits();
        }
        // The threshold screens quantize; the patterns and the halftone shapes draw marks.
        let marks = matches!(
            settings.style,
            DitherStyle::Patterns | DitherStyle::Dots | DitherStyle::Lines | DitherStyle::Diamonds
        );
        let entry = if settings.style == DitherStyle::Scanlines {
            Fx::Scanlines
        } else if marks {
            Fx::DitherMarks
        } else {
            Fx::DitherOrdered
        };
        let dithered = self.fx_run(entry, &canvas, &blank, &blank, &blank, &words, &params)?;
        let straight = self.fx_run(Fx::Straighten, &dithered, &blank, &blank, &blank, &program(&[]), &params)?;
        Bitmap8::from_raw(image.width(), image.height(), straight).ok()
    }

    fn upload(&self, label: &str, bytes: &[u8], size: u64, usage: wgpu::BufferUsages) -> wgpu::Buffer {
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some(label),
            size,
            usage,
            mapped_at_creation: false,
        });
        self.queue.write_buffer(&buffer, 0, bytes);
        buffer
    }
}

impl std::fmt::Debug for GpuBackend {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("GpuBackend").field("adapter", &self.adapter_name).field("backend", &self.backend_name).finish()
    }
}

/// Which of the layer effect passes a dispatch runs.
#[derive(Clone, Copy)]
enum Fx {
    Prepare,
    Shape,
    Shift,
    BlurH,
    BlurV,
    Extreme,
    Combine,
    Fill,
    Over,
    Straighten,
    /// Built and measured, but the vignette's colour write lands on a rounding knife edge (see
    /// filter_accepts), so nothing selects it yet.
    #[allow(dead_code)]
    Vignette,
    Lens,
    /// The filters' blur: the adjustment blur's own entry point, reached through the effects layout.
    Blur,
    BloomHighlights,
    BloomAdd,
    Tonal,
    DitherOrdered,
    DitherMarks,
    Scanlines,
}

/// The shape of one effects pass: the grown canvas, the layer's own grid inside it, and the few knobs the
/// pass reads.
struct FxParams {
    count: u32,
    width: u32,
    height: u32,
    layer_width: u32,
    layer_height: u32,
    inset: u32,
    mode: u32,
    axis: u32,
    coverage_planes: u32,
    plane_words: u32,
}

/// A pass program: sixteen scalars, eight integers, then the table.
fn program(scalars: &[f32]) -> Vec<u32> {
    let mut words = vec![0u32; 32 + 1200];
    for (index, value) in scalars.iter().enumerate().take(16) {
        words[2 + index] = value.to_bits();
    }
    words
}

/// The same parameters with the plane algebra's mode set, which fx_combine reads.
fn with_mode(params: &FxParams, mode: u32) -> FxParams {
    with_axis(params, |copy| copy.mode = mode)
}

/// The same parameters with one field changed, for a pass that differs only in its axis.
fn with_axis(params: &FxParams, change: impl FnOnce(&mut FxParams)) -> FxParams {
    let mut copy = FxParams {
        count: params.count,
        width: params.width,
        height: params.height,
        layer_width: params.layer_width,
        layer_height: params.layer_height,
        inset: params.inset,
        mode: params.mode,
        axis: params.axis,
        coverage_planes: params.coverage_planes,
        plane_words: params.plane_words,
    };
    change(&mut copy);
    copy
}

/// Which of the blur family's passes a dispatch runs.
#[derive(Clone, Copy)]
enum Pass {
    Prepare,
    Blur,
    Motion,
    Finish,
}

/// The uniform block the shader reads: count, mode, opacity, the dispatch width, how the coverage planes
/// are laid out, and the placement of the layer's own image.
const PARAMS_BYTES: u64 = 128;

/// The most layers the clipping walk follows before giving up on a cycle.
const MAX_CLIP_DEPTH: usize = 256;

/// The most coverage planes one layer may carry: its own mask, its clipping coverage, and its folders'
/// masks. The shader folds them one at a time, in the same order and with the same rounding at each step
/// the CPU uses, so this is a bound on what one dispatch reads rather than a correctness limit; past it a
/// document takes the CPU path instead.
const MAX_COVERAGE_PLANES: usize = 64;

fn storage_entry(binding: u32, read_only: bool) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

/// The process's backend, opened on first use. A machine without one keeps reporting `None`.
///
/// One device per process, shared by every call: opening a device per composite would cost more than the
/// composite does, and a program with several threads would run out of devices.
static BACKEND: OnceLock<Result<GpuBackend, String>> = OnceLock::new();

fn opened() -> &'static Result<GpuBackend, String> {
    BACKEND.get_or_init(GpuBackend::open)
}

/// The shared backend, if this machine has one.
pub fn backend() -> Option<&'static GpuBackend> {
    opened().as_ref().ok()
}

/// Packs coverage planes four bytes to a word, one plane after another, as the shader reads them.
fn pack_planes(planes: &[Vec<u8>], plane_words: u32) -> Vec<u8> {
    let mut packed = vec![0u8; planes.len().max(1) * plane_words as usize * 4];
    for (index, plane) in planes.iter().enumerate() {
        let start = index * plane_words as usize * 4;
        for (word, chunk) in plane.chunks(4).enumerate() {
            let mut value = 0u32;
            for (byte, sample) in chunk.iter().enumerate() {
                value |= (*sample as u32) << (byte * 8);
            }
            let at = start + word * 4;
            packed[at..at + 4].copy_from_slice(&value.to_le_bytes());
        }
    }
    packed
}

/// True when a layer's pixels land on the canvas one to one: full size, unrotated, unflipped and at the
/// origin. That is the placement the shader takes without sampling anything.
fn fills_canvas_one_to_one(layer: &Layer, image: &Bitmap8, document: &Document) -> bool {
    let transform = layer.transform;
    transform.origin.x == 0.0
        && transform.origin.y == 0.0
        && transform.size.width == document.width as f64
        && transform.size.height == document.height as f64
        && transform.rotation == 0.0
        && !transform.flip_x
        && !transform.flip_y
        && image.width() == document.width
        && image.height() == document.height
}

/// What the shader needs to place a layer's own image on the canvas, or nothing when the transform does
/// not land on it at all.
fn cursor_placement(layer: &Layer, image: &Bitmap8, document: &Document) -> Option<crate::place::Placement> {
    crate::place::placement_for(&layer.transform, image.width(), image.height(), document.width, document.height)
}

/// A layer's pixels' alpha across the canvas, through its placement: the coverage a clipping base
/// contributes. The placement is the CPU's own, so a base that is scaled or turned clips exactly as it
/// does on the CPU.
fn placement_alpha(document: &Document, layer: &Layer, image: &Bitmap8) -> Result<Vec<u8>, String> {
    if fills_canvas_one_to_one(layer, image, document) {
        return Ok(image.pixels().chunks_exact(4).map(|texel| texel[3]).collect());
    }
    let Some(placement) = cursor_placement(layer, image, document) else {
        return Err(format!("{}: its transform does not land on the canvas", layer.name));
    };
    if placement.level > 0 {
        return Err(format!("{}: reduced below half, which needs the CPU's halving pyramid", layer.name));
    }
    let source = crate::pixel::Surface::from_bitmap(image);
    let frame = (0, 0, document.width, document.height);
    let (placed, _) = crate::place::place_surface_box(&source, &layer.transform, frame)
        .ok_or_else(|| format!("{}: its pixels do not land on the canvas", layer.name))?;
    Ok(placed.alpha_plane().values().to_vec())
}

/// The name of an adjustment kind, for a refusal that says what it cannot run.
fn kind_name(kind: &comp_core::adjustment::AdjustmentKind) -> &'static str {
    use comp_core::adjustment::AdjustmentKind as K;
    match kind {
        K::HueSaturation => "hue/saturation",
        K::Levels => "levels",
        K::Curves => "curves",
        K::Exposure => "exposure",
        K::GradientMap => "gradient map",
        K::Grain => "grain",
        K::Invert => "invert",
        K::BlackWhite => "black & white",
        K::ColorBalance => "color balance",
        K::GaussianBlur => "gaussian blur",
        K::MotionBlur => "motion blur",
        K::AddNoise => "add noise",
    }
}

/// An adjustment layer's coverage as one plane, the way adjust_into builds it: the layer's own mask, then
/// each folder's mask multiplied in, then the effective opacity scaled in - with the CPU's own rounding at
/// every step. Nothing means the adjustment applies to the whole canvas.
fn adjustment_coverage(document: &Document, layer: &Layer) -> Option<Vec<u8>> {
    let mut coverage: Option<Vec<u8>> = None;
    if let Some(mask) = enabled_mask(layer) {
        let transform = layer.effective_mask_transform().unwrap_or(layer.transform);
        coverage = place_mask(document, mask, transform);
    }
    let mut folder = layer.parent;
    let mut depth = 0;
    while let Some(id) = folder {
        if depth >= 64 {
            break;
        }
        let Some(group) = document.layer(id) else { break };
        if let Some(mask) = enabled_mask(group) {
            let transform = group.effective_mask_transform().unwrap_or(group.transform);
            let plane = match place_mask(document, mask, transform) {
                Some(plane) => plane,
                None => break,
            };
            match &mut coverage {
                Some(existing) => {
                    for (value, factor) in existing.iter_mut().zip(plane.iter()) {
                        *value = ((*value as u32 * *factor as u32 + 127) / 255) as u8;
                    }
                }
                None => coverage = Some(plane),
            }
        }
        folder = group.parent;
        depth += 1;
    }
    let opacity = document.effective_opacity(layer.id);
    if opacity < 1.0 {
        let value = (opacity * 255.0).round().clamp(0.0, 255.0) as u8;
        match &mut coverage {
            Some(existing) => {
                for entry in existing.iter_mut() {
                    *entry = ((*entry as u32 * value as u32 + 127) / 255) as u8;
                }
            }
            None => coverage = Some(vec![value; (document.width * document.height) as usize]),
        }
    }
    coverage
}

/// Whether every layer of a document maps onto what the shader does, and a sentence naming the first layer
/// that does not when one does not.
///
/// The shader composites whole canvases: each layer's pixels are its own, unrotated, unscaled and exactly
/// canvas-sized, blended in its mode at its opacity, with its mask, its clipping coverage and its folders'
/// masks multiplied into its alpha. Everything that needs a neighbourhood or a resample - a transform, an
/// effect, an adjustment layer - is refused, and a refusal sends the whole document to the CPU rather than
/// mixing two compositors in one picture.
pub fn gpu_accepts(document: &Document) -> Result<(), String> {
    if document.width == 0 || document.height == 0 {
        return Err("the canvas has no pixels".to_string());
    }
    if backend().is_none() {
        return Err(format!("no GPU backend ({})", unavailability().unwrap_or("unknown reason")));
    }
    for id in document.renderable_ids() {
        let Some(layer) = document.layer(id) else {
            return Err("a renderable layer is missing from the document".to_string());
        };
        let name = || layer.name.clone();
        // An adjustment layer has no pixels of its own, so it is asked about first: that is what it is,
        // not what it is missing.
        if let Some(adjustment) = layer.adjustment.as_ref() {
            // An adjustment that names a clipping base is skipped by both compositors, so there is nothing
            // to check.
            if layer.mask_source.is_some() {
                continue;
            }
            if crate::adjustment::gpu_adjustment(adjustment).is_none() {
                return Err(format!(
                    "{}: a {} reads its neighbours, which is not on the GPU yet",
                    name(),
                    kind_name(&adjustment.kind)
                ));
            }
            let planes = adjustment_coverage(document, layer);
            if planes.map(|plane| plane.is_empty()).unwrap_or(false) {
                return Err(format!("{}: its mask does not land on the canvas", name()));
            }
            continue;
        }
        let Some(image) = layer.image.as_ref() else {
            return Err(format!("{}: no pixels to place", name()));
        };
        // Layer effects are rendered in the layer's own grid on the GPU and land through a grown transform,
        // so they are no reason to refuse.
        // A layer either fills the canvas one to one, which is a straight copy, or it is placed by its
        // transform: the shader samples it with the CPU's own mapping, filter and coverage.
        if !fills_canvas_one_to_one(layer, image, document) {
            // A layer placed entirely off the canvas is not a reason to refuse anything: it draws nothing,
            // and the CPU draws nothing for it either.
            // A reduced layer is fine: the halving chain is built here with the CPU's own reduction.
            let _ = cursor_placement(layer, image, document);
        }
        let planes = coverage_planes(document, layer, true)?;
        if planes.len() > MAX_COVERAGE_PLANES {
            return Err(format!(
                "{}: more than {MAX_COVERAGE_PLANES} masks and clipping links above it",
                name()
            ));
        }
    }
    Ok(())
}

/// The coverage planes a layer's alpha passes through, in the order the CPU multiplies them: its own
/// raster mask, its clipping coverage (the base's pixels through the base's mask and opacity, and whatever
/// clips the base in turn), and then its folders' masks.
///
/// This is the CPU's own coverage arithmetic on the alpha channel alone, which is all a coverage plane is:
/// the base's color never contributes. A cycle in the clipping chain stops where the CPU's walk stops.
fn coverage_planes(document: &Document, layer: &Layer, own_mask: bool) -> Result<Vec<Vec<u8>>, String> {
    let mut planes = Vec::new();
    if let Some(mask) = enabled_mask(layer).filter(|_| own_mask) {
        let transform = layer.effective_mask_transform().unwrap_or(layer.transform);
        let plane = place_mask(document, mask, transform)
            .ok_or_else(|| format!("{}: its mask does not land on the canvas", layer.name))?;
        planes.push(plane);
    }
    if let Some(base_id) = layer.mask_source {
        let mut visiting = std::collections::HashSet::new();
        visiting.insert(layer.id);
        let coverage = clip_coverage(document, base_id, &mut visiting, 0)?
            .ok_or_else(|| format!("{}: its clipping base has no pixels", layer.name))?;
        planes.push(coverage);
    }
    let mut folder = layer.parent;
    let mut depth = 0;
    while let Some(id) = folder {
        if depth >= 64 {
            break;
        }
        let Some(group) = document.layer(id) else { break };
        if let Some(mask) = enabled_mask(group) {
            let transform = group.effective_mask_transform().unwrap_or(group.transform);
            let plane = place_mask(document, mask, transform)
                .ok_or_else(|| format!("{}: the mask of the folder {} does not land on the canvas", layer.name, group.name))?;
            planes.push(plane);
        }
        folder = group.parent;
        depth += 1;
    }
    planes.truncate(MAX_COVERAGE_PLANES + 1);
    Ok(planes)
}

fn enabled_mask(layer: &Layer) -> Option<&comp_core::Gray8> {
    if !layer.mask_enabled {
        return None;
    }
    layer.mask.as_deref()
}

/// A layer's raster mask as a canvas-sized coverage plane, through any placement it carries.
fn place_mask(document: &Document, mask: &comp_core::Gray8, transform: comp_core::geom::Transform) -> Option<Vec<u8>> {
    let mut plane = crate::pixel::Plane::new(document.width, document.height);
    crate::place::place_coverage(&mut plane, mask, &transform)?;
    Some(plane.values().to_vec())
}

/// A clipping base's coverage: its pixels' alpha through its own mask and its effective opacity, and then
/// whatever clips it in turn - the CPU's clip_coverage on the alpha channel alone.
fn clip_coverage(
    document: &Document,
    base_id: uuid::Uuid,
    visiting: &mut std::collections::HashSet<uuid::Uuid>,
    depth: usize,
) -> Result<Option<Vec<u8>>, String> {
    if visiting.contains(&base_id) {
        return Err("a clipping chain loops back on itself".to_string());
    }
    if depth >= MAX_CLIP_DEPTH {
        return Err(format!("a clipping chain is deeper than {MAX_CLIP_DEPTH} layers"));
    }
    let Some(base) = document.layer(base_id) else {
        return Ok(None);
    };
    let Some(image) = base.image.as_ref() else {
        return Ok(None);
    };
    // The base's alpha - placed through its own transform - then its mask, then its effective opacity, the
    // order own_into uses.
    let mut coverage: Vec<u8> = placement_alpha(document, base, image)?;
    if let Some(mask) = enabled_mask(base) {
        let transform = base.effective_mask_transform().unwrap_or(base.transform);
        let plane = place_mask(document, mask, transform)
            .ok_or_else(|| format!("{}: its mask does not land on the canvas", base.name))?;
        for (value, mask_value) in coverage.iter_mut().zip(plane.iter()) {
            *value = scale_alpha_byte(*value, *mask_value);
        }
    }
    let opacity = document.effective_opacity(base.id);
    if opacity < 1.0 {
        let scaled = (opacity * 255.0).round().clamp(0.0, 255.0) as u8;
        for value in coverage.iter_mut() {
            *value = round_byte(*value as f32 * (scaled as f32 / 255.0));
        }
    }
    if let Some(upstream_id) = base.mask_source {
        visiting.insert(base_id);
        let upstream = clip_coverage(document, upstream_id, visiting, depth + 1)?;
        visiting.remove(&base_id);
        if let Some(upstream) = upstream {
            for (value, above) in coverage.iter_mut().zip(upstream.iter()) {
                *value = scale_alpha_byte(*value, *above);
            }
        }
    }
    Ok(Some(coverage))
}

/// The alpha step of Surface::mask_by_plane: (a * m + 127) / 255.
fn scale_alpha_byte(alpha: u8, mask: u8) -> u8 {
    if mask == 255 {
        return alpha;
    }
    if mask == 0 || alpha == 0 {
        return 0;
    }
    ((alpha as u32 * mask as u32 + 127) / 255) as u8
}

fn round_byte(value: f32) -> u8 {
    value.round().clamp(0.0, 255.0) as u8
}

/// Why there is no backend, when there is not one: `no adapter`, `no device`, or the blend shader
/// being rejected. `None` once a backend exists.
pub fn unavailability() -> Option<&'static str> {
    opened().as_ref().err().map(String::as_str)
}

/// True when a GPU backend is usable here.
pub fn available() -> bool {
    backend().is_some()
}

/// The adapter and backend in use, or `None` when there is no GPU.
pub fn describe() -> Option<String> {
    backend().map(GpuBackend::describe)
}

/// Composites two straight-alpha images in a blend mode on the GPU, or `None` when there is no GPU, the
/// sizes differ, or the device refused the work.
pub fn composite_gpu(backdrop: &Bitmap8, source: &Bitmap8, mode: BlendMode, opacity: f64) -> Option<Bitmap8> {
    backend()?.composite(backdrop, source, mode, opacity)
}

/// Composites a document on the GPU when the whole of it maps onto what the shader does, and reports
/// `None` otherwise - so the caller falls back to the CPU for the whole image rather than mixing two
/// compositors in one picture.
///
/// The documents this takes are the plain stacks: visible raster layers that fill the canvas exactly (no
/// rotation, no flips, no scaling), blended in their own modes and opacities. A layer's own mask, its
/// folders' masks and its clipping coverage all ride along as coverage planes the shader multiplies into
/// its alpha, so a masked or clipped document composites here too. What is still refused - a transform, an
/// effect, an adjustment layer - is refused for the whole document, never for one layer of it; gpu_accepts
/// says which layer and why.
pub fn flatten_document_gpu(document: &Document) -> Option<Bitmap8> {
    let backend = backend()?;
    gpu_accepts(document).ok()?;
    let mut canvas = Bitmap8::new(document.width, document.height);
    for id in document.renderable_ids() {
        let layer = document.layer(id)?;
        if let Some(adjustment) = layer.adjustment.clone() {
            // An adjustment that names a clipping base is skipped, as the CPU's renderer skips it.
            if layer.mask_source.is_some() {
                continue;
            }
            let program = crate::adjustment::gpu_adjustment(&adjustment)?;
            let planes: Vec<Vec<u8>> = adjustment_coverage(document, layer).into_iter().collect();
            let blend = if layer.blend == BlendMode::Normal { None } else { Some(layer.blend) };
            // A blur runs its own passes; every other kind is one per-pixel kernel. Either way the coverage
            // plane already carries the layer's opacity, exactly as adjust_into folds it in.
            canvas = if program.kind >= 8 {
                backend.blur_adjustment(&canvas, &program, &planes, blend, program.kind == 8)?
            } else {
                backend.adjust(&canvas, &program, &planes, blend, 1.0)?
            };
            continue;
        }
        let image = layer.image.as_ref()?;
        let opacity = document.effective_opacity(id);
        // A layer with effects is drawn from the effects image, which is bigger than the layer and lands
        // through a grown transform; its own raster mask went into that image's shape, so it is not one of
        // the coverage planes here.
        let visible_effects = layer.effects.map(|effects| crate::effects::visible(&effects)).unwrap_or_default();
        let grown_source;
        let (source, placement, own_mask) = if visible_effects.is_empty() {
            let placement = if fills_canvas_one_to_one(layer, image, document) {
                None
            } else {
                match cursor_placement(layer, image, document) {
                    Some(placement) => Some(placement),
                    // Nowhere on the canvas: nothing to draw for this layer.
                    None => continue,
                }
            };
            (image.as_ref(), placement, true)
        } else {
            let grid = layer
                .mask
                .as_deref()
                .filter(|_| layer.mask_enabled)
                .map(|mask| {
                    crate::place::mask_into_grid(
                        mask,
                        &layer.effective_mask_transform().unwrap_or(layer.transform),
                        &layer.transform,
                        image.width(),
                        image.height(),
                    )
                });
            grown_source = backend.effects_image(image, grid.as_ref(), &visible_effects)?;
            let transform = crate::composite::grown_transform(
                &layer.transform,
                grown_source.0.width(),
                grown_source.0.height(),
                grown_source.1,
            );
            let Some(placement) = crate::place::placement_for(
                &transform,
                grown_source.0.width(),
                grown_source.0.height(),
                document.width,
                document.height,
            ) else {
                continue;
            };
            (&grown_source.0, Some(placement), false)
        };
        let planes = coverage_planes(document, layer, own_mask).ok()?;
        canvas = backend.composite_placed(&canvas, source, placement.as_ref(), &planes, layer.blend, opacity)?;
    }
    Some(canvas)
}

/// The document composited on the GPU when it can be, and on the CPU when it cannot.
pub fn flatten_document_preferring_gpu(document: &Document) -> Bitmap8 {
    flatten_document_gpu(document).unwrap_or_else(|| crate::flatten_document(document))
}

/// A premultiplied surface composited on the GPU, for callers already working in surfaces.
pub fn composite_surface_gpu(backdrop: &Surface, source: &Surface, mode: BlendMode, opacity: f64) -> Option<Surface> {
    let result = composite_gpu(&backdrop.to_bitmap(), &source.to_bitmap(), mode, opacity)?;
    Some(Surface::from_bitmap(&result))
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::blend::composite_surface;
    use crate::pixel::Surface;
    use comp_core::geom::{PointF, Sampling, SizeF, Transform};
    use comp_core::{Gray8, Layer};

    /// The backend, or a printed skip when this machine has no usable adapter. A test that skips says so
    /// rather than passing quietly, so a run on a GPU-less machine cannot look like a verified one.
    fn gpu_or_skip(test: &str) -> Option<&'static GpuBackend> {
        match backend() {
            Some(backend) => Some(backend),
            None => {
                let reason = unavailability().unwrap_or("unknown reason");
                // A machine without a GPU is a skip. A shader this build cannot hand to a driver is a bug,
                // and a bug must not disappear into a skip: that is exactly how a broken shader once made
                // every GPU test "pass".
                assert!(
                    !reason.contains("rejected"),
                    "{test}: this machine has an adapter but the blend shader was rejected: {reason}"
                );
                println!("{test}: skipped, no GPU backend ({reason})");
                None
            }
        }
    }

    /// The CPU pipeline's own answer: premultiply both, fold the opacity into the source's alpha, composite,
    /// unpremultiply. This is what `composite_gpu` has to agree with.
    fn cpu_composite(backdrop: &Bitmap8, source: &Bitmap8, mode: BlendMode, opacity: f64) -> Bitmap8 {
        let mut under = Surface::from_bitmap(backdrop);
        let mut over = Surface::from_bitmap(source);
        over.scale_alpha(opacity as f32);
        composite_surface(&mut under, &over, mode);
        under.to_bitmap()
    }

    /// The worst channel difference between two images of the same size.
    fn worst_difference(left: &Bitmap8, right: &Bitmap8) -> i32 {
        assert_eq!((left.width(), left.height()), (right.width(), right.height()));
        left.pixels()
            .iter()
            .zip(right.pixels().iter())
            .map(|(a, b)| (*a as i32 - *b as i32).abs())
            .max()
            .unwrap_or(0)
    }

    /// A deterministic, varied image: ramps in every channel, a couple of saturated blocks and a
    /// transparent corner.
    fn pattern(width: u32, height: u32, seed: u32) -> Bitmap8 {
        let mut bitmap = Bitmap8::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let red = ((x * 37 + seed * 11) % 256) as u8;
                let green = ((y * 53 + seed * 7) % 256) as u8;
                let blue = (((x ^ y) * 29 + seed * 3) % 256) as u8;
                let alpha = (((x + y + seed) % 4) * 85) as u8;
                bitmap.set(x, y, [red, green, blue, alpha]);
            }
        }
        bitmap
    }

    /// The same, fully opaque: the blend function itself, with no alpha algebra in the way.
    fn opaque_pattern(width: u32, height: u32, seed: u32) -> Bitmap8 {
        let mut bitmap = pattern(width, height, seed);
        for texel in bitmap.pixels_mut().chunks_exact_mut(4) {
            texel[3] = 255;
        }
        bitmap
    }

    fn layer_with(name: &str, bitmap: Bitmap8) -> Layer {
        let mut layer = Layer::with_image(name, bitmap);
        layer.image_file = None;
        layer
    }

    fn document(width: u32, height: u32) -> Document {
        Document::new(width, height)
    }

    /// How far the composite's premultiplied value sits from a half byte, in f64, for the channels of one
    /// pixel.
    ///
    /// A value exactly half way between two bytes is a tie, and the CPU and the GPU each round it the way
    /// their own float expression came out - a difference that no amount of care in the shader removes,
    /// because the two are different instruction sets. This measures the distance from that tie so a test
    /// can allow it there and nowhere else.
    fn distance_from_a_half_byte(under: [u8; 4], over: [u8; 4], opacity: f64, mode: BlendMode) -> f64 {
        let backdrop_alpha_byte = under[3] as f64;
        let source_alpha_byte = over[3] as f64;
        let alpha_byte = (source_alpha_byte * opacity).round();
        if alpha_byte == 0.0 {
            return f64::INFINITY;
        }
        let alpha_s = alpha_byte / 255.0;
        let alpha_b = backdrop_alpha_byte / 255.0;
        let inv_s = 1.0 - alpha_s;
        let inv_b = 1.0 - alpha_b;
        let ratio = alpha_byte / source_alpha_byte.max(1.0);
        // The colors both implementations read, from the same quantized bytes.
        let mut cs = [0.0f32; 3];
        let mut cb = [0.0f32; 3];
        for channel in 0..3 {
            let stored = ((over[channel] as f64 * source_alpha_byte + 127.0) / 255.0).floor();
            let scaled = (stored * ratio + 0.5).floor();
            cs[channel] = (scaled / 255.0) as f32 / (alpha_byte / 255.0) as f32;
            let stored_under = ((under[channel] as f64 * backdrop_alpha_byte + 127.0) / 255.0).floor();
            cb[channel] = (stored_under / 255.0) as f32 / (backdrop_alpha_byte / 255.0) as f32;
        }
        let blended = crate::blend::blend_colors(mode, cb, cs);
        let mut closest = f64::INFINITY;
        for channel in 0..3 {
            let premultiplied = alpha_s * inv_b * cs[channel] as f64
                + alpha_s * alpha_b * blended[channel] as f64
                + inv_s * alpha_b * cb[channel] as f64;
            let scaled = premultiplied * 255.0;
            let distance = (scaled - scaled.floor() - 0.5).abs();
            closest = closest.min(distance);
        }
        closest
    }

    /// Asserts the GPU agrees with the CPU, allowing the extra level only where the composite's own value
    /// is a half byte: a tie the two float pipelines may break in opposite directions. A difference
    /// anywhere else, or beyond that one byte, is a failure.
    fn assert_matches_cpu(label: &str, backdrop: &Bitmap8, source: &Bitmap8, mode: BlendMode, opacity: f64, gpu: &Bitmap8) {
        let cpu = cpu_composite(backdrop, source, mode, opacity);
        assert_eq!((gpu.width(), gpu.height()), (cpu.width(), cpu.height()));
        let mut worst = 0i32;
        for y in 0..cpu.height() {
            for x in 0..cpu.width() {
                let before = cpu.get(x, y);
                let after = gpu.get(x, y);
                let difference = before.iter().zip(after.iter()).map(|(a, b)| (*a as i32 - *b as i32).abs()).max().unwrap();
                if difference > 1 {
                    // The threshold is loose on purpose: the reference here mixes the crate's f32 blend
                    // functions with f64 algebra, so it carries about that much noise of its own. It is
                    // still three orders of magnitude below a byte, so a real difference cannot hide in it.
                    let tie = distance_from_a_half_byte(backdrop.get(x, y), source.get(x, y), opacity, mode);
                    assert!(
                        tie < 1e-4,
                        "{label}: ({x},{y}) differs by {difference} ({before:?} against {after:?}) away from a half-byte tie ({tie})"
                    );
                }
                worst = worst.max(difference);
            }
        }
        assert!(worst <= 2, "{label}: worst channel differs by {worst}");
    }

    #[test]
    fn the_backend_reports_what_it_runs_on() {
        let Some(backend) = gpu_or_skip("the_backend_reports_what_it_runs_on") else { return };
        let description = backend.describe();
        assert!(!description.is_empty(), "a backend has a name");
        assert!(!backend.adapter_name().is_empty());
        assert!(!backend.backend_name().is_empty());
        // The shared backend is opened once and reports the same thing every time.
        assert_eq!(describe(), Some(description));
        assert!(available());
    }

    #[test]
    fn every_mode_matches_the_cpu_on_opaque_images() {
        let Some(backend) = gpu_or_skip("every_mode_matches_the_cpu_on_opaque_images") else { return };
        let backdrop = opaque_pattern(16, 12, 1);
        let source = opaque_pattern(16, 12, 5);
        for mode in BlendMode::ALL {
            let cpu = cpu_composite(&backdrop, &source, mode, 1.0);
            let gpu = backend.composite(&backdrop, &source, mode, 1.0).expect("the GPU composites");
            let worst = worst_difference(&cpu, &gpu);
            assert!(worst <= 1, "{mode:?}: worst channel differs by {worst}");
        }
    }

    #[test]
    fn every_mode_matches_the_cpu_through_alpha_and_opacity() {
        let Some(backend) = gpu_or_skip("every_mode_matches_the_cpu_through_alpha_and_opacity") else { return };
        let backdrop = pattern(16, 12, 2);
        let source = pattern(16, 12, 9);
        for mode in BlendMode::ALL {
            for opacity in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let gpu = backend.composite(&backdrop, &source, mode, opacity).expect("the GPU composites");
                assert_matches_cpu(&format!("{mode:?} at opacity {opacity}"), &backdrop, &source, mode, opacity, &gpu);
            }
        }
    }

    #[test]
    fn the_component_modes_match_the_cpu_on_saturated_colors() {
        let Some(backend) = gpu_or_skip("the_component_modes_match_the_cpu_on_saturated_colors") else { return };
        let mut backdrop = Bitmap8::new(4, 1);
        let mut source = Bitmap8::new(4, 1);
        for (index, (under, over)) in [
            ([255u8, 0, 0, 255], [0u8, 0, 255, 255]),
            ([10, 200, 30, 255], [200, 10, 90, 255]),
            ([0, 0, 0, 255], [255, 255, 255, 255]),
            ([128, 128, 128, 255], [255, 128, 0, 255]),
        ]
        .into_iter()
        .enumerate()
        {
            backdrop.set(index as u32, 0, under);
            source.set(index as u32, 0, over);
        }
        for mode in [BlendMode::Hue, BlendMode::Saturation, BlendMode::Color, BlendMode::Luminosity] {
            let cpu = cpu_composite(&backdrop, &source, mode, 1.0);
            let gpu = backend.composite(&backdrop, &source, mode, 1.0).expect("the GPU composites");
            let worst = worst_difference(&cpu, &gpu);
            assert!(worst <= 1, "{mode:?}: worst channel differs by {worst}");
        }
    }

    #[test]
    fn a_clear_source_leaves_the_backdrop_alone() {
        let Some(backend) = gpu_or_skip("a_clear_source_leaves_the_backdrop_alone") else { return };
        let backdrop = pattern(12, 8, 3);
        let source = pattern(12, 8, 4);
        let mut clear = source.clone();
        for texel in clear.pixels_mut().chunks_exact_mut(4) {
            texel[3] = 0;
        }
        for mode in BlendMode::ALL {
            let gpu = backend.composite(&backdrop, &clear, mode, 1.0).expect("the GPU composites");
            // The CPU's own answer, which is the backdrop after its round trip through a premultiplied
            // surface: a fully clear pixel carries no color there, so it comes back as nothing.
            let cpu = cpu_composite(&backdrop, &clear, mode, 1.0);
            assert!(worst_difference(&cpu, &gpu) <= 1, "{mode:?} with a fully transparent source");
        }
    }

    #[test]
    fn zero_opacity_leaves_the_backdrop_alone() {
        let Some(backend) = gpu_or_skip("zero_opacity_leaves_the_backdrop_alone") else { return };
        let backdrop = pattern(12, 8, 5);
        let source = pattern(12, 8, 6);
        for mode in BlendMode::ALL {
            let gpu = backend.composite(&backdrop, &source, mode, 0.0).expect("the GPU composites");
            let cpu = cpu_composite(&backdrop, &source, mode, 0.0);
            assert!(worst_difference(&cpu, &gpu) <= 1, "{mode:?} at zero opacity");
        }
    }

    #[test]
    fn the_boundary_channels_match_the_cpu() {
        let Some(backend) = gpu_or_skip("the_boundary_channels_match_the_cpu") else { return };
        // Black over white, white over black, and the half-covered quarter: every dodging mode's boundary.
        let mut backdrop = Bitmap8::new(4, 1);
        let mut source = Bitmap8::new(4, 1);
        let pairs = [
            ([0u8, 0, 0, 255], [255u8, 255, 255, 255]),
            ([255, 255, 255, 255], [0, 0, 0, 255]),
            ([0, 0, 0, 128], [255, 255, 255, 128]),
            ([255, 0, 128, 64], [0, 255, 64, 192]),
        ];
        for (index, (under, over)) in pairs.into_iter().enumerate() {
            backdrop.set(index as u32, 0, under);
            source.set(index as u32, 0, over);
        }
        for mode in BlendMode::ALL {
            let cpu = cpu_composite(&backdrop, &source, mode, 0.6);
            let gpu = backend.composite(&backdrop, &source, mode, 0.6).expect("the GPU composites");
            let worst = worst_difference(&cpu, &gpu);
            assert!(worst <= 1, "{mode:?}: worst channel differs by {worst}");
        }
    }

    #[test]
    fn an_opacity_above_one_is_clamped_like_the_cpu() {
        let Some(backend) = gpu_or_skip("an_opacity_above_one_is_clamped_like_the_cpu") else { return };
        let backdrop = pattern(8, 8, 7);
        let source = pattern(8, 8, 8);
        let cpu = cpu_composite(&backdrop, &source, BlendMode::Multiply, 1.0);
        let gpu = backend.composite(&backdrop, &source, BlendMode::Multiply, 5.0).expect("the GPU composites");
        assert!(worst_difference(&cpu, &gpu) <= 1);
    }

    #[test]
    fn mismatched_and_empty_images_report_none() {
        let Some(backend) = gpu_or_skip("mismatched_and_empty_images_report_none") else { return };
        let small = pattern(4, 4, 1);
        let large = pattern(8, 8, 1);
        assert!(backend.composite(&small, &large, BlendMode::Normal, 1.0).is_none());
        let empty = Bitmap8::new(0, 0);
        assert!(backend.composite(&empty, &empty, BlendMode::Normal, 1.0).is_none());
        // And the one-shot entry point reports the same, rather than panicking.
        assert!(composite_gpu(&small, &large, BlendMode::Normal, 1.0).is_none());
    }

    #[test]
    fn a_composite_keeps_the_size() {
        let Some(backend) = gpu_or_skip("a_composite_keeps_the_size") else { return };
        let backdrop = pattern(7, 3, 1);
        let source = pattern(7, 3, 2);
        let out = backend.composite(&backdrop, &source, BlendMode::Screen, 0.5).expect("the GPU composites");
        assert_eq!((out.width(), out.height()), (7, 3));
    }

    #[test]
    fn a_document_of_plain_canvas_layers_matches_the_cpu() {
        let Some(_backend) = gpu_or_skip("a_document_of_plain_canvas_layers_matches_the_cpu") else { return };
        let mut document = document(16, 12);
        document.add_layer(layer_with("Base", opaque_pattern(16, 12, 1)), None);
        let mut second = layer_with("Second", pattern(16, 12, 2));
        second.blend = BlendMode::Multiply;
        document.add_layer(second, None);
        let mut third = layer_with("Third", opaque_pattern(16, 12, 3));
        third.blend = BlendMode::SoftLight;
        third.opacity = 0.6;
        document.add_layer(third, None);
        let gpu = flatten_document_gpu(&document).expect("a plain stack runs on the GPU");
        let cpu = crate::flatten_document(&document);
        let worst = worst_difference(&cpu, &gpu);
        assert!(worst <= 1, "worst channel differs by {worst}");
    }

    #[test]
    fn a_folder_opacity_reaches_the_gpu_path() {
        let Some(_backend) = gpu_or_skip("a_folder_opacity_reaches_the_gpu_path") else { return };
        let mut document = document(8, 8);
        document.add_layer(layer_with("Base", opaque_pattern(8, 8, 1)), None);
        let mut folder = Layer::group("Folder", 8, 8);
        folder.opacity = 0.5;
        let folder_id = folder.id;
        document.add_layer(folder, None);
        let mut inner = layer_with("Inner", opaque_pattern(8, 8, 4));
        inner.blend = BlendMode::Screen;
        document.add_layer(inner, Some(folder_id));
        let gpu = flatten_document_gpu(&document).expect("folder opacity is a multiplier");
        let cpu = crate::flatten_document(&document);
        assert!(worst_difference(&cpu, &gpu) <= 1);
    }

    #[test]
    fn hidden_layers_are_skipped_like_the_cpu() {
        let Some(_backend) = gpu_or_skip("hidden_layers_are_skipped_like_the_cpu") else { return };
        let mut document = document(8, 8);
        document.add_layer(layer_with("Base", opaque_pattern(8, 8, 1)), None);
        let mut hidden = layer_with("Hidden", opaque_pattern(8, 8, 2));
        hidden.visible = false;
        hidden.blend = BlendMode::Difference;
        document.add_layer(hidden, None);
        let gpu = flatten_document_gpu(&document).expect("a hidden layer is skipped, not refused");
        assert_eq!(gpu, crate::flatten_document(&document));
    }

    /// The documents the GPU still cannot take: one carrying more masks than the shader's coverage planes.
    /// Effects, blur adjustments, masks, clipping links, transforms and the mip chain used to be here.

    #[test]
    fn five_masked_folders_match_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("five_masked_folders_match_on_the_gpu") else { return };
        // Six coverage planes: five folders' masks and the layer's own. This is the document that used to
        // be refused outright.
        let document = masked_folder_document(5);
        assert!(gpu_accepts(&document).is_ok(), "six planes are folded on the gpu now");
        let gpu = flatten_document_gpu(&document).expect("six planes composite on the gpu");
        assert_document_matches("five masked folders", &document, &gpu);
    }

    #[test]
    fn deeper_folder_stacks_match_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("deeper_folder_stacks_match_on_the_gpu") else { return };
        for depth in [8usize, 16, 32] {
            let document = masked_folder_document(depth);
            assert!(gpu_accepts(&document).is_ok(), "{depth} folders are accepted");
            let gpu = flatten_document_gpu(&document).expect("a deep stack composites on the gpu");
            assert_document_matches("a deep stack", &document, &gpu);
        }
    }

    #[test]
    fn exactly_the_cap_matches_and_one_more_is_refused() {
        let Some(_backend) = gpu_or_skip("exactly_the_cap_matches_and_one_more_is_refused") else { return };
        // The cap is a bound on one dispatch's planes, so the boundary is worth pinning down: the deepest
        // document that fits is composited on the gpu, and one plane more is not.
        let document = masked_folder_document(MAX_COVERAGE_PLANES - 1);
        assert!(gpu_accepts(&document).is_ok(), "{MAX_COVERAGE_PLANES} planes are accepted");
        let gpu = flatten_document_gpu(&document).expect("the deepest document fits");
        assert_document_matches("the plane cap", &document, &gpu);

        let past = masked_folder_document(MAX_COVERAGE_PLANES);
        let reason = gpu_accepts(&past).expect_err("one plane past the cap is refused");
        assert!(reason.contains("Crowded") && reason.contains("masks"), "{reason}");
        assert!(flatten_document_gpu(&past).is_none());
    }

    #[test]
    fn a_deeply_masked_document_matches_in_a_region() {
        let Some(_backend) = gpu_or_skip("a_deeply_masked_document_matches_in_a_region") else { return };
        // Every plane folded one at a time has to land the same way in a rectangle as it does whole.
        let document = masked_folder_document(8);
        let whole = crate::flatten_document(&document);
        for bounds in [(0i64, 0i64, 12u32, 12u32), (3, 4, 6, 5)] {
            let region = crate::flatten_region(&document, bounds);
            for row in 0..bounds.3 as i64 {
                for column in 0..bounds.2 as i64 {
                    assert_eq!(
                        region.get(column as u32, row as u32),
                        whole.get((bounds.0 + column) as u32, (bounds.1 + row) as u32),
                        "region {bounds:?} at ({column},{row})"
                    );
                }
            }
        }
    }

    #[test]
    fn two_masked_folders_and_a_clipping_chain_agree_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("two_masked_folders_and_a_clipping_chain_agree_on_the_gpu") else { return };
        // Planes of both kinds at once: two folder masks, a clipping base's coverage and the layer's own.
        let mut document = document(14, 12);
        let mut base = layer_with("Base", opaque_pattern(14, 12, 1));
        base.mask = Some(std::sync::Arc::new(gradient_mask(14, 12)));
        let base_id = base.id;
        document.add_layer(base, None);
        let mut parent = None;
        for depth in 0..2 {
            let mut folder = Layer::group(format!("Folder {depth}"), 14, 12);
            folder.mask = Some(std::sync::Arc::new(comp_core::Gray8::filled(14, 12, 180)));
            let id = folder.id;
            document.add_layer(folder, parent);
            parent = Some(id);
        }
        let mut clipped = layer_with("Clipped", pattern(14, 12, 4));
        clipped.mask_source = Some(base_id);
        clipped.mask = Some(std::sync::Arc::new(comp_core::Gray8::filled(14, 12, 220)));
        document.add_layer(clipped, parent);
        let gpu = flatten_document_gpu(&document).expect("mixed planes composite on the gpu");
        assert_document_matches("mixed planes", &document, &gpu);
    }

    #[test]
    fn documents_the_shader_cannot_take_report_none() {
        let Some(_backend) = gpu_or_skip("documents_the_shader_cannot_take_report_none") else { return };
        let crowded = masked_folder_document(MAX_COVERAGE_PLANES);
        assert!(flatten_document_gpu(&crowded).is_none(), "a document past the plane cap stays on the CPU");
        assert_eq!(
            flatten_document_preferring_gpu(&crowded),
            crate::flatten_document(&crowded),
            "and it is composited on the CPU whole"
        );
    }

    #[test]
    fn preferring_the_gpu_never_mixes_two_compositors() {
        let Some(_backend) = gpu_or_skip("preferring_the_gpu_never_mixes_two_compositors") else { return };
        let mut plain = document(8, 8);
        plain.add_layer(layer_with("Base", opaque_pattern(8, 8, 1)), None);
        assert_eq!(flatten_document_preferring_gpu(&plain), crate::flatten_document(&plain));

        let mut masked = document(8, 8);
        let mut layer = layer_with("Masked", opaque_pattern(8, 8, 2));
        layer.mask = Some(std::sync::Arc::new(comp_core::Gray8::filled(8, 8, 64)));
        masked.add_layer(layer, None);
        assert_eq!(flatten_document_preferring_gpu(&masked), crate::flatten_document(&masked));
    }

    #[test]
    fn an_empty_document_composites_to_nothing() {
        let Some(_backend) = gpu_or_skip("an_empty_document_composites_to_nothing") else { return };
        // No layers is nothing to upload, and the answer is the transparent canvas the CPU would give.
        let empty = flatten_document_gpu(&document(8, 8)).expect("an empty document composites");
        assert_eq!(empty, crate::flatten_document(&document(8, 8)));
        // A canvas with no pixels at all cannot be uploaded, so that one reports None.
        assert!(flatten_document_gpu(&document(0, 0)).is_none());
    }

    #[test]
    fn the_surface_helper_agrees_with_the_bitmap_helper() {
        let Some(backend) = gpu_or_skip("the_surface_helper_agrees_with_the_bitmap_helper") else { return };
        let backdrop = pattern(9, 5, 1);
        let source = pattern(9, 5, 2);
        let through_surface = composite_surface_gpu(
            &Surface::from_bitmap(&backdrop),
            &Surface::from_bitmap(&source),
            BlendMode::Overlay,
            0.8,
        )
        .expect("the GPU composites");
        let through_bitmap = backend.composite(&backdrop, &source, BlendMode::Overlay, 0.8).expect("the GPU composites");
        assert_eq!(through_surface, Surface::from_bitmap(&through_bitmap));
    }

    #[test]
    fn a_single_pixel_composite_works() {
        let Some(backend) = gpu_or_skip("a_single_pixel_composite_works") else { return };
        // One pixel is smaller than a workgroup, which is where an off-by-one in the dispatch shows up.
        let backdrop = Bitmap8::filled(1, 1, [200, 100, 50, 255]);
        let source = Bitmap8::filled(1, 1, [10, 20, 30, 128]);
        for mode in BlendMode::ALL {
            let cpu = cpu_composite(&backdrop, &source, mode, 0.5);
            let gpu = backend.composite(&backdrop, &source, mode, 0.5).expect("the GPU composites");
            assert!(worst_difference(&cpu, &gpu) <= 1, "{mode:?}");
        }
    }

    #[test]
    fn a_workgroup_boundary_composite_works() {
        let Some(backend) = gpu_or_skip("a_workgroup_boundary_composite_works") else { return };
        // 64 pixels is exactly one workgroup; 65 needs a second, partial one.
        for width in [63u32, 64, 65, 129] {
            let backdrop = opaque_pattern(width, 1, 1);
            let source = opaque_pattern(width, 1, 2);
            let cpu = cpu_composite(&backdrop, &source, BlendMode::HardLight, 1.0);
            let gpu = backend.composite(&backdrop, &source, BlendMode::HardLight, 1.0).expect("the GPU composites");
            assert!(worst_difference(&cpu, &gpu) <= 1, "width {width}");
        }
    }

    #[test]
    fn repeating_a_composite_gives_the_same_answer() {
        let Some(backend) = gpu_or_skip("repeating_a_composite_gives_the_same_answer") else { return };
        let backdrop = pattern(16, 16, 1);
        let source = pattern(16, 16, 2);
        let first = backend.composite(&backdrop, &source, BlendMode::ColorBurn, 0.7).expect("the GPU composites");
        for _ in 0..3 {
            let again = backend.composite(&backdrop, &source, BlendMode::ColorBurn, 0.7).expect("the GPU composites");
            assert_eq!(again, first, "the same inputs give the same pixels");
        }
    }

    #[test]
    fn the_gpu_leaves_its_inputs_alone() {
        let Some(backend) = gpu_or_skip("the_gpu_leaves_its_inputs_alone") else { return };
        let backdrop = pattern(8, 8, 1);
        let source = pattern(8, 8, 2);
        let before = (backdrop.clone(), source.clone());
        let _ = backend.composite(&backdrop, &source, BlendMode::Exclusion, 0.4).expect("the GPU composites");
        assert_eq!(backdrop, before.0);
        assert_eq!(source, before.1);
    }

    // ---------------------------------------------------------------------------------------------
    // Masks and clipping coverage: planes the shader multiplies into the layer's alpha.
    // ---------------------------------------------------------------------------------------------

    /// A mask that ramps in both axes, so a comparison sees every coverage from zero to full.
    fn gradient_mask(width: u32, height: u32) -> Gray8 {
        let mut values = Vec::with_capacity((width * height) as usize);
        for y in 0..height {
            for x in 0..width {
                values.push(((x * 13 + y * 7) % 256) as u8);
            }
        }
        Gray8::from_raw(width, height, values).expect("the mask matches the canvas")
    }

    fn inverted_gradient_mask(width: u32, height: u32) -> Gray8 {
        let mask = gradient_mask(width, height);
        let inverted = mask.pixels().iter().map(|value| 255 - *value).collect();
        Gray8::from_raw(width, height, inverted).expect("the mask matches the canvas")
    }

    /// Asserts a whole document's GPU render agrees with the CPU's within a level, and reports the worst
    /// pixel when it does not. Returns the worst difference so a report can print it.
    fn assert_document_matches(label: &str, document: &Document, gpu: &Bitmap8) -> i32 {
        assert_document_within(label, document, gpu, 1)
    }

    fn assert_document_within(label: &str, document: &Document, gpu: &Bitmap8, tolerance: i32) -> i32 {
        let cpu = crate::flatten_document(document);
        assert_eq!((gpu.width(), gpu.height()), (cpu.width(), cpu.height()));
        let mut worst = 0i32;
        let mut at = (0u32, 0u32);
        for y in 0..cpu.height() {
            for x in 0..cpu.width() {
                let difference = cpu
                    .get(x, y)
                    .iter()
                    .zip(gpu.get(x, y).iter())
                    .map(|(a, b)| (*a as i32 - *b as i32).abs())
                    .max()
                    .unwrap_or(0);
                if difference > worst {
                    worst = difference;
                    at = (x, y);
                }
            }
        }
        assert!(
            worst <= tolerance,
            "{label}: worst channel differs by {worst} at {at:?} (cpu {:?} against gpu {:?})",
            cpu.get(at.0, at.1),
            gpu.get(at.0, at.1)
        );
        worst
    }

    #[test]
    fn a_masked_layer_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_masked_layer_matches_on_the_gpu") else { return };
        let mut document = document(16, 12);
        let mut layer = layer_with("Masked", pattern(16, 12, 1));
        layer.mask = Some(std::sync::Arc::new(gradient_mask(16, 12)));
        document.add_layer(layer, None);
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a masked layer composites on the GPU");
        assert_document_matches("a masked layer", &document, &gpu);
    }

    #[test]
    fn two_layers_with_different_masks_match_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("two_layers_with_different_masks_match_on_the_gpu") else { return };
        let mut document = document(16, 12);
        document.add_layer(layer_with("Base", opaque_pattern(16, 12, 1)), None);
        let mut lower = layer_with("Lower", pattern(16, 12, 4));
        lower.mask = Some(std::sync::Arc::new(gradient_mask(16, 12)));
        lower.blend = BlendMode::Multiply;
        lower.opacity = 0.7;
        document.add_layer(lower, None);
        let mut upper = layer_with("Upper", pattern(16, 12, 7));
        upper.mask = Some(std::sync::Arc::new(inverted_gradient_mask(16, 12)));
        upper.blend = BlendMode::Screen;
        document.add_layer(upper, None);
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("two masks composite on the GPU");
        assert_document_matches("two masks", &document, &gpu);
    }

    #[test]
    fn a_mask_with_a_placement_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_mask_with_a_placement_matches_on_the_gpu") else { return };
        let mut document = document(16, 16);
        let mut layer = layer_with("Shifted mask", pattern(16, 16, 1));
        layer.mask = Some(std::sync::Arc::new(gradient_mask(16, 16)));
        // The mask sits four columns left and two rows up from the layer.
        layer.mask_placement = Some(Transform {
            origin: PointF::new(-4.0, -2.0),
            size: SizeF::new(16.0, 16.0),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Nearest,
        });
        document.add_layer(layer, None);
        let gpu = flatten_document_gpu(&document).expect("a shifted mask composites on the GPU");
        assert_document_matches("a shifted mask", &document, &gpu);
    }

    #[test]
    fn a_mask_of_zero_and_a_mask_of_full_match() {
        let Some(_backend) = gpu_or_skip("a_mask_of_zero_and_a_mask_of_full_match") else { return };
        // The two boundaries: a mask that hides everything, and one that changes nothing.
        let mut hidden = document(12, 8);
        let mut layer = layer_with("Hidden", pattern(12, 8, 1));
        layer.mask = Some(std::sync::Arc::new(Gray8::filled(12, 8, 0)));
        hidden.add_layer(layer, None);
        let gpu = flatten_document_gpu(&hidden).expect("a zero mask composites on the GPU");
        assert_document_matches("a zero mask", &hidden, &gpu);
        assert!(gpu.pixels().iter().all(|byte| *byte == 0), "a zero mask hides the layer");

        let mut shown = document(12, 8);
        let mut layer = layer_with("Shown", pattern(12, 8, 1));
        layer.mask = Some(std::sync::Arc::new(Gray8::filled(12, 8, 255)));
        shown.add_layer(layer, None);
        let gpu = flatten_document_gpu(&shown).expect("a full mask composites on the GPU");
        assert_document_matches("a full mask", &shown, &gpu);
        let mut plain = document(12, 8);
        plain.add_layer(layer_with("Shown", pattern(12, 8, 1)), None);
        assert_eq!(gpu, crate::flatten_document(&plain), "a full mask changes nothing");
    }

    #[test]
    fn a_masked_folder_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_masked_folder_matches_on_the_gpu") else { return };
        // A folder's mask lands on every child's alpha. It travels to the shader as one more coverage
        // plane, so a masked folder no longer sends the document to the CPU.
        let mut document = document(16, 16);
        let mut folder = Layer::group("Folder", 16, 16);
        folder.mask = Some(std::sync::Arc::new(Gray8::filled(16, 16, 96)));
        let folder_id = folder.id;
        document.add_layer(folder, None);
        document.add_layer(layer_with("Child", opaque_pattern(16, 16, 3)), Some(folder_id));
        assert!(gpu_accepts(&document).is_ok(), "a folder mask is a coverage plane now");
        let gpu = flatten_document_gpu(&document).expect("a masked folder composites on the GPU");
        assert_document_matches("a masked folder", &document, &gpu);
    }

    #[test]
    fn a_disabled_folder_mask_stays_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_disabled_folder_mask_stays_on_the_gpu") else { return };
        // A mask that is switched off applies to nothing, so it is no reason to leave the GPU.
        let mut document = document(8, 8);
        let mut folder = Layer::group("Folder", 8, 8);
        folder.mask = Some(std::sync::Arc::new(Gray8::filled(8, 8, 96)));
        folder.mask_enabled = false;
        let folder_id = folder.id;
        document.add_layer(folder, None);
        document.add_layer(layer_with("Child", opaque_pattern(8, 8, 3)), Some(folder_id));
        let gpu = flatten_document_gpu(&document).expect("a disabled mask is not a mask");
        assert_eq!(gpu, crate::flatten_document(&document));
    }

    #[test]
    fn a_single_clipping_link_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_single_clipping_link_matches_on_the_gpu") else { return };
        let mut document = document(16, 16);
        let base = layer_with("Base", pattern(16, 16, 3));
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = layer_with("Clipped", pattern(16, 16, 6));
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a clipping link composites on the GPU");
        assert_document_matches("a clipping link", &document, &gpu);
    }

    #[test]
    fn a_clipping_chain_of_three_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_clipping_chain_of_three_matches_on_the_gpu") else { return };
        let mut document = document(16, 16);
        // The base carries a mask of its own, so the chain has to fold it into the coverage the two clipped
        // layers above it see.
        let mut base = layer_with("Base", pattern(16, 16, 2));
        base.mask = Some(std::sync::Arc::new(gradient_mask(16, 16)));
        let base_id = base.id;
        document.add_layer(base, None);
        let mut middle = layer_with("Middle", pattern(16, 16, 5));
        middle.mask_source = Some(base_id);
        let middle_id = middle.id;
        document.add_layer(middle, None);
        let mut top = layer_with("Top", pattern(16, 16, 8));
        top.mask_source = Some(middle_id);
        top.blend = BlendMode::Multiply;
        document.add_layer(top, None);
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a clipping chain composites on the GPU");
        assert_document_matches("a clipping chain", &document, &gpu);
    }

    #[test]
    fn a_transformed_clipping_base_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_transformed_clipping_base_matches_on_the_gpu") else { return };
        // The base is enlarged, so its coverage has to be placed through its own transform before the
        // layers above it are clipped by it.
        let mut document = document(24, 24);
        let mut base = layer_with("Base", pattern(12, 12, 3));
        base.transform = Transform {
            origin: PointF::new(4.0, 5.0),
            size: SizeF::new(15.0, 15.0),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Nearest,
        };
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = layer_with("Clipped", pattern(24, 24, 6));
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a transformed base composites on the GPU");
        assert_document_matches("a transformed clipping base", &document, &gpu);
    }

    #[test]
    fn a_clipping_cycle_is_refused_rather_than_guessed() {
        let Some(_backend) = gpu_or_skip("a_clipping_cycle_is_refused_rather_than_guessed") else { return };
        // Two layers that clip each other would send the coverage walk round forever; the CPU's guard stops
        // it, and the GPU refuses the document instead of inventing coverage.
        let mut document = document(8, 8);
        let mut first = layer_with("First", opaque_pattern(8, 8, 1));
        let mut second = layer_with("Second", opaque_pattern(8, 8, 2));
        let (first_id, second_id) = (first.id, second.id);
        first.mask_source = Some(second_id);
        second.mask_source = Some(first_id);
        document.add_layer(first, None);
        document.add_layer(second, None);
        assert!(gpu_accepts(&document).is_err(), "a clipping cycle is not a document the shader can take");
        assert!(flatten_document_gpu(&document).is_none());
        assert_eq!(
            flatten_document_preferring_gpu(&document),
            crate::flatten_document(&document),
            "a refused document is composited on the CPU, all of it"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Placement: the layer's own pixels sampled through its transform.
    // ---------------------------------------------------------------------------------------------

    /// A layer of @@width@@ x @@height@@ placed at @@origin@@ with @@size@@, turned by @@rotation@@ and sampled
    /// the way the test asks for.
    #[allow(clippy::too_many_arguments)]
    fn placed_layer(
        name: &str,
        width: u32,
        height: u32,
        seed: u32,
        origin: (f64, f64),
        size: (f64, f64),
        rotation: f64,
        flip_x: bool,
        sampling: Sampling,
    ) -> Layer {
        let mut layer = layer_with(name, Bitmap8::new(width, height));
        let image = std::sync::Arc::make_mut(layer.image.as_mut().expect("the layer has pixels"));
        for (index, texel) in image.pixels_mut().chunks_exact_mut(4).enumerate() {
            let value = ((index as u32 * 37 + seed * 11) % 256) as u8;
            texel.copy_from_slice(&[value, value.wrapping_add(40), value.wrapping_add(90), (index as u32 % 4) as u8 * 85]);
        }
        layer.transform = placement(origin, size, rotation, flip_x, sampling);
        layer
    }

    /// A transform at `origin` with `size`, turned by `rotation` and sampled the way the test asks for.
    fn placement(origin: (f64, f64), size: (f64, f64), rotation: f64, flip_x: bool, sampling: Sampling) -> Transform {
        Transform {
            origin: PointF::new(origin.0, origin.1),
            size: SizeF::new(size.0, size.1),
            rotation,
            flip_x,
            flip_y: false,
            sampling,
        }
    }

    #[test]
    fn an_integer_offset_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_integer_offset_matches_on_the_gpu") else { return };
        let mut document = document(64, 64);
        document.add_layer(layer_with("Backdrop", opaque_pattern(64, 64, 1)), None);
        document.add_layer(
            placed_layer("Placed", 16, 12, 3, (9.0, 6.0), (16.0, 12.0), 0.0, false, Sampling::Nearest),
            None,
        );
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a placed layer composites on the GPU");
        assert_document_within("an integer offset", &document, &gpu, 0);
    }

    #[test]
    fn a_flipped_layer_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_flipped_layer_matches_on_the_gpu") else { return };
        let mut document = document(32, 24);
        document.add_layer(layer_with("Backdrop", opaque_pattern(32, 24, 2)), None);
        document.add_layer(
            placed_layer("Mirrored", 32, 24, 5, (0.0, 0.0), (32.0, 24.0), 0.0, true, Sampling::Nearest),
            None,
        );
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a flipped layer composites on the GPU");
        assert_document_within("a flip", &document, &gpu, 0);
    }

    #[test]
    fn an_enlarged_layer_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_enlarged_layer_matches_on_the_gpu") else { return };
        let mut document = document(64, 64);
        document.add_layer(layer_with("Backdrop", opaque_pattern(64, 64, 1)), None);
        document.add_layer(
            placed_layer("Scaled", 16, 12, 7, (4.0, 8.0), (32.0, 24.0), 0.0, false, Sampling::Nearest),
            None,
        );
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a scaled layer composites on the GPU");
        assert_document_within("a scale", &document, &gpu, 0);
    }

    #[test]
    fn a_turned_layer_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_turned_layer_matches_on_the_gpu") else { return };
        // A quarter turn is exact; the coverage of a turned edge is the CPU's own quad clipping.
        let mut document = document(64, 64);
        document.add_layer(layer_with("Backdrop", opaque_pattern(64, 64, 3)), None);
        document.add_layer(
            placed_layer("Turned", 16, 16, 11, (16.0, 16.0), (16.0, 16.0), 90.0, false, Sampling::Nearest),
            None,
        );
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a turned layer composites on the GPU");
        assert_document_matches("a quarter turn", &document, &gpu);
    }

    #[test]
    fn a_small_angle_rotation_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_small_angle_rotation_matches_on_the_gpu") else { return };
        let mut document = document(64, 64);
        document.add_layer(layer_with("Backdrop", opaque_pattern(64, 64, 4)), None);
        document.add_layer(
            placed_layer("Turned", 20, 20, 13, (14.0, 15.0), (20.0, 20.0), 15.0, false, Sampling::Smooth),
            None,
        );
        let gpu = flatten_document_gpu(&document).expect("a rotated layer composites on the GPU");
        assert_document_matches("a 15 degree turn", &document, &gpu);
    }

    #[test]
    fn a_rotated_masked_layer_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_rotated_masked_layer_matches_on_the_gpu") else { return };
        let mut document = document(48, 48);
        document.add_layer(layer_with("Backdrop", opaque_pattern(48, 48, 6)), None);
        let mut layer = placed_layer("Turned", 20, 20, 17, (10.0, 11.0), (24.0, 24.0), 30.0, false, Sampling::Smooth);
        layer.mask = Some(std::sync::Arc::new(gradient_mask(20, 20)));
        document.add_layer(layer, None);
        let gpu = flatten_document_gpu(&document).expect("a rotated masked layer composites on the GPU");
        assert_document_matches("a rotated masked layer", &document, &gpu);
    }

    #[test]
    fn a_layer_hanging_off_the_canvas_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_layer_hanging_off_the_canvas_matches_on_the_gpu") else { return };
        // Half the layer is past the right edge and the bottom, which the destination box has to clip.
        let mut document = document(32, 32);
        document.add_layer(layer_with("Backdrop", opaque_pattern(32, 32, 8)), None);
        document.add_layer(
            placed_layer("Overhang", 24, 24, 19, (20.0, 22.0), (24.0, 24.0), 0.0, false, Sampling::Nearest),
            None,
        );
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("an overhanging layer composites on the GPU");
        assert_document_matches("an overhang", &document, &gpu);
    }


    #[test]
    fn a_layer_entirely_off_the_canvas_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_layer_entirely_off_the_canvas_matches_on_the_gpu") else { return };
        let mut document = document(16, 16);
        document.add_layer(layer_with("Backdrop", opaque_pattern(16, 16, 9)), None);
        document.add_layer(
            placed_layer("Past", 8, 8, 21, (40.0, 40.0), (8.0, 8.0), 0.0, false, Sampling::Nearest),
            None,
        );
        let gpu = flatten_document_gpu(&document).expect("a layer past the edge changes nothing");
        assert_eq!(gpu, crate::flatten_document(&document));
    }

    #[test]
    fn a_bilinear_and_a_high_quality_placement_stay_within_a_level() {
        let Some(_backend) = gpu_or_skip("a_bilinear_and_a_high_quality_placement_stay_within_a_level") else { return };
        // Smooth is bilinear on both sides. High quality is Catmull-Rom on the CPU, and the shader carries
        // the same four weights, so this is the measurement that says whether it does.
        for sampling in [Sampling::Smooth, Sampling::HighQuality] {
            let mut document = document(64, 64);
            document.add_layer(layer_with("Backdrop", opaque_pattern(64, 64, 1)), None);
            document.add_layer(
                placed_layer("Enlarged", 16, 16, 23, (6.25, 7.5), (32.0, 32.0), 0.0, false, sampling),
                None,
            );
            let gpu = flatten_document_gpu(&document).expect("an enlarged layer composites on the GPU");
            assert_document_matches("an enlargement", &document, &gpu);
        }
    }

    #[test]
    fn a_layer_reduced_to_a_quarter_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_layer_reduced_to_a_quarter_matches_on_the_gpu") else { return };
        // A 64 pixel layer shown in 16 is reduced twice before it is sampled, on both sides: the CPU halves
        // in its DownsampleCache, the GPU asks for the same halvings and samples the chain at its scale.
        let mut document = document(64, 64);
        document.add_layer(layer_with("Backdrop", opaque_pattern(64, 64, 1)), None);
        document.add_layer(
            placed_layer("Tiny", 64, 64, 29, (8.0, 8.0), (16.0, 16.0), 0.0, false, Sampling::HighQuality),
            None,
        );
        assert!(gpu_accepts(&document).is_ok(), "a reduced layer is accepted now");
        let gpu = flatten_document_gpu(&document).expect("a reduced layer composites on the gpu");
        assert_document_matches("a quarter-size layer", &document, &gpu);
    }

    #[test]
    fn a_layer_reduced_by_smooth_sampling_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_layer_reduced_by_smooth_sampling_matches_on_the_gpu") else { return };
        // One halving: 48 pixels shown in 20 is just under half, which is the boundary where the reduction
        // starts.
        let mut document = document(64, 64);
        document.add_layer(layer_with("Backdrop", opaque_pattern(64, 64, 2)), None);
        document.add_layer(
            placed_layer("Small", 48, 48, 31, (10.0, 12.0), (20.0, 20.0), 0.0, false, Sampling::Smooth),
            None,
        );
        let gpu = flatten_document_gpu(&document).expect("a reduced layer composites on the gpu");
        assert_document_matches("a reduced layer", &document, &gpu);
    }

    #[test]
    fn the_acceptance_query_names_the_layer_it_refuses() {
        let Some(_backend) = gpu_or_skip("the_acceptance_query_names_the_layer_it_refuses") else { return };
        // A plain document is accepted, and each thing the shader cannot do is refused with a reason that
        // says which layer and what about it.
        let mut plain = document(8, 8);
        plain.add_layer(layer_with("Plain", opaque_pattern(8, 8, 1)), None);
        assert_eq!(gpu_accepts(&plain).ok(), Some(()));

        let mut placed = document(8, 8);
        placed.add_layer(
            placed_layer("Moved", 4, 4, 2, (1.0, 1.0), (4.0, 4.0), 0.0, false, Sampling::Nearest),
            None,
        );
        assert_eq!(gpu_accepts(&placed).ok(), Some(()), "a placement is accepted now");

        let mut adjusted = document(8, 8);
        adjusted.add_layer(
            Layer::adjustment("Invert", comp_core::Adjustment::new(comp_core::AdjustmentKind::Invert), 8, 8),
            None,
        );
        assert_eq!(gpu_accepts(&adjusted).ok(), Some(()), "a per-pixel adjustment is accepted now");

        let mut blurred = document(8, 8);
        let mut blur = comp_core::Adjustment::new(comp_core::AdjustmentKind::GaussianBlur);
        blur.blur_radius = Some(4.0);
        blurred.add_layer(Layer::adjustment("Blur", blur, 8, 8), None);
        assert_eq!(gpu_accepts(&blurred).ok(), Some(()), "a blur adjustment is accepted now");

        let mut effected = document(8, 8);
        let mut layer = layer_with("Effected", opaque_pattern(8, 8, 1));
        layer.effects = Some(comp_core::effects::LayerEffects {
            color_overlay: Some(comp_core::effects::ColorOverlayEffect {
                enabled: None,
                red: 1.0,
                green: 0.0,
                blue: 0.0,
                opacity: 1.0,
            }),
            ..Default::default()
        });
        effected.add_layer(layer, None);
        assert_eq!(gpu_accepts(&effected).ok(), Some(()), "a layer effect is accepted now");

        // What is still refused is a layer carrying more masks than one dispatch folds, and the reason
        // names that layer.
        let crowded = masked_folder_document(MAX_COVERAGE_PLANES);
        let reason = gpu_accepts(&crowded).expect_err("one plane past the cap is refused");
        assert!(reason.contains("Crowded"), "{reason}");
    }


    /// A layer under `depth` masked folders, with a mask of its own: `depth + 1` coverage planes for the
    /// shader to fold one at a time, and the reason for any refusal names the layer.
    fn masked_folder_document(depth: usize) -> Document {
        let mut document = document(12, 12);
        document.add_layer(layer_with("Base", opaque_pattern(12, 12, 1)), None);
        let mut parent = None;
        for depth in 0..depth {
            let mut folder = Layer::group(format!("Folder {depth}"), 12, 12);
            folder.mask = Some(std::sync::Arc::new(comp_core::Gray8::filled(12, 12, 200)));
            let id = folder.id;
            document.add_layer(folder, parent);
            parent = Some(id);
        }
        let mut layer = layer_with("Crowded", opaque_pattern(12, 12, 2));
        layer.mask = Some(std::sync::Arc::new(comp_core::Gray8::filled(12, 12, 128)));
        document.add_layer(layer, parent);
        document
    }

    #[test]
    fn a_refused_document_falls_back_as_a_whole() {
        let Some(_backend) = gpu_or_skip("a_refused_document_falls_back_as_a_whole") else { return };
        // Whatever the reason, a refused document is composited on the CPU from end to end: never half on one
        // compositor and half on the other.
        let document = masked_folder_document(MAX_COVERAGE_PLANES);
        let reason = gpu_accepts(&document).expect_err("one plane past the cap is refused");
        assert!(reason.contains("Crowded"), "{reason}");
        assert!(flatten_document_gpu(&document).is_none());
        assert_eq!(flatten_document_preferring_gpu(&document), crate::flatten_document(&document));
    }

    // ---------------------------------------------------------------------------------------------
    // Adjustment layers: the per-pixel kernels, run as a pass over the canvas.
    // ---------------------------------------------------------------------------------------------

    /// A canvas with a graded backdrop, so an adjustment has something to change.
    fn graded_document(width: u32, height: u32) -> Document {
        let mut document = document(width, height);
        let mut bitmap = Bitmap8::new(width, height);
        for (index, texel) in bitmap.pixels_mut().chunks_exact_mut(4).enumerate() {
            let value = ((index * 37) % 256) as u8;
            texel.copy_from_slice(&[value, value.wrapping_add(60), 255 - value, 255]);
        }
        let mut layer = layer_with("Canvas", bitmap);
        layer.image_file = None;
        document.add_layer(layer, None);
        document
    }

    /// A document of one canvas and one adjustment layer of the given kind, adjusted by `configure`.
    fn adjusted_document(
        kind: comp_core::AdjustmentKind,
        configure: impl FnOnce(&mut comp_core::Adjustment),
    ) -> Document {
        let mut document = graded_document(24, 18);
        let mut adjustment = comp_core::Adjustment::new(kind);
        configure(&mut adjustment);
        document.add_layer(Layer::adjustment("Adjustment", adjustment, 24, 18), None);
        document
    }


    #[test]
    fn a_gaussian_blur_adjustment_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_gaussian_blur_adjustment_matches_on_the_gpu") else { return };
        // A small block on a plain canvas, so the blur has an edge to spread.
        let mut document = graded_document(24, 18);
        let mut blur = comp_core::Adjustment::new(comp_core::AdjustmentKind::GaussianBlur);
        blur.blur_radius = Some(2.5);
        document.add_layer(Layer::adjustment("Blur", blur, 24, 18), None);
        assert!(gpu_accepts(&document).is_ok(), "a blur adjustment is accepted now");
        let gpu = flatten_document_gpu(&document).expect("a gaussian blur composites on the gpu");
        assert_document_matches("a gaussian blur", &document, &gpu);
    }

    #[test]
    fn a_motion_blur_adjustment_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_motion_blur_adjustment_matches_on_the_gpu") else { return };
        let mut document = graded_document(24, 18);
        let mut blur = comp_core::Adjustment::new(comp_core::AdjustmentKind::MotionBlur);
        blur.motion_angle = Some(30.0);
        blur.motion_distance = Some(9.0);
        document.add_layer(Layer::adjustment("Streak", blur, 24, 18), None);
        assert!(gpu_accepts(&document).is_ok(), "a motion blur is accepted now");
        let gpu = flatten_document_gpu(&document).expect("a motion blur composites on the gpu");
        assert_document_matches("a motion blur", &document, &gpu);
    }



    /// The effects image on its own, against the CPU's own effects::render: the rasterisation compared
    /// without the grown placement and the composite that follow it, so a difference here is the effect
    /// pipeline's and nowhere else.
    fn assert_effects_match(label: &str, image: &Bitmap8, effects: &comp_core::effects::LayerEffects) {
        let Some(backend) = gpu_or_skip(label) else { return };
        let shaped = crate::pixel::Surface::from_bitmap(image);
        let (expected, expected_inset) = crate::effects::render(&shaped, effects);
        let (gpu, inset) = backend
            .effects_image(image, None, effects)
            .unwrap_or_else(|| panic!("{label}: the effects image rendered"));
        assert_eq!(inset, expected_inset, "{label}: the margin");
        let expected = expected.to_bitmap();
        assert_eq!((gpu.width(), gpu.height()), (expected.width(), expected.height()), "{label}: the grown size");
        let mut worst = 0i32;
        let mut at = (0u32, 0u32);
        for y in 0..expected.height() {
            for x in 0..expected.width() {
                let difference = expected
                    .get(x, y)
                    .iter()
                    .zip(gpu.get(x, y).iter())
                    .map(|(a, b)| (*a as i32 - *b as i32).abs())
                    .max()
                    .unwrap_or(0);
                if difference > worst {
                    worst = difference;
                    at = (x, y);
                }
            }
        }
        println!(
            "{label}: worst {worst} at {at:?} (cpu {:?} against gpu {:?})",
            expected.get(at.0, at.1),
            gpu.get(at.0, at.1)
        );
        assert!(worst <= 1, "{label}: worst channel differs by {worst} at {at:?}");
    }

    /// The image the effect tests work on: a varied, semi-transparent block.
    fn effect_test_image(width: u32, height: u32) -> Bitmap8 {
        let mut image = Bitmap8::new(width, height);
        for (index, texel) in image.pixels_mut().chunks_exact_mut(4).enumerate() {
            let value = ((index * 37) % 256) as u8;
            texel.copy_from_slice(&[
                value,
                value.wrapping_add(40),
                value.wrapping_add(90),
                ((index as u32 % 4) * 85) as u8,
            ]);
        }
        image
    }

    #[test]
    fn the_effects_image_matches_the_cpu_for_a_color_overlay() {
        let image = effect_test_image(12, 10);
        let effects = comp_core::effects::LayerEffects {
            color_overlay: Some(comp_core::effects::ColorOverlayEffect {
                enabled: None,
                red: 0.9,
                green: 0.2,
                blue: 0.1,
                opacity: 0.8,
            }),
            ..Default::default()
        };
        assert_effects_match("a color overlay image", &image, &effects);
    }




    /// A document with one effected layer over a backdrop, so the effects land through the grown placement.
    fn effected_document(effects: comp_core::effects::LayerEffects) -> Document {
        let mut document = document(28, 22);
        document.add_layer(layer_with("Backdrop", opaque_pattern(28, 22, 2)), None);
        let mut layer = layer_with("Effected", pattern(12, 9, 5));
        layer.transform = placement((7.0, 5.0), (12.0, 9.0), 0.0, false, Sampling::Nearest);
        layer.effects = Some(effects);
        document.add_layer(layer, None);
        document
    }

    fn stroke_effect(size: f64, inside: bool) -> comp_core::effects::LayerEffects {
        comp_core::effects::LayerEffects {
            stroke: Some(comp_core::effects::StrokeEffect {
                enabled: None,
                size,
                inside,
                red: 0.2,
                green: 0.8,
                blue: 0.4,
                opacity: 0.9,
            }),
            ..Default::default()
        }
    }

    #[test]
    fn every_layer_effect_matches_in_a_document() {
        let Some(_backend) = gpu_or_skip("every_layer_effect_matches_in_a_document") else { return };
        let cases: Vec<(&str, comp_core::effects::LayerEffects)> = vec![
            ("a stroke", stroke_effect(3.0, false)),
            ("an inner stroke", stroke_effect(2.0, true)),
            (
                "a shadow",
                comp_core::effects::LayerEffects {
                    shadow: Some(comp_core::effects::ShadowEffect {
                        enabled: None,
                        angle: 135.0,
                        distance: 4.0,
                        blur: 6.0,
                        red: 0.0,
                        green: 0.0,
                        blue: 0.0,
                        opacity: 0.7,
                    }),
                    ..Default::default()
                },
            ),
            (
                "an outer glow",
                comp_core::effects::LayerEffects {
                    outer_glow: Some(comp_core::effects::OuterGlowEffect {
                        enabled: None,
                        size: 5.0,
                        red: 1.0,
                        green: 0.9,
                        blue: 0.2,
                        opacity: 0.8,
                    }),
                    ..Default::default()
                },
            ),
            (
                "an inner glow",
                comp_core::effects::LayerEffects {
                    inner_glow: Some(comp_core::effects::InnerGlowEffect {
                        enabled: None,
                        size: 3.0,
                        red: 0.1,
                        green: 0.4,
                        blue: 1.0,
                        opacity: 0.75,
                    }),
                    ..Default::default()
                },
            ),
            (
                "an inner shadow",
                comp_core::effects::LayerEffects {
                    inner_shadow: Some(comp_core::effects::InnerShadowEffect {
                        enabled: None,
                        angle: 45.0,
                        distance: 3.0,
                        blur: 5.0,
                        red: 0.0,
                        green: 0.0,
                        blue: 0.0,
                        opacity: 0.6,
                    }),
                    ..Default::default()
                },
            ),
            (
                "a color overlay",
                comp_core::effects::LayerEffects {
                    color_overlay: Some(comp_core::effects::ColorOverlayEffect {
                        enabled: None,
                        red: 0.9,
                        green: 0.2,
                        blue: 0.1,
                        opacity: 0.8,
                    }),
                    ..Default::default()
                },
            ),
        ];
        for (name, effects) in cases {
            let document = effected_document(effects);
            assert!(gpu_accepts(&document).is_ok(), "{name} is accepted now");
            let gpu = flatten_document_gpu(&document).unwrap_or_else(|| panic!("{name} composites on the gpu"));
            assert_document_matches(name, &document, &gpu);
        }
    }

    #[test]
    fn several_effects_at_once_match_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("several_effects_at_once_match_on_the_gpu") else { return };
        // All six at once, which is where the order they are painted in shows: behind, then the layer, then
        // on top.
        let effects = comp_core::effects::LayerEffects {
            shadow: Some(comp_core::effects::ShadowEffect {
                enabled: None,
                angle: 120.0,
                distance: 5.0,
                blur: 4.0,
                red: 0.0,
                green: 0.0,
                blue: 0.0,
                opacity: 0.6,
            }),
            outer_glow: Some(comp_core::effects::OuterGlowEffect {
                enabled: None,
                size: 4.0,
                red: 1.0,
                green: 0.8,
                blue: 0.0,
                opacity: 0.5,
            }),
            stroke: Some(comp_core::effects::StrokeEffect {
                enabled: None,
                size: 2.0,
                inside: false,
                red: 0.1,
                green: 0.2,
                blue: 0.9,
                opacity: 0.8,
            }),
            color_overlay: Some(comp_core::effects::ColorOverlayEffect {
                enabled: None,
                red: 0.2,
                green: 0.9,
                blue: 0.3,
                opacity: 0.4,
            }),
            inner_glow: Some(comp_core::effects::InnerGlowEffect {
                enabled: None,
                size: 2.0,
                red: 1.0,
                green: 0.0,
                blue: 0.4,
                opacity: 0.5,
            }),
            inner_shadow: Some(comp_core::effects::InnerShadowEffect {
                enabled: None,
                angle: 200.0,
                distance: 2.0,
                blur: 3.0,
                red: 0.0,
                green: 0.0,
                blue: 0.0,
                opacity: 0.5,
            }),
        };
        let document = effected_document(effects);
        let gpu = flatten_document_gpu(&document).expect("all six effects composite on the gpu");
        assert_document_matches("all six effects", &document, &gpu);
    }

    #[test]
    fn an_effect_with_a_mask_and_a_blend_mode_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_effect_with_a_mask_and_a_blend_mode_matches_on_the_gpu") else { return };
        // The mask goes into the shape before the effects; the clip coverage and the blend mode come after
        // the grown placement.
        let mut document = document(28, 22);
        document.add_layer(layer_with("Backdrop", opaque_pattern(28, 22, 3)), None);
        let mut layer = layer_with("Effected", pattern(12, 9, 6));
        layer.transform = placement((7.0, 5.0), (12.0, 9.0), 0.0, false, Sampling::Nearest);
        layer.mask = Some(std::sync::Arc::new(gradient_mask(12, 9)));
        layer.blend = BlendMode::Screen;
        layer.opacity = 0.7;
        layer.effects = Some(stroke_effect(3.0, false));
        document.add_layer(layer, None);
        let gpu = flatten_document_gpu(&document).expect("a masked effect composites on the gpu");
        assert_document_matches("a masked stroke", &document, &gpu);
    }

    #[test]
    fn an_effect_with_an_extreme_radius_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_effect_with_an_extreme_radius_matches_on_the_gpu") else { return };
        // A shadow wide enough to reach past the grown canvas, a stroke wider than the layer, and a glow
        // whose blur has many taps: the widest the kernels ever get.
        for (name, effects) in [
            (
                "a wide shadow",
                comp_core::effects::LayerEffects {
                    shadow: Some(comp_core::effects::ShadowEffect {
                        enabled: None,
                        angle: 30.0,
                        distance: 18.0,
                        blur: 20.0,
                        red: 0.0,
                        green: 0.0,
                        blue: 0.0,
                        opacity: 0.8,
                    }),
                    ..Default::default()
                },
            ),
            ("a wide stroke", stroke_effect(9.0, false)),
            (
                "a wide glow",
                comp_core::effects::LayerEffects {
                    outer_glow: Some(comp_core::effects::OuterGlowEffect {
                        enabled: None,
                        size: 16.0,
                        red: 1.0,
                        green: 0.5,
                        blue: 0.0,
                        opacity: 0.9,
                    }),
                    ..Default::default()
                },
            ),
        ] {
            let document = effected_document(effects);
            let gpu = flatten_document_gpu(&document).unwrap_or_else(|| panic!("{name} composites on the gpu"));
            assert_document_matches(name, &document, &gpu);
        }
    }

    #[test]
    fn an_effected_region_matches_the_whole_render() {
        let Some(_backend) = gpu_or_skip("an_effected_region_matches_the_whole_render") else { return };
        // An effected layer grows past its own rectangle, so a region renderer has to read the effect's
        // reach outside the rectangle it is asked for.
        let mut document = effected_document(stroke_effect(4.0, false));
        let mut shadow = comp_core::effects::LayerEffects {
            shadow: Some(comp_core::effects::ShadowEffect {
                enabled: None,
                angle: 135.0,
                distance: 6.0,
                blur: 8.0,
                red: 0.0,
                green: 0.0,
                blue: 0.0,
                opacity: 0.7,
            }),
            ..Default::default()
        };
        shadow.stroke = stroke_effect(4.0, false).stroke;
        if let Some(layer) = document.layers.iter_mut().find(|layer| layer.name == "Effected") {
            layer.effects = Some(shadow);
        }
        let whole = crate::flatten_document(&document);
        for bounds in [(10i64, 8i64, 9u32, 7u32), (0, 0, 28, 22), (24, 2, 4, 18)] {
            let region = crate::flatten_region(&document, bounds);
            for row in 0..bounds.3 as i64 {
                for column in 0..bounds.2 as i64 {
                    assert_eq!(
                        region.get(column as u32, row as u32),
                        whole.get((bounds.0 + column) as u32, (bounds.1 + row) as u32),
                        "region {bounds:?} at ({column},{row})"
                    );
                }
            }
        }
    }

    /// Every effect on its own, image against image, with the CPU's own render as the reference.
    #[test]
    fn the_effects_image_matches_the_cpu_for_every_effect() {
        let image = effect_test_image(12, 10);
        let cases: Vec<(&str, comp_core::effects::LayerEffects)> = vec![
            (
                "stroke outside",
                comp_core::effects::LayerEffects {
                    stroke: Some(comp_core::effects::StrokeEffect {
                        enabled: None,
                        size: 3.0,
                        inside: false,
                        red: 0.2,
                        green: 0.8,
                        blue: 0.4,
                        opacity: 0.9,
                    }),
                    ..Default::default()
                },
            ),
            (
                "stroke inside",
                comp_core::effects::LayerEffects {
                    stroke: Some(comp_core::effects::StrokeEffect {
                        enabled: None,
                        size: 2.0,
                        inside: true,
                        red: 0.9,
                        green: 0.3,
                        blue: 0.1,
                        opacity: 1.0,
                    }),
                    ..Default::default()
                },
            ),
            (
                "drop shadow",
                comp_core::effects::LayerEffects {
                    shadow: Some(comp_core::effects::ShadowEffect {
                        enabled: None,
                        angle: 135.0,
                        distance: 4.0,
                        blur: 6.0,
                        red: 0.0,
                        green: 0.0,
                        blue: 0.0,
                        opacity: 0.7,
                    }),
                    ..Default::default()
                },
            ),
            (
                "outer glow",
                comp_core::effects::LayerEffects {
                    outer_glow: Some(comp_core::effects::OuterGlowEffect {
                        enabled: None,
                        size: 4.0,
                        red: 1.0,
                        green: 0.9,
                        blue: 0.2,
                        opacity: 0.8,
                    }),
                    ..Default::default()
                },
            ),
            (
                "inner glow",
                comp_core::effects::LayerEffects {
                    inner_glow: Some(comp_core::effects::InnerGlowEffect {
                        enabled: None,
                        size: 3.0,
                        red: 0.1,
                        green: 0.4,
                        blue: 1.0,
                        opacity: 0.75,
                    }),
                    ..Default::default()
                },
            ),
            (
                "inner shadow",
                comp_core::effects::LayerEffects {
                    inner_shadow: Some(comp_core::effects::InnerShadowEffect {
                        enabled: None,
                        angle: 45.0,
                        distance: 3.0,
                        blur: 5.0,
                        red: 0.0,
                        green: 0.0,
                        blue: 0.0,
                        opacity: 0.6,
                    }),
                    ..Default::default()
                },
            ),
        ];
        for (name, effects) in cases {
            assert_effects_match(name, &image, &effects);
        }
    }


    /// A filter on the GPU against the same filter on the CPU, pixel for pixel.
    fn assert_filter_matches(label: &str, image: &Bitmap8, kind: crate::filters::FilterKind, settings: &crate::filters::FilterSettings) {
        let Some(backend) = backend() else { return };
        let expected = crate::filters::apply_filter(image, kind, settings).expect("the cpu runs the filter");
        let gpu = backend
            .filter_image(image, kind, settings)
            .unwrap_or_else(|| panic!("{label}: the filter ran on the gpu"));
        let mut worst = 0i32;
        let mut at = (0u32, 0u32);
        for y in 0..expected.height() {
            for x in 0..expected.width() {
                let difference = expected
                    .get(x, y)
                    .iter()
                    .zip(gpu.get(x, y).iter())
                    .map(|(a, b)| (*a as i32 - *b as i32).abs())
                    .max()
                    .unwrap_or(0);
                if difference > worst {
                    worst = difference;
                    at = (x, y);
                }
            }
        }
        println!(
            "{label}: worst {worst} at {at:?} (cpu {:?} against gpu {:?})",
            expected.get(at.0, at.1),
            gpu.get(at.0, at.1)
        );
        assert!(worst <= 1, "{label}: worst channel differs by {worst} at {at:?}");
    }

    #[test]
    fn the_vignette_filter_matches_on_the_gpu() {
        let image = effect_test_image(21, 16);
        // The last of these is the one that used to come out three levels away: a small feather makes the
        // mask's ramp steep, and a low alpha is where a premultiplied level turns into three.
        for (amount, midpoint, roundness, feather, highlights) in [
            (35.0f64, 50.0f64, 100.0f64, 50.0f64, 0.0f64),
            (80.0, 30.0, 0.0, 10.0, 40.0),
            (100.0, 75.0, 50.0, 90.0, 100.0),
            (5.0, 50.0, 100.0, 0.0, 0.0),
            (60.0, 40.0, 20.0, 1.0, 20.0),
        ] {
            let settings = crate::filters::FilterSettings {
                vignette_amount: amount,
                vignette_midpoint: midpoint,
                vignette_roundness: roundness,
                vignette_feather: feather,
                vignette_highlights: highlights,
                ..Default::default()
            };
            assert_filter_matches(
                &format!("a vignette amount {amount} feather {feather}"),
                &image,
                crate::filters::FilterKind::Vignette,
                &settings,
            );
        }
    }

    #[test]
    fn the_vignette_is_taken_now_that_its_write_rounds_like_the_cpu() {
        let Some(backend) = backend() else { return };
        // It was refused for a year of this file's life with "the CPU works in f64 and its colour write lands
        // on a rounding knife edge". The edge was the shader's round being half to even; the rounding audit
        // ruled that out, and the filter now agrees with the CPU at every setting the test above tries.
        assert!(GpuBackend::filter_accepts(crate::filters::FilterKind::Vignette).is_ok());
        let image = effect_test_image(21, 16);
        let settings = crate::filters::FilterSettings::default();
        assert!(
            crate::gpu::GpuBackend::filter_image(backend, &image, crate::filters::FilterKind::Vignette, &settings).is_some(),
            "and it runs"
        );
    }

    #[test]
    fn the_lens_correction_filter_matches_on_the_gpu() {
        let image = effect_test_image(19, 14);
        for distortion in [-60.0f64, -15.0, 0.0, 25.0, 70.0] {
            let settings = crate::filters::FilterSettings { distortion, ..Default::default() };
            assert_filter_matches("a lens correction", &image, crate::filters::FilterKind::LensCorrection, &settings);
        }
    }


    #[test]
    fn the_bloom_filter_matches_on_the_gpu() {
        let image = effect_test_image(23, 17);
        for (amount, radius) in [(30.0f64, 8.0f64), (50.0, 20.0), (12.0, 4.0), (80.0, 30.0)] {
            let settings = crate::filters::FilterSettings { bloom_amount: amount, bloom_radius: radius, ..Default::default() };
            assert_filter_matches("a bloom", &image, crate::filters::FilterKind::BloomGlow, &settings);
        }
    }

    #[test]
    fn the_tonal_contrast_filter_matches_on_the_gpu() {
        let image = effect_test_image(21, 15);
        for (amount, radius, shadows, midtones, highlights) in [
            (50.0f64, 12.0f64, 50.0f64, 50.0f64, 50.0f64),
            (25.0, 4.0, 100.0, 0.0, 0.0),
            (75.0, 24.0, 0.0, 0.0, 100.0),
            (40.0, 9.0, 20.0, 80.0, 30.0),
        ] {
            let settings = crate::filters::FilterSettings {
                tonal_amount: amount,
                tonal_radius: radius,
                tonal_shadows: shadows,
                tonal_midtones: midtones,
                tonal_highlights: highlights,
                ..Default::default()
            };
            assert_filter_matches("a tonal contrast", &image, crate::filters::FilterKind::TonalContrast, &settings);
        }
    }


    /// The ordered screens at one pixel per cell: a chunky pixel size averages the image down first, which
    /// is a pass of its own on the CPU.
    fn dither_settings(style: crate::filters::DitherStyle) -> crate::filters::DitherSettings {
        crate::filters::DitherSettings { style, pixel_size: 1.0, ..Default::default() }
    }

    #[test]
    fn the_ordered_dither_styles_match_on_the_gpu() {
        let image = effect_test_image(23, 17);
        for (name, style) in [
            ("Bayer 2", crate::filters::DitherStyle::Bayer2),
            ("Bayer 4", crate::filters::DitherStyle::Bayer4),
            ("Bayer 8", crate::filters::DitherStyle::Bayer8),
        ] {
            let settings = crate::filters::FilterSettings {
                dither: dither_settings(style),
                ..Default::default()
            };
            assert_filter_matches(name, &image, crate::filters::FilterKind::Dither, &settings);
        }
    }

    #[test]
    fn the_ordered_dither_follows_its_settings_on_the_gpu() {
        let image = effect_test_image(21, 15);
        // Density moves the gamma, contrast pivots on mid gray, levels set the steps, and the ramp's two
        // ends are the colors it paints between.
        for (density, contrast, levels) in [(0.0f64, 0.0f64, 2u32), (60.0, 40.0, 4), (-40.0, -30.0, 8), (100.0, 80.0, 16)] {
            let mut dither = dither_settings(crate::filters::DitherStyle::Bayer4);
            dither.density = density;
            dither.contrast = contrast;
            dither.levels = levels.into();
            let settings = crate::filters::FilterSettings { dither, ..Default::default() };
            assert_filter_matches("a tuned dither", &image, crate::filters::FilterKind::Dither, &settings);
        }
    }

    #[test]
    fn the_ordered_dither_in_two_colors_matches_on_the_gpu() {
        let image = effect_test_image(19, 13);
        let mut dither = dither_settings(crate::filters::DitherStyle::Bayer8);
        dither.colors = crate::filters::DitherColors::TwoColors;
        dither.dark = comp_core::effects::EffectColor { red: 0.1, green: 0.0, blue: 0.2 };
        dither.light = comp_core::effects::EffectColor { red: 0.9, green: 0.8, blue: 0.3 };
        let settings = crate::filters::FilterSettings { dither, ..Default::default() };
        assert_filter_matches("a two color dither", &image, crate::filters::FilterKind::Dither, &settings);
    }


    #[test]
    #[ignore = "probe: prints the CPU and GPU marks intermediates instead of guessing"]
    fn probe_the_marks_intermediates() {
        let Some(backend) = backend() else { return };
        let mut image = Bitmap8::new(8, 2);
        for (index, texel) in image.pixels_mut().chunks_exact_mut(4).enumerate() {
            let value = (index as u32 * 31) % 256;
            texel.copy_from_slice(&[value as u8, 255 - value as u8, ((value * 7) % 256) as u8, 255]);
        }
        let dither = crate::filters::DitherSettings {
            style: crate::filters::DitherStyle::Patterns,
            pixel_size: 1.0,
            colors: crate::filters::DitherColors::TwoColors,
            light_on_dark: true,
            dark: comp_core::effects::EffectColor { red: 0.0, green: 0.0, blue: 0.0 },
            light: comp_core::effects::EffectColor { red: 1.0, green: 1.0, blue: 1.0 },
            ..Default::default()
        };
        let settings = crate::filters::FilterSettings { dither: dither.clone(), ..Default::default() };
        let expected = crate::filters::apply_filter(&image, crate::filters::FilterKind::Dither, &settings).expect("cpu");
        // Straight at the pass, past the gate: the probe is here to see what it produces.
        let gpu = backend.dither_ordered(&image, &dither).expect("gpu");
        let gamma = 2f32.powf((dither.density / 100.0) as f32 * 1.5);
        let contrast_setting = (dither.contrast / 100.0) as f32;
        let contrast = if contrast_setting >= 0.0 { 1.0 / (1.0 - 0.95 * contrast_setting) } else { 1.0 + contrast_setting };
        println!("gamma {gamma} contrast {contrast} light_on_dark {}", dither.light_on_dark);
        for (x, y) in [(0u32, 0u32), (1, 0), (2, 0), (3, 0), (4, 0)] {
            let texel = image.get(x, y);
            let luminance = (0.2126 * texel[0] as f32 + 0.7152 * texel[1] as f32 + 0.0722 * texel[2] as f32) / 255.0;
            let toned = {
                let v = luminance.clamp(0.0, 1.0).powf(gamma);
                ((v - 0.5) * contrast + 0.5).clamp(0.0, 1.0)
            };
            let value = if dither.light_on_dark { toned } else { 1.0 - toned };
            let reported = gpu.get(x, y);
            println!(
                "({x},{y}) cpu {:?} | gpu toned {} slot {} mark {} | cpu-side toned {toned:.4} slot {}",
                expected.get(x, y),
                reported[0],
                reported[1],
                reported[2],
                (value * 16.0).round(),
            );
        }
    }

    #[test]
    fn the_pattern_and_halftone_dithers_match_on_the_gpu() {
        let image = effect_test_image(23, 17);
        for style in [
            crate::filters::DitherStyle::Patterns,
            crate::filters::DitherStyle::Dots,
            crate::filters::DitherStyle::Lines,
            crate::filters::DitherStyle::Diamonds,
        ] {
            let settings = crate::filters::FilterSettings {
                dither: dither_settings(style),
                ..Default::default()
            };
            assert_filter_matches(&format!("{style:?}"), &image, crate::filters::FilterKind::Dither, &settings);
        }
    }

    #[test]
    fn the_halftone_screens_follow_their_cell_and_angle_on_the_gpu() {
        let image = effect_test_image(21, 15);
        // The cell's size and the screen's angle are what place the marks, and light-on-dark turns the
        // ink and the paper over.
        for (cell, angle, light_on_dark) in [(2.0f64, 0.0f64, false), (6.0, 45.0, false), (10.0, 30.0, true), (4.0, -20.0, true)] {
            for style in [crate::filters::DitherStyle::Dots, crate::filters::DitherStyle::Lines] {
                let mut dither = dither_settings(style);
                dither.cell_size = cell;
                dither.angle = angle;
                dither.light_on_dark = light_on_dark;
                let settings = crate::filters::FilterSettings { dither, ..Default::default() };
                assert_filter_matches("a halftone screen", &image, crate::filters::FilterKind::Dither, &settings);
            }
        }
    }

    #[test]
    fn the_patterns_follow_their_ramp_on_the_gpu() {
        let image = effect_test_image(19, 13);
        let mut dither = dither_settings(crate::filters::DitherStyle::Patterns);
        dither.colors = crate::filters::DitherColors::TwoColors;
        dither.dark = comp_core::effects::EffectColor { red: 0.2, green: 0.1, blue: 0.0 };
        dither.light = comp_core::effects::EffectColor { red: 0.8, green: 0.9, blue: 1.0 };
        dither.light_on_dark = true;
        let settings = crate::filters::FilterSettings { dither, ..Default::default() };
        assert_filter_matches("a two color pattern", &image, crate::filters::FilterKind::Dither, &settings);
    }



    #[test]
    #[ignore = "probe: prints the scanlines intermediates the pass itself worked out"]
    fn probe_the_scanlines_intermediates() {
        let Some(backend) = backend() else { return };
        // The test's own image, so these numbers are the ones the failing test compares.
        let image = effect_test_image(23, 17);
        let mut dither = dither_settings(crate::filters::DitherStyle::Scanlines);
        dither.line_spacing = 2.0;
        dither.dots = 0.0;
        dither.wobble = 0.0;
        dither.glow = 0.0;
        let settings = crate::filters::FilterSettings { dither: dither.clone(), ..Default::default() };
        let expected = crate::filters::apply_filter(&image, crate::filters::FilterKind::Dither, &settings).expect("cpu");
        let reported = backend.dither_ordered(&image, &dither).expect("gpu");
        let premultiplied = crate::pixel::Surface::from_bitmap(&image);
        println!(
            "cpu premultiplied at (10,11) {:?} | colors {:?}",
            premultiplied.get(10, 11),
            dither.colors
        );
        for (x, y) in [(10u32, 11u32), (10, 10), (10, 12)] {
            let g = reported.get(x, y);
            println!(
                "({x},{y}) cpu {:?} | gpu written [{}, {}, {}] | cpu premultiplied {:?}",
                expected.get(x, y),
                g[0],
                g[1],
                g[2],
                premultiplied.get(x, y)
            );
        }
    }

    #[test]
    fn the_scanlines_dither_matches_on_the_gpu() {
        let image = effect_test_image(23, 17);
        // The screen with no glow: the lines are pixel by pixel, and the spacing, the beads and the wobble
        // are what place them.
        for (spacing, dots, wobble) in [(2.0f64, 0.0f64, 0.0f64), (4.0, 50.0, 2.0), (6.0, 100.0, 4.0), (3.0, 25.0, 1.0)] {
            let mut dither = dither_settings(crate::filters::DitherStyle::Scanlines);
            dither.line_spacing = spacing;
            dither.dots = dots;
            dither.wobble = wobble;
            dither.glow = 0.0;
            let settings = crate::filters::FilterSettings { dither, ..Default::default() };
            assert_filter_matches(
                &format!("scanlines spacing {spacing} dots {dots} wobble {wobble}"),
                &image,
                crate::filters::FilterKind::Dither,
                &settings,
            );
        }
    }

    #[test]
    fn a_glowing_scanline_stays_on_the_cpu_and_says_why() {
        let Some(_backend) = gpu_or_skip("a_glowing_scanline_stays_on_the_cpu_and_says_why") else { return };
        let mut dither = dither_settings(crate::filters::DitherStyle::Scanlines);
        dither.glow = 40.0;
        let reason = GpuBackend::dither_accepts(&dither).expect_err("a glow is refused");
        assert!(reason.contains("Scanlines") && reason.contains("glow"), "{reason}");
        // Without one it is taken, which is what the pair of tests pins down.
        dither.glow = 0.0;
        assert!(GpuBackend::dither_accepts(&dither).is_ok(), "the lines themselves are taken");
    }

    #[test]
    fn the_dither_matches_across_a_sweep_of_grey_levels() {
        let Some(_backend) = gpu_or_skip("the_dither_matches_across_a_sweep_of_grey_levels") else { return };
        // Every grey from 0 to 248 in steps of 8. Some of them land the pattern slot on a half, which is
        // where the CPU's .round() and WGSL's round() part company, so this sweep is the boundary case for
        // the whole dither family rather than for one setting of it.
        let mut image = Bitmap8::new(32, 4);
        for (index, texel) in image.pixels_mut().chunks_exact_mut(4).enumerate() {
            let grey = ((index % 32) as u8).wrapping_mul(8);
            texel.copy_from_slice(&[grey, grey, grey, 255]);
        }
        for style in [
            crate::filters::DitherStyle::Patterns,
            crate::filters::DitherStyle::Bayer8,
            crate::filters::DitherStyle::Dots,
            crate::filters::DitherStyle::Scanlines,
        ] {
            let mut dither = dither_settings(style);
            dither.glow = 0.0;
            let settings = crate::filters::FilterSettings { dither, ..Default::default() };
            assert_filter_matches(
                &format!("{style:?} over a grey sweep"),
                &image,
                crate::filters::FilterKind::Dither,
                &settings,
            );
        }
    }

    #[test]
    fn the_dither_styles_the_gpu_cannot_take_name_themselves() {
        let Some(_backend) = gpu_or_skip("the_dither_styles_the_gpu_cannot_take_name_themselves") else { return };
        use crate::filters::DitherStyle;
        for (style, needle) in [
            (DitherStyle::Atkinson, "serial"),
            (DitherStyle::FloydSteinberg, "serial"),
            (DitherStyle::Ascii, "glyph"),
        ] {
            let reason = GpuBackend::dither_accepts(&dither_settings(style)).expect_err("refused");
            assert!(reason.contains(needle), "{style:?}: {reason}");
        }
        // A chunky pixel size and the dot shape are their own passes, and say so.
        let mut chunky = dither_settings(DitherStyle::Bayer8);
        chunky.pixel_size = 4.0;
        let reason = GpuBackend::dither_accepts(&chunky).expect_err("refused");
        assert!(reason.contains("block average"), "{reason}");
        let mut dotted = dither_settings(DitherStyle::Bayer8);
        dotted.pixel_shape = crate::filters::DitherPixelShape::Dot;
        let reason = GpuBackend::dither_accepts(&dotted).expect_err("refused");
        assert!(reason.contains("dot shape"), "{reason}");
        // And the ones it does take say nothing.
        for style in [
            DitherStyle::Bayer2,
            DitherStyle::Bayer4,
            DitherStyle::Bayer8,
            DitherStyle::Patterns,
            DitherStyle::Dots,
            DitherStyle::Lines,
            DitherStyle::Diamonds,
        ] {
            assert!(GpuBackend::dither_accepts(&dither_settings(style)).is_ok(), "{style:?}");
        }
        // Scanlines' default glow is a refusal of its own, and the lines behind it are a second one.
        let glow = GpuBackend::dither_accepts(&dither_settings(DitherStyle::Scanlines)).expect_err("refused");
        assert!(glow.contains("glow"), "{glow}");
        let mut plain = dither_settings(DitherStyle::Scanlines);
        plain.glow = 0.0;
        assert!(GpuBackend::dither_accepts(&plain).is_ok(), "the lines themselves are taken");
    }

    #[test]
    fn a_refused_dither_falls_back_to_the_cpu_whole() {
        let Some(_backend) = gpu_or_skip("a_refused_dither_falls_back_to_the_cpu_whole") else { return };
        let image = effect_test_image(17, 11);
        let settings = crate::filters::FilterSettings {
            dither: dither_settings(crate::filters::DitherStyle::Atkinson),
            ..Default::default()
        };
        assert!(GpuBackend::filter_image(backend().expect("an adapter"), &image, crate::filters::FilterKind::Dither, &settings).is_none());
        // The CPU still runs it, and the answer is the CPU's own.
        let expected = crate::filters::apply_filter(&image, crate::filters::FilterKind::Dither, &settings).expect("the cpu runs it");
        assert!(expected.width() == image.width() && expected.height() == image.height());
    }

    #[test]
    fn the_filters_the_gpu_takes_say_so() {
        let Some(_backend) = gpu_or_skip("the_filters_the_gpu_takes_say_so") else { return };
        assert!(
            GpuBackend::filter_accepts(crate::filters::FilterKind::LensCorrection).is_ok(),
            "the lens correction is taken"
        );
        for kind in [crate::filters::FilterKind::BloomGlow, crate::filters::FilterKind::TonalContrast] {
            assert!(GpuBackend::filter_accepts(kind).is_ok(), "{kind:?} is taken");
        }
        // The vignette joined them with the rounding audit; the dither is judged on its settings.
        assert!(
            GpuBackend::filter_accepts(crate::filters::FilterKind::Vignette).is_ok(),
            "the vignette is taken now"
        );
        assert!(
            GpuBackend::filter_accepts(crate::filters::FilterKind::Dither).is_err(),
            "the dither is refused at the kind level with a reason"
        );
        // The dither's kind alone says nothing: which styles run is a question about its settings.
        let reason = GpuBackend::filter_accepts(crate::filters::FilterKind::Dither).expect_err("dither is judged on its settings");
        assert!(reason.contains("settings"), "{reason}");
    }

    #[test]
    fn every_per_pixel_adjustment_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("every_per_pixel_adjustment_matches_on_the_gpu") else { return };
        type Configure = fn(&mut comp_core::Adjustment);
        let cases: Vec<(&str, comp_core::AdjustmentKind, Configure)> = vec![
            ("invert", comp_core::AdjustmentKind::Invert, |_| {}),
            ("levels", comp_core::AdjustmentKind::Levels, |adjustment| {
                adjustment.levels.ranges[0].black = 20.0;
                adjustment.levels.ranges[0].white = 230.0;
                adjustment.levels.ranges[0].gamma = 1.3;
                adjustment.levels.ranges[1].output_white = 240.0;
            }),
            ("curves", comp_core::AdjustmentKind::Curves, |adjustment| {
                adjustment.curves.channels[0] = vec![
                    comp_core::adjustment::CurvePoint { x: 0.0, y: 12.0 },
                    comp_core::adjustment::CurvePoint { x: 128.0, y: 150.0 },
                    comp_core::adjustment::CurvePoint { x: 255.0, y: 240.0 },
                ];
            }),
            ("exposure", comp_core::AdjustmentKind::Exposure, |adjustment| {
                adjustment.exposure_settings = Some(serde_json::json!({
                    "exposure": 0.8, "offset": 0.05, "gamma": 1.4
                }));
            }),
            ("hue/saturation", comp_core::AdjustmentKind::HueSaturation, |adjustment| {
                adjustment.hue = 40.0;
                adjustment.saturation = 30.0;
                adjustment.lightness = 10.0;
            }),
            ("hue/saturation colorize", comp_core::AdjustmentKind::HueSaturation, |adjustment| {
                adjustment.colorize = true;
                adjustment.hue = 200.0;
                adjustment.saturation = 60.0;
                adjustment.lightness = 15.0;
            }),
            ("gradient map", comp_core::AdjustmentKind::GradientMap, |adjustment| {
                adjustment.gradient_map_settings = Some(serde_json::json!({
                    "shadows": [0.1, 0.0, 0.3], "highlights": [0.9, 0.8, 0.2]
                }));
            }),
            ("black & white", comp_core::AdjustmentKind::BlackWhite, |adjustment| {
                adjustment.black_white_settings = Some(serde_json::json!({
                    "reds": 70.0, "yellows": 40.0, "greens": 90.0,
                    "cyans": 30.0, "blues": 10.0, "magentas": 60.0
                }));
            }),
            ("color balance", comp_core::AdjustmentKind::ColorBalance, |adjustment| {
                adjustment.color_balance_settings = Some(comp_core::adjustment::ColorBalanceSettings {
                    shadow_cyan_red: 30.0,
                    shadow_magenta_green: -20.0,
                    shadow_yellow_blue: 10.0,
                    mid_cyan_red: -15.0,
                    mid_magenta_green: 25.0,
                    mid_yellow_blue: -5.0,
                    highlight_cyan_red: 10.0,
                    highlight_magenta_green: -10.0,
                    highlight_yellow_blue: 20.0,
                    preserve_luminosity: true,
                });
            }),
            ("grain", comp_core::AdjustmentKind::Grain, |adjustment| {
                adjustment.grain_settings = Some(serde_json::json!({
                    "amount": 60.0, "size": 2.0, "roughness": 40.0, "seed": 7
                }));
            }),
            ("add noise", comp_core::AdjustmentKind::AddNoise, |adjustment| {
                adjustment.noise_amount = Some(40.0);
                adjustment.noise_seed = Some(11);
            }),
        ];
        for (name, kind, configure) in cases {
            let document = adjusted_document(kind, configure);
            assert!(gpu_accepts(&document).is_ok(), "{name} is accepted");
            let gpu = match flatten_document_gpu(&document) {
                Some(gpu) => gpu,
                None => panic!("{name} composites on the gpu"),
            };
            assert_document_matches(name, &document, &gpu);
        }
    }

    #[test]
    fn an_identity_adjustment_changes_nothing() {
        let Some(_backend) = gpu_or_skip("an_identity_adjustment_changes_nothing") else { return };
        // The CPU skips a kernel whose settings are the identity; the shader has to skip it too rather than
        // pushing every pixel through a round trip.
        let document = adjusted_document(comp_core::AdjustmentKind::Levels, |_| {});
        let gpu = flatten_document_gpu(&document).expect("an identity adjustment composites on the gpu");
        assert_document_matches("an identity adjustment", &document, &gpu);
        let plain = graded_document(24, 18);
        assert_eq!(gpu, crate::flatten_document(&plain), "the identity leaves the canvas alone");
    }

    #[test]
    fn an_adjustment_over_a_soft_canvas_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_adjustment_over_a_soft_canvas_matches_on_the_gpu") else { return };
        // Every other case here is an opaque canvas, where premultiplied and straight bytes agree. A
        // semi-transparent canvas is where the two representations differ, so it is checked on its own.
        let mut document = document(20, 16);
        let mut layer = layer_with("Canvas", pattern(20, 16, 5));
        layer.image_file = None;
        document.add_layer(layer, None);
        document.add_layer(
            Layer::adjustment("Invert", comp_core::Adjustment::new(comp_core::AdjustmentKind::Invert), 20, 16),
            None,
        );
        let gpu = flatten_document_gpu(&document).expect("a soft canvas composites on the gpu");
        assert_document_matches("a soft canvas", &document, &gpu);
    }


    #[test]
    fn an_adjustment_with_a_mask_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_adjustment_with_a_mask_matches_on_the_gpu") else { return };
        let mut document = graded_document(20, 16);
        let mut adjustment = Layer::adjustment(
            "Masked",
            comp_core::Adjustment::new(comp_core::AdjustmentKind::Invert),
            20,
            16,
        );
        adjustment.mask = Some(std::sync::Arc::new(gradient_mask(20, 16)));
        document.add_layer(adjustment, None);
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a masked adjustment composites on the gpu");
        assert_document_matches("a masked adjustment", &document, &gpu);
    }

    #[test]
    fn an_adjustment_with_an_opacity_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_adjustment_with_an_opacity_matches_on_the_gpu") else { return };
        let mut document = graded_document(20, 16);
        let mut adjustment = Layer::adjustment(
            "Half",
            comp_core::Adjustment::new(comp_core::AdjustmentKind::Invert),
            20,
            16,
        );
        adjustment.opacity = 0.4;
        document.add_layer(adjustment, None);
        let gpu = flatten_document_gpu(&document).expect("a half-opacity adjustment composites on the gpu");
        assert_document_matches("a half-opacity adjustment", &document, &gpu);
    }

    #[test]
    fn an_adjustment_in_a_blend_mode_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_adjustment_in_a_blend_mode_matches_on_the_gpu") else { return };
        // A blend mode runs the adjusted colors against what was under them at full coverage, and shows
        // the result only where the canvas had coverage.
        let mut document = graded_document(20, 16);
        let mut adjustment = Layer::adjustment(
            "Blended",
            comp_core::Adjustment::new(comp_core::AdjustmentKind::Invert),
            20,
            16,
        );
        adjustment.blend = BlendMode::SoftLight;
        document.add_layer(adjustment, None);
        let gpu = flatten_document_gpu(&document).expect("a blended adjustment composites on the gpu");
        assert_document_matches("a blended adjustment", &document, &gpu);
    }

    #[test]
    fn an_adjustment_inside_a_masked_folder_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("an_adjustment_inside_a_masked_folder_matches_on_the_gpu") else { return };
        let mut document = graded_document(20, 16);
        let mut folder = Layer::group("Folder", 20, 16);
        folder.mask = Some(std::sync::Arc::new(Gray8::filled(20, 16, 180)));
        folder.opacity = 0.8;
        let folder_id = folder.id;
        document.add_layer(folder, None);
        document.add_layer(
            Layer::adjustment("Inside", comp_core::Adjustment::new(comp_core::AdjustmentKind::Invert), 20, 16),
            Some(folder_id),
        );
        let gpu = flatten_document_gpu(&document).expect("a folder's adjustment composites on the gpu");
        assert_document_matches("an adjustment in a folder", &document, &gpu);
    }

    #[test]
    fn a_chain_of_adjustments_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_chain_of_adjustments_matches_on_the_gpu") else { return };
        // Adjustments stack on the canvas, so the third one sees what the first two left.
        let mut document = graded_document(24, 18);
        document.add_layer(
            Layer::adjustment("Invert", comp_core::Adjustment::new(comp_core::AdjustmentKind::Invert), 24, 18),
            None,
        );
        let mut levels = comp_core::Adjustment::new(comp_core::AdjustmentKind::Levels);
        levels.levels.ranges[0].gamma = 1.6;
        document.add_layer(Layer::adjustment("Levels", levels, 24, 18), None);
        let mut noise = comp_core::Adjustment::new(comp_core::AdjustmentKind::AddNoise);
        noise.noise_amount = Some(30.0);
        noise.noise_seed = Some(3);
        document.add_layer(Layer::adjustment("Noise", noise, 24, 18), None);
        let gpu = flatten_document_gpu(&document).expect("a chain of adjustments composites on the gpu");
        assert_document_matches("a chain of adjustments", &document, &gpu);
    }

    /// A blur adjustment of either kind, over a graded canvas.
    fn blurred_document(kind: comp_core::AdjustmentKind, configure: impl FnOnce(&mut comp_core::Adjustment)) -> Document {
        let mut document = graded_document(24, 18);
        let mut adjustment = comp_core::Adjustment::new(kind);
        configure(&mut adjustment);
        document.add_layer(Layer::adjustment("Blur", adjustment, 24, 18), None);
        document
    }

    #[test]
    fn every_blur_radius_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("every_blur_radius_matches_on_the_gpu") else { return };
        // A radius below one, one that makes a single tap, and one wide enough to reach past the canvas.
        for radius in [0.4f64, 1.0, 3.5, 8.0] {
            let document = blurred_document(comp_core::AdjustmentKind::GaussianBlur, |adjustment| {
                adjustment.blur_radius = Some(radius);
            });
            assert!(gpu_accepts(&document).is_ok(), "radius {radius} is accepted");
            let gpu = flatten_document_gpu(&document).expect("a gaussian blur composites on the gpu");
            assert_document_matches("a gaussian blur", &document, &gpu);
        }
    }

    #[test]
    fn every_blur_angle_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("every_blur_angle_matches_on_the_gpu") else { return };
        // Straight across, straight down (a negative sine), a diagonal, and one that rounds to a single
        // step so the streak is a copy.
        for (angle, distance) in [(0.0f64, 9.0f64), (90.0, 7.0), (131.0, 12.0), (30.0, 1.5)] {
            let document = blurred_document(comp_core::AdjustmentKind::MotionBlur, |adjustment| {
                adjustment.motion_angle = Some(angle);
                adjustment.motion_distance = Some(distance);
            });
            assert!(gpu_accepts(&document).is_ok(), "angle {angle} is accepted");
            let gpu = flatten_document_gpu(&document).expect("a motion blur composites on the gpu");
            assert_document_matches("a motion blur", &document, &gpu);
        }
    }

    #[test]
    fn a_blur_with_a_mask_and_a_blend_mode_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_blur_with_a_mask_and_a_blend_mode_matches_on_the_gpu") else { return };
        // The blur runs first, then the layer's blend mode and coverage, exactly as adjust_into orders it.
        let mut document = graded_document(24, 18);
        let mut adjustment = Layer::adjustment(
            "Blurred",
            {
                let mut adjustment = comp_core::Adjustment::new(comp_core::AdjustmentKind::GaussianBlur);
                adjustment.blur_radius = Some(2.0);
                adjustment
            },
            24,
            18,
        );
        adjustment.mask = Some(std::sync::Arc::new(gradient_mask(24, 18)));
        adjustment.blend = BlendMode::Multiply;
        adjustment.opacity = 0.6;
        document.add_layer(adjustment, None);
        assert!(gpu_accepts(&document).is_ok());
        let gpu = flatten_document_gpu(&document).expect("a masked blur composites on the gpu");
        assert_document_matches("a masked blur", &document, &gpu);
    }

    #[test]
    fn an_identity_blur_leaves_the_canvas_alone() {
        let Some(_backend) = gpu_or_skip("an_identity_blur_leaves_the_canvas_alone") else { return };
        // A radius of zero, like the CPU's guard, blurs nothing - and the layer's blend and coverage steps
        // still run, which is what makes this worth its own case.
        let document = blurred_document(comp_core::AdjustmentKind::GaussianBlur, |adjustment| {
            adjustment.blur_radius = Some(0.0);
        });
        let gpu = flatten_document_gpu(&document).expect("an identity blur composites on the gpu");
        assert_document_matches("an identity blur", &document, &gpu);
        let plain = graded_document(24, 18);
        assert_eq!(gpu, crate::flatten_document(&plain), "a zero radius leaves the canvas alone");
    }

    #[test]
    fn a_blurred_region_matches_the_whole_render() {
        let Some(_backend) = gpu_or_skip("a_blurred_region_matches_the_whole_render") else { return };
        // The region renderer pads a rectangle by the blur's reach before rendering it, so a blur that
        // spreads into the rectangle from outside still lands on the same pixels.
        let mut document = graded_document(48, 32);
        let mut blur = comp_core::Adjustment::new(comp_core::AdjustmentKind::GaussianBlur);
        blur.blur_radius = Some(3.0);
        document.add_layer(Layer::adjustment("Blur", blur, 48, 32), None);
        for bounds in [(20i64, 13i64, 9u32, 7u32), (0, 0, 48, 32), (40, 3, 8, 26)] {
            let region = crate::flatten_region(&document, bounds);
            let whole = crate::flatten_document(&document);
            for row in 0..bounds.3 as i64 {
                for column in 0..bounds.2 as i64 {
                    let x = bounds.0 + column;
                    let y = bounds.1 + row;
                    assert_eq!(
                        region.get(column as u32, row as u32),
                        whole.get(x as u32, y as u32),
                        "region {bounds:?} at ({column},{row})"
                    );
                }
            }
        }
    }

    /// placements. Run with --ignored --nocapture.
    #[test]
    #[ignore = "report; run with --ignored --nocapture"]
    fn report_gpu_fidelity() {
        let Some(_backend) = backend() else {
            println!("no GPU backend: {:?}", unavailability());
            return;
        };
        let show = |label: &str, document: &Document| match (gpu_accepts(document), flatten_document_gpu(document)) {
            (Ok(()), Some(gpu)) => {
                let worst = assert_document_within(label, document, &gpu, 255);
                println!("{label:<32} on the gpu, worst {worst}");
            }
            (Err(reason), _) => println!("{label:<32} refused: {reason}"),
            (Ok(()), None) => println!("{label:<32} accepted but returned nothing"),
        };

        let mut masked = document(64, 64);
        let mut layer = layer_with("Masked", pattern(64, 64, 1));
        layer.mask = Some(std::sync::Arc::new(gradient_mask(64, 64)));
        masked.add_layer(layer, None);
        show("one masked layer", &masked);

        let mut two = document(64, 64);
        two.add_layer(layer_with("Base", opaque_pattern(64, 64, 1)), None);
        let mut lower = layer_with("Lower", pattern(64, 64, 4));
        lower.mask = Some(std::sync::Arc::new(gradient_mask(64, 64)));
        lower.blend = BlendMode::Multiply;
        lower.opacity = 0.7;
        two.add_layer(lower, None);
        let mut upper = layer_with("Upper", pattern(64, 64, 7));
        upper.mask = Some(std::sync::Arc::new(inverted_gradient_mask(64, 64)));
        upper.blend = BlendMode::Screen;
        two.add_layer(upper, None);
        show("two different masks", &two);

        let mut chain = document(64, 64);
        let mut base = layer_with("Base", pattern(64, 64, 2));
        base.mask = Some(std::sync::Arc::new(gradient_mask(64, 64)));
        let base_id = base.id;
        chain.add_layer(base, None);
        let mut middle = layer_with("Middle", pattern(64, 64, 5));
        middle.mask_source = Some(base_id);
        let middle_id = middle.id;
        chain.add_layer(middle, None);
        let mut top = layer_with("Top", pattern(64, 64, 8));
        top.mask_source = Some(middle_id);
        top.blend = BlendMode::Multiply;
        chain.add_layer(top, None);
        show("a three-layer clip chain", &chain);

        for (label, sampling, rotation, flip, size, origin) in [
            ("offset 1:1, nearest", Sampling::Nearest, 0.0, false, (16.0, 12.0), (9.0, 6.0)),
            ("2x enlargement, nearest", Sampling::Nearest, 0.0, false, (32.0, 24.0), (4.0, 8.0)),
            ("half size, smooth", Sampling::Smooth, 0.0, false, (8.0, 6.0), (4.0, 4.0)),
            ("quarter turn, nearest", Sampling::Nearest, 90.0, false, (16.0, 16.0), (16.0, 16.0)),
            ("15 degree turn, smooth", Sampling::Smooth, 15.0, false, (20.0, 20.0), (14.0, 15.0)),
            ("15 degree turn, high quality", Sampling::HighQuality, 15.0, false, (20.0, 20.0), (14.0, 15.0)),
            ("enlargement, high quality", Sampling::HighQuality, 0.0, false, (32.0, 32.0), (6.25, 7.5)),
            ("enlargement, smooth", Sampling::Smooth, 0.0, false, (32.0, 32.0), (6.25, 7.5)),
            ("flipped, nearest", Sampling::Nearest, 0.0, true, (64.0, 64.0), (0.0, 0.0)),
        ] {
            let mut document = document(64, 64);
            document.add_layer(layer_with("Backdrop", opaque_pattern(64, 64, 3)), None);
            let layer = placed_layer("Placed", 16, 12, 31, origin, size, rotation, flip, sampling);
            document.add_layer(layer, None);
            show(label, &document);
        }
    }


    #[test]
    fn a_blur_over_a_soft_canvas_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_blur_over_a_soft_canvas_matches_on_the_gpu") else { return };
        // A semi-transparent canvas is where straight and premultiplied bytes differ, and the blur's
        // premultiplied pass is where that shows.
        let mut document = document(20, 16);
        let mut layer = layer_with("Canvas", pattern(20, 16, 5));
        layer.image_file = None;
        document.add_layer(layer, None);
        let mut blur = comp_core::Adjustment::new(comp_core::AdjustmentKind::GaussianBlur);
        blur.blur_radius = Some(1.5);
        document.add_layer(Layer::adjustment("Blur", blur, 20, 16), None);
        let gpu = flatten_document_gpu(&document).expect("a blurred soft canvas composites on the gpu");
        assert_document_matches("a soft blurred canvas", &document, &gpu);
    }

    #[test]
    fn a_blur_inside_a_masked_folder_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_blur_inside_a_masked_folder_matches_on_the_gpu") else { return };
        let mut document = graded_document(20, 16);
        let mut folder = Layer::group("Folder", 20, 16);
        folder.mask = Some(std::sync::Arc::new(Gray8::filled(20, 16, 150)));
        folder.opacity = 0.75;
        let folder_id = folder.id;
        document.add_layer(folder, None);
        let mut blur = comp_core::Adjustment::new(comp_core::AdjustmentKind::GaussianBlur);
        blur.blur_radius = Some(2.0);
        document.add_layer(Layer::adjustment("Blur", blur, 20, 16), Some(folder_id));
        let gpu = flatten_document_gpu(&document).expect("a folder's blur composites on the gpu");
        assert_document_matches("a blur in a folder", &document, &gpu);
    }

    #[test]
    fn a_fractional_angle_motion_blur_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_fractional_angle_motion_blur_matches_on_the_gpu") else { return };
        // The CPU walks fractional sample points through a transparent bilinear read, so the shader has to
        // sample the same way rather than snapping to pixels.
        let document = blurred_document(comp_core::AdjustmentKind::MotionBlur, |adjustment| {
            adjustment.motion_angle = Some(45.5);
            adjustment.motion_distance = Some(11.0);
        });
        let gpu = flatten_document_gpu(&document).expect("a fractional streak composites on the gpu");
        assert_document_matches("a fractional streak", &document, &gpu);
    }

    #[test]
    fn a_chain_of_blurs_matches_on_the_gpu() {
        let Some(_backend) = gpu_or_skip("a_chain_of_blurs_matches_on_the_gpu") else { return };
        // Two blurs and a colour move between them: each pass sees what the last one left, on both sides.
        let mut document = graded_document(24, 18);
        let mut first = comp_core::Adjustment::new(comp_core::AdjustmentKind::GaussianBlur);
        first.blur_radius = Some(1.5);
        document.add_layer(Layer::adjustment("Blur", first, 24, 18), None);
        document.add_layer(
            Layer::adjustment("Invert", comp_core::Adjustment::new(comp_core::AdjustmentKind::Invert), 24, 18),
            None,
        );
        let mut second = comp_core::Adjustment::new(comp_core::AdjustmentKind::MotionBlur);
        second.motion_angle = Some(20.0);
        second.motion_distance = Some(6.0);
        document.add_layer(Layer::adjustment("Streak", second, 24, 18), None);
        let gpu = flatten_document_gpu(&document).expect("a chain of blurs composites on the gpu");
        assert_document_matches("a chain of blurs", &document, &gpu);
    }

    #[test]
    fn a_document_of_ten_layers_agrees_with_the_cpu() {
        let Some(_backend) = gpu_or_skip("a_document_of_ten_layers_agrees_with_the_cpu") else { return };
        let mut document = document(12, 12);
        let modes = [
            BlendMode::Normal,
            BlendMode::Multiply,
            BlendMode::Screen,
            BlendMode::Overlay,
            BlendMode::SoftLight,
            BlendMode::ColorDodge,
            BlendMode::Difference,
            BlendMode::HardMix,
            BlendMode::Color,
            BlendMode::Luminosity,
        ];
        for (index, mode) in modes.into_iter().enumerate() {
            let mut layer = layer_with(&format!("Layer {index}"), pattern(12, 12, index as u32 + 1));
            layer.blend = mode;
            layer.opacity = 0.5 + (index as f64) * 0.05;
            document.add_layer(layer, None);
        }
        let gpu = flatten_document_gpu(&document).expect("a plain stack runs on the GPU");
        assert!(worst_difference(&crate::flatten_document(&document), &gpu) <= 1);
    }
}