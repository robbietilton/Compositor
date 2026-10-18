import AppKit
import CameraRawHostContract
import Combine
import Foundation

@MainActor
final class CameraRawPanelModel: ObservableObject {
    let controls: [CameraRawControl]
    let sourceImage: CGImage
    @Published private(set) var previewImage: CGImage
    @Published private(set) var numericText: [String: String] = [:]
    @Published private(set) var inputErrors: [String: String] = [:]
    @Published private(set) var operationError: String?
    @Published private(set) var isPreviewing = false
    @Published private(set) var isApplying = false
    @Published private(set) var isFinished = false
    private(set) var initializationError: String?
    var didApply: (() -> Void)?

    private var host: (any CameraRawEditingHost)?
    private var draft: CameraRawDraft?
    private var previewTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(host: any CameraRawEditingHost) {
        self.host = host
        controls = host.controls
        sourceImage = host.sourceImage
        previewImage = host.sourceImage
        do {
            let draft = try CameraRawDraft(payload: host.initialPayload, controls: controls)
            self.draft = draft
            for control in controls {
                numericText[control.id] = Self.format(try draft.value(for: control))
            }
            schedulePreview()
        } catch {
            initializationError = error.localizedDescription
        }
    }

    var groups: [String] {
        controls.reduce(into: []) { result, control in
            if !result.contains(control.group) { result.append(control.group) }
        }
    }

    var errorMessage: String? {
        initializationError ?? controls.compactMap { inputErrors[$0.id] }.first ?? operationError
    }

    var canEdit: Bool { !isFinished && !isApplying && initializationError == nil }
    var canApply: Bool { canEdit && !isPreviewing && errorMessage == nil }
    var canRetryPreview: Bool { canEdit && inputErrors.isEmpty && operationError != nil }

    func value(for control: CameraRawControl) -> Double {
        (try? draft?.value(for: control)) ?? control.defaultValue
    }

    func setSlider(_ value: Double, for control: CameraRawControl) {
        guard canEdit else { return }
        numericText[control.id] = Self.format(value)
        update(value, for: control)
    }

    func setNumericText(_ text: String, for control: CameraRawControl) {
        guard canEdit else { return }
        numericText[control.id] = text
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite,
              (control.lowerBound...control.upperBound).contains(value) else {
            inputErrors[control.id] = CameraRawLocalization.format(
                "%1$@ must be a number from %2$@ to %3$@.",
                control.title, Self.format(control.lowerBound), Self.format(control.upperBound)
            )
            invalidatePreview()
            return
        }
        update(value, for: control)
    }

    func reset() {
        guard canEdit, var updatedDraft = draft else { return }
        do {
            for control in controls { try updatedDraft.set(control.defaultValue, for: control) }
            draft = updatedDraft
            inputErrors = [:]
            for control in controls { numericText[control.id] = Self.format(control.defaultValue) }
            schedulePreview()
        } catch {
            operationError = error.localizedDescription
        }
    }

    func retryPreview() {
        guard canRetryPreview else { return }
        schedulePreview()
    }

    func apply() {
        guard canApply, let host, let draft else { return }
        do {
            let payload = try draft.payload()
            invalidatePreview()
            isApplying = true
            applyTask = Task { [weak self] in
                do {
                    try await host.apply(payload: payload)
                    guard let self, !self.isFinished else { return }
                    self.isApplying = false
                    self.isFinished = true
                    self.host = nil
                    self.applyTask = nil
                    self.didApply?()
                    self.didApply = nil
                } catch {
                    guard let self, !self.isFinished else { return }
                    self.isApplying = false
                    self.operationError = CameraRawLocalization.format("Could not apply Camera Raw settings: %1$@", error.localizedDescription)
                    self.applyTask = nil
                }
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// The controller prevents user dismissal during the atomic host apply operation.
    func cancel() {
        guard !isFinished, !isApplying else { return }
        isFinished = true
        invalidatePreview()
        let retainedHost = host
        host = nil
        didApply = nil
        retainedHost?.cancel()
    }

    private func update(_ value: Double, for control: CameraRawControl) {
        do {
            try draft?.set(value, for: control)
            inputErrors[control.id] = nil
            schedulePreview()
        } catch {
            inputErrors[control.id] = error.localizedDescription
            invalidatePreview()
        }
    }

    private func invalidatePreview() {
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
    }

    private func schedulePreview() {
        invalidatePreview()
        guard canEdit, inputErrors.isEmpty, let draft else { return }
        operationError = nil
        isPreviewing = true
        let requestedGeneration = generation
        do {
            let payload = try draft.payload()
            previewTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    guard let self, let host = self.host, !self.isFinished else { return }
                    let image = try await host.preview(payload: payload)
                    // Host work may ignore cancellation. Never publish an obsolete result or error.
                    guard !Task.isCancelled, self.generation == requestedGeneration, !self.isFinished else { return }
                    self.previewImage = image
                    self.isPreviewing = false
                    self.previewTask = nil
                } catch {
                    guard let self, !Task.isCancelled,
                          self.generation == requestedGeneration, !self.isFinished else { return }
                    self.operationError = CameraRawLocalization.format("Could not preview Camera Raw settings: %1$@", error.localizedDescription)
                    self.isPreviewing = false
                    self.previewTask = nil
                }
            }
        } catch {
            operationError = error.localizedDescription
            isPreviewing = false
        }
    }

    private static func format(_ value: Double) -> String {
        // Keep enough precision that opening a field does not silently quantize the draft.
        String(value)
    }
}
