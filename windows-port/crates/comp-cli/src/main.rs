//! \`compc\`: the command line tool for \`.comp\` projects.
//!
//! It exposes the same format contract the editor uses, so scripts and agents can inspect, build and
//! render projects without a window — the Windows counterpart of the macOS app's document package.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use comp_core::bitmap::Bitmap8;
use comp_core::document::Document;
use comp_core::layer::Layer;
use comp_core::manifest::Manifest;
use comp_core::{store, Error, ErrorSource};

#[derive(Parser, Debug)]
#[command(name = "compc", version, about = "Work with Compositor (.comp) projects")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum UpdateAction {
    /// Compare the running build against a release manifest.
    Check {
        manifest: PathBuf,
        /// The running version; defaults to this build's version.
        #[arg(long)]
        current: Option<String>,
        #[arg(long, default_value = "portable")]
        channel: String,
    },
    /// Check a downloaded directory against a release manifest.
    Verify {
        manifest: PathBuf,
        #[arg(long)]
        dir: PathBuf,
    },
    /// Hash a directory and write the manifest that describes it.
    Describe {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long)]
        version: String,
        #[arg(long, default_value = "compositor-windows")]
        name: String,
        #[arg(long, default_value = "portable")]
        channel: String,
        /// Where the payload can be fetched, stored in the manifest.
        #[arg(long)]
        url: Option<String>,
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Replace a binary with a staged one, parking the previous build beside it.
    Apply {
        #[arg(long)]
        staged: PathBuf,
        #[arg(long)]
        target: PathBuf,
    },
    /// Report whether the last update finished, and clean up the parked build.
    Status {
        #[arg(long)]
        target: PathBuf,
        /// Remove the parked build once the new one has started cleanly.
        #[arg(long)]
        cleanup: bool,
    },
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Print a document's metadata.
    Info {
        package: PathBuf,
        /// Print the manifest as JSON instead of a summary.
        #[arg(long)]
        json: bool,
    },
    /// List layers, bottom to top.
    Layers { package: PathBuf },
    /// Check that a package loads, and report why it does not.
    Validate { package: PathBuf },
    /// Create an empty project, optionally filled with one color.
    Create {
        package: PathBuf,
        #[arg(long)]
        width: u32,
        #[arg(long)]
        height: u32,
        /// A hex color such as ff8800 or ff880080; omit for a transparent layer.
        #[arg(long)]
        color: Option<String>,
        #[arg(long, default_value = "Background")]
        name: String,
        /// Pixels per inch stored in the manifest.
        #[arg(long, default_value_t = 72.0)]
        resolution: f64,
    },
    /// Write one layer's pixels or mask to a PNG.
    Extract {
        package: PathBuf,
        /// A layer id or a layer name.
        #[arg(long)]
        layer: String,
        #[arg(long)]
        mask: bool,
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Composite a project and write a PNG.
    Render {
        package: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
        /// Use the GPU for the layers it can take, falling back as a whole otherwise.
        #[arg(long)]
        gpu: bool,
        /// Composite only this rectangle, as x,y,width,height, the way the editor redraws a dirty area.
        /// Negative coordinates are allowed, so the value may start with a dash.
        #[arg(long, allow_hyphen_values = true)]
        region: Option<String>,
    },
    /// Load a project and write it back out, which is what saving from the editor does.
    Resave {
        package: PathBuf,
        output: PathBuf,
    },
    /// Report the compositing backends this build can use, and whether a project can run on the GPU.
    Backends {
        /// A project to check; without it, only the available backends are reported.
        package: Option<PathBuf>,
    },
    /// Composite a project and write a JPEG.
    Export {
        package: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
        /// JPEG quality, 1-100.
        #[arg(long, default_value_t = 92)]
        quality: u8,
    },
    /// Build a project from an image file, as one layer.
    Import {
        image: PathBuf,
        package: PathBuf,
        /// Canvas size; defaults to the image's own size.
        #[arg(long)]
        width: Option<u32>,
        #[arg(long)]
        height: Option<u32>,
        #[arg(long, default_value = "Imported")]
        name: String,
    },
    /// Read a Photoshop document into a project.
    Psd {
        psd: PathBuf,
        package: PathBuf,
    },
    /// Write a project that exercises every feature the format holds.
    Sample { package: PathBuf },
    /// Apply one filter to an image file.
    Filter {
        input: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
        /// The filter's name, exactly as Compositor spells it, for example "Lens Correction".
        #[arg(long)]
        kind: String,
        /// A JSON file of filter settings; omit for the filter's defaults.
        #[arg(long)]
        settings: Option<PathBuf>,
    },
    /// List the filters this build can apply.
    Filters,
    /// Measure the latency of a brush stroke and of compositing what it changed.
    Bench {
        #[arg(long, default_value_t = 4000)]
        canvas: u32,
        #[arg(long, default_value_t = 800.0)]
        brush: f64,
        #[arg(long, default_value_t = 100)]
        samples: usize,
        /// Composite the whole canvas every sample instead of just the changed rectangle.
        #[arg(long)]
        full: bool,
    },
    /// Release and update maintenance: check, verify, describe, apply.
    Update {
        #[command(subcommand)]
        action: UpdateAction,
    },
    /// Turn text and shape metadata into pixels, the way the editor does on commit.
    Rasterize {
        package: PathBuf,
        /// Write the result here instead of replacing the project in place.
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Develop an image or raw/DNG file with the Camera Raw pipeline.
    Raw {
        input: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
        /// A JSON file of raw settings; omit for a neutral develop.
        #[arg(long)]
        settings: Option<PathBuf>,
    },
    /// Paint one straight or circular stroke onto a canvas and write it as a PNG.
    ///
    /// This is the engine's public shape as a command: the tip model the editor paints with, over a
    /// path a test can describe without a mouse. tools/verify/brush_oracle.py recomputes the same
    /// stroke from the model in NumPy, so check_brush.ps1 compares two implementations instead of
    /// one implementation with itself.
    Stroke {
        output: PathBuf,
        #[arg(long, default_value_t = 256)]
        width: u32,
        #[arg(long, default_value_t = 192)]
        height: u32,
        /// Tip diameter in document pixels.
        #[arg(long, allow_hyphen_values = true)]
        brush: f64,
        #[arg(long, default_value_t = 1.0, allow_hyphen_values = true)]
        hardness: f64,
        #[arg(long, default_value_t = 1.0, allow_hyphen_values = true)]
        flow: f64,
        #[arg(long, default_value_t = 1.0, allow_hyphen_values = true)]
        opacity: f64,
        /// Dab spacing as a fraction of the diameter; 0 derives it from the hardness.
        #[arg(long, default_value_t = 0.0, allow_hyphen_values = true)]
        spacing: f64,
        /// Paint colour, in the same hex forms --color accepts.
        #[arg(long, default_value = "000000ff")]
        color: String,
        /// Colour of the canvas before the stroke.
        #[arg(long, default_value = "ffffffff")]
        background: String,
        /// line or arc.
        #[arg(long, default_value = "line")]
        path: String,
        /// How many control points describe the path.
        #[arg(long, default_value_t = 2)]
        samples: usize,
        /// Start of a line, or the first end of an arc, as x,y.
        #[arg(long, default_value = "40,96", allow_hyphen_values = true)]
        from: String,
        /// End of a line, as x,y.
        #[arg(long, default_value = "216,96", allow_hyphen_values = true)]
        to: String,
        /// Centre of an arc, as x,y.
        #[arg(long, default_value = "128,96", allow_hyphen_values = true)]
        center: String,
        #[arg(long, default_value_t = 64.0, allow_hyphen_values = true)]
        radius: f64,
        /// Degrees from the +x axis; y grows downward, so this reads clockwise on screen.
        #[arg(long, default_value_t = 0.0, allow_hyphen_values = true)]
        start_deg: f64,
        #[arg(long, default_value_t = 180.0, allow_hyphen_values = true)]
        sweep_deg: f64,
    },
}

/// Everything one @compc stroke@ run needs, so the command stays one call.
struct StrokeRequest {
    width: u32,
    height: u32,
    brush: f64,
    hardness: f64,
    flow: f64,
    opacity: f64,
    spacing: f64,
    color: String,
    background: String,
    path: String,
    samples: usize,
    from: String,
    to: String,
    center: String,
    radius: f64,
    start_deg: f64,
    sweep_deg: f64,
}

/// The name of the file a command was writing, so an export failure can name it instead of saying
/// "an image". The path itself is already in the command line the user typed.
fn output_name(path: &Path) -> Option<&str> {
    path.file_name().and_then(|name| name.to_str())
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("compc: {}", error.user_message());
            // The stage, field, asset and path are what a script would otherwise have to scrape out
            // of the sentence; they go on their own line, and only when the error knows them.
            let mut where_it_went_wrong = vec![format!("stage: {}", error.source().as_str())];
            if let Some(field) = error.field() {
                where_it_went_wrong.push(format!("field: {field}"));
            }
            if let Some(asset) = error.asset() {
                where_it_went_wrong.push(format!("asset: {asset}"));
            }
            if let Some(path) = error.path() {
                where_it_went_wrong.push(format!("path: {path}"));
            }
            if let (Some(line), Some(column)) = (error.line(), error.column()) {
                where_it_went_wrong.push(format!("at: line {line}, column {column}"));
            }
            if where_it_went_wrong.len() > 1 {
                eprintln!("compc: {}", where_it_went_wrong.join(", "));
            }
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<(), Error> {
    match cli.command {
        Command::Info { package, json } => info(&package, json),
        Command::Layers { package } => layers(&package),
        Command::Validate { package } => validate(&package),
        Command::Create { package, width, height, color, name, resolution } => {
            create(&package, width, height, color.as_deref(), &name, resolution)
        }
        Command::Extract { package, layer, mask, output } => extract(&package, &layer, mask, &output),
        Command::Render { package, output, gpu, region } => {
            render(&package, &output, gpu, region.as_deref())
        }
        Command::Resave { package, output } => {
            let document = store::load(&package)?;
            store::save(&document, &output)?;
            println!("resaved {} -> {}", package.display(), output.display());
            Ok(())
        }
        Command::Backends { package } => {
            match comp_render::gpu::describe() {
                Some(adapter) => println!("gpu: {adapter}"),
                None => println!(
                    "gpu: unavailable ({})",
                    comp_render::gpu::unavailability().unwrap_or("no reason reported")
                ),
            }
            println!("cpu: always available, the reference implementation");
            if let Some(package) = package {
                let document = store::load(&package)?;
                match comp_render::gpu::gpu_accepts(&document) {
                    Ok(()) => println!("this project: the whole document can composite on the gpu"),
                    Err(reason) => println!("this project: the cpu path is required ({reason})"),
                }
            }
            Ok(())
        }
        Command::Export { package, output, quality } => export(&package, &output, quality),
        Command::Import { image, package, width, height, name } => {
            import(&image, &package, width, height, &name)
        }
        Command::Psd { psd: source, package } => psd(&source, &package),
        Command::Sample { package } => sample(&package),
        Command::Filter { input, output, kind, settings } => {
            filter(&input, &output, &kind, settings.as_deref())
        }
        Command::Bench { canvas, brush, samples, full } => bench(canvas, brush, samples, full),
        Command::Filters => {
            for kind in comp_render::filters::FilterKind::ALL {
                println!("{}", kind.as_str());
            }
            Ok(())
        }
        Command::Update { action } => update(action),
        Command::Rasterize { package, output } => rasterize(&package, output.as_deref()),
        Command::Raw { input, output, settings } => raw(&input, &output, settings.as_deref()),
        Command::Stroke {
            output,
            width,
            height,
            brush,
            hardness,
            flow,
            opacity,
            spacing,
            color,
            background,
            path,
            samples,
            from,
            to,
            center,
            radius,
            start_deg,
            sweep_deg,
        } => stroke(
            &output,
            &StrokeRequest {
                width,
                height,
                brush,
                hardness,
                flow,
                opacity,
                spacing,
                color,
                background,
                path,
                samples,
                from,
                to,
                center,
                radius,
                start_deg,
                sweep_deg,
            },
        ),
    }
}

fn info(package: &Path, as_json: bool) -> Result<(), Error> {
    let document = store::load(package)?;
    if as_json {
        let manifest = Manifest::from_document(&document);
        println!("{}", manifest.to_json()?);
        return Ok(());
    }
    let (images, masks) = document.pixel_counts();
    println!("document   {}", document.id);
    println!("canvas     {} x {} at {} ppi", document.width, document.height, document.resolution);
    println!("version    {} (this build writes {})", document.version, comp_core::CURRENT_VERSION);
    println!("layers     {}", document.layers.len());
    println!("guides     {}", document.guides.len());
    println!("pixels     {images} image, {masks} mask");
    Ok(())
}

fn layers(package: &Path) -> Result<(), Error> {
    let document = store::load(package)?;
    for layer in &document.layers {
        let indent = "  ".repeat(document.depth(layer.id));
        let kind = match layer.kind() {
            comp_core::LayerKind::Group => "group",
            comp_core::LayerKind::Adjustment => "adjustment",
            comp_core::LayerKind::Raster => "raster",
        };
        let pixels = layer
            .image
            .as_ref()
            .map(|image| format!("{}x{}", image.width(), image.height()))
            .unwrap_or_else(|| "-".to_string());
        let mask = if layer.mask.is_some() {
            if layer.mask_enabled {
                " mask"
            } else {
                " mask(off)"
            }
        } else {
            ""
        };
        println!(
            "{indent}{} [{kind}] opacity {:.2} {} {pixels}{mask}",
            layer.name,
            layer.opacity,
            layer.blend.as_str()
        );
    }
    Ok(())
}

fn validate(package: &Path) -> Result<(), Error> {
    let loaded = store::load_project(package)?;
    println!(
        "ok: {} layers, {}x{}, digest {}",
        loaded.document.layers.len(),
        loaded.document.width,
        loaded.document.height,
        &loaded.digest[..16]
    );
    Ok(())
}

fn create(
    package: &Path,
    width: u32,
    height: u32,
    color: Option<&str>,
    name: &str,
    resolution: f64,
) -> Result<(), Error> {
    if !(1..=comp_core::limits::MAX_SIDE).contains(&width)
        || !(1..=comp_core::limits::MAX_SIDE).contains(&height)
    {
        return Err(Error::TooLarge(format!("{width}x{height}")));
    }
    let mut document = Document::new(width, height);
    document.resolution = resolution;
    let mut layer = Layer::raster(name.to_string(), width, height);
    layer.image = Some(std::sync::Arc::new(match color {
        Some(text) => Bitmap8::filled(width, height, parse_color(text)?),
        None => Bitmap8::new(width, height),
    }));
    layer.image_file = Some(layer.expected_image_file());
    document.active_layer = Some(layer.id);
    document.layers.push(layer);
    store::save(&document, package)?;
    println!("created {}", package.display());
    Ok(())
}

/// Accepts RGB, RGBA and RRGGBBAA hex, with or without a leading #.
///
/// A value the user typed is reported as what it is. Blaming a damaged project for a mistyped colour
/// sends whoever runs this looking in the wrong place.
pub fn parse_color(text: &str) -> Result<[u8; 4], Error> {
    let refusal = || {
        Error::failed(
            ErrorSource::Other,
            format!("{text} is not a hex colour: use ff8800, ff880080, #ff8800 or the same in three digits"),
        )
    };
    let digits: Vec<u8> = text
        .trim_start_matches('#')
        .chars()
        .map(|c| c.to_digit(16).map(|v| v as u8))
        .collect::<Option<Vec<u8>>>()
        .ok_or_else(refusal)?;
    let value = |slice: &[u8]| -> u8 { slice[0] * 16 + slice[1] };
    match digits.len() {
        3 => Ok([value(&[digits[0], digits[0]]), value(&[digits[1], digits[1]]), value(&[digits[2], digits[2]]), 255]),
        4 => Ok([
            value(&[digits[0], digits[0]]),
            value(&[digits[1], digits[1]]),
            value(&[digits[2], digits[2]]),
            value(&[digits[3], digits[3]]),
        ]),
        6 => Ok([value(&digits[0..2]), value(&digits[2..4]), value(&digits[4..6]), 255]),
        8 => Ok([value(&digits[0..2]), value(&digits[2..4]), value(&digits[4..6]), value(&digits[6..8])]),
        _ => Err(refusal()),
    }
}

fn find_layer<'a>(document: &'a Document, key: &str) -> Result<&'a Layer, Error> {
    if let Ok(id) = uuid::Uuid::parse_str(key) {
        if let Some(layer) = document.layer(id) {
            return Ok(layer);
        }
    }
    document
        .layers
        .iter()
        .find(|layer| layer.name == key)
        .ok_or_else(|| {
            Error::failed(
                ErrorSource::Other,
                format!(
                    "there is no layer named or identified by {key}; use --help on layers to list them, or pass a layer id"
                ),
            )
        })
}

