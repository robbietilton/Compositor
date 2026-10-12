import AppKit
import SwiftUI

/// The Navigator: a minimap in the canvas's top right corner, shown from 300% zoom, when the view is a small part of
/// the document. The whole document in small, with a box in the accent color around what the canvas shows; clicking
/// or dragging in it moves the view there. Its picture is redrawn a moment after edits settle, and only while it shows.
struct NavigatorMinimap: View {
    @Bindable var session: EditorSession
    @State private var picture: CGImage?

    static let zoomShown: CGFloat = 3
    /// The most room the document takes, in points: it's fitted inside, keeping its proportions.
    static let largest = CGSize(width: 126, height: 90)
    /// Pixels on the picture's longer side: sharp on a Retina display.
    static let picturePixels = 300

    /// The minimap's size for a document: fitted inside `largest`, its proportions kept.
    static func size(for document: CGSize) -> CGSize {
        guard document.width > 0, document.height > 0 else { return .zero }
        let scale = min(largest.width / document.width, largest.height / document.height)
        return CGSize(width: (document.width * scale).rounded(), height: (document.height * scale).rounded())
    }

    var body: some View {
        if let document = session.document {
            let size = Self.size(for: document.size)
            let geometry = NavigatorGeometry(documentSize: document.size, box: size)
            ZStack(alignment: .topLeading) {
                Color(white: 0.11)
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().interpolation(.medium)
                }
                let shown = geometry.thumbnailRect(for: session.viewport.visibleDocumentRect(documentSize: document.size))
                    .intersection(geometry.imageRect)
                if !shown.isNull, !shown.isEmpty {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .frame(width: max(3, shown.width), height: max(3, shown.height))
                        .offset(x: shown.minX, y: shown.minY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1) }
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                session.viewport.centerView(on: geometry.documentPoint(for: value.location), documentSize: document.size)
            })
            .pointerStyle(.default)
            .accessibilityElement()
            .accessibilityLabel(Text(L10n.string("Navigator")))
            .accessibilityHint(Text(L10n.string("Click or drag to move the view")))
            .task(id: RenderKey(document: session.document, revision: session.brushRevision)) {
                // Edits settle first, so a stroke or a drag redraws the picture once, afterwards.
                if picture != nil { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                picture = session.navigatorImage(maxSide: Self.picturePixels)
            }
        }
    }

    /// What the picture is drawn from. The layers rather than the whole document, so selecting, placing guides and
    /// the like don't redraw it.
    struct RenderKey: Equatable {
        let documentID: UUID?
        let size: CGSize
        let layers: [ImageLayer]
        let revision: Int

        init(document: CanvasDocument?, revision: Int) {
            documentID = document?.id
            size = document?.size ?? .zero
            layers = document?.layers ?? []
            self.revision = revision
        }
    }
}
