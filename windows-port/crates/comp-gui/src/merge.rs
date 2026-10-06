//! Merging and flattening layers, following the macOS LayerMerge plan.
//!
//! A merge composites the layers it covers exactly as the canvas shows them — blend modes, opacity,
//! masks, clipping and adjustments baked in — trims the result to what is actually there, and drops
//! it back into the stack where the layer stood.

use std::collections::HashSet;

use comp_core::bitmap::Bitmap8;
use comp_core::document::Document;
use comp_core::geom::{PointF, SizeF, Transform};
use comp_core::layer::Layer;
use uuid::Uuid;

/// What a merge would do, worked out before anything changes.
#[derive(Clone, Debug, PartialEq)]
pub struct MergePlan {
    /// The layers that go in, bottom to top.
    pub ids: Vec<Uuid>,
    /// What the result is called: the name of the layer it merges into.
    pub name: String,
    /// The folder the result joins.
    pub parent: Option<Uuid>,
    /// The layer whose place the result takes.
    pub anchor: Uuid,
    /// The undo label.
    pub label: &'static str,
}

/// Works out what the selection would merge.
///
/// Several selected layers merge together, with anything their folders hold. One layer merges down
/// into the nearest sibling below that is not a folder; a folder merges its own contents and goes
/// away. Both are what macOS does.
pub fn merge_plan(document: &Document, selected: &[Uuid]) -> Option<MergePlan> {
    let mut ordered: Vec<Uuid> = selected.iter().copied().filter(|id| document.index_of(*id).is_some()).collect();
    ordered.sort_by_key(|id| document.index_of(*id).unwrap_or(usize::MAX));
    ordered.dedup();
    if ordered.len() > 1 {
        return multi_plan(document, &ordered);
    }
    let active_id = ordered.first().copied().or(document.active_layer)?;
    let active = document.layer(active_id)?;
    if active.is_group {
        let indices = document.subtree_indices(active_id);
        let ids: Vec<Uuid> = indices.iter().map(|index| document.layers[*index].id).collect();
        // A folder holding only folders has no pixels of its own to merge.
        if !indices.iter().any(|index| !document.layers[*index].is_group) {
            return None;
        }
        return Some(MergePlan {
            ids,
            name: active.name.clone(),
            parent: active.parent,
            anchor: active_id,
            label: "Merge Group",
        });
    }
    let index = document.index_of(active_id)?;
    let below = document.layers[..index]
        .iter()
        .rev()
        .find(|layer| layer.parent == active.parent && !layer.is_group)?;
    Some(MergePlan {
        ids: vec![below.id, active_id],
        name: below.name.clone(),
        parent: active.parent,
        anchor: active_id,
        label: "Merge Down",
    })
}

/// The plan for several selected layers: they merge into the topmost one's place and name.
fn multi_plan(document: &Document, ordered: &[Uuid]) -> Option<MergePlan> {
    let mut ids: Vec<Uuid> = Vec::new();
    for id in ordered {
        for index in document.subtree_indices(*id) {
            ids.push(document.layers[index].id);
        }
    }
    ids.sort_by_key(|id| document.index_of(*id).unwrap_or(usize::MAX));
    ids.dedup();
    // A selection of folders with nothing but folders inside has no pixels to merge.
    if !ids.iter().any(|id| document.layer(*id).map(|layer| !layer.is_group).unwrap_or(false)) {
        return None;
    }
    let anchor = *ordered.last()?;
    let top = document.layer(anchor)?;
    Some(MergePlan { ids, name: top.name.clone(), parent: top.parent, anchor, label: "Merge Layers" })
}

