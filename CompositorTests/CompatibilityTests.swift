import CoreGraphics
import Combine
import Testing
@testable import Compositor

@Test("legacy delay converts milliseconds to nanoseconds")
func delayConversion() {
    #expect(LegacyDelay.milliseconds(30) == 30_000_000)
    #expect(LegacyDelay.milliseconds(250) == 250_000_000)
}

@Test("legacy change state reports the previous and new values")
func changeState() {
    var state = LegacyChangeState(10)
    #expect(state.update(10) == nil)
    #expect(state.update(12)?.old == 10)
    #expect(state.update(13)?.new == 13)
}

@Test("legacy observable models publish UI state changes")
@MainActor
func combineModelChanges() {
    let session = EditorSession()
    var emissions = 0
    let cancellable = session.objectWillChange.sink { _ in emissions += 1 }

    session.tool = .brush

    #expect(emissions > 0)
    _ = cancellable
}

@Test("legacy editor forwards nested observable changes")
@MainActor
func combineNestedEditorChanges() {
    let session = EditorSession()
    let picker = ColorPickerState(background: false, original: .white)
    session.colorPicker = picker

    var emissions = 0
    let cancellable = session.objectWillChange.sink { _ in emissions += 1 }
    picker.hsb.hue = 0.25

    #expect(emissions > 0)
    _ = cancellable
}

@Test("legacy workspace forwards its own state changes")
@MainActor
func combineWorkspaceChanges() {
    let workspace = ProjectWorkspace()
    var emissions = 0
    let cancellable = workspace.objectWillChange.sink { _ in emissions += 1 }

    workspace.isManaging = true

    #expect(emissions > 0)
    _ = cancellable
}

@Test("legacy workspace forwards active tab changes")
@MainActor
func combineWorkspaceTabChanges() {
    let workspace = ProjectWorkspace()
    let tab = workspace.addTab(reuseEmpty: false)
    var emissions = 0
    let cancellable = workspace.objectWillChange.sink { _ in emissions += 1 }

    tab.session.tool = .brush

    #expect(emissions > 0)
    _ = cancellable
}
