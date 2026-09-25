import AppKit
import SwiftUI

/// The tool rail scrolls when it overflows without showing or reserving space
/// for a macOS scroller, even when the system setting always shows scroll bars.
struct IndicatorlessScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Container {
        Container(rootView: content())
    }

    func updateNSView(_ view: Container, context: Context) {
        view.host.rootView = content()
        view.host.invalidateIntrinsicContentSize()
        view.updateDocumentSize()
    }

    final class Container: NSScrollView {
        let host: NSHostingView<Content>

        init(rootView: Content) {
            host = NSHostingView(rootView: rootView)
            super.init(frame: .zero)
            drawsBackground = false
            borderType = .noBorder
            hasVerticalScroller = false
            hasHorizontalScroller = false
            horizontalScrollElasticity = .none
            documentView = host
            updateDocumentSize()
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            updateDocumentSize()
        }

        func updateDocumentSize() {
            let height = host.fittingSize.height
            let size = NSSize(width: 56, height: height)
            if host.frame.size != size { host.setFrameSize(size) }
            verticalScrollElasticity = height > contentView.bounds.height + 1 ? .allowed : .none
        }
    }
}