/// Composites just these layers the way the canvas shows them, trimmed to what is there.
///
/// Returns the pixels and the canvas point their top-left corner sits at, or None when the result
/// is empty. Clips and parents that point outside the merge are cut loose first, exactly as macOS
/// does, so a layer is not clipped to something it no longer sits on.
pub fn composite_subset(document: &Document, ids: &[Uuid]) -> Option<(Bitmap8, (i64, i64))> {
    let kept: HashSet<Uuid> = ids.iter().copied().collect();
    let mut subset = Document::new(document.width, document.height);
    subset.resolution = document.resolution;
    for layer in &document.layers {
        if !kept.contains(&layer.id) {
            continue;
        }
        let mut copy = layer.clone();
        if copy.parent.map(|parent| !kept.contains(&parent)).unwrap_or(false) {
            copy.parent = None;
        }
        if copy.mask_source.map(|source| !kept.contains(&source)).unwrap_or(false) {
            copy.mask_source = None;
        }
        subset.layers.push(copy);
    }
    if subset.layers.is_empty() {
        return None;
    }
    let flattened = comp_render::flatten_document(&subset);
    let (x, y, width, height) = flattened.opaque_bounds()?;
    Some((flattened.subimage(x as i64, y as i64, width, height), (x as i64, y as i64)))
}

/// Replaces the planned layers with the merged result, in the place the anchor held.
///
/// Returns false when the merge would produce nothing, leaving the document untouched.
pub fn apply_plan(document: &mut Document, plan: &MergePlan) -> bool {
    let Some((pixels, origin)) = composite_subset(document, &plan.ids) else { return false };
    if pixels.is_empty() {
        return false;
    }
    let Some(anchor_index) = document.index_of(plan.anchor) else { return false };
    let removed: HashSet<Uuid> = plan.ids.iter().copied().collect();
    let insertion = anchor_index - document.layers[..anchor_index].iter().filter(|layer| removed.contains(&layer.id)).count();

    let mut merged = Layer::with_image(plan.name.clone(), pixels);
    merged.transform = Transform::new(
        PointF::new(origin.0 as f64, origin.1 as f64),
        SizeF::new(merged.image.as_deref().map(|image| image.width()).unwrap_or(0) as f64,
                   merged.image.as_deref().map(|image| image.height()).unwrap_or(0) as f64),
    );
    merged.parent = plan.parent;
    let merged_id = merged.id;

    document.layers.retain(|layer| !removed.contains(&layer.id));
    // Anything that clipped to a layer which is now part of the merge clips to the result instead.
    for layer in document.layers.iter_mut() {
        if layer.mask_source.map(|source| removed.contains(&source)).unwrap_or(false) {
            layer.mask_source = Some(merged_id);
        }
    }
    let index = insertion.min(document.layers.len());
    document.layers.insert(index, merged);
    document.active_layer = Some(merged_id);
    true
}

