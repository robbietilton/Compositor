import AppKit
import SwiftUI

/// The Navigator, above the Layers panel: the whole document in small, with a red box around what the canvas shows.
/// Clicking or dragging in it moves the view there; its zoom row zooms the canvas. Its picture is redrawn a moment
/// after edits settle, and only while the panel is open.
struct NavigatorPanel: View {
    @Bindable var session: EditorSession
    /// The height of the column the Navigator shares with the Layers panel.
    var columnHeight = Double.infinity
    @AppStorage("navigator.expanded") private var expanded = true
    @AppStorage("navigator.height") private var height = 160.0
    @State private var picture: CGImage?
    @State private var dragStartHeight: Double?

    static let heights: ClosedRange<Double> = 90...420
    /// Pixels on the picture's longer side: sharp on a Retina display at the tallest height.
    static let picturePixels = 900
    static let zooms: ClosedRange<Double> = 0.01...32

    static func clampedHeight(_ value: Double) -> Double { min(heights.upperBound, max(heights.lowerBound, value)) }
    /// What the rest of the column keeps below and around the picture: the Navigator's header and zoom row, and room
    /// for the Layers panel to show its list.
    static let reservedHeight = 380.0
    /// The picture's height in a column `column` points tall: the stored height, shortened so Layers keeps its room.
    static func pictureHeight(_ stored: Double, column: Double) -> Double {
        max(heights.lowerBound, min(clampedHeight(stored), column - reservedHeight))
    }
    /// The slider moves in doublings (log2 of the zoom), so 1%–3200% spread evenly along it.
    static func slider(forZoom zoom: Double) -> Double { log2(min(zooms.upperBound, max(zooms.lowerBound, zoom))) }
    static func zoom(forSlider value: Double) -> Double { min(zooms.upperBound, max(zooms.lowerBound, pow(2, value))) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                preview.frame(height: shownHeight)
                zoomRow
                resizeHandle
            }
        }
        .task(id: RenderKey(document: session.document, revision: session.brushRevision, expanded: expanded)) {
            guard expanded, session.document != nil else { picture = nil; return }
            // Edits settle first, so a stroke or a drag redraws the picture once, afterwards.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            picture = session.navigatorImage(maxSide: Self.picturePixels)
        }
    }

    private var shownHeight: Double { Self.pictureHeight(height, column: columnHeight) }

    /// What the picture is drawn from. The layers rather than the whole document, so selecting, placing guides and
    /// the like don't redraw it.
    struct RenderKey: Equatable {
        let documentID: UUID?
        let size: CGSize
        let layers: [ImageLayer]
        let revision: Int
        let expanded: Bool

        init(document: CanvasDocument?, revision: Int, expanded: Bool) {
            documentID = document?.id
            size = document?.size ?? .zero
            layers = document?.layers ?? []
            self.revision = revision
            self.expanded = expanded
        }
    }

    private var header: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                Text("Navigator").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .accessibilityLabel(expanded ? "Collapse Navigator" : "Expand Navigator")
    }

    private var preview: some View {
        GeometryReader { proxy in
            let geometry = NavigatorGeometry(documentSize: session.document?.size ?? .zero, box: proxy.size)
            let image = geometry.imageRect
            ZStack(alignment: .topLeading) {
                Color(white: 0.11)
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().interpolation(.medium)
                        .frame(width: image.width, height: image.height)
                        .offset(x: image.minX, y: image.minY)
                }
                if let document = session.document {
                    let shown = geometry.thumbnailRect(for: session.viewport.visibleDocumentRect(documentSize: document.size))
                        .intersection(image)
                    if !shown.isNull, !shown.isEmpty {
                        Rectangle().strokeBorder(Color.red, lineWidth: 1.5)
                            .frame(width: max(3, shown.width), height: max(3, shown.height))
                            .offset(x: shown.minX, y: shown.minY)
                            .allowsHitTesting(false)
                    }
                } else {
                    Text("No document").font(.caption).foregroundStyle(.secondary)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard let document = session.document else { return }
                session.viewport.centerView(on: geometry.documentPoint(for: value.location), documentSize: document.size)
            })
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Navigator")
        .accessibilityHint("Click or drag to move the view")
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            Button { session.zoomKeyboard(by: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Slider(value: Binding(get: { Self.slider(forZoom: Double(session.viewport.zoom)) },
                                  set: { session.zoom(to: CGFloat(Self.zoom(forSlider: $0))) }),
                   in: Self.slider(forZoom: Self.zooms.lowerBound)...Self.slider(forZoom: Self.zooms.upperBound))
            Button { session.zoomKeyboard(by: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Text(session.viewport.zoom, format: .percent.precision(.fractionLength(0...1)))
                .font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .disabled(session.document == nil)
    }

    /// Drag the bottom edge to make the picture taller or shorter. Measured on the screen, as the handle moves with
    /// the edge it drags.
    private var resizeHandle: some View {
        Color.clear.frame(height: 6).contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                let start = dragStartHeight ?? shownHeight
                dragStartHeight = start
                height = Self.clampedHeight(start + value.translation.height)
            }.onEnded { _ in dragStartHeight = nil })
            .accessibilityLabel("Resize Navigator")
    }
}
