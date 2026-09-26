import SwiftUI

/// A compact, selectable History list. Selecting a row restores that document state and keeps
/// the ordinary undo/redo stack intact, so the panel is useful as well as merely diagnostic.
struct HistoryPanel: View {
    @Bindable var session: EditorSession
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(session.history.states.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("historyStateCount")
            }
            .padding(18)
            Divider()
            if session.history.states.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 25, weight: .light))
                    Text("No history yet").font(.callout.weight(.medium))
                    Text("Create or edit a canvas to see states.")
                        .font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(session.history.states) { state in
                                Button {
                                    _ = session.jumpToHistoryState(state.index)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: state.isCurrent ? "record.circle.fill" : "circle")
                                            .foregroundStyle(state.isCurrent ? Color.accentColor : .secondary)
                                        Text(state.name).lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(state.isCurrent ? Color.accentColor.opacity(0.14) : .clear)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("historyState-\(state.index)")
                                .accessibilityLabel(state.name)
                                .disabled(!session.canUseHistory)
                                .id(state.id)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(session.history.currentStateIndex, anchor: .center) }
                    .onChange(of: session.history.currentStateIndex) { _, index in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
            Divider()
            HStack(spacing: 0) {
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").footerHitArea() }
                    .help("Undo")
                    .disabled(!session.canUndo)
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward").footerHitArea() }
                    .help("Redo")
                    .disabled(!session.canRedo)
                Spacer()
                Text("⌘Z / ⇧⌘Z").font(.caption2).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(width: width)
        .accessibilityIdentifier("historyPanel")
    }
}
