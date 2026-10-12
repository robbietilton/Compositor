import CryptoKit
import Foundation
import Observation

struct AppLanguage: Codable, Hashable, Identifiable, Sendable {
    let code: String
    let displayName: String
    let file: String?
    let sha256: String?
    let revision: Int

    static let storageKey = "application.language"
    static let english = AppLanguage(code: "en", displayName: "English", file: nil, sha256: nil, revision: 0)
    static let simplifiedChinese = AppLanguage(code: "zh-Hans", displayName: "简体中文",
                                                file: "zh-Hans.json", sha256: nil, revision: 1)
    static let traditionalChinese = AppLanguage(code: "zh-Hant", displayName: "繁體中文",
                                                 file: "zh-Hant.json", sha256: nil, revision: 1)
    static let initialChoices = [english, simplifiedChinese, traditionalChinese]

    var id: String { code }
    var rawValue: String { code }
    var locale: Locale { Locale(identifier: code) }
    var isBuiltIn: Bool { code == Self.english.code }

    static func resolved(_ code: String?, from choices: [AppLanguage] = initialChoices) -> AppLanguage {
        choices.first { $0.code == code } ?? .english
    }

    static var current: AppLanguage {
        LanguageManager.shared.activeLanguage
    }
}

private struct LanguageManifest: Codable, Sendable {
    let schemaVersion: Int
    let languages: [AppLanguage]
}

private struct LanguagePack: Codable, Sendable {
    let schemaVersion: Int
    let language: String
    let revision: Int
    let strings: [String: String]
}

enum LanguagePackFailure: LocalizedError {
    case invalidManifest
    case invalidLanguageCode
    case invalidResponse
    case packTooLarge
    case checksum
    case wrongLanguage

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The language list is not compatible with this version of Compositor."
        case .invalidLanguageCode: "The language code is invalid."
        case .invalidResponse: "The language server returned an invalid response."
        case .packTooLarge: "The language file is larger than Compositor allows."
        case .checksum: "The downloaded language file failed its integrity check."
        case .wrongLanguage: "The downloaded file contains a different language."
        }
    }
}

/// Downloads optional languages and keeps verified copies in Application Support. English remains built in, so the
/// interface always has a usable fallback. The active pack is decoded in memory while the app is running; its source
/// file persists on disk and is reused until the remote manifest advertises a different checksum.
@MainActor @Observable
final class LanguageManager {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let shared = LanguageManager()
    nonisolated static let defaultManifestURL = URL(string:
        "https://raw.githubusercontent.com/RyuProject/Compositor/main/Languages/manifest.json")!

    private(set) var availableLanguages: [AppLanguage]
    private(set) var selectedLanguage: AppLanguage
    private(set) var activeLanguage: AppLanguage = .english
    private(set) var downloadingLanguageCode: String?
    private(set) var lastError: String?
    private(set) var revision = 0

    private let manifestURL: URL
    private let loader: Loader
    private let directory: URL
    private let defaults: UserDefaults
    private var translations: [String: String] = [:]

    init(manifestURL: URL? = nil, session: URLSession? = nil,
         directory: URL? = nil, defaults: UserDefaults = .standard, loader: Loader? = nil) {
        let resolvedDirectory = directory ?? Self.languageDirectory()
        let initialLanguages = Self.initialLanguages(from: resolvedDirectory)
        let initialSelection = AppLanguage.resolved(defaults.string(forKey: AppLanguage.storageKey),
                                                    from: initialLanguages)

        self.manifestURL = manifestURL ?? Self.defaultManifestURL
        let downloadSession = session ?? Self.downloadSession()
        self.loader = loader ?? { try await downloadSession.data(for: $0) }
        self.directory = resolvedDirectory
        self.defaults = defaults
        availableLanguages = initialLanguages
        selectedLanguage = initialSelection
        try? FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        if initialSelection != .english,
           let pack = try? Self.readPack(for: initialSelection, from: resolvedDirectory) {
            activeLanguage = initialSelection
            translations = pack.strings
        }
    }

    var locale: Locale { activeLanguage.locale }

    func prepare() async {
        do {
            try await refreshManifest()
            if selectedLanguage != .english {
                guard let refreshedLanguage = availableLanguages.first(where: { $0.code == selectedLanguage.code }) else {
                    translations = [:]
                    activeLanguage = .english
                    revision += 1
                    return
                }
                selectedLanguage = refreshedLanguage
                if !activateCached(refreshedLanguage) { await downloadAndActivate(refreshedLanguage) }
            }
        } catch {
            lastError = error.localizedDescription
            if selectedLanguage != .english, activeLanguage == .english {
                _ = activateCached(selectedLanguage)
            }
        }
    }

