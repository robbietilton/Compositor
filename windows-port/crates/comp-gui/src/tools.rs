//! Tool selection and pointer state machine.
//!
//! The machine owns only what the tools decide from raw pointer positions; rasterizing, history and
//! document mutation stay with the caller. That split keeps every transition testable without a
//! window and keeps undo granularity (one step per stroke or drag) explicit.

use egui::{Pos2, Rect, Vec2};

/// The tools the toolbar offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tool {
    Brush,
    Eraser,
    Eyedropper,
    RectSelect,
    Move,
    Text,
    /// Draws a gradient into the selected layer's mask.
    Gradient,
}

impl Tool {
    /// Toolbar order.
    pub const ALL: [Tool; 7] = [
        Tool::Move,
        Tool::RectSelect,
        Tool::Gradient,
        Tool::Brush,
        Tool::Eraser,
        Tool::Eyedropper,
        Tool::Text,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Tool::Brush => "Brush",
            Tool::Eraser => "Eraser",
            Tool::Eyedropper => "Eyedropper",
            Tool::RectSelect => "Rectangular Marquee",
            Tool::Move => "Move",
            Tool::Text => "Text",
            Tool::Gradient => "Gradient",
        }
    }

    /// The single-key shortcut, shown in the tooltip and handled by the shortcut table.
    pub fn key(self) -> char {
        match self {
            Tool::Brush => 'B',
            Tool::Eraser => 'E',
            Tool::Eyedropper => 'I',
            Tool::RectSelect => 'M',
            Tool::Move => 'V',
            Tool::Text => 'T',
            Tool::Gradient => 'G',
        }
    }

    /// True for the tools that paint into layer pixels.
    pub fn paints(self) -> bool {
        matches!(self, Tool::Brush | Tool::Eraser)
    }
}

/// Brush shape settings, shared by the brush and the eraser.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BrushSettings {
    /// Diameter in document pixels.
    pub size: f32,
    /// 0 is a fully feathered edge, 1 a crisp one.
    pub hardness: f32,
    /// 0.01 to 1; a stroke never covers more than this.
    pub opacity: f32,
}

impl Default for BrushSettings {
    fn default() -> Self {
        BrushSettings { size: 24.0, hardness: 0.85, opacity: 1.0 }
    }
}

impl BrushSettings {
    /// Clamps to the ranges the sliders offer so an out-of-range value cannot blank the brush.
    pub fn clamped(mut self) -> Self {
        // 2100 is the engine's largest diameter; clamping here keeps the sliders honest.
        self.size = self.size.clamp(1.0, 2100.0);
        self.hardness = self.hardness.clamp(0.0, 1.0);
        self.opacity = self.opacity.clamp(0.01, 1.0);
        self
    }

    /// Dab spacing in document pixels: an eighth of the diameter, floored so that a small brush
    /// still connects on a fast drag.
    pub fn spacing(&self) -> f32 {
        (self.size * 0.125).max(0.5)
    }
}

/// What a pointer event asks the caller to do.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ToolEffect {
    /// Paint a segment in document space, end points inclusive.
    Paint { from: Pos2, to: Pos2 },
    /// The marquee now covers this document rectangle.
    Selection { rect: Rect },
    /// Translate the active layer by this document-space delta.
    Move { delta: Vec2 },
    /// Sample the composite at this document point.
    Pick { at: Pos2 },
    /// Create or select a text layer at this document point.
    TextClick { at: Pos2 },
    /// A finished gradient drag: fill the mask between these two document points.
    Gradient { from: Pos2, to: Pos2 },
    /// The event changed nothing.
    None,
}

/// The gesture currently in flight.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Gesture {
    Paint { last: Pos2 },
    Marquee { start: Pos2 },
    Move { last: Pos2 },
    Gradient { start: Pos2 },
}

/// Turns pointer events into tool effects.
#[derive(Clone, Debug)]
pub struct ToolMachine {
    tool: Tool,
    gesture: Option<Gesture>,
}

impl Default for ToolMachine {
    fn default() -> Self {
        ToolMachine { tool: Tool::Brush, gesture: None }
    }
}

impl ToolMachine {
    pub fn tool(&self) -> Tool {
        self.tool
    }

    /// Switching tools abandons a gesture in flight, the way a modal tool switch does.
    pub fn set_tool(&mut self, tool: Tool) {
        self.tool = tool;
        self.gesture = None;
    }

    pub fn is_dragging(&self) -> bool {
        self.gesture.is_some()
    }