fn extract(package: &Path, key: &str, mask: bool, output: &Path) -> Result<(), Error> {
    let document = store::load(package)?;
    let layer = find_layer(&document, key)?;
    let bytes = if mask {
        let mask = layer.mask.as_ref().ok_or_else(|| {
            Error::failed(
                ErrorSource::Other,
                format!("the layer {} has no mask to extract", layer.name),
            )
        })?;
        comp_core::png_io::encode_gray8(mask)?
    } else {
        let image = layer.image.as_ref().ok_or_else(|| {
            Error::failed(
                ErrorSource::Other,
                format!("the layer {} has no pixels to extract", layer.name),
            )
        })?;
        comp_core::png_io::encode_rgba8(image)?
    };
    std::fs::write(output, bytes)?;
    println!("wrote {}", output.display());
    Ok(())
}

fn render(package: &Path, output: &Path, gpu: bool, region: Option<&str>) -> Result<(), Error> {
    let document = store::load(package)?;
    if let Some(text) = region {
        let bounds = parse_region(text)?;
        let pixels = comp_render::flatten_region(&document, bounds);
        let bytes = comp_core::png_io::encode_rgba8(&pixels)?;
        std::fs::write(output, bytes)?;
        println!(
            "rendered {} region {}x{} at {},{} -> {}",
            package.display(),
            bounds.2,
            bounds.3,
            bounds.0,
            bounds.1,
            output.display()
        );
        return Ok(());
    }
    // The GPU path only takes a document it can composite entirely; the CPU answer is the reference
    // either way, so a document the GPU cannot handle simply renders on the CPU.
    let flattened = if gpu {
        // Asking the GPU first and falling back here — rather than inside the renderer — is what makes
        // the choice visible: a check can then tell a GPU render from a silent fallback.
        match comp_render::gpu::flatten_document_gpu(&document) {
            Some(bitmap) => {
                println!("  composited on the gpu");
                bitmap
            }
            None => {
                println!(
                    "  composited on the cpu ({})",
                    comp_render::gpu::unavailability().unwrap_or("this document needs the cpu path")
                );
                comp_render::flatten_document(&document)
            }
        }
    } else {
        comp_render::flatten_document(&document)
    };
    let bytes = comp_core::png_io::encode_rgba8(&flattened)?;
    std::fs::write(output, bytes)?;
    println!(
        "rendered {} -> {}{}",
        package.display(),
        output.display(),
        if gpu { " (gpu preferred)" } else { "" }
    );
    Ok(())
}

