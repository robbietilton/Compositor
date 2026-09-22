import SwiftUI

/// Enlarger (AI upscaling): the scale, the model (downloaded on request), and the run with its progress.
struct AIUpscaleSheet: View {
    let session: EditorSession
    let autoStart: Bool
    let finish: () -> Void
    @State private var factor: Int
    @State private var running = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var error: String?
    @State private var cancellation = UpscaleCancellation()
    @State private var work: Task<Void, Never>?
    private var store: AIModelStore { .shared }

    init(session: EditorSession, factor: Int = 2, autoStart: Bool = false, finish: @escaping () -> Void) {
        self.session = session
        self.autoStart = autoStart
        self.finish = finish
        _factor = State(initialValue: factor == 4 ? 4 : 2)
    }

    private var tooLarge: Bool {
        guard session.document != nil else { return true }
        do { try session.validateAIUpscale(factor: factor); return false }
        catch { return true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enlarger").font(.headline)
            Text("Enlarges the canvas. Visible image layers are rebuilt by an AI model that adds convincing fine detail, such as fabric weave and rug fibres, instead of only interpolating; hidden layers, text, shapes and masks are resampled.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Scale", selection: $factor) {
                Text("2×").tag(2)
                Text("4×").tag(4)
            }
            .pickerStyle(.segmented).disabled(running)
            if let document = session.document {
                Text("\(document.width) × \(document.height) px  →  \(document.width * factor) × \(document.height * factor) px")
                    .font(.callout.monospacedDigit())
                if tooLarge {
                    Text("The canvas or image layers exceed the 100-megapixel, 30,000-pixel-per-side limit.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Divider()
            model
            if running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(running ? "Stop" : "Cancel") {
                    if running { cancellation.cancel(); status = "Stopping after this tile…" } else { finish() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Enlarge") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.state != .ready || running || tooLarge)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { if autoStart, store.state == .ready, !tooLarge { start() } }
        .onDisappear { cancellation.cancel(); work?.cancel() }
    }

    @ViewBuilder private var model: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.model.name).font(.callout.weight(.medium))
                Spacer()
                switch store.state {
                case .missing:
                    Button("Download Model (\(ByteCountFormatter.string(fromByteCount: Int64(store.model.size), countStyle: .file)))") {
                        store.download()
                    }
                case .downloading:
                    Button("Stop Download") { store.cancelDownload() }
                case .ready:
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    Button("Remove") { store.remove() }.buttonStyle(.link).disabled(running)
                case .failed:
                    Button("Try Again") { store.download() }
                }
            }
            if case .downloading(let fraction) = store.state {
                ProgressView(value: fraction)
            }
            if case .failed(let message) = store.state {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("\(store.model.credit). Downloaded once from the authors' official GitHub release and checked before use; it runs on this Mac's GPU, nothing is uploaded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start() {
        running = true
        error = nil
        progress = 0
        let token = UpscaleCancellation()
        cancellation = token
        let scale = factor, url = store.fileURL
        work = Task {
            do {
                try await session.aiUpscale(factor: scale, model: url, cancellation: token) { value, text in
                    guard running, cancellation === token, !token.isCancelled else { return }
                    progress = max(progress, value)
                    status = text
                }
                running = false
                finish()
            } catch is CancellationError {
                running = false
                status = ""
            } catch {
                running = false
                self.error = error.localizedDescription
            }
        }
    }
}
