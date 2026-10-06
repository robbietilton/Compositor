//! Which compositor draws the canvas, and what the status bar says about it.
//!
//! comp-render has two paths: the CPU one that any document takes, and the GPU one that takes a
//! plain stack and is faster on a whole canvas. A stroke repaints a small rectangle, where the GPU's
//! fixed readback costs more than the CPU work it would save, so the choice depends on what is being
//! drawn as well as on what the machine has. This module owns that decision so it can be tested
//! without a device.

/// What the user asked for.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Preference {
    /// Use the GPU wherever it can do the work.
    #[default]
    PreferGpu,
    /// Never use the GPU, for a machine whose driver misbehaves or a reproducible export.
    ForceCpu,
}

impl Preference {
    pub fn label(self) -> &'static str {
        match self {
            Preference::PreferGpu => "Prefer GPU",
            Preference::ForceCpu => "Force CPU",
        }
    }

    /// The other setting, for the toggle.
    pub fn flipped(self) -> Self {
        match self {
            Preference::PreferGpu => Preference::ForceCpu,
            Preference::ForceCpu => Preference::PreferGpu,
        }
    }
}

/// The compositor a render used.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Gpu,
    Cpu,
}

impl Backend {
    pub fn label(self) -> &'static str {
        match self {
            Backend::Gpu => "GPU",
            Backend::Cpu => "CPU",
        }
    }
}

/// What the machine and the document allow, as the renderer sees it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Availability {
    /// The adapter and backend in use, when there is a device.
    pub description: Option<String>,
    /// Why there is no device, when there is none.
    pub reason: Option<String>,
    /// Why this document cannot go to the GPU, when it cannot.
    pub refused: Option<String>,
}

impl Availability {
    /// True when the GPU could take this document right now.
    pub fn usable(&self) -> bool {
        self.description.is_some() && self.refused.is_none()
    }
}

/// Which backend a render should use: a region always the CPU, a whole canvas the GPU when asked for
/// and possible, and the CPU otherwise.
pub fn choose(preference: Preference, region: bool, availability: &Availability) -> Backend {
    if region {
        // A dirty rectangle is a few milliseconds of CPU work; a GPU round trip is not worth it.
        return Backend::Cpu;
    }
    if preference == Preference::ForceCpu {
        return Backend::Cpu;
    }
    if availability.usable() {
        Backend::Gpu
    } else {
        Backend::Cpu
    }
}

/// The line the status bar shows: the device when the GPU is doing the work, and the reason when it
/// is not.
pub fn status_line(preference: Preference, used: Option<Backend>, availability: &Availability) -> String {
    let used = used.unwrap_or_else(|| choose(preference, false, availability));
    match (preference, used, availability.description.as_deref()) {
        (Preference::ForceCpu, _, Some(description)) => format!("CPU (forced) - {description}"),
        (Preference::ForceCpu, _, None) => "CPU (forced)".to_string(),
        (_, Backend::Gpu, Some(description)) => format!("GPU: {description}"),
        (_, _, Some(description)) => match availability.refused.as_deref() {
            Some(refused) => format!("CPU - {refused}"),
            None => format!("CPU - {description}"),
        },
        (_, _, None) => match availability.reason.as_deref() {
            Some(reason) => format!("CPU - no GPU: {reason}"),
            None => "CPU".to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_gpu() -> Availability {
        Availability { description: Some("Test Adapter (Vulkan)".to_string()), ..Default::default() }
    }

    fn without_gpu() -> Availability {
        Availability { reason: Some("no adapter".to_string()), ..Default::default() }
    }

    fn refused() -> Availability {
        Availability {
            description: Some("Test Adapter (Vulkan)".to_string()),
            refused: Some("Blur: adjustment layers are not on the GPU".to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn a_stroke_rectangle_stays_on_the_cpu_whatever_the_machine_has() {
        for preference in [Preference::PreferGpu, Preference::ForceCpu] {
            assert_eq!(choose(preference, true, &with_gpu()), Backend::Cpu);
        }
    }

    #[test]
    fn a_whole_canvas_prefers_the_gpu_when_it_can_take_it() {
        assert_eq!(choose(Preference::PreferGpu, false, &with_gpu()), Backend::Gpu);
        assert_eq!(choose(Preference::PreferGpu, false, &refused()), Backend::Cpu, "the document is refused");
        assert_eq!(choose(Preference::PreferGpu, false, &without_gpu()), Backend::Cpu, "there is no device");
    }

    #[test]
    fn forcing_the_cpu_ignores_a_usable_device() {
        assert_eq!(choose(Preference::ForceCpu, false, &with_gpu()), Backend::Cpu);
        assert_eq!(Preference::ForceCpu.flipped(), Preference::PreferGpu);
        assert_eq!(Preference::PreferGpu.flipped(), Preference::ForceCpu);
    }

    #[test]
    fn the_status_line_names_the_device_when_it_is_drawing() {
        let availability = with_gpu();
        assert_eq!(
            status_line(Preference::PreferGpu, Some(Backend::Gpu), &availability),
            "GPU: Test Adapter (Vulkan)"
        );
        // Before the first render the line still says what the next one will use.
        assert_eq!(
            status_line(Preference::PreferGpu, None, &availability),
            "GPU: Test Adapter (Vulkan)"
        );
    }

    #[test]
    fn the_status_line_explains_a_cpu_choice() {
        assert_eq!(status_line(Preference::PreferGpu, None, &without_gpu()), "CPU - no GPU: no adapter");
        assert_eq!(
            status_line(Preference::PreferGpu, Some(Backend::Cpu), &refused()),
            "CPU - Blur: adjustment layers are not on the GPU"
        );
        assert_eq!(
            status_line(Preference::ForceCpu, Some(Backend::Cpu), &with_gpu()),
            "CPU (forced) - Test Adapter (Vulkan)"
        );
        assert_eq!(status_line(Preference::ForceCpu, None, &without_gpu()), "CPU (forced)");
        assert_eq!(status_line(Preference::PreferGpu, None, &Availability::default()), "CPU");
    }

    #[test]
    fn a_render_that_fell_back_says_so_even_though_the_device_is_there() {
        // The device can refuse after the choice was made; the line follows what actually ran.
        assert_eq!(
            status_line(Preference::PreferGpu, Some(Backend::Cpu), &with_gpu()),
            "CPU - Test Adapter (Vulkan)"
        );
        assert_eq!(
            status_line(Preference::PreferGpu, Some(Backend::Gpu), &refused()),
            "GPU: Test Adapter (Vulkan)",
            "a finished GPU render is reported as one, whatever a later check would say"
        );
    }
}