/// The whole document as one flat image, or None when there is nothing to flatten.
pub fn flatten(document: &Document) -> Option<Bitmap8> {
    if document.layers.is_empty() {
        return None;
    }
    Some(comp_render::flatten_document(document))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reorder::subtrees_are_contiguous;

    fn solid(name: &str, size: u32, color: [u8; 4]) -> Layer {
        Layer::with_image(name, Bitmap8::filled(size, size, color))
    }

    /// Bottom to top: [Bottom, Folder, Child, Top].
    fn document() -> (Document, Uuid, Uuid, Uuid, Uuid) {
        let mut document = Document::new(16, 16);
        let bottom = document.add_layer(solid("Bottom", 16, [200, 0, 0, 255]), None);
        let folder = Layer::group("Folder", 16, 16);
        let folder_id = folder.id;
        document.add_layer(folder, None);
        let child = document.add_layer(solid("Child", 16, [0, 200, 0, 255]), Some(folder_id));
        let top = document.add_layer(solid("Top", 16, [0, 0, 200, 255]), None);
        (document, bottom, folder_id, child, top)
    }

    #[test]
    fn merging_down_picks_the_sibling_below_and_takes_its_name() {
        let (document, bottom, _folder, _child, top) = document();
        let plan = merge_plan(&document, &[top]).expect("the top layer has a sibling below");
        assert_eq!(plan.label, "Merge Down");
        assert_eq!(plan.ids, vec![bottom, top]);
        assert_eq!(plan.name, "Bottom");
        assert_eq!(plan.parent, None);
        assert_eq!(plan.anchor, top);
    }

    #[test]
    fn a_merge_is_refused_when_there_is_nothing_to_merge_into() {
        let mut document = Document::new(16, 16);
        let only = document.add_layer(solid("Only", 16, [1, 2, 3, 255]), None);
        assert!(merge_plan(&document, &[only]).is_none(), "the bottom layer has nothing below it");

        // A folder directly below the active layer is not a merge partner.
        let mut stacked = Document::new(16, 16);
        let folder = Layer::group("Folder", 16, 16);
        let folder_id = folder.id;
        stacked.add_layer(folder, None);
        let top = stacked.add_layer(solid("Top", 16, [9, 9, 9, 255]), None);
        stacked.active_layer = Some(top);
        assert!(merge_plan(&stacked, &[top]).is_none(), "macOS does not merge into a folder");
        assert_eq!(stacked.layers.len(), 2);
        let _ = (only, folder_id);
    }

    #[test]
    fn a_folder_merges_its_contents_and_goes_away() {
        let (mut document, _bottom, folder, child, _top) = document();
        document.active_layer = Some(folder);
        let plan = merge_plan(&document, &[folder]).expect("the folder holds pixels");
        assert_eq!(plan.label, "Merge Group");
        assert_eq!(plan.ids, vec![folder, child]);
        assert_eq!(plan.name, "Folder");
        assert!(apply_plan(&mut document, &plan));
        assert_eq!(document.layers.len(), 3, "the folder and its child became one layer");
        assert!(document.layer(folder).is_none());
        assert!(document.layer(child).is_none());
        assert!(subtrees_are_contiguous(&document));
    }

    #[test]
    fn a_folder_of_folders_has_nothing_to_merge() {
        let mut document = Document::new(16, 16);
        let outer = Layer::group("Outer", 16, 16);
        let outer_id = outer.id;
        document.add_layer(outer, None);
        document.add_layer(Layer::group("Inner", 16, 16), Some(outer_id));
        document.active_layer = Some(outer_id);
        assert!(merge_plan(&document, &[outer_id]).is_none());
    }

    #[test]
    fn a_subset_composite_trims_to_what_is_there() {
        let mut document = Document::new(16, 16);
        let mut patch = solid("Patch", 4, [10, 20, 30, 255]);
        patch.transform.origin = PointF::new(5.0, 6.0);
        patch.transform.size = SizeF::new(4.0, 4.0);
        let patch_id = patch.id;
        document.add_layer(patch, None);
        let other = document.add_layer(solid("Elsewhere", 16, [200, 200, 200, 255]), None);

        let (pixels, origin) = composite_subset(&document, &[patch_id]).expect("the patch has pixels");
        assert_eq!((pixels.width(), pixels.height()), (4, 4), "the empty canvas around it is trimmed");
        assert_eq!(origin, (5, 6));
        assert_eq!(pixels.get(0, 0), [10, 20, 30, 255]);
        assert!(composite_subset(&document, &[other]).is_some());
        assert!(composite_subset(&document, &[Uuid::nil()]).is_none());
    }

    #[test]
    fn merging_down_takes_the_place_of_the_layer_above() {
        let (mut document, _bottom, _folder, _child, top) = document();
        let plan = merge_plan(&document, &[top]).unwrap();
        assert!(apply_plan(&mut document, &plan));
        assert_eq!(document.layers.len(), 3);
        assert!(document.layer(top).is_none(), "the anchor layer became the merged one");
        let merged = document.layers.last().unwrap();
        assert_eq!(merged.name, "Bottom");
        assert_eq!(merged.parent, None);
        assert_eq!(document.active_layer, Some(merged.id));
        // The top layer covered everything, so the merge keeps the whole canvas.
        let image = merged.image.as_ref().unwrap();
        assert_eq!(image.get(8, 8), [0, 0, 200, 255], "the upper layer wins where it covers");
        assert!(subtrees_are_contiguous(&document));
    }

    #[test]
    fn layers_clipped_to_a_merged_layer_follow_the_result() {
        let mut document = Document::new(8, 8);
        let base = document.add_layer(solid("Base", 8, [255, 0, 0, 255]), None);
        let mut clipped = solid("Clipped", 8, [0, 0, 255, 255]);
        clipped.mask_source = Some(base);
        let clipped_id = document.add_layer(clipped, None);
        let mut over = solid("Over", 8, [0, 255, 0, 255]);
        over.mask_source = Some(clipped_id);
        let over_id = document.add_layer(over, None);

        document.active_layer = Some(clipped_id);
        let plan = merge_plan(&document, &[clipped_id]).expect("it has a sibling below");
        assert!(apply_plan(&mut document, &plan));
        let merged_id = document.active_layer.unwrap();
        assert_eq!(document.layer(over_id).unwrap().mask_source, Some(merged_id), "the clip follows the result");
        assert_eq!(document.layers.len(), 2);
    }

    #[test]
    fn flattening_leaves_one_layer_with_the_whole_picture() {
        let (document, _bottom, _folder, _child, _top) = document();
        let expected = comp_render::flatten_document(&document);
        let flattened = flatten(&document).expect("a document with layers flattens");
        assert_eq!(flattened.pixels(), expected.pixels());
        assert!(flatten(&Document::new(4, 4)).is_none(), "nothing to flatten");
    }

    #[test]
    fn several_selected_layers_merge_into_the_topmost_ones_place() {
        let (mut document, bottom, folder, child, top) = document();
        // Bottom and the child inside the folder: the folder's subtree only travels if it is picked.
        let plan = merge_plan(&document, &[bottom, child]).expect("two layers with pixels");
        assert_eq!(plan.label, "Merge Layers");
        assert_eq!(plan.ids, vec![bottom, child], "only what was selected");
        assert_eq!(plan.name, "Child", "the topmost selected layer names the result");
        assert_eq!(plan.anchor, child, "and gives it its place");
        assert_eq!(plan.parent, Some(folder));
        assert!(apply_plan(&mut document, &plan));
        assert_eq!(document.layers.len(), 3, "two layers became one inside the folder");
        assert!(document.layer(bottom).is_none());
        assert!(document.layer(child).is_none());
        assert_eq!(document.layer(folder).unwrap().parent, None);
        assert!(subtrees_are_contiguous(&document));
        let _ = top;
    }

    #[test]
    fn selecting_a_folder_merges_what_is_inside_it() {
        let (mut document, bottom, folder, child, top) = document();
        let plan = merge_plan(&document, &[folder, top]).expect("the folder and the top layer");
        assert_eq!(plan.ids, vec![folder, child, top], "a picked folder brings its contents");
        assert_eq!(plan.name, "Top");
        assert_eq!(plan.parent, None);
        assert!(apply_plan(&mut document, &plan));
        assert_eq!(document.layers.len(), 2, "the folder, its child and the top layer became one");
        assert!(document.layer(bottom).is_some(), "the layers that were not picked are untouched");
        assert!(subtrees_are_contiguous(&document));
    }

    #[test]
    fn a_selection_of_empty_folders_has_nothing_to_merge() {
        let mut document = Document::new(16, 16);
        let outer = Layer::group("Outer", 16, 16);
        let outer_id = outer.id;
        document.add_layer(outer, None);
        let inner = Layer::group("Inner", 16, 16);
        let inner_id = inner.id;
        document.add_layer(inner, Some(outer_id));
        assert!(merge_plan(&document, &[outer_id, inner_id]).is_none());
    }

    #[test]
    fn a_merge_into_an_empty_region_is_refused() {
        let mut document = Document::new(8, 8);
        let base = document.add_layer(Layer::with_image("Empty", Bitmap8::new(8, 8)), None);
        let top = document.add_layer(Layer::with_image("Also empty", Bitmap8::new(8, 8)), None);
        document.active_layer = Some(top);
        let plan = merge_plan(&document, &[top]).expect("two layers, one below the other");
        let before = document.clone();
        assert!(!apply_plan(&mut document, &plan), "a fully transparent merge has nothing to keep");
        assert_eq!(document, before);
        let _ = base;
    }
}