fn export(package: &Path, output: &Path, quality: u8) -> Result<(), Error> {
    if !(1..=100).contains(&quality) {
        return Err(Error::failed(
            ErrorSource::Other,
            format!("JPEG quality {quality} is outside 1-100"),
        ));
    }
    let document = store::load(package)?;
    let flattened = comp_render::flatten_document(&document);
    comp_io::export_jpeg(&flattened, output, quality, document.resolution)
        .map_err(|error| Error::encode_failed(output_name(output), error.to_string()))?;
    println!("exported {} -> {}", package.display(), output.display());
    Ok(())
}

fn import(image: &Path, package: &Path, width: Option<u32>, height: Option<u32>, name: &str) -> Result<(), Error> {
    let pixels = comp_io::import_image(image).map_err(|error| Error::Decode(error.to_string()))?;
    let canvas_width = width.unwrap_or_else(|| pixels.width());
    let canvas_height = height.unwrap_or_else(|| pixels.height());
    if canvas_width < pixels.width() || canvas_height < pixels.height() {
        return Err(Error::TooLarge(format!(
            "canvas {canvas_width}x{canvas_height} is smaller than the image {}x{}",
            pixels.width(),
            pixels.height()
        )));
    }
    let mut document = Document::new(canvas_width, canvas_height);
    let mut layer = Layer::raster(name.to_string(), canvas_width, canvas_height);
    layer.image = Some(std::sync::Arc::new(pixels));
    layer.image_file = Some(layer.expected_image_file());
    document.active_layer = Some(layer.id);
    document.layers.push(layer);
    store::save(&document, package)?;
    println!("imported {} -> {}", image.display(), package.display());
    Ok(())
}