    /// Abandons the gesture without producing an effect, for Escape or a lost pointer.
    pub fn cancel(&mut self) {
        self.gesture = None;
    }

    pub fn press(&mut self, doc: Pos2) -> ToolEffect {
        self.gesture = None;
        match self.tool {
            Tool::Brush | Tool::Eraser => {
                self.gesture = Some(Gesture::Paint { last: doc });
                ToolEffect::Paint { from: doc, to: doc }
            }
            Tool::RectSelect => {
                self.gesture = Some(Gesture::Marquee { start: doc });
                ToolEffect::Selection { rect: Rect::from_two_pos(doc, doc) }
            }
            Tool::Move => {
                self.gesture = Some(Gesture::Move { last: doc });
                ToolEffect::None
            }
            Tool::Eyedropper => {
                self.gesture = None;
                ToolEffect::Pick { at: doc }
            }
            Tool::Text => {
                // Text is a click tool: dragging does not lay anything down or move a box.
                self.gesture = None;
                ToolEffect::TextClick { at: doc }
            }
            Tool::Gradient => {
                // The fill happens on release, when the drag has said where both ends are.
                self.gesture = Some(Gesture::Gradient { start: doc });
                ToolEffect::None
            }
        }
    }

    pub fn drag(&mut self, doc: Pos2) -> ToolEffect {
        match self.gesture {
            Some(Gesture::Paint { last }) => {
                self.gesture = Some(Gesture::Paint { last: doc });
                ToolEffect::Paint { from: last, to: doc }
            }
            Some(Gesture::Marquee { start }) => ToolEffect::Selection { rect: Rect::from_two_pos(start, doc) },
            Some(Gesture::Move { last }) => {
                self.gesture = Some(Gesture::Move { last: doc });
                ToolEffect::Move { delta: doc - last }
            }
            Some(Gesture::Gradient { .. }) => ToolEffect::None,
            None => ToolEffect::None,
        }
    }

