import SwiftUI
import UniformTypeIdentifiers

/// The panel for Generative Fill, Remove and Generative Expand. Every block keeps a fixed height: the floating
/// panel is sized once, when it opens, and results, errors and references all arrive later.
struct GenerativeFillSheet: View {
    @Bindable var session: EditorSession
    @FocusState private var promptFocused: Bool
    private var edit: GenerativeEdit? { session.generativeEdit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let edit {
                Text(intro(edit.mode)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if edit.mode != .remove {
                    TextField(edit.mode == .fill ? "Describe what to put here. Leave empty to remove what is selected." : "Optional: describe what the new area should show.",
                              text: Binding(get: { edit.prompt }, set: { edit.prompt = $0 }), axis: .vertical)
                        .lineLimit(3...3).textFieldStyle(.roundedBorder).focused($promptFocused)
                        .onSubmit { session.generate() }
                    references(edit)
                }
                options(edit)
                results(edit)
                status(edit)
                Divider()
                HStack {
                    Button("Cancel") { session.cancelGenerative() }.configuredNativeShortcut(.escape)
                    Spacer()
                    if edit.isGenerating {
                        ProgressView().controlSize(.small)
                        Text("Generating…").font(.callout).foregroundStyle(.secondary)
                        Button("Stop") { session.stopGenerating() }
                    } else if edit.variations.isEmpty {
                        Button("Generate") { session.generate() }
                            .configuredNativeShortcut(.return).buttonStyle(.borderedProminent).disabled(edit.needsDisclosure)
                    } else {
                        Button("Generate More") { session.generate() }
                        Button("Keep") { session.keepGenerative() }
                            .configuredNativeShortcut(.return).buttonStyle(.borderedProminent).disabled(edit.selected == nil)
                    }
                }
            }
        }
        .padding(24).frame(width: 420).fixedSize()
        .onAppear { promptFocused = true }
    }

    private func intro(_ mode: GenerativeMode) -> String {
        switch mode {
        case .fill: "Generates new content for the selection, on a new masked layer. Nothing outside the selection changes."
        case .remove: "Removes what is selected and fills in behind it, on a new masked layer."
        case .expand: "Fills the area the crop frame adds beyond the canvas, then enlarges the canvas to the frame."
        }
    }

    private func references(_ edit: GenerativeEdit) -> some View {
        HStack(spacing: 8) {
            ForEach(edit.references) { reference in
                Image(decorative: reference.thumbnail, scale: 1).resizable().scaledToFill()
                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .topTrailing) {
                        Button { edit.references.removeAll { $0.id == reference.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                        }.buttonStyle(.plain).offset(x: 5, y: -5).help("Remove this reference")
                    }
            }
            Button("Add Reference…") { chooseReference() }
                .disabled(edit.references.count >= GenerativeModel.referenceLimit || edit.isGenerating)
                .help("A picture of the object, material or style to use")
            Spacer()
        }.frame(height: 44)
    }

    private func options(_ edit: GenerativeEdit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Model", selection: Binding(get: { edit.model }, set: { edit.model = $0 })) {
                    ForEach(GenerativeModel.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 215)
                Picker("Results", selection: Binding(get: { edit.count }, set: { edit.count = $0 })) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 110).help("Each result is a separate, separately charged request")
            }
            HStack(spacing: 12) {
                Picker("Size", selection: Binding(get: { edit.size }, set: { edit.size = $0 })) {
                    Text("Automatic").tag(GenerativeSize?.none)
                    ForEach(GenerativeSize.allCases.filter { $0 <= edit.model.largestSize }, id: \.self) { Text($0.rawValue).tag(GenerativeSize?.some($0)) }
                }.frame(width: 215)
                if let plan = edit.plan {
                    Text(plan.detail < 0.995 ? "\(plan.size.rawValue) · \(Int((plan.detail * 100).rounded()))% of document detail" : "\(plan.size.rawValue) · full detail")
                        .font(.callout).foregroundStyle(plan.detail < 0.6 ? .orange : .secondary)
                        .help("Large areas are generated smaller than the document and enlarged to fit, which looks softer")
                }
            }
        }.disabled(edit.isGenerating)
    }

    private func results(_ edit: GenerativeEdit) -> some View {
        HStack(spacing: 8) {
            if edit.variations.isEmpty {
                Text(edit.isGenerating ? "This can take up to a minute." : "Results appear here and on the canvas.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(edit.variations) { variation in
                        if let thumbnail = variation.layer.asset?.thumbnail {
                            Button { session.selectVariation(variation.id) } label: {
                                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(variation.id == edit.selectedID ? Color.accentColor : .clear, lineWidth: 2.5))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(3)
            }
        }.frame(height: 64)
    }

    private func status(_ edit: GenerativeEdit) -> some View {
        // A container, not a Group: with nothing to say a Group is empty, and a height set on it reserves nothing.
        ZStack(alignment: .topLeading) {
            if edit.needsDisclosure {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Generating sends this part of your image with some of its surroundings, your prompt and any references to Google, using your API key. Each result is charged to your Google account.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Continue") { session.acceptGenerativeDisclosure() }
                }
            } else if edit.needsKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text(edit.error ?? "").foregroundStyle(.orange)
                    Button("Open Settings…") { GenerativeSettings.shared.show() }
                }
            } else if let error = edit.error {
                Text(error).foregroundStyle(.orange).lineLimit(5)
            }
        }
        .font(.callout).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 92, alignment: .topLeading)
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose a Reference Image"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await session.addGenerativeReference(url) }
        }
    }
}

/// Shows and hides the panel with the session's open generative edit. A modifier of its own: the editor's
/// body is already as much as the type checker will take.
struct GenerativePanelHost: ViewModifier {
    let session: EditorSession
    @State private var panel = FloatingPanelController(name: "generativePanel")

    func body(content: Content) -> some View {
        content.onChange(of: session.generativeEdit == nil) { _, closed in
            if closed { panel.close() }
            else {
                panel.onClose = { session.cancelGenerative() }
                panel.show(title: session.generativeEdit?.mode.title ?? "Generative Fill", content: GenerativeFillSheet(session: session))
            }
        }
    }
}