/// Develops an image through the Camera Raw pipeline. Camera raw files (NEF, CR2, CR3, ARW, RAF,
/// DNG with sensor data, …) go through the pure-Rust sensor decoder; anything else is an ordinary
/// image and the regular importers read it.
fn raw(input: &Path, output: &Path, settings_path: Option<&Path>) -> Result<(), Error> {
    let settings: comp_raw::RawSettings = match settings_path {
        Some(path) => {
            let value: serde_json::Value = serde_json::from_slice(&std::fs::read(path)?)?;
            // Serde ignores unknown keys, so a typo would silently develop a neutral image.
            let known = serde_json::to_value(comp_raw::RawSettings::default())?;
            let unknown = unknown_keys(&value, &known, "");
            if !unknown.is_empty() {
                return Err(Error::Decode(format!(
                    "unknown raw settings: {}",
                    unknown.join(", ")
                )));
            }
            serde_json::from_value(value)?
        }
        None => comp_raw::RawSettings::default(),
    };
    if !settings.is_valid() {
        return Err(Error::failed(
            ErrorSource::Other,
            "the raw settings are out of range for this build",
        ));
    }
    // A vendor raw extension is sensor data by definition, so it goes to the sensor decoder, which
    // also reports what the camera recorded. Everything else is an ordinary image first: the regular
    // importers read it, and a file they refuse is handed to the raw decoder, which names whatever it
    // could not do (an unknown camera, an unsupported compression, a damaged frame).
    let extension = input
        .extension()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    let pixels = if comp_raw::needs_demosaic_engine(&extension) {
        let decoded = comp_raw::decode_raw_file(input).map_err(|error| Error::Decode(error.to_string()))?;
        report_decode(&decoded);
        decoded.image
    } else {
        match comp_io::import_image(input) {
            Ok(bitmap) => bitmap,
            Err(_) => {
                let decoded = comp_raw::decode_raw_file(input).map_err(|error| Error::Decode(error.to_string()))?;
                report_decode(&decoded);
                decoded.image
            }
        }
    };
    let developed = comp_raw::develop(&pixels, &settings);
    comp_io::export_png(&developed, output, 72.0)
        .map_err(|error| Error::encode_failed(output_name(output), error.to_string()))?;
    println!("developed {} -> {}", input.display(), output.display());
    Ok(())
}

/// Says which backend read a raw file and what the file said about the shot, so a surprising develop
/// can be traced back to the metadata it started from.
fn report_decode(decoded: &comp_raw::DecodedImage) {
    match decoded.metadata() {
        Some(metadata) => {
            println!(
                "decoded with the {} decoder: {} {} ({}x{}, CFA {}, {} channel(s), black {:?}, white {:?}, \
white balance {:?} from {:?}, matrix from {:?})",
                match metadata.engine {
                    comp_raw::SensorEngine::Rawloader => "pure-Rust",
                    comp_raw::SensorEngine::LibRaw => "LibRaw",
                },
                metadata.clean_make,
                metadata.clean_model,
                metadata.width,
                metadata.height,
                if metadata.cfa.is_empty() { "none" } else { metadata.cfa.as_str() },
                metadata.channels,
                metadata.black_levels,
                metadata.white_levels,
                metadata.white_balance,
                metadata.white_balance_source,
                metadata.matrix_source,
            );
            if !metadata.decoder.is_empty() {
                println!("  LibRaw used {}", metadata.decoder);
            }
            if let Some(reason) = &metadata.fallback_reason {
                println!("  the pure-Rust decoder was tried first and said: {reason}");
            }
        }
        None => println!("decoded with the DNG/TIFF container reader (no sensor metadata)"),
    }
    if !comp_raw::libraw_available() {
        println!("  (no supplementary decoder in this build: CR3, DNG lossy JPEG and unknown camera bodies are refused)");
    }
}

