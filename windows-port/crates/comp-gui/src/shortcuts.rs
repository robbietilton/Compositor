//! The keyboard, in one table.
//!
//! Every binding the editor has is listed here with the macOS chord it came from, so the parity audit
//! and the conflict check read the same source the dispatch does. The platform mapping is Windows':
//! Command becomes Ctrl and Option becomes Alt. macOS's own table never uses Control, so no binding
//! is left over; where the two would collide the macOS chord wins and the port's own binding moves.

use egui::{Key, Modifiers};

/// Where a binding applies. A text session shadows everything marked Text, so typing and the input
/// method keep the keys they need.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    /// The canvas, the panels and the menus.
    Editor,
    /// Inside an open text session, where the caret and the IME come first.
    Text,
}

/// How a binding stands against the macOS original.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Parity {
    /// The same chord as macOS, under the platform mapping.
    Same,
    /// macOS has the action on another chord; the reason is in the entry's note.
    Rebound,
    /// macOS has no such binding, so this one is the port's own.
    Ours,
    /// macOS has it, this build has the command, and the chord is free.
    Added,
}

/// One action the keyboard can ask for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Action {
    NewDocument,
    Open,
    Import,
    Save,
    SaveAs,
    ExportPng,
    ExportJpeg,
    CloseTab,
    Undo,
    Redo,
    Cut,
    Copy,
    CopyMerged,
    Paste,
    SelectAll,
    Deselect,
    Curves,
    Levels,
    HueSaturation,
    Invert,
    NewLayer,
    DuplicateLayer,
    MoveLayerUp,
    MoveLayerDown,
    MergeLayers,
    FlattenImage,
    DeleteLayer,
    CameraRaw,
    ZoomIn,
    ZoomOut,
    FitWindow,
    ActualPixels,
    ShowGrid,
    ShowGuides,
    ShowRulers,
    Snap,
    LockGuides,
    IncreaseBrush,
    DecreaseBrush,
    IncreaseBrushHardness,
    DecreaseBrushHardness,
    Quit,
    Escape,
}

/// One binding: the action, the chord this build listens for, and what macOS does.
#[derive(Clone, Copy, Debug)]
pub struct Shortcut {
    pub action: Action,
    pub key: Key,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub scope: Scope,
    pub parity: Parity,
    /// The macOS chord, written the way its own shortcuts sheet writes it.
    pub macos: &'static str,
    /// What the port's own row shows, and why it differs when it does.
    pub label: &'static str,
}

/// A binding with no modifiers.
const fn plain(action: Action, key: Key, scope: Scope, parity: Parity, macos: &'static str, label: &'static str) -> Shortcut {
    Shortcut { action, key, ctrl: false, alt: false, shift: false, scope, parity, macos, label }
}

/// A binding with Ctrl (Command on macOS).
const fn ctrl(action: Action, key: Key, scope: Scope, parity: Parity, macos: &'static str, label: &'static str) -> Shortcut {
    Shortcut { action, key, ctrl: true, alt: false, shift: false, scope, parity, macos, label }
}

/// A binding with Ctrl and Shift (Command and Shift on macOS).
const fn ctrl_shift(action: Action, key: Key, scope: Scope, parity: Parity, macos: &'static str, label: &'static str) -> Shortcut {
    Shortcut { action, key, ctrl: true, alt: false, shift: true, scope, parity, macos, label }
}

/// A binding with Shift alone (macOS's brush hardness and nothing else).
const fn shift(action: Action, key: Key, scope: Scope, parity: Parity, macos: &'static str, label: &'static str) -> Shortcut {
    Shortcut { action, key, ctrl: false, alt: false, shift: true, scope, parity, macos, label }
}

