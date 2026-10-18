import AppKit
import CameraRawHostContract
import SwiftUI

@MainActor
public final class CameraRawPrincipal: NSObject, CameraRawPluginPrincipal {
    public required override init() { super.init() }

    public func makePanel(host: any CameraRawEditingHost) -> NSWindowController {
        CameraRawWindowController(host: host)
    }
}

@MainActor
private final class CameraRawWindowController: NSWindowController, NSWindowDelegate {
    private let model: CameraRawPanelModel

    init(host: any CameraRawEditingHost) {
        model = CameraRawPanelModel(host: host)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = CameraRawLocalization.string("Camera Raw")
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: CameraRawPanel(model: model, dismiss: { [weak self] in
            self?.close()
        }))
        model.didApply = { [weak self] in self?.close() }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func close() {
        guard !model.isApplying else { NSSound.beep(); return }
        model.cancel()
        super.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isApplying { NSSound.beep(); return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
    }
}

@MainActor
private struct CameraRawPanel: View {
    @ObservedObject var model: CameraRawPanelModel
    let dismiss: () -> Void
    @State private var compareOriginal = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Toggle(isOn: $compareOriginal) {
                            Text("Compare with Original", bundle: CameraRawLocalization.bundle)
                        }
                            .toggleStyle(.checkbox)
                        Spacer()
                        if model.isPreviewing {
                            ProgressView().controlSize(.small)
                            Text("Rendering Preview…", bundle: CameraRawLocalization.bundle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        if compareOriginal { image(model.sourceImage, title: CameraRawLocalization.string("Original")) }
                        image(model.previewImage, title: CameraRawLocalization.string("Preview"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(model.groups, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 16) {
                                Text(verbatim: group).font(.headline)
                                ForEach(model.controls.filter { $0.group == group }, id: \.id) { control in
                                    controlRow(control)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .frame(width: 320)
                .disabled(!model.canEdit)
            }
            Divider()
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(verbatim: error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if model.canRetryPreview {
                        Button { model.retryPreview() } label: {
                            Text("Retry Preview", bundle: CameraRawLocalization.bundle)
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .accessibilityIdentifier("cameraRaw.error")
            }
            HStack {
                Button { model.reset() } label: {
                    Text("Reset Sliders", bundle: CameraRawLocalization.bundle)
                }
                    .disabled(!model.canEdit)
                    .accessibilityIdentifier("cameraRaw.reset")
                Spacer()
                if model.isApplying {
                    ProgressView().controlSize(.small)
                    Text("Applying…", bundle: CameraRawLocalization.bundle).foregroundStyle(.secondary)
                }
                Button(action: dismiss) {
                    Text("Cancel", bundle: CameraRawLocalization.bundle)
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isApplying)
                    .accessibilityIdentifier("cameraRaw.cancel")
                Button { model.apply() } label: {
                    Text("Apply", bundle: CameraRawLocalization.bundle)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply)
                    .accessibilityIdentifier("cameraRaw.apply")
            }
            .padding(20)
        }
    }

    private func image(_ image: CGImage, title: String) -> some View {
        VStack(spacing: 8) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text(verbatim: CameraRawLocalization.format("%1$@ image", title)))
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func controlRow(_ control: CameraRawControl) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: control.title)
                Spacer()
                TextField(control.title, text: Binding(
                    get: { model.numericText[control.id] ?? String(control.defaultValue) },
                    set: { model.setNumericText($0, for: control) }
                ))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .accessibilityIdentifier("cameraRaw.value.\(control.id)")
            }
            // Invalid host metadata must not be passed to Slider's range precondition.
            if control.lowerBound.isFinite, control.upperBound.isFinite, control.lowerBound < control.upperBound {
                Slider(value: Binding(
                    get: { min(control.upperBound, max(control.lowerBound, model.value(for: control))) },
                    set: { model.setSlider($0, for: control) }
                ), in: control.lowerBound...control.upperBound)
                .accessibilityLabel(Text(verbatim: control.title))
                .accessibilityIdentifier("cameraRaw.slider.\(control.id)")
            }
        }
    }
}
