import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor struct LayersFooterTests {
    /// Every button under the layers fits at the panel's narrowest: its icons can't shrink, and a footer wider than the
    /// panel pushes them out past both edges.
    @Test func theFooterFitsThePanelAtItsNarrowest() {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        let footer = NSHostingView(rootView: LayersFooter(session: session).fixedSize())
        #expect(footer.fittingSize.width <= LayersPanel.widths.lowerBound, "the footer needs \(footer.fittingSize.width)")
    }
}