/// Measures the loop a painter feels: one pointer sample, then the pixels it changed.
///
/// The macOS app's target is a 16 ms budget between a pointer sample and the canvas showing it
/// (docs/brush-performance.md records 8-9 ms for mouse-up and 2.6-3.1 ms per pointer update on a
/// 4000x4000 canvas with an 800 px brush). This prints the same shape of number for the Windows
/// engine, so a regression is visible without opening the editor.
fn bench(canvas: u32, brush_size: f64, samples: usize, full: bool) -> Result<(), Error> {
    use std::time::Instant;

    let mut document = Document::with_background(canvas, canvas);
    let layer_id = document.layers[0].id;
    let brush = comp_brush::Brush {
        size: brush_size,
        hardness: 0.6,
        opacity: 1.0,
        ..comp_brush::Brush::default()
    };
    brush.validate().map_err(|error| Error::Message(error.to_string()))?;
    let engine = comp_brush::BrushEngine::new(brush);

    let step = (canvas as f64 * 0.6) / samples.max(1) as f64;
    let mut session = engine
        .begin_stroke(comp_core::PointF::new(canvas as f64 * 0.2, canvas as f64 * 0.2))
        .map_err(|error| Error::Message(error.to_string()))?;

    let mut brush_times = Vec::with_capacity(samples);
    let mut composite_times = Vec::with_capacity(samples);
    let mut region: Option<((i64, i64, u32, u32), u32)> = None;
    for index in 1..=samples {
        let point = comp_core::PointF::new(
            canvas as f64 * 0.2 + step * index as f64,
            canvas as f64 * 0.2 + step * index as f64 * 0.6,
        );
        let started = Instant::now();
        // Paint into the layer's own pixels. A real editor holds the only reference, so this is a
        // borrow rather than a copy; cloning the buffer per sample would dwarf everything else.
        let outcome = {
            let layer = document.layer_mut(layer_id).ok_or(Error::Invalid)?;
            let image = layer.image.as_mut().ok_or(Error::Invalid)?;
            let pixels = std::sync::Arc::get_mut(image)
                .ok_or_else(|| Error::Message("the layer's pixels are shared; the editor would not be".into()))?;
            session.extend(pixels, point)
        };
        brush_times.push(started.elapsed());

        let started = Instant::now();
        let _ = if full {
            comp_render::flatten_document(&document)
        } else {
            match outcome.bounds {
                Some(bounds) => {
                    region = Some((bounds, (bounds.2 as f64 * bounds.3 as f64).sqrt().round() as u32));
                    comp_render::flatten_region(&document, bounds)
                }
                None => comp_core::Bitmap8::new(1, 1),
            }
        };
        composite_times.push(started.elapsed());
    }
    let finished = {
        let layer = document.layer_mut(layer_id).ok_or(Error::Invalid)?;
        let image = layer.image.as_mut().ok_or(Error::Invalid)?;
        let pixels = std::sync::Arc::get_mut(image).ok_or(Error::Invalid)?;
        session.finish(pixels)
    };
    let _ = finished;

    fn report(label: &str, times: &mut [std::time::Duration]) -> f64 {
        times.sort();
        let at = |fraction: f64| times[((times.len() as f64 - 1.0) * fraction) as usize].as_secs_f64() * 1000.0;
        let median = at(0.5);
        println!(
            "{label:<26} min {:6.2} ms  median {:6.2} ms  p95 {:6.2} ms  max {:6.2} ms",
            times[0].as_secs_f64() * 1000.0,
            median,
            at(0.95),
            times[times.len() - 1].as_secs_f64() * 1000.0
        );
        median
    }

    println!("canvas {canvas}x{canvas}, brush {brush_size} px, {samples} pointer samples");
    let brush_median = report("brush sample", &mut brush_times);
    let composite_median = report(
        if full { "composite (whole canvas)" } else { "composite (changed area)" },
        &mut composite_times,
    );
    if let Some((bounds, side)) = region {
        println!("changed area: {}x{} at {},{} (about {side} px across)", bounds.2, bounds.3, bounds.0, bounds.1);
    }
    let total = brush_median + composite_median;
    println!(
        "\nsample to pixels: {total:.2} ms  (budget 16 ms)  {}",
        if total <= 16.0 { "within budget" } else { "OVER BUDGET" }
    );
    Ok(())
}

/// Parses "x,y,width,height".
fn parse_region(text: &str) -> Result<(i64, i64, u32, u32), Error> {
    let refusal = || {
        Error::failed(
            ErrorSource::Other,
            format!("{text} is not a region: use x,y,width,height, for example 10,20,300,200"),
        )
    };
    let parts: Vec<i64> = text
        .split(',')
        .map(|part| part.trim().parse::<i64>())
        .collect::<std::result::Result<Vec<i64>, _>>()
        .map_err(|_| refusal())?;
    if parts.len() != 4 || parts[2] < 0 || parts[3] < 0 {
        return Err(refusal());
    }
    Ok((parts[0], parts[1], parts[2] as u32, parts[3] as u32))
}

/// Applies one filter to an image file, the same kernel the editor's Filters menu runs.
fn filter(input: &Path, output: &Path, kind: &str, settings_path: Option<&Path>) -> Result<(), Error> {
    let pixels = comp_io::import_image(input).map_err(|error| Error::Decode(error.to_string()))?;
    let kind: comp_render::filters::FilterKind =
        serde_json::from_value(serde_json::Value::String(kind.to_string()))
            .map_err(|_| Error::Message(format!("unknown filter {kind:?}")))?;
    let settings: comp_render::filters::FilterSettings = match settings_path {
        Some(path) => {
            let value: serde_json::Value = serde_json::from_slice(&std::fs::read(path)?)?;
            serde_json::from_value(value)?
        }
        None => Default::default(),
    };
    let filtered = comp_render::filters::apply_filter(&pixels, kind, &settings)
        .map_err(|error| Error::Message(error.to_string()))?;
    comp_io::export_png(&filtered, output, 72.0)
        .map_err(|error| Error::encode_failed(output_name(output), error.to_string()))?;
    println!("filtered {} -> {} ({})", input.display(), output.display(), kind.as_str());
    Ok(())
}