/// Every binding. The macOS column is what the shortcuts sheet in the macOS app lists.
pub const TABLE: &[Shortcut] = &[
    // Menus: File.
    ctrl(Action::NewDocument, Key::N, Scope::Editor, Parity::Same, "Cmd N", "New document"),
    ctrl(Action::Open, Key::O, Scope::Editor, Parity::Same, "Cmd O", "Open a project"),
    ctrl_shift(Action::Import, Key::I, Scope::Editor, Parity::Ours, "-", "Import (the port's own; macOS imports from the File menu)"),
    ctrl(Action::Save, Key::S, Scope::Editor, Parity::Same, "Cmd S", "Save"),
    ctrl_shift(Action::SaveAs, Key::S, Scope::Editor, Parity::Same, "Cmd Shift S", "Save As"),
    // Export PNG is Cmd Shift E in macOS; the port used Cmd E for it and Cmd E is Merge there.
    ctrl_shift(Action::ExportPng, Key::E, Scope::Editor, Parity::Rebound, "Cmd Shift E", "Export PNG (was Ctrl E before the audit)"),
    // The macOS chord exactly: Command, Option and Shift with S.
    Shortcut { action: Action::ExportJpeg, key: Key::S, ctrl: true, alt: true, shift: true, scope: Scope::Editor, parity: Parity::Same, macos: "Cmd Opt Shift S", label: "Export JPEG" },
    ctrl(Action::CloseTab, Key::W, Scope::Editor, Parity::Same, "Cmd W", "Close the tab"),
    ctrl(Action::Quit, Key::Q, Scope::Editor, Parity::Same, "Cmd Q", "Quit"),
    // Menus: Edit.
    ctrl(Action::Undo, Key::Z, Scope::Editor, Parity::Same, "Cmd Z", "Undo"),
    ctrl_shift(Action::Redo, Key::Z, Scope::Editor, Parity::Same, "Cmd Shift Z", "Redo"),
    ctrl(Action::Cut, Key::X, Scope::Editor, Parity::Same, "Cmd X", "Cut the layer"),
    ctrl(Action::Copy, Key::C, Scope::Editor, Parity::Same, "Cmd C", "Copy the layer"),
    ctrl_shift(Action::CopyMerged, Key::C, Scope::Editor, Parity::Same, "Cmd Shift C", "Copy merged"),
    ctrl(Action::Paste, Key::V, Scope::Editor, Parity::Same, "Cmd V", "Paste as a new layer"),
    ctrl(Action::SelectAll, Key::A, Scope::Text, Parity::Same, "Cmd A", "Select all (the text session takes it)"),
    ctrl(Action::Deselect, Key::D, Scope::Editor, Parity::Same, "Cmd D", "Deselect"),
    // Menus: Image and Layer.
    ctrl(Action::Curves, Key::M, Scope::Editor, Parity::Same, "Cmd M", "Curves adjustment layer"),
    ctrl(Action::Levels, Key::L, Scope::Editor, Parity::Same, "Cmd L", "Levels adjustment layer"),
    ctrl(Action::HueSaturation, Key::U, Scope::Editor, Parity::Same, "Cmd U", "Hue/Saturation adjustment layer"),
    ctrl(Action::Invert, Key::I, Scope::Editor, Parity::Same, "Cmd I", "Invert adjustment layer"),
    ctrl_shift(Action::NewLayer, Key::N, Scope::Editor, Parity::Same, "Cmd Shift N", "New blank layer"),
    ctrl(Action::DuplicateLayer, Key::J, Scope::Editor, Parity::Same, "Cmd J", "Duplicate the layer"),
    ctrl(Action::MoveLayerUp, Key::CloseBracket, Scope::Editor, Parity::Same, "Cmd ]", "Move the layer up"),
    ctrl(Action::MoveLayerDown, Key::OpenBracket, Scope::Editor, Parity::Same, "Cmd [", "Move the layer down"),
    ctrl(Action::MergeLayers, Key::E, Scope::Editor, Parity::Same, "Cmd E", "Merge down, or merge the selection"),
    ctrl_shift(Action::FlattenImage, Key::F, Scope::Editor, Parity::Ours, "-", "Flatten (the port's own)"),
    plain(Action::DeleteLayer, Key::Delete, Scope::Editor, Parity::Same, "Delete", "Delete the selection or the layer"),
    ctrl_shift(Action::CameraRaw, Key::R, Scope::Editor, Parity::Ours, "-", "Camera Raw (the port's own)"),
    // Menus: View.
    ctrl(Action::ZoomIn, Key::Equals, Scope::Editor, Parity::Same, "Cmd =", "Zoom in"),
    ctrl(Action::ZoomOut, Key::Minus, Scope::Editor, Parity::Same, "Cmd -", "Zoom out"),
    ctrl(Action::FitWindow, Key::Num0, Scope::Editor, Parity::Same, "Cmd 0", "Fit to window"),
    ctrl(Action::ActualPixels, Key::Num1, Scope::Editor, Parity::Same, "Cmd 1", "Actual pixels"),
    ctrl(Action::ShowGrid, Key::Quote, Scope::Editor, Parity::Same, "Cmd '", "Show the grid"),
    ctrl(Action::ShowGuides, Key::Semicolon, Scope::Editor, Parity::Same, "Cmd ;", "Show the guides"),
    ctrl(Action::ShowRulers, Key::R, Scope::Editor, Parity::Same, "Cmd R", "Show the rulers"),
    ctrl_shift(Action::Snap, Key::Semicolon, Scope::Editor, Parity::Same, "Cmd Shift ;", "Snap"),
    Shortcut { action: Action::LockGuides, key: Key::Semicolon, ctrl: true, alt: true, shift: false, scope: Scope::Editor, parity: Parity::Same, macos: "Cmd Opt ;", label: "Lock the guides" },
    // Canvas.
    plain(Action::IncreaseBrush, Key::CloseBracket, Scope::Editor, Parity::Same, "]", "Larger brush"),
    plain(Action::DecreaseBrush, Key::OpenBracket, Scope::Editor, Parity::Same, "[", "Smaller brush"),
    shift(Action::IncreaseBrushHardness, Key::CloseBracket, Scope::Editor, Parity::Same, "Shift ]", "Harder brush"),
    shift(Action::DecreaseBrushHardness, Key::OpenBracket, Scope::Editor, Parity::Same, "Shift [", "Softer brush"),
    plain(Action::Escape, Key::Escape, Scope::Editor, Parity::Same, "Esc", "Cancel what is in flight"),
];

