//! The layers panel's row layout, kept apart from egui so the ordering and nesting rules are
//! testable without a window.

use std::collections::HashSet;

use comp_core::document::Document;
use uuid::Uuid;

/// How far a virtualized list scrolls while something is being dragged near its edge.
///
/// The list only draws the rows its viewport can show, so a dragged row cannot reach a row that is off
/// screen unless the list scrolls under the pointer. This answers the step for one frame: negative
/// scrolls up, positive down, zero when the pointer is away from both edges. The step grows with how
/// far into the margin the pointer is, up to a ceiling, so a drag close to the edge creeps and one at
/// the edge moves.
pub fn autoscroll_step(pointer_y: f32, top: f32, bottom: f32, margin: f32, max_step: f32) -> f32 {
    if margin <= 0.0 || max_step <= 0.0 || bottom <= top {
        return 0.0;
    }
    let margin = margin.min((bottom - top) / 2.0);
    if pointer_y < top + margin {
        let depth = ((top + margin) - pointer_y).min(margin);
        return -max_step * (depth / margin);
    }
    if pointer_y > bottom - margin {
        let depth = (pointer_y - (bottom - margin)).min(margin);
        return max_step * (depth / margin);
    }
    0.0
}

/// One row of the layers panel, in the order the panel draws them: top of the stack first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LayerRow {
    /// Index into Document::layers, which runs bottom to top.
    pub index: usize,
    pub id: Uuid,
    /// Nesting level, 0 for a root layer.
    pub depth: usize,
    pub is_group: bool,
    pub is_adjustment: bool,
    /// True for the topmost child of its parent, which the panel uses to close a tree guide.
    pub last_child: bool,
}

/// Builds the visible rows, skipping the descendants of collapsed groups.
///
/// The walk goes bottom to top because a group's children follow it in the document; the result is
/// reversed so the panel can draw straight down.
pub fn layer_rows(document: &Document, collapsed: &HashSet<Uuid>) -> Vec<LayerRow> {
    let mut rows: Vec<LayerRow> = Vec::new();
    let mut hidden_below: Option<usize> = None;
    for (index, layer) in document.layers.iter().enumerate() {
        let depth = document.depth(layer.id);
        if let Some(hidden_depth) = hidden_below {
            if depth > hidden_depth {
                continue;
            }
            hidden_below = None;
        }
        let siblings = document.child_indices(layer.parent);
        rows.push(LayerRow {
            index,
            id: layer.id,
            depth,
            is_group: layer.is_group,
            is_adjustment: layer.adjustment.is_some(),
            last_child: siblings.last() == Some(&index),
        });
        if layer.is_group && collapsed.contains(&layer.id) {
            hidden_below = Some(depth);
        }
    }
    rows.reverse();
    rows
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_drag_near_an_edge_scrolls_the_list_and_one_in_the_middle_does_not() {
        use super::autoscroll_step;
        let (top, bottom, margin, most) = (100.0, 500.0, 24.0, 14.0);
        assert_eq!(autoscroll_step(300.0, top, bottom, margin, most), 0.0, "the middle scrolls nothing");
        assert_eq!(autoscroll_step(top + margin, top, bottom, margin, most), 0.0, "the margin's edge is still");
        // Just inside the top margin: a slow scroll up. At the very top: the full step.
        let near_top = autoscroll_step(top + margin / 2.0, top, bottom, margin, most);
        assert!(near_top < 0.0 && near_top > -most, "{near_top}");
        assert_eq!(autoscroll_step(top, top, bottom, margin, most), -most);
        // And the same the other way round.
        let near_bottom = autoscroll_step(bottom - margin / 2.0, top, bottom, margin, most);
        assert!(near_bottom > 0.0 && near_bottom < most, "{near_bottom}");
        assert_eq!(autoscroll_step(bottom, top, bottom, margin, most), most);
        // Past the ends the step is capped rather than growing.
        assert_eq!(autoscroll_step(4000.0, top, bottom, margin, most), most);
        assert_eq!(autoscroll_step(-4000.0, top, bottom, margin, most), -most);
    }

    #[test]
    fn auto_scroll_declines_to_work_without_room_or_without_a_step() {
        use super::autoscroll_step;
        assert_eq!(autoscroll_step(10.0, 100.0, 500.0, 0.0, 14.0), 0.0, "no margin");
        assert_eq!(autoscroll_step(10.0, 100.0, 500.0, 24.0, 0.0), 0.0, "no step");
        assert_eq!(autoscroll_step(10.0, 500.0, 100.0, 24.0, 14.0), 0.0, "an inverted viewport");
        // A list shorter than twice the margin uses half its height as the margin, so the two edges
        // cannot overlap and fight each other.
        let step = autoscroll_step(10.0, 100.0, 140.0, 200.0, 14.0);
        assert!(step < 0.0 && step >= -14.0, "{step}");
    }

    use super::*;
    use comp_core::layer::Layer;

    fn document() -> (Document, Uuid, Uuid) {
        let mut document = Document::new(64, 64);
        document.add_layer(Layer::raster("Bottom", 64, 64), None);
        let group = Layer::group("Folder", 64, 64);
        let group_id = group.id;
        document.add_layer(group, None);
        document.add_layer(Layer::raster("Inner A", 64, 64), Some(group_id));
        document.add_layer(Layer::raster("Inner B", 64, 64), Some(group_id));
        document.add_layer(Layer::raster("Top", 64, 64), None);
        let inner = document.layers.iter().find(|layer| layer.name == "Inner B").unwrap().id;
        (document, group_id, inner)
    }

    #[test]
    fn rows_run_from_the_top_of_the_stack_downwards() {
        let (document, group_id, _) = document();
        let rows = layer_rows(&document, &HashSet::new());
        let names: Vec<&str> = rows.iter().map(|row| document.layers[row.index].name.as_str()).collect();
        assert_eq!(names, vec!["Top", "Inner B", "Inner A", "Folder", "Bottom"]);
        let folder = rows.iter().find(|row| row.id == group_id).unwrap();
        assert!(folder.is_group);
        assert_eq!(folder.depth, 0);
    }

    #[test]
    fn children_are_indented_one_level_under_their_group() {
        let (document, group_id, inner) = document();
        let rows = layer_rows(&document, &HashSet::new());
        let folder = rows.iter().find(|row| row.id == group_id).unwrap();
        let child = rows.iter().find(|row| row.id == inner).unwrap();
        assert_eq!(child.depth, folder.depth + 1);
        let inner_a = rows.iter().find(|row| document.layers[row.index].name == "Inner A").unwrap();
        assert!(!inner_a.last_child);
        assert!(child.last_child, "the topmost child closes the tree guide");
        assert!(rows.iter().find(|row| document.layers[row.index].name == "Top").unwrap().last_child);
    }

    #[test]
    fn collapsing_a_group_hides_exactly_its_descendants() {
        let (document, group_id, _) = document();
        let mut collapsed = HashSet::new();
        collapsed.insert(group_id);
        let rows = layer_rows(&document, &collapsed);
        let names: Vec<&str> = rows.iter().map(|row| document.layers[row.index].name.as_str()).collect();
        assert_eq!(names, vec!["Top", "Folder", "Bottom"]);
        assert!(rows.iter().all(|row| row.id != group_id || row.is_group));
    }

    #[test]
    fn an_empty_document_has_no_rows() {
        let document = Document::new(8, 8);
        assert!(layer_rows(&document, &HashSet::new()).is_empty());
    }
}