/// Release and update maintenance.
fn update(action: UpdateAction) -> Result<(), Error> {
    match action {
        UpdateAction::Check { manifest, current, channel } => {
            let release = comp_release::UpdateManifest::load(&manifest)
                .map_err(|error| Error::Message(error.to_string()))?;
            let running = current.unwrap_or_else(|| comp_core::VERSION.to_string());
            match release.check(&running, &channel).map_err(|error| Error::Message(error.to_string()))? {
                comp_release::Decision::Available { current, offered } => {
                    println!("update available: {current} -> {offered} ({} files)", release.files.len());
                }
                comp_release::Decision::UpToDate { current, offered } => {
                    println!("up to date: running {current}, published {offered}");
                }
                comp_release::Decision::OtherChannel { channel } => {
                    println!("published on another channel: {channel}");
                }
            }
            Ok(())
        }
        UpdateAction::Verify { manifest, dir } => {
            let release = comp_release::UpdateManifest::load(&manifest)
                .map_err(|error| Error::Message(error.to_string()))?;
            release.verify_directory(&dir).map_err(|error| Error::Message(error.to_string()))?;
            println!("verified {} files in {}", release.files.len(), dir.display());
            Ok(())
        }
        UpdateAction::Describe { dir, version, name, channel, url, output } => {
            let mut release =
                comp_release::UpdateManifest::describe_directory(&name, &version, &channel, &dir)
                    .map_err(|error| Error::Message(error.to_string()))?;
            release.url = url;
            release.published_at = Some(now_utc());
            std::fs::write(&output, release.to_json().map_err(|e| Error::Message(e.to_string()))?)?;
            println!("wrote {} ({} files, version {version})", output.display(), release.files.len());
            Ok(())
        }
        UpdateAction::Apply { staged, target } => {
            comp_release::stage_and_swap(&staged, &target)
                .map_err(|error| Error::Message(error.to_string()))?;
            println!("applied {} -> {}", staged.display(), target.display());
            Ok(())
        }
        UpdateAction::Status { target, cleanup } => {
            if comp_release::update_was_interrupted(&target) {
                println!("a previous build is parked beside {}", target.display());
                if cleanup {
                    comp_release::cleanup_previous(&target)
                        .map_err(|error| Error::Message(error.to_string()))?;
                    println!("removed the parked build");
                }
            } else {
                println!("the last update finished cleanly");
            }
            Ok(())
        }
    }
}

/// An RFC 3339 stamp for a release manifest, from the system clock.
fn now_utc() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    // Days since the epoch to a calendar date, the usual civil-from-days conversion.
    let days = (seconds / 86_400) as i64;
    let (hour, minute, second) = ((seconds / 3600) % 24, (seconds / 60) % 60, seconds % 60);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// Rasterizes every text and shape layer, so the pixels a save stores match the metadata beside them.
fn rasterize(package: &Path, output: Option<&Path>) -> Result<(), Error> {
    let mut document = store::load(package)?;
    let mut library = comp_text::FontLibrary::new();
    let mut committed = 0usize;
    let targets: Vec<uuid::Uuid> = document
        .layers
        .iter()
        .filter(|layer| layer.text.is_some() || layer.shape.is_some())
        .map(|layer| layer.id)
        .collect();
    for id in targets {
        let has_text = document.layer(id).map(|layer| layer.text.is_some()).unwrap_or(false);
        let result = if has_text {
            comp_text::commit_text_layer(&mut document, id, &mut library)
        } else {
            comp_text::commit_shape_layer(&mut document, id)
        };
        match result {
            Ok((width, height)) => {
                committed += 1;
                // The pixels replace the metadata, so the layer box follows the new size, the way the
                // editor reshapes a text or shape layer when it commits an edit.
                if let Some(layer) = document.layer_mut(id) {
                    layer.transform.size = comp_core::SizeF::new(width as f64, height as f64);
                }
                println!("rasterized {} -> {width}x{height}", document.layer(id).map(|l| l.name.clone()).unwrap_or_default());
            }
            Err(error) => eprintln!("compc: {} could not be rasterized: {error}", document.layer(id).map(|l| l.name.clone()).unwrap_or_default()),
        }
    }
    for fallback in library.fallbacks() {
        eprintln!("compc: font {} fell back", fallback.requested);
    }
    if committed == 0 {
        return Err(Error::failed(
            ErrorSource::Other,
            format!("no layer in {} carries text or a shape to rasterize", package.display()),
        ));
    }
    let destination = output.unwrap_or(package);
    store::save(&document, destination)?;
    println!("wrote {}", destination.display());
    Ok(())
}

