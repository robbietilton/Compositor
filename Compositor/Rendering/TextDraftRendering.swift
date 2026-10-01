import CoreGraphics
import Foundation

/// The text being typed, as the canvases draw it: rendered as its layer will hold it, where the on-canvas editor shows
/// it, so what is typed looks the same at any zoom as it will once it is committed — and on a layer with effects, with
/// them around it.
@MainActor final class TextDraftRendering {
    private let session: EditorSession
    /// The text rendered, remade only when its style changes.
    private var cache: (style: LayerTextStyle, image: CGImage)?
    /// The effects rendered for the text being edited, and what they were rendered from.
    private var effects: (image: CGImage, effects: LayerEffects, transform: LayerTransform, rendered: CGImage, inset: CGFloat)?
    /// Which layer and text `effects` were made for, so they can stand in once the edit is committed.
    private var effectsSource: (layerID: UUID, style: LayerTextStyle)?

    init(session: EditorSession) {
        self.session = session
    }

    /// The text being typed as pixels, placed where the editor shows it, `transform`.
    func text(shownAt transform: LayerTransform?) -> (image: CGImage, transform: LayerTransform)? {
        guard let draft = session.textDraft, let transform else { cache = nil; return nil }
        if cache?.style != draft.style {
            guard let image = try? EditorSession.textImage(draft.style) else { cache = nil; return nil }
            cache = (draft.style, image)
        }
        return cache.map { ($0.image, transform) }
    }

    /// Text being edited, as it shows among the layers: as it will be committed, with its effects around it. They stay
    /// on while it's edited, redone from the text as typed — and until a change has been redone, the last effects
    /// stand in under the new text rather than blinking off.
    func editedText(_ layer: ImageLayer, shownAt transform: LayerTransform?) -> (image: CGImage, transform: LayerTransform)? {
        guard let text = text(shownAt: transform) else { return nil }
        guard let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else { return text }
        // Redone only when the text's pixels, its place or its effects change.
        if self.effects?.image !== text.image || self.effects?.effects != effects || self.effects?.transform != text.transform {
            let mask = layer.mask.flatMap { owned -> CGImage? in
                guard let placement = owned.placement else { return owned.enabledImage }
                return owned.clipImage(placement: placement, over: text.transform,
                                       width: text.image.width, height: text.image.height, limit: 2048)
            }
            self.effects = session.effectsPreviews.renderNow(image: text.image, mask: mask, effects: effects)
                .map { (text.image, effects, text.transform, $0.image, $0.inset) }
            effectsSource = session.textDraft.map { (layer.id, $0.style) }
        }
        guard let built = self.effects else { return text }
        return (built.rendered, LayerEffectsRenderer.placed(text.transform, image: built.rendered, inset: built.inset))
    }

    /// Text editing just ended: if the layer now holds the text as it was last typed, its effects from the edit stand
    /// in until they're rebuilt from the committed pixels, so they don't blink off for a frame.
    func handOffEffects(_ document: CanvasDocument) {
        guard session.textDraft == nil, let built = effects, let source = effectsSource else { return }
        if document.layers.first(where: { $0.id == source.layerID })?.liveText?.style == source.style {
            session.effectsPreviews.seed(source.layerID, image: built.rendered,
                placement: LayerEffectsRenderer.placed(built.transform, image: built.rendered, inset: built.inset))
        }
        effects = nil
        effectsSource = nil
    }
}
