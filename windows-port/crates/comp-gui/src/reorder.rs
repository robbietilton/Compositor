//! Moving layers around the stack, including in and out of folders.
//!
//! A group owns a contiguous run of the layer vector, so a reorder has to keep that run together.
//! The rules live here rather than in the panel so the resulting order can be tested without a
//! window: the panel only turns a pointer position into a placement.

use comp_core::document::Document;
use uuid::Uuid;

/// Where a layer should land: the folder it joins, and the index among that folder's children
/// counted from the bottom of the stack.
pub type Placement = (Option<Uuid>, usize);

/// True when a layer is the root of a subtree or inside it.
fn in_subtree(document: &Document, root: Uuid, node: Uuid) -> bool {
    node == root || document.is_descendant(root, node)
}

/// The placement a drop just above a row means.
///
/// The panel lists the stack top first, so a layer dropped above a row belongs immediately after it
/// in the document, and a row inside a folder keeps the drop inside that folder. The layer being
/// dragged is left out of the count, so the same drop means the same thing wherever the drag
/// started; a drop above the row being dragged has no placement at all.
pub fn placement_above(document: &Document, dragged: Uuid, row: Uuid) -> Option<Placement> {
    let layer = document.layer(row)?;
    let parent = layer.parent;
    let siblings: Vec<Uuid> = document
        .child_indices(parent)
        .into_iter()
        .map(|index| document.layers[index].id)
        .filter(|id| !in_subtree(document, dragged, *id))
        .collect();
    let position = siblings.iter().position(|id| *id == row)?;
    Some((parent, position + 1))
}

/// The placement a drop at the bottom of the list means: the bottom of the stack.
pub fn placement_bottom() -> Placement {
    (None, 0)
}

/// Moves a layer, with everything inside it, to a placement.
///
/// Refuses a destination that would put a folder inside its own subtree, and reports false when the
/// stack ends up exactly as it was, so a drag that changes nothing records no undo step.
pub fn move_to(document: &mut Document, id: Uuid, (parent, index): Placement) -> bool {
    if document.index_of(id).is_none() {
        return false;
    }
    if let Some(parent_id) = parent {
        match document.layer(parent_id) {
            Some(target) if target.is_group => {}
            _ => return false,
        }
        if in_subtree(document, id, parent_id) {
            return false;
        }
    }
    // The index counts the sibling list without the moving subtree, which is what the panel shows.
    let moved = document.subtree_indices(id);
    let siblings: Vec<usize> = document
        .child_indices(parent)
        .into_iter()
        .filter(|index| !moved.contains(index))
        .collect();
    let target = if index < siblings.len() {
        siblings[index]
    } else if let Some(parent_id) = parent {
        // Past the last child: the end of the folder's own subtree.
        document.subtree_indices(parent_id).last().map(|last| last + 1).unwrap_or(document.layers.len())
    } else {
        document.layers.len()
    };

    let before = document.clone();
    match document.layer_mut(id) {
        Some(layer) => layer.parent = parent,
        None => return false,
    }
    // A move that lands the layer back where it was reports no change; comparing the whole document
    // is cheaper and far safer than predicting the vector surgery.
    if !document.move_layer(id, target) || *document == before {
        *document = before;
        return false;
    }
    true
}

