import SwiftUI

/// The History panel: every edit the session recorded, listed oldest first, with the document's
/// current state highlighted; clicking a state returns the document to it, undoing or redoing
/// every step between. Shown docked at the canvas's top right corner — below the Navigator, when
/// that shows — or, from the header's button, in a separate floating window.
struct HistoryPanel: View {
    @Bindable var session: EditorSession
    /// Whether the panel lives in a separate window rather than docked on the canvas. Both
    /// arrangements share the setting, so the header's button moves the panel to the other.
    @Binding var showsInWindow: Bool

    var body: some View {
        if showsInWindow {
            content.frame(width: 200, height: 300)
        } else {
            content.frame(width: 200, height: 300)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    showsInWindow.toggle()
                } label: {
                    Image(systemName: showsInWindow ? "inset.filled.toptrailing.rectangle" : "macwindow.on.rectangle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showsInWindow ? "Dock to the canvas" : "Show in a separate window")
                .accessibilityLabel(showsInWindow ? "Dock to the canvas" : "Show in a separate window")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            statesList
        }
    }

    private var statesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(session.history.states.enumerated()), id: \.element.revision) { index, state in
                        stateRow(state, index: index)
                    }
                }
                .padding(6)
            }
            .onAppear { scrollCurrentIntoView(proxy) }
            .onChange(of: session.history.currentIndex) { _, _ in scrollCurrentIntoView(proxy) }
            .accessibilityLabel("History states")
        }
    }

    private func scrollCurrentIntoView(_ proxy: ScrollViewProxy) {
        let states = session.history.states
        guard states.indices.contains(session.history.currentIndex) else { return }
        proxy.scrollTo(states[session.history.currentIndex].revision)
    }

    private func stateRow(_ state: DocumentHistory.State, index: Int) -> some View {
        let current = index == session.history.currentIndex
        return Button {
            session.jumpToHistoryState(index)
        } label: {
            Text(state.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(current ? AnyShapeStyle(Color.white)
                                 : index > session.history.currentIndex ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        // Not `.disabled`: that would dim the current state's text, which the highlight already marks.
        .allowsHitTesting(!current)
        .help(current ? "Current state" : "Return to “\(state.name)”")
    }
}
