import SwiftUI

/// The user's API key and choices for generative features. The key lives in the keychain; the rest are
/// ordinary preferences. Tests make their own, around a store and a provider that touch nothing real.
@MainActor @Observable
final class GenerativeSettings {
    static let shared = GenerativeSettings()

    enum KeyState: Equatable { case unchecked, checking, accepted, rejected(String) }

    @ObservationIgnored let provider: any GenerativeImageProvider
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let panel = FloatingPanelController(name: "generativeSettings")
    @ObservationIgnored private var check: Task<Void, Never>?
    private static let account = "gemini", modelKey = "generative.model", disclosureKey = "generative.disclosureAccepted"

    private(set) var hasKey: Bool
    private(set) var keyState = KeyState.unchecked
    var model: GenerativeModel { didSet { defaults.set(model.rawValue, forKey: Self.modelKey) } }
    /// Set once the user has been told what leaves the machine, and on whose account.
    var hasAcceptedDisclosure: Bool { didSet { defaults.set(hasAcceptedDisclosure, forKey: Self.disclosureKey) } }

    init(secrets: any SecretStore = KeychainSecretStore(), provider: any GenerativeImageProvider = GeminiProvider(), defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.provider = provider
        self.defaults = defaults
        // A model retired since it was chosen falls back to the default.
        model = defaults.string(forKey: Self.modelKey).flatMap(GenerativeModel.init) ?? .flash
        hasAcceptedDisclosure = defaults.bool(forKey: Self.disclosureKey)
        hasKey = secrets.secret(for: Self.account)?.isEmpty == false
    }

    var key: String? { secrets.secret(for: Self.account) }

    func setKey(_ key: String) throws {
        check?.cancel()
        try secrets.setSecret(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.account)
        hasKey = self.key?.isEmpty == false
        keyState = .unchecked
    }

    /// Asks the service whether the saved key works. Free: it lists models, it generates nothing.
    func verifyKey() async {
        check?.cancel()
        guard let key, !key.isEmpty else { keyState = .rejected(GenerativeError.missingKey.localizedDescription); return }
        keyState = .checking
        let provider = provider
        let task = Task { @MainActor [weak self] in
            let failure: String? = await Task.detached {
                do { try await provider.verify(key: key); return nil } catch { return error.localizedDescription }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.keyState = failure.map(KeyState.rejected) ?? .accepted
        }
        check = task
        await task.value
    }

    func show() { panel.show(title: "Generative AI Settings", content: GenerativeSettingsSheet(settings: self)) }
    func close() { panel.close() }
}