/// True when every group's subtree is still one contiguous run, which the document model requires.
pub fn subtrees_are_contiguous(document: &Document) -> bool {
    document.layers.iter().filter(|layer| layer.is_group).all(|group| {
        let indices = document.subtree_indices(group.id);
        match (indices.first(), indices.last()) {
            (Some(first), Some(last)) => *last - *first + 1 == indices.len(),
            _ => true,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::layer::Layer;

    /// Bottom to top the document reads [Bottom, Folder, Child A, Child B, Top], so the panel lists
    /// it as Top, Child B, Child A, Folder, Bottom.
    fn document() -> (Document, Uuid, Uuid, Uuid, Uuid, Uuid) {
        let mut document = Document::new(32, 32);
        let bottom = document.add_layer(Layer::raster("Bottom", 32, 32), None);
        let folder = Layer::group("Folder", 32, 32);
        let folder_id = folder.id;
        document.add_layer(folder, None);
        let child_a = document.add_layer(Layer::raster("Child A", 32, 32), Some(folder_id));
        let child_b = document.add_layer(Layer::raster("Child B", 32, 32), Some(folder_id));
        let top = document.add_layer(Layer::raster("Top", 32, 32), None);
        (document, bottom, folder_id, child_a, child_b, top)
    }

    fn names(document: &Document) -> Vec<String> {
        document.layers.iter().map(|layer| layer.name.clone()).collect()
    }

    fn children(document: &Document, folder: Uuid) -> Vec<String> {
        document
            .child_indices(Some(folder))
            .into_iter()
            .map(|index| document.layers[index].name.clone())
            .collect()
    }

    #[test]
    fn dropping_above_a_row_places_the_layer_just_above_it_in_the_list() {
        let (mut document, bottom, _folder, _child_a, _child_b, top) = document();
        // The strip above the bottom row sits between the folder and the bottom layer, which is
        // root index 1: the layer lands just above the bottom row and below the folder.
        let placement = placement_above(&document, top, bottom).unwrap();
        assert_eq!(placement, (None, 1));
        assert!(move_to(&mut document, top, placement));
        assert_eq!(names(&document), vec!["Bottom", "Top", "Folder", "Child A", "Child B"]);
        assert!(subtrees_are_contiguous(&document));
        assert_eq!(document.child_indices(None).len(), 3, "all three are still root layers");
    }

    #[test]
    fn a_layer_moves_into_a_folder_and_back_out_again() {
        let (mut document, bottom, folder, _child_a, child_b, _top) = document();
        // Above the folder's topmost child is the top of that folder.
        let into = placement_above(&document, bottom, child_b).unwrap();
        assert_eq!(into, (Some(folder), 2));
        assert!(move_to(&mut document, bottom, into));
        assert_eq!(children(&document, folder), vec!["Child A", "Child B", "Bottom"]);
        assert_eq!(document.layer(bottom).unwrap().parent, Some(folder));
        assert!(subtrees_are_contiguous(&document));

        // The bottom of the list takes it back out.
        assert!(move_to(&mut document, bottom, placement_bottom()));
        assert_eq!(document.layers[0].id, bottom);
        assert_eq!(document.layer(bottom).unwrap().parent, None);
        assert_eq!(children(&document, folder), vec!["Child A", "Child B"]);
        assert!(subtrees_are_contiguous(&document));
    }

    #[test]
    fn a_drop_past_the_last_child_lands_at_the_top_of_the_folder() {
        let (mut document, bottom, folder, _child_a, _child_b, top) = document();
        assert!(move_to(&mut document, bottom, (Some(folder), 99)));
        assert_eq!(children(&document, folder), vec!["Child A", "Child B", "Bottom"]);
        assert_eq!(document.layers.last().unwrap().id, top, "the stack above the folder is untouched");
        assert_eq!(document.subtree_indices(folder).len(), 4, "the folder, three children");
        assert!(subtrees_are_contiguous(&document));
    }

    #[test]
    fn a_folder_cannot_be_dropped_inside_itself() {
        let (mut document, _bottom, folder, child_a, _child_b, _top) = document();
        assert!(!move_to(&mut document, folder, (Some(folder), 0)), "into itself");
        assert!(!move_to(&mut document, folder, (Some(child_a), 0)), "into its own child");
        assert_eq!(document.layer(folder).unwrap().parent, None);
        assert_eq!(document.layers.len(), 5);
        assert!(subtrees_are_contiguous(&document));
    }

    #[test]
    fn a_drop_that_changes_nothing_reports_no_move() {
        let (mut document, bottom, folder, child_a, _child_b, _top) = document();
        let before = document.clone();
        assert!(!move_to(&mut document, bottom, placement_bottom()), "it is already the bottom layer");
        assert!(!move_to(&mut document, child_a, (Some(folder), 0)), "already the folder's first child");
        assert!(!move_to(&mut document, Uuid::nil(), (None, 0)), "there is no such layer");
        assert!(!move_to(&mut document, bottom, (Some(child_a), 0)), "a raster layer is not a folder");
        assert_eq!(document, before, "a refused move leaves the stack alone");
    }

    #[test]
    fn moving_a_folder_carries_its_children() {
        let (mut document, _bottom, folder, child_a, child_b, _top) = document();
        // The bottom of the list takes the whole folder down with its children.
        assert!(move_to(&mut document, folder, placement_bottom()));
        let indices = document.subtree_indices(folder);
        assert_eq!(indices.len(), 3, "the folder and its two children travel together");
        assert_eq!(document.layers[indices[0]].id, folder);
        assert!(indices.contains(&document.index_of(child_a).unwrap()));
        assert!(indices.contains(&document.index_of(child_b).unwrap()));
        assert_eq!(children(&document, folder), vec!["Child A", "Child B"]);
        assert!(subtrees_are_contiguous(&document));
    }

    #[test]
    fn a_placement_is_counted_without_the_layer_being_dragged() {
        let (document, bottom, folder, _child_a, child_b, top) = document();
        // Dragging the top layer, the rows below it keep their own places.
        assert_eq!(placement_above(&document, top, bottom), Some((None, 1)));
        assert_eq!(placement_above(&document, top, child_b), Some((Some(folder), 2)));
        assert_eq!(placement_above(&document, top, folder), Some((None, 2)));
        // There is no drop above the row being dragged.
        assert_eq!(placement_above(&document, top, top), None);
        assert_eq!(placement_above(&document, top, Uuid::nil()), None);
    }
}