    /// Ends the gesture. Painting and moving report nothing here: the caller commits them once,
    /// when the whole stroke or drag is over.
    pub fn release(&mut self, doc: Pos2) -> ToolEffect {
        match self.gesture.take() {
            Some(Gesture::Marquee { start }) => ToolEffect::Selection { rect: Rect::from_two_pos(start, doc) },
            Some(Gesture::Gradient { start }) => ToolEffect::Gradient { from: start, to: doc },
            _ => ToolEffect::None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn point(x: f32, y: f32) -> Pos2 {
        Pos2::new(x, y)
    }

    #[test]
    fn the_gradient_tool_reports_one_drag_when_it_ends() {
        let mut machine = ToolMachine::default();
        machine.set_tool(Tool::Gradient);
        assert_eq!(machine.press(point(2.0, 3.0)), ToolEffect::None, "the press only remembers the start");
        assert!(machine.is_dragging());
        assert_eq!(machine.drag(point(8.0, 3.0)), ToolEffect::None);
        assert_eq!(
            machine.release(point(20.0, 3.0)),
            ToolEffect::Gradient { from: point(2.0, 3.0), to: point(20.0, 3.0) }
        );
        assert!(!machine.is_dragging());
        assert_eq!(machine.release(point(20.0, 3.0)), ToolEffect::None, "one release is one gradient");
    }

    #[test]
    fn the_brush_stamps_on_press_and_segments_afterwards() {
        let mut machine = ToolMachine::default();
        assert_eq!(machine.tool(), Tool::Brush);
        assert_eq!(machine.press(point(4.0, 4.0)), ToolEffect::Paint { from: point(4.0, 4.0), to: point(4.0, 4.0) });
        assert!(machine.is_dragging());
        assert_eq!(machine.drag(point(9.0, 4.0)), ToolEffect::Paint { from: point(4.0, 4.0), to: point(9.0, 4.0) });
        // The next segment starts where the previous one ended, so no gap appears on a fast drag.
        assert_eq!(machine.drag(point(9.0, 12.0)), ToolEffect::Paint { from: point(9.0, 4.0), to: point(9.0, 12.0) });
        assert_eq!(machine.release(point(9.0, 12.0)), ToolEffect::None);
        assert!(!machine.is_dragging());
        assert_eq!(machine.drag(point(50.0, 50.0)), ToolEffect::None);
    }

    #[test]
    fn the_eraser_shares_the_brush_gesture() {
        let mut machine = ToolMachine::default();
        machine.set_tool(Tool::Eraser);
        assert!(machine.tool().paints());
        assert_eq!(machine.press(point(1.0, 1.0)), ToolEffect::Paint { from: point(1.0, 1.0), to: point(1.0, 1.0) });
    }

    #[test]
    fn a_marquee_is_reported_normalized_and_finishes_on_release() {
        let mut machine = ToolMachine::default();
        machine.set_tool(Tool::RectSelect);
        assert_eq!(
            machine.press(point(10.0, 10.0)),
            ToolEffect::Selection { rect: Rect::from_min_max(point(10.0, 10.0), point(10.0, 10.0)) }
        );
        match machine.drag(point(30.0, 4.0)) {
            ToolEffect::Selection { rect } => {
                assert_eq!(rect.min, point(10.0, 4.0));
                assert_eq!(rect.max, point(30.0, 10.0));
            }
            other => panic!("expected a selection, got {other:?}"),
        }
        match machine.release(point(12.0, 6.0)) {
            ToolEffect::Selection { rect } => assert_eq!(rect.min, point(10.0, 6.0)),
            other => panic!("expected a selection, got {other:?}"),
        }
        assert!(!machine.is_dragging());
    }

    #[test]
    fn moving_accumulates_the_dragged_delta() {
        let mut machine = ToolMachine::default();
        machine.set_tool(Tool::Move);
        assert_eq!(machine.press(point(0.0, 0.0)), ToolEffect::None);
        assert_eq!(machine.drag(point(3.0, -2.0)), ToolEffect::Move { delta: Vec2::new(3.0, -2.0) });
        assert_eq!(machine.drag(point(4.0, -2.0)), ToolEffect::Move { delta: Vec2::new(1.0, 0.0) });
        assert_eq!(machine.release(point(4.0, -2.0)), ToolEffect::None);
        assert_eq!(machine.drag(point(9.0, 9.0)), ToolEffect::None);
    }

    #[test]
    fn the_eyedropper_picks_once_and_keeps_no_gesture() {
        let mut machine = ToolMachine::default();
        machine.set_tool(Tool::Eyedropper);
        assert_eq!(machine.press(point(2.0, 3.0)), ToolEffect::Pick { at: point(2.0, 3.0) });
        assert!(!machine.is_dragging());
        assert_eq!(machine.drag(point(2.0, 4.0)), ToolEffect::None);
    }

    #[test]
    fn the_text_tool_reports_a_click_and_keeps_no_gesture() {
        let mut machine = ToolMachine::default();
        machine.set_tool(Tool::Text);
        assert_eq!(machine.press(point(12.0, 30.0)), ToolEffect::TextClick { at: point(12.0, 30.0) });
        assert!(!machine.is_dragging());
        assert_eq!(machine.drag(point(12.0, 40.0)), ToolEffect::None);
        assert_eq!(machine.release(point(12.0, 40.0)), ToolEffect::None);
        assert!(!machine.tool().paints());
        assert_eq!(machine.tool().key(), 'T');
    }

    #[test]
    fn switching_tools_drops_the_gesture_in_flight() {
        let mut machine = ToolMachine::default();
        machine.press(point(0.0, 0.0));
        assert!(machine.is_dragging());
        machine.set_tool(Tool::Move);
        assert!(!machine.is_dragging());
        assert_eq!(machine.drag(point(5.0, 5.0)), ToolEffect::None);
    }

    #[test]
    fn cancelling_ends_a_stroke_without_an_effect() {
        let mut machine = ToolMachine::default();
        machine.press(point(1.0, 1.0));
        machine.cancel();
        assert!(!machine.is_dragging());
        assert_eq!(machine.release(point(1.0, 1.0)), ToolEffect::None);
    }

    #[test]
    fn every_tool_has_a_distinct_shortcut() {
        let mut keys: Vec<char> = Tool::ALL.iter().map(|tool| tool.key()).collect();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(keys.len(), Tool::ALL.len());
    }

    #[test]
    fn brush_settings_clamp_to_usable_ranges() {
        let clamped = BrushSettings { size: -5.0, hardness: 4.0, opacity: 0.0 }.clamped();
        assert_eq!(clamped.size, 1.0);
        assert_eq!(clamped.hardness, 1.0);
        assert_eq!(clamped.opacity, 0.01);
        let wide = BrushSettings { size: 10_000.0, hardness: 0.5, opacity: 2.0 }.clamped();
        assert_eq!(wide.size, 2100.0);
        assert_eq!(wide.opacity, 1.0);
    }
}