    func select(_ language: AppLanguage) async {
        defaults.set(language.code, forKey: AppLanguage.storageKey)
        lastError = nil
        if language.isBuiltIn {
            selectedLanguage = .english
            translations = [:]
            activeLanguage = .english
            downloadingLanguageCode = nil
            revision += 1
            return
        }
        do {
            if !Self.isValidRemoteLanguage(language) { try await refreshManifest() }
            guard let verifiedLanguage = availableLanguages.first(where: { $0.code == language.code }),
                  Self.isValidRemoteLanguage(verifiedLanguage) else {
                throw LanguagePackFailure.invalidManifest
            }
            selectedLanguage = verifiedLanguage
            if activateCached(verifiedLanguage) { return }
            await downloadAndActivate(verifiedLanguage)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func string(_ key: String) -> String {
        activeLanguage == .english ? key : translations[key] ?? key
    }

    private func apply(_ manifest: LanguageManifest) {
        guard manifest.schemaVersion == 1 else { return }
        let valid = manifest.languages.filter(Self.isValidRemoteLanguage)
        availableLanguages = [.english] + valid
    }

    private func refreshManifest() async throws {
        let manifest = try await downloadManifest()
        try Self.write(manifest.data, to: directory.appending(path: "manifest.json"))
        apply(manifest.value)
    }

    private func activateCached(_ language: AppLanguage) -> Bool {
        guard let pack = try? Self.readPack(for: language, from: directory) else { return false }
        translations = pack.strings
        activeLanguage = language
        revision += 1
        return true
    }

    private func downloadAndActivate(_ language: AppLanguage) async {
        guard Self.isValidLanguageCode(language.code), let file = language.file,
              let url = URL(string: file, relativeTo: manifestURL.deletingLastPathComponent())?.absoluteURL else {
            lastError = LanguagePackFailure.invalidLanguageCode.localizedDescription
            return
        }
        downloadingLanguageCode = language.code
        defer { downloadingLanguageCode = nil }
        do {
            let data = try await download(url, maximumBytes: 5_000_000)
            try Self.validate(data, for: language)
            try Self.write(data, to: Self.packURL(for: language.code, in: directory))
            guard activateCached(language) else { throw LanguagePackFailure.wrongLanguage }
        } catch {
            lastError = error.localizedDescription
            if activeLanguage.code != language.code {
                translations = [:]
                activeLanguage = .english
                revision += 1
            }
        }
    }

    private func downloadManifest() async throws -> (value: LanguageManifest, data: Data) {
        let data = try await download(manifestURL, maximumBytes: 1_000_000)
        let manifest = try JSONDecoder().decode(LanguageManifest.self, from: data)
        guard manifest.schemaVersion == 1 else { throw LanguagePackFailure.invalidManifest }
        return (manifest, data)
    }

    private func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await loader(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LanguagePackFailure.invalidResponse
        }
        guard data.count <= maximumBytes else { throw LanguagePackFailure.packTooLarge }
        return data
    }

    private static func readPack(for language: AppLanguage, from directory: URL) throws -> LanguagePack {
        let data = try Data(contentsOf: packURL(for: language.code, in: directory), options: [.mappedIfSafe])
        try validate(data, for: language)
        return try JSONDecoder().decode(LanguagePack.self, from: data)
    }

    private static func validate(_ data: Data, for language: AppLanguage) throws {
        guard let checksum = language.sha256, !checksum.isEmpty else { throw LanguagePackFailure.invalidManifest }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == checksum.lowercased() else { throw LanguagePackFailure.checksum }
        let pack = try JSONDecoder().decode(LanguagePack.self, from: data)
        guard pack.schemaVersion == 1, pack.language == language.code,
              pack.revision == language.revision else { throw LanguagePackFailure.wrongLanguage }
    }

    private static func initialLanguages(from directory: URL) -> [AppLanguage] {
        guard let data = try? Data(contentsOf: directory.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(LanguageManifest.self, from: data),
              manifest.schemaVersion == 1 else { return AppLanguage.initialChoices }
        let valid = manifest.languages.filter(isValidRemoteLanguage)
        return [.english] + valid
    }

    private static func downloadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func languageDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Compositor/Languages", directoryHint: .isDirectory)
    }

    private static func isValidLanguageCode(_ code: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !code.isEmpty && code.count <= 32 && code.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isValidRemoteLanguage(_ language: AppLanguage) -> Bool {
        guard !language.isBuiltIn, isValidLanguageCode(language.code), language.revision > 0,
              let file = language.file, !file.isEmpty, file == URL(fileURLWithPath: file).lastPathComponent,
              let checksum = language.sha256, checksum.count == 64 else { return false }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return checksum.unicodeScalars.allSatisfy { hexadecimal.contains($0) }
    }

    private static func packURL(for code: String, in directory: URL) -> URL {
        directory.appending(path: code + ".json")
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Localizes every UI boundary through the active downloaded pack. Missing strings deliberately fall back to their
/// English keys so a partial community translation can never make a control blank.
@MainActor
enum L10n {
    static func string(_ key: String) -> String {
        LanguageManager.shared.string(key)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: LanguageManager.shared.locale, arguments: arguments)
    }
}