/// Writes a project using every optional feature, for interop checks and for exercising the editor.
fn sample(package: &Path) -> Result<(), Error> {
    use comp_core::adjustment::{Adjustment, AdjustmentKind};
    use comp_core::effects::{ColorOverlayEffect, LayerEffects, OuterGlowEffect, ShadowEffect, StrokeEffect};
    use comp_core::geom::{Guide, GuideAxis, PointF, SizeF, Transform};
    use comp_core::shape::{ShapeKind, ShapeStyle};
    use comp_core::text::{SizeD, TextColorRun, TextFontRun, TextStyle};

    let (width, height) = (320u32, 200u32);
    let mut document = Document::new(width, height);

    let mut backdrop = Layer::raster("Backdrop", width, height);
    backdrop.image = Some(std::sync::Arc::new(Bitmap8::filled(width, height, [40, 60, 120, 255])));
    backdrop.image_file = Some(backdrop.expected_image_file());
    let backdrop_id = document.add_layer(backdrop, None);

    let group = Layer::group("Folder", width, height);
    let group_id = group.id;
    document.add_layer(group, None);
    document.set_layer_mask(group_id, comp_core::Gray8::filled(width, height, 200));

    let mut pixels = Layer::raster("Pixels", 64, 48);
    pixels.image = Some(std::sync::Arc::new(Bitmap8::filled(64, 48, [230, 120, 40, 255])));
    pixels.image_file = Some(pixels.expected_image_file());
    pixels.transform = Transform {
        origin: PointF::new(20.0, 30.0),
        size: SizeF::new(64.0, 48.0),
        rotation: 15.0,
        flip_x: true,
        flip_y: false,
        sampling: comp_core::Sampling::Smooth,
    };
    pixels.mask = Some(std::sync::Arc::new(comp_core::Gray8::filled(64, 48, 128)));
    pixels.mask_file = Some(pixels.expected_mask_file());
    pixels.effects = Some(LayerEffects {
        stroke: Some(StrokeEffect { size: 3.0, inside: true, ..StrokeEffect::default() }),
        shadow: Some(ShadowEffect::default()),
        color_overlay: Some(ColorOverlayEffect::default()),
        outer_glow: Some(OuterGlowEffect::default()),
        ..LayerEffects::default()
    });
    pixels.blend = comp_core::BlendMode::Multiply;
    pixels.opacity = 0.8;
    let pixels_id = document.add_layer(pixels, Some(group_id));

    let mut clipped = Layer::raster("Clipped", width, height);
    clipped.image = Some(std::sync::Arc::new(Bitmap8::filled(width, height, [90, 200, 120, 200])));
    clipped.image_file = Some(clipped.expected_image_file());
    clipped.mask_source = Some(pixels_id);
    document.add_layer(clipped, Some(group_id));

    let mut text = Layer::raster("Title", width, height);
    text.image = Some(std::sync::Arc::new(Bitmap8::new(width, height)));
    text.image_file = Some(text.expected_image_file());
    text.transform = Transform {
        origin: PointF::new(16.0, 14.0),
        size: SizeF::new(200.0, 60.0),
        rotation: 0.0,
        flip_x: false,
        flip_y: false,
        sampling: comp_core::Sampling::HighQuality,
    };
    text.text = Some(TextStyle {
        content: "Compositor".to_string(),
        font_name: "Helvetica".to_string(),
        font_size: 48.0,
        red: 1.0,
        green: 1.0,
        blue: 1.0,
        box_size: Some(SizeD::new(200.0, 80.0)),
        color_runs: Some(vec![TextColorRun { location: 0, length: 4, red: 1.0, green: 0.4, blue: 0.2 }]),
        font_runs: Some(vec![TextFontRun {
            location: 4,
            length: 6,
            font_name: "Helvetica-Bold".to_string(),
        }]),
        ..TextStyle::default()
    });
    document.add_layer(text, None);

    let mut shape = Layer::raster("Shape", 96, 56);
    shape.image = Some(std::sync::Arc::new(Bitmap8::new(96, 56)));
    shape.image_file = Some(shape.expected_image_file());
    shape.transform = Transform {
        origin: PointF::new(196.0, 118.0),
        size: SizeF::new(96.0, 56.0),
        rotation: 0.0,
        flip_x: false,
        flip_y: false,
        sampling: comp_core::Sampling::HighQuality,
    };
    shape.shape = Some(ShapeStyle {
        kind: ShapeKind::Rectangle,
        red: 0.9,
        green: 0.3,
        blue: 0.4,
        corner_radius: 12.0,
        ..ShapeStyle::default()
    });
    document.add_layer(shape, None);

    let adjustment = Layer::adjustment("Warm Grade", Adjustment::new(AdjustmentKind::ColorBalance), width, height);
    document.add_layer(adjustment, None);

    document.guides.push(Guide { id: uuid::Uuid::new_v4(), axis: GuideAxis::Vertical, position: 160.0 });
    document.guides.push(Guide { id: uuid::Uuid::new_v4(), axis: GuideAxis::Horizontal, position: 100.0 });
    document.active_layer = Some(backdrop_id);
    document.resolution = 300.0;

    store::save(&document, package)?;
    println!(
        "wrote sample {} ({} layers, {} guides)",
        package.display(),
        document.layers.len(),
        document.guides.len()
    );
    Ok(())
}

/// Every key in `given` that `known` does not have, with its path.
fn unknown_keys(given: &serde_json::Value, known: &serde_json::Value, prefix: &str) -> Vec<String> {
    let mut unknown = Vec::new();
    if let (Some(given), Some(known)) = (given.as_object(), known.as_object()) {
        for (key, value) in given {
            match known.get(key) {
                None => unknown.push(format!("{prefix}{key}")),
                Some(known_value) => {
                    unknown.extend(unknown_keys(value, known_value, &format!("{prefix}{key}.")))
                }
            }
        }
    }
    unknown
}

/// One point of the stroke path, written as "x,y".
fn parse_point(text: &str) -> Result<(f64, f64), Error> {
    let refusal = || {
        Error::failed(
            ErrorSource::Other,
            format!("{text} is not a point: use x,y, for example 40,96"),
        )
    };
    let (x, y) = text.split_once(',').ok_or_else(refusal)?;
    let x: f64 = x.trim().parse().map_err(|_| refusal())?;
    let y: f64 = y.trim().parse().map_err(|_| refusal())?;
    if !x.is_finite() || !y.is_finite() {
        return Err(refusal());
    }
    Ok((x, y))
}

/// The control points of a stroke path, in the shape brush_oracle.py also builds.
///
/// A line is `samples` points from `from` to `to`; an arc is `samples` points on a circle around
/// `center`, starting at `start_deg` and turning through `sweep_deg`. Degrees are measured from the
/// +x axis with y growing downward, so a positive sweep reads clockwise on screen. One sample is a
/// click: the point itself.
fn stroke_path(request: &StrokeRequest) -> Result<Vec<comp_core::PointF>, Error> {
    use comp_core::PointF;
    let (fx, fy) = parse_point(&request.from)?;
    if request.samples == 0 {
        return Err(Error::failed(ErrorSource::Other, "--samples must be at least 1"));
    }
    if request.samples == 1 {
        return Ok(vec![PointF::new(fx, fy)]);
    }
    let last = (request.samples - 1) as f64;
    match request.path.as_str() {
        "line" => {
            let (tx, ty) = parse_point(&request.to)?;
            Ok((0..request.samples)
                .map(|index| {
                    let t = index as f64 / last;
                    PointF::new(fx + (tx - fx) * t, fy + (ty - fy) * t)
                })
                .collect())
        }
        "arc" => {
            let (cx, cy) = parse_point(&request.center)?;
            if !request.radius.is_finite() || request.radius <= 0.0 {
                return Err(Error::failed(ErrorSource::Other, "--radius must be above zero"));
            }
            Ok((0..request.samples)
                .map(|index| {
                    let degrees = request.start_deg + request.sweep_deg * (index as f64 / last);
                    let radians = degrees.to_radians();
                    PointF::new(cx + request.radius * radians.cos(), cy + request.radius * radians.sin())
                })
                .collect())
        }
        other => Err(Error::failed(
            ErrorSource::Other,
            format!("{other} is not a path: use line or arc"),
        )),
    }
}

