import SwiftUI

extension EditorSession {
    /// Set by the project controller: runs Enlarger on `session` once a Darkroom apply with an Enlarger step is done.
    static var enlargeAfterDarkroom: ((EditorSession, Int) -> Void)?
}

/// Darkroom's last step: enlarge the finished canvas 2× or 4× with the AI model after Apply. The model is downloaded
/// here on request, as in the Enlarger sheet.
struct EnlargerStep: View {
    let session: EditorSession
    private var store: AIModelStore { .shared }
    private var edit: FilterEdit? { session.filterEdit }
    private var factor: Int { edit?.enlargeFactor ?? 0 }

    static func isReady(session: EditorSession, factor: Int) -> Bool {
        guard AIModelStore.shared.state == .ready else { return false }
        return (try? session.validateAIUpscale(factor: factor)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OUTPUT").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                .foregroundStyle(.secondary).padding(.top, 10).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 11) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 15)).frame(width: 18)
                        .foregroundStyle(factor > 1 ? FinishStyle.accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Enlarger").font(.system(size: 12, weight: factor > 1 ? .semibold : .regular))
                            .foregroundStyle(factor > 1 ? Color.white : Color(white: 0.7))
                        Text("AI detail, after Apply").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("Enlarger", isOn: Binding(get: { factor > 1 }, set: { edit?.enlargeFactor = $0 ? 2 : 0 }))
                        .labelsHidden().toggleStyle(.checkbox).accessibilityLabel("Enlarge after Apply")
                }
                if factor > 1 {
                    Picker("Scale", selection: Binding(get: { factor }, set: { edit?.enlargeFactor = $0 })) {
                        Text("2×").tag(2)
                        Text("4×").tag(4)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    if let document = session.document {
                        Text("\(document.width * factor) × \(document.height * factor) px")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if (try? session.validateAIUpscale(factor: factor)) == nil {
                        Text("Too large for the 100-megapixel canvas limit.").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    model
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(factor > 1 ? FinishStyle.accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(factor > 1 ? FinishStyle.accent.opacity(0.25) : Color.clear))
            .help("Enlarges the canvas with Real-ESRGAN after the finish is applied, with its own progress and undo step.")
        }
    }

    @ViewBuilder private var model: some View {
        switch store.state {
        case .missing:
            Button("Download model (\(ByteCountFormatter.string(fromByteCount: Int64(store.model.size), countStyle: .file)))") {
                store.download()
            }
            .controlSize(.small)
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction).controlSize(.small)
                Button("Stop") { store.cancelDownload() }.buttonStyle(.link).font(.system(size: 10))
            }
        case .ready:
            Label("Model ready", systemImage: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { store.download() }.controlSize(.small)
        }
    }
}