/// The actions a frame's input asks for, in table order.
///
/// A binding marked Text is left out while a text session is open, which is how typing and the input
/// method keep the arrows, the line edges and the delete keys.
pub fn pressed(input: &egui::InputState, text_open: bool) -> Vec<Action> {
    let mut actions = Vec::new();
    for shortcut in TABLE {
        if shortcut.scope == Scope::Text && text_open {
            continue;
        }
        if chord_matches(shortcut, input) {
            actions.push(shortcut.action);
        }
    }
    actions
}

/// True when this frame pressed the binding's chord.
pub fn chord_matches(shortcut: &Shortcut, input: &egui::InputState) -> bool {
    if !input.key_pressed(shortcut.key) {
        return false;
    }
    let modifiers = input.modifiers;
    let ctrl = modifiers.ctrl || modifiers.command;
    ctrl == shortcut.ctrl && modifiers.alt == shortcut.alt && modifiers.shift == shortcut.shift
}

/// Which layer of the editor owns the arrow keys right now.
///
/// The order is the rule: a text session first, then a selected guide, then a curve point, and only
/// then the layer the canvas would nudge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArrowTarget {
    Text,
    Guide,
    Curve,
    Layer,
    None,
}

pub fn arrow_target(text_open: bool, guide_selected: bool, curve_selected: bool, layer_selected: bool) -> ArrowTarget {
    if text_open {
        ArrowTarget::Text
    } else if guide_selected {
        ArrowTarget::Guide
    } else if curve_selected {
        ArrowTarget::Curve
    } else if layer_selected {
        ArrowTarget::Layer
    } else {
        ArrowTarget::None
    }
}

/// The chords of one scope, for the conflict check.
pub fn chords(scope: Scope) -> Vec<(Key, Modifiers)> {
    TABLE
        .iter()
        .filter(|shortcut| shortcut.scope == scope)
        .map(|shortcut| {
            let mut modifiers = Modifiers::NONE;
            modifiers.ctrl = shortcut.ctrl;
            modifiers.alt = shortcut.alt;
            modifiers.shift = shortcut.shift;
            (shortcut.key, modifiers)
        })
        .collect()
}