/// Paints one stroke and writes the canvas as a PNG.
fn stroke(output: &Path, request: &StrokeRequest) -> Result<(), Error> {
    let brush = comp_brush::Brush {
        size: request.brush,
        hardness: request.hardness,
        spacing: request.spacing,
        flow: request.flow,
        opacity: request.opacity,
        smoothing: 0.0,
        erase: false,
    };
    brush.validate().map_err(|error| Error::failed(ErrorSource::Other, error.to_string()))?;
    let points = stroke_path(request)?;
    let mut canvas = Bitmap8::filled(request.width, request.height, parse_color(&request.background)?);
    let engine = comp_brush::BrushEngine::new(brush).with_color(parse_color(&request.color)?);
    let outcome = engine.stroke(&mut canvas, &points)?;
    let bytes = comp_core::png_io::encode_rgba8(&canvas)?;
    std::fs::write(output, bytes)?;
    println!(
        "stroked {} points of a {} px tip over {}x{} -> {} ({} segments, path {} px)",
        points.len(),
        request.brush,
        request.width,
        request.height,
        output.display(),
        outcome.dab_count,
        outcome.path_length_milli as f64 / 1000.0
    );
    Ok(())
}

/// Reads a Photoshop document and writes it as a project.
fn psd(psd_path: &Path, package: &Path) -> Result<(), Error> {
    let bytes = std::fs::read(psd_path)?;
    let document = comp_io::read_psd(&bytes).map_err(|error| Error::Decode(error.to_string()))?;
    store::save(&document, package)?;
    println!(
        "read {} -> {} ({} layers, {}x{})",
        psd_path.display(),
        package.display(),
        document.layers.len(),
        document.width,
        document.height
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colors_parse_in_every_accepted_form() {
        assert_eq!(parse_color("#fff").unwrap(), [255, 255, 255, 255]);
        assert_eq!(parse_color("f80").unwrap(), [255, 136, 0, 255]);
        assert_eq!(parse_color("ff8800").unwrap(), [255, 136, 0, 255]);
        assert_eq!(parse_color("ff880080").unwrap(), [255, 136, 0, 128]);
        assert_eq!(parse_color("0000").unwrap(), [0, 0, 0, 0]);
        // Four digits are CSS RGBA shorthand, five are not a color.
        assert_eq!(parse_color("f80a").unwrap(), [255, 136, 0, 170]);
        assert!(parse_color("zzz").is_err());
        assert!(parse_color("ff888").is_err());
        assert!(parse_color("").is_err());
    }

    #[test]
    fn unknown_settings_keys_are_reported_with_their_path() {
        let known = serde_json::json!({"light": {"exposure": 0.0}, "curve": {"rgb": []}});
        let given = serde_json::json!({"light": {"exposure": 1.0, "expsure": 0.5}, "curves": {}});
        let unknown = unknown_keys(&given, &known, "");
        assert!(unknown.contains(&"light.expsure".to_string()));
        assert!(unknown.contains(&"curves".to_string()));
        assert_eq!(unknown.len(), 2);
        assert!(unknown_keys(&serde_json::json!({"light": {"exposure": 1.0}}), &known, "").is_empty());
    }


    #[test]
    fn a_mistyped_argument_is_reported_as_the_argument_it_is() {
        // The wording matters: "this is not a valid Compositor project" for a mistyped colour or
        // region sends whoever ran this looking at the project instead of at their command line.
        let colour = parse_color("zz").unwrap_err();
        assert!(matches!(colour, Error::Failed { .. }), "{colour:?}");
        assert!(colour.to_string().contains("zz"), "{colour}");
        assert!(colour.to_string().contains("hex colour"), "{colour}");
        assert!(!colour.is_coarse(), "a mistyped value is not a damaged project");

        let region = parse_region("2,2").unwrap_err();
        assert!(region.to_string().contains("2,2"), "{region}");
        assert!(region.to_string().contains("x,y,width,height"), "{region}");
        let negative = parse_region("0,0,-4,4").unwrap_err();
        assert!(negative.to_string().contains("x,y,width,height"), "{negative}");
        let text = parse_region("a,b,c,d").unwrap_err();
        assert!(text.to_string().contains("x,y,width,height"), "{text}");
    }

    #[test]
    fn a_region_is_four_numbers_with_a_positive_size() {
        assert_eq!(parse_region("10,20,300,200").unwrap(), (10, 20, 300, 200));
        assert_eq!(parse_region(" -5 , 6 , 7 , 8 ").unwrap(), (-5, 6, 7, 8));
        assert_eq!(parse_region("0,0,0,0").unwrap(), (0, 0, 0, 0));
    }

    #[test]
    fn a_layer_that_is_not_there_is_named_in_the_error() {
        let document = Document::new(8, 8);
        let error = find_layer(&document, "NoSuchLayer").unwrap_err();
        assert!(error.to_string().contains("NoSuchLayer"), "{error}");
    }

    #[test]
    fn a_quality_outside_its_range_says_so() {
        let error = export(Path::new("gone.comp"), Path::new("out.jpg"), 0).unwrap_err();
        assert!(error.to_string().contains("quality 0"), "{error}");
        assert!(error.to_string().contains("1-100"), "{error}");
    }

    #[test]
    fn layer_lookup_accepts_ids_and_names() {
        let mut document = Document::new(8, 8);
        let layer = Layer::raster("Sky", 8, 8);
        let id = layer.id;
        document.layers.push(layer);
        assert!(find_layer(&document, "Sky").is_ok());
        assert!(find_layer(&document, &id.to_string()).is_ok());
        assert!(find_layer(&document, "Nope").is_err());
    }
}
