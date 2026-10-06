//! Which layers a click selects, and what the merge commands do with that selection.
//!
//! The panel asks this module what a click means; the rules are macOS's: a plain click replaces the
//! selection, Ctrl toggles one layer, and Shift extends from the active layer over the rows between.

use comp_core::document::Document;
use uuid::Uuid;

/// How a click on a layer row modifies the selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClickKind {
    /// A plain click: this layer, alone.
    Replace,
    /// Ctrl: add the layer, or take it out when it was already selected.
    Toggle,
    /// Shift: everything from the active layer to this one, in document order.
    Extend,
}

/// The selection a click leaves behind, in document order.
///
/// The active layer is the layer the click landed on, except when Ctrl removed it: then the topmost
/// remaining layer stays active so the panels always have something to edit.
pub fn apply_click(document: &Document, selected: &[Uuid], active: Option<Uuid>, clicked: Uuid, kind: ClickKind) -> Vec<Uuid> {
    if document.index_of(clicked).is_none() {
        return selected.to_vec();
    }
    let mut next: Vec<Uuid> = match kind {
        ClickKind::Replace => vec![clicked],
        ClickKind::Toggle => {
            let mut next = selected.to_vec();
            match next.iter().position(|id| *id == clicked) {
                Some(position) => {
                    next.remove(position);
                }
                None => next.push(clicked),
            }
            next
        }
        ClickKind::Extend => {
            let anchor = active.filter(|id| document.index_of(*id).is_some()).unwrap_or(clicked);
            let (Some(from), Some(to)) = (document.index_of(anchor), document.index_of(clicked)) else {
                return selected.to_vec();
            };
            let (low, high) = if from <= to { (from, to) } else { (to, from) };
            document.layers[low..=high].iter().map(|layer| layer.id).collect()
        }
    };
    // Document order, so the merge plan and the panel agree on what "the topmost selected" means.
    next.sort_by_key(|id| document.index_of(*id).unwrap_or(usize::MAX));
    next.dedup();
    next
}

/// The layer the panels edit after a click: the one clicked, or the topmost that is left.
pub fn active_after_click(document: &Document, selected: &[Uuid], clicked: Uuid, kind: ClickKind) -> Option<Uuid> {
    match kind {
        ClickKind::Replace | ClickKind::Extend => Some(clicked),
        ClickKind::Toggle => {
            if selected.contains(&clicked) {
                // It was just removed; keep the topmost of what remains.
                let mut remaining = selected.to_vec();
                remaining.retain(|id| *id != clicked);
                remaining.sort_by_key(|id| document.index_of(*id).unwrap_or(usize::MAX));
                remaining.last().copied()
            } else {
                Some(clicked)
            }
        }
    }
}

/// The selection after layers disappear, keeping the order and dropping anything gone.
pub fn prune(document: &Document, selected: &[Uuid]) -> Vec<Uuid> {
    let mut kept: Vec<Uuid> = selected.iter().copied().filter(|id| document.index_of(*id).is_some()).collect();
    kept.sort_by_key(|id| document.index_of(*id).unwrap_or(usize::MAX));
    kept.dedup();
    kept
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::layer::Layer;

    fn document() -> (Document, [Uuid; 4]) {
        let mut document = Document::new(16, 16);
        let a = document.add_layer(Layer::raster("A", 16, 16), None);
        let b = document.add_layer(Layer::raster("B", 16, 16), None);
        let c = document.add_layer(Layer::raster("C", 16, 16), None);
        let d = document.add_layer(Layer::raster("D", 16, 16), None);
        (document, [a, b, c, d])
    }

    #[test]
    fn a_plain_click_selects_one_layer() {
        let (document, [a, b, _, _]) = document();
        let next = apply_click(&document, &[a], Some(a), b, ClickKind::Replace);
        assert_eq!(next, vec![b]);
        assert_eq!(active_after_click(&document, &[a], b, ClickKind::Replace), Some(b));
    }

    #[test]
    fn control_click_adds_and_removes_one_layer() {
        let (document, [a, b, c, _]) = document();
        let added = apply_click(&document, &[a, c], Some(c), b, ClickKind::Toggle);
        assert_eq!(added, vec![a, b, c], "the selection comes back in document order");
        assert_eq!(active_after_click(&document, &[a, c], b, ClickKind::Toggle), Some(b));

        let removed = apply_click(&document, &[a, b, c], Some(b), b, ClickKind::Toggle);
        assert_eq!(removed, vec![a, c]);
        assert_eq!(
            active_after_click(&document, &[a, b, c], b, ClickKind::Toggle),
            Some(c),
            "the topmost layer left becomes active"
        );
    }

    #[test]
    fn shift_click_selects_the_rows_in_between() {
        let (document, [a, b, c, d]) = document();
        assert_eq!(apply_click(&document, &[b], Some(b), d, ClickKind::Extend), vec![b, c, d]);
        assert_eq!(apply_click(&document, &[c], Some(c), a, ClickKind::Extend), vec![a, b, c]);
        assert_eq!(apply_click(&document, &[a], Some(a), a, ClickKind::Extend), vec![a], "one row is just that row");
        assert_eq!(apply_click(&document, &[a], Some(d), b, ClickKind::Extend), vec![b, c, d]);
    }

    #[test]
    fn a_click_on_a_layer_that_is_gone_changes_nothing() {
        let (document, [a, _, _, _]) = document();
        assert_eq!(apply_click(&document, &[a], Some(a), Uuid::nil(), ClickKind::Replace), vec![a]);
    }

    #[test]
    fn a_selection_is_pruned_to_what_still_exists() {
        let (mut document, [a, b, c, d]) = document();
        document.remove_layer(b);
        assert_eq!(prune(&document, &[a, b, c, d]), vec![a, c, d]);
        assert!(prune(&document, &[]).is_empty());
    }

    #[test]
    fn shifting_across_a_folder_takes_its_children_too() {
        let mut document = Document::new(16, 16);
        let bottom = document.add_layer(Layer::raster("Bottom", 16, 16), None);
        let folder = Layer::group("Folder", 16, 16);
        let folder_id = folder.id;
        document.add_layer(folder, None);
        let child = document.add_layer(Layer::raster("Child", 16, 16), Some(folder_id));
        let next = apply_click(&document, &[bottom], Some(bottom), child, ClickKind::Extend);
        assert_eq!(next, vec![bottom, folder_id, child], "the rows in between include the folder");
    }
}