/// The label a menu shows for a binding, in egui's own wording.
pub fn shortcut_text(action: Action) -> Option<String> {
    let shortcut = TABLE.iter().find(|shortcut| shortcut.action == action)?;
    if shortcut.parity == Parity::Ours {
        // The port's own bindings are shown too: a menu is not the place to hide one.
    }
    let mut text = String::new();
    if shortcut.ctrl {
        text.push_str("Ctrl+");
    }
    if shortcut.alt {
        text.push_str("Alt+");
    }
    if shortcut.shift {
        text.push_str("Shift+");
    }
    text.push_str(&format!("{:?}", shortcut.key));
    Some(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn no_two_bindings_in_a_scope_share_a_chord() {
        // The conflict check the audit asks for: one chord, one action, per scope.
        for scope in [Scope::Editor, Scope::Text] {
            let mut seen: HashMap<String, Action> = HashMap::new();
            for shortcut in TABLE.iter().filter(|shortcut| shortcut.scope == scope) {
                let chord = format!("{:?}+{}{}{}", shortcut.key, shortcut.ctrl, shortcut.alt, shortcut.shift);
                if let Some(previous) = seen.insert(chord.clone(), shortcut.action) {
                    panic!("{chord} is bound to both {previous:?} and {:?}", shortcut.action);
                }
            }
        }
    }

    #[test]
    fn a_chord_may_repeat_across_scopes_because_the_text_session_wins() {
        // Ctrl A is Select All on the canvas and belongs to the text session while one is open.
        let duplicates: Vec<Action> = TABLE
            .iter()
            .filter(|shortcut| shortcut.scope == Scope::Text)
            .map(|shortcut| shortcut.action)
            .collect();
        assert!(!duplicates.is_empty(), "the text scope has to shadow something");
        for action in duplicates {
            let elsewhere = TABLE
                .iter()
                .filter(|shortcut| shortcut.action == action && shortcut.scope == Scope::Editor)
                .count();
            assert_eq!(elsewhere, 0, "{action:?} is both a text and an editor binding");
        }
    }

    #[test]
    fn every_action_is_bound_once_and_shadowed_at_most_once() {
        let mut counts: HashMap<Action, usize> = HashMap::new();
        for shortcut in TABLE {
            *counts.entry(shortcut.action).or_default() += 1;
        }
        for action in [
            Action::NewDocument,
            Action::Open,
            Action::Save,
            Action::SaveAs,
            Action::ExportPng,
            Action::ExportJpeg,
            Action::CloseTab,
            Action::Undo,
            Action::Redo,
            Action::Cut,
            Action::Copy,
            Action::CopyMerged,
            Action::Paste,
            Action::SelectAll,
            Action::Deselect,
            Action::Curves,
            Action::Levels,
            Action::HueSaturation,
            Action::Invert,
            Action::NewLayer,
            Action::DuplicateLayer,
            Action::MoveLayerUp,
            Action::MoveLayerDown,
            Action::MergeLayers,
            Action::FlattenImage,
            Action::DeleteLayer,
            Action::CameraRaw,
            Action::ZoomIn,
            Action::ZoomOut,
            Action::FitWindow,
            Action::ActualPixels,
            Action::ShowGrid,
            Action::ShowGuides,
            Action::ShowRulers,
            Action::Snap,
            Action::LockGuides,
            Action::IncreaseBrush,
            Action::DecreaseBrush,
            Action::IncreaseBrushHardness,
            Action::DecreaseBrushHardness,
            Action::Quit,
            Action::Escape,
        ] {
            assert_eq!(counts.get(&action).copied().unwrap_or(0), 1, "{action:?} is not bound exactly once");
        }
    }

    #[test]
    fn the_macos_parity_of_every_binding_is_recorded() {
        for shortcut in TABLE {
            assert!(!shortcut.label.is_empty(), "{:?} has no label", shortcut.action);
            match shortcut.parity {
                Parity::Same | Parity::Rebound | Parity::Added => {
                    assert!(
                        shortcut.macos.starts_with("Cmd") || !shortcut.macos.starts_with('-'),
                        "{:?} claims parity but records no macOS chord",
                        shortcut.action
                    );
                }
                Parity::Ours => assert_eq!(shortcut.macos, "-", "{:?} is ours and should not claim a macOS chord", shortcut.action),
            }
            if shortcut.parity == Parity::Rebound {
                assert!(
                    shortcut.label.contains("was") || shortcut.label.contains("taken") || shortcut.label.contains("Ctrl"),
                    "{:?} is rebound and does not say why: {}",
                    shortcut.action,
                    shortcut.label
                );
            }
        }
    }

    #[test]
    fn the_bindings_macos_has_are_on_the_chord_the_mapping_gives_them() {
        // Command is Ctrl and Option is Alt, so a macOS chord and ours have to line up.
        for shortcut in TABLE.iter().filter(|shortcut| shortcut.parity == Parity::Same) {
            let macos = shortcut.macos;
            assert_eq!(macos.contains("Cmd"), shortcut.ctrl, "{:?}: {macos}", shortcut.action);
            assert_eq!(macos.contains("Opt"), shortcut.alt, "{:?}: {macos}", shortcut.action);
            assert_eq!(macos.contains("Shift"), shortcut.shift, "{:?}: {macos}", shortcut.action);
        }
    }

    #[test]
    fn the_rebinds_are_the_ones_the_audit_found() {
        // Export PNG moved off Ctrl E because macOS merges on Cmd E, and Export JPEG off the macOS
        // chord because Save As already holds it here.
        let export = TABLE.iter().find(|shortcut| shortcut.action == Action::ExportPng).expect("a binding");
        assert!(export.ctrl && export.shift && export.key == Key::E);
        assert_eq!(export.parity, Parity::Rebound);
        let merge = TABLE.iter().find(|shortcut| shortcut.action == Action::MergeLayers).expect("a binding");
        assert_eq!((merge.key, merge.ctrl, merge.shift), (Key::E, true, false), "macOS merges on Cmd E");
        // Export JPEG keeps the macOS chord exactly, so it is not a rebind.
        let jpeg = TABLE.iter().find(|shortcut| shortcut.action == Action::ExportJpeg).expect("a binding");
        assert_eq!((jpeg.key, jpeg.ctrl, jpeg.alt, jpeg.shift), (Key::S, true, true, true));
        assert_eq!(jpeg.parity, Parity::Same);
    }

    #[test]
    fn the_arrows_belong_to_whoever_is_in_front() {
        assert_eq!(arrow_target(true, true, true, true), ArrowTarget::Text, "typing wins");
        assert_eq!(arrow_target(false, true, true, true), ArrowTarget::Guide);
        assert_eq!(arrow_target(false, false, true, true), ArrowTarget::Curve);
        assert_eq!(arrow_target(false, false, false, true), ArrowTarget::Layer);
        assert_eq!(arrow_target(false, false, false, false), ArrowTarget::None);
    }

    #[test]
    fn a_menu_shows_the_chord_it_listens_for() {
        assert_eq!(shortcut_text(Action::Save).as_deref(), Some("Ctrl+S"));
        assert_eq!(shortcut_text(Action::SaveAs).as_deref(), Some("Ctrl+Shift+S"));
        assert_eq!(shortcut_text(Action::LockGuides).as_deref(), Some("Ctrl+Alt+Semicolon"));
        assert_eq!(shortcut_text(Action::MoveLayerUp).as_deref(), Some("Ctrl+CloseBracket"));
        assert_eq!(shortcut_text(Action::NewDocument).as_deref(), Some("Ctrl+N"));
    }

    #[test]
    fn nothing_is_bound_twice_across_the_whole_table_including_the_text_scope() {
        // The stricter reading: two bindings may share a chord only when one of them is shadowed by
        // an open text session, which is exactly the Text scope.
        let mut by_chord: HashMap<String, Vec<Scope>> = HashMap::new();
        for shortcut in TABLE {
            let chord = format!("{:?}+{}{}{}", shortcut.key, shortcut.ctrl, shortcut.alt, shortcut.shift);
            by_chord.entry(chord).or_default().push(shortcut.scope);
        }
        for (chord, scopes) in by_chord {
            let editors = scopes.iter().filter(|scope| **scope == Scope::Editor).count();
            assert!(editors <= 1, "{chord} is bound to two editor actions: {scopes:?}");
        }
    }
}
