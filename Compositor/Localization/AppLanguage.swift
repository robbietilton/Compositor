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
    case invalidResponse
    case unavailableLanguages
    case packTooLarge
    case checksum
    case wrongLanguage

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The language list is not compatible with this version of Compositor."
        case .invalidResponse: "The language server returned an invalid response."
        case .unavailableLanguages: "No verified language files are currently available."
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
    typealias Loader = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)
    static let shared = LanguageManager()
    nonisolated static let defaultManifestURL = URL(string:
        "https://raw.githubusercontent.com/RyuProject/Compositor/main/Languages/manifest.json")!
    private static let maximumRemoteLanguages = 32

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
    private var selectionGeneration = 0

    init(manifestURL: URL? = nil, session: URLSession? = nil,
         directory: URL? = nil, defaults: UserDefaults = .standard, loader: Loader? = nil) {
        let resolvedDirectory = directory ?? Self.languageDirectory()
        let cachedManifest = Self.cachedManifest(from: resolvedDirectory)
        let cachedLanguages = Self.usableCachedLanguages(from: cachedManifest, in: resolvedDirectory)
        let localLanguages = Self.standaloneLanguages(in: resolvedDirectory,
                                                      excluding: Set(cachedLanguages.map { $0.code.lowercased() }))
        let initialLanguages = Self.merging(cachedLanguages, localLanguages)
        let initialSelection = AppLanguage.resolved(defaults.string(forKey: AppLanguage.storageKey),
                                                    from: [.english] + initialLanguages)

        self.manifestURL = manifestURL ?? Self.defaultManifestURL
        let downloadSession = session ?? Self.downloadSession()
        self.loader = loader ?? { request, maximumBytes in
            let (bytes, response) = try await downloadSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw LanguagePackFailure.invalidResponse
            }
            let expectedLength = response.expectedContentLength
            guard expectedLength <= 0 || expectedLength <= maximumBytes else {
                throw LanguagePackFailure.packTooLarge
            }
            var data = Data()
            if expectedLength > 0 { data.reserveCapacity(Int(expectedLength)) }
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw LanguagePackFailure.packTooLarge }
                data.append(byte)
            }
            return (data, response)
        }
        self.directory = resolvedDirectory
        self.defaults = defaults
        availableLanguages = [.english] + initialLanguages
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
        lastError = nil
        do {
            let refreshedLanguages = try await refreshAvailableLanguages()
            if selectedLanguage != .english {
                guard let refreshedLanguage = refreshedLanguages.first(where: {
                    $0.code == selectedLanguage.code
                }) else {
                    activateEnglish(persistSelection: true)
                    return
                }
                selectedLanguage = refreshedLanguage
                guard activateCached(refreshedLanguage) else { throw LanguagePackFailure.wrongLanguage }
            }
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
            if selectedLanguage != .english, activeLanguage == .english {
                if let cachedLanguage = availableLanguages.first(where: { $0.code == selectedLanguage.code }) {
                    selectedLanguage = cachedLanguage
                    _ = activateCached(cachedLanguage)
                }
            }
        }
    }

    func select(_ language: AppLanguage) async {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        lastError = nil
        if language.isBuiltIn {
            activateEnglish(persistSelection: true)
            return
        }
        do {
            var verifiedLanguage = availableLanguages.first(where: { $0.code == language.code })
            let needsRefresh: Bool
            if let verifiedLanguage {
                needsRefresh = !activateCached(verifiedLanguage)
            } else {
                needsRefresh = true
            }
            if needsRefresh {
                downloadingLanguageCode = language.code
                defer {
                    if selectionGeneration == generation { downloadingLanguageCode = nil }
                }
                let refreshedLanguages = try await refreshAvailableLanguages()
                guard selectionGeneration == generation else { return }
                verifiedLanguage = refreshedLanguages.first(where: { $0.code == language.code })
            }
            guard let verifiedLanguage, Self.isValidRemoteLanguage(verifiedLanguage),
                  activeLanguage.code == verifiedLanguage.code || activateCached(verifiedLanguage) else {
                throw LanguagePackFailure.unavailableLanguages
            }
            selectedLanguage = verifiedLanguage
            defaults.set(verifiedLanguage.code, forKey: AppLanguage.storageKey)
        } catch is CancellationError {
            return
        } catch {
            if selectionGeneration == generation { lastError = error.localizedDescription }
        }
    }

    func string(_ key: String) -> String {
        activeLanguage == .english ? key : translations[key] ?? key
    }

    private func apply(_ languages: [AppLanguage]) {
        availableLanguages = [.english] + languages
    }

    /// Publishes only languages whose complete files are stored locally. Remote files must match their advertised
    /// checksums; standalone packs copied into the Languages directory are validated directly from their contents.
    /// A manifest by itself is not enough to expose an option that can never be activated.
    private func refreshAvailableLanguages() async throws -> [AppLanguage] {
        let manifest = try await downloadManifest()
        try Task.checkCancellation()
        let candidates = Self.validLanguages(in: manifest)
        var usableCodes: Set<String> = []
        var pending: [AppLanguage] = []
        for language in candidates {
            if (try? Self.readPack(for: language, from: directory)) != nil {
                usableCodes.insert(language.code)
            } else {
                pending.append(language)
            }
        }

        // Bound concurrency so a larger community manifest does not make launch wait on every file serially or start
        // an unbounded number of network requests at once.
        for batchStart in stride(from: 0, to: pending.count, by: 4) {
            let batchEnd = min(batchStart + 4, pending.count)
            let batch = Array(pending[batchStart..<batchEnd])
            let baseURL = manifestURL.deletingLastPathComponent()
            let loader = loader
            let downloads = await withTaskGroup(of: (AppLanguage, Data?).self) { group in
                for language in batch {
                    group.addTask {
                        guard let file = language.file,
                              let url = URL(string: file, relativeTo: baseURL)?.absoluteURL else {
                            return (language, nil)
                        }
                        return (language, try? await Self.download(url, maximumBytes: 5_000_000, loader: loader))
                    }
                }
                var results: [(AppLanguage, Data?)] = []
                for await result in group { results.append(result) }
                return results
            }
            try Task.checkCancellation()
            for (language, data) in downloads {
                guard let data else { continue }
                do {
                    _ = try Self.decodePack(data, for: language)
                    try Self.write(data, to: Self.packURL(for: language.code, in: directory))
                    usableCodes.insert(language.code)
                } catch {
                    continue
                }
            }
        }
        let previousLanguages = Dictionary(uniqueKeysWithValues:
            availableLanguages.dropFirst().map { ($0.code, $0) })
        let usable = candidates.compactMap { language -> AppLanguage? in
            if usableCodes.contains(language.code) { return language }
            // Do not force an active language back to English just because its newly advertised revision is
            // temporarily unavailable. The previously checksum-verified revision remains safe and usable offline.
            guard let previous = previousLanguages[language.code],
                  (try? Self.readPack(for: previous, from: directory)) != nil else { return nil }
            return previous
        }
        let local = Self.standaloneLanguages(in: directory,
                                             excluding: Set(usable.map { $0.code.lowercased() }))
        let available = Self.merging(usable, local)
        guard !available.isEmpty else { throw LanguagePackFailure.unavailableLanguages }

        if !usable.isEmpty {
            // The cached manifest contains only verified remote files. Standalone packs are rediscovered from disk,
            // so editing or removing one takes effect on the next launch without rewriting this manifest.
            let cachedManifest = LanguageManifest(schemaVersion: 1, languages: usable)
            let data = try JSONEncoder().encode(cachedManifest)
            try Task.checkCancellation()
            try Self.write(data, to: directory.appending(path: "manifest.json"))
        }
        apply(available)
        return available
    }

    private func activateCached(_ language: AppLanguage) -> Bool {
        guard let pack = try? Self.readPack(for: language, from: directory) else { return false }
        let changed = activeLanguage != language || translations != pack.strings
        translations = pack.strings
        activeLanguage = language
        if changed { revision += 1 }
        return true
    }

    private func activateEnglish(persistSelection: Bool) {
        let changed = activeLanguage != .english || !translations.isEmpty
        selectedLanguage = .english
        translations = [:]
        activeLanguage = .english
        downloadingLanguageCode = nil
        if persistSelection { defaults.set(AppLanguage.english.code, forKey: AppLanguage.storageKey) }
        if changed { revision += 1 }
    }

    private func downloadManifest() async throws -> LanguageManifest {
        let data = try await Self.download(manifestURL, maximumBytes: 1_000_000, loader: loader)
        let manifest = try JSONDecoder().decode(LanguageManifest.self, from: data)
        guard manifest.schemaVersion == 1 else { throw LanguagePackFailure.invalidManifest }
        return manifest
    }

    nonisolated private static func download(_ url: URL, maximumBytes: Int, loader: Loader) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await loader(request, maximumBytes)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LanguagePackFailure.invalidResponse
        }
        guard data.count <= maximumBytes else { throw LanguagePackFailure.packTooLarge }
        return data
    }

    private static func readPack(for language: AppLanguage, from directory: URL) throws -> LanguagePack {
        let data = try Data(contentsOf: packURL(for: language.code, in: directory), options: [.mappedIfSafe])
        return try decodePack(data, for: language)
    }

    private static func decodePack(_ data: Data, for language: AppLanguage) throws -> LanguagePack {
        guard let checksum = language.sha256, !checksum.isEmpty else { throw LanguagePackFailure.invalidManifest }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == checksum.lowercased() else { throw LanguagePackFailure.checksum }
        let pack = try JSONDecoder().decode(LanguagePack.self, from: data)
        guard pack.schemaVersion == 1, pack.language == language.code,
              pack.revision == language.revision else { throw LanguagePackFailure.wrongLanguage }
        let strings = sanitizedStrings(pack.strings)
        guard !strings.isEmpty else { throw LanguagePackFailure.wrongLanguage }
        return LanguagePack(schemaVersion: pack.schemaVersion, language: pack.language,
                            revision: pack.revision, strings: strings)
    }

    /// Empty translations and unsafe printf-style substitutions fall back to the English key. This prevents a typo in
    /// a community pack from making a control blank or passing incompatible arguments to String(format:).
    private static func sanitizedStrings(_ strings: [String: String]) -> [String: String] {
        let expression = try? NSRegularExpression(pattern:
            #"%(?:\d+\$)?[-+0#]*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|L|z|t|j)?[@diuoxXfFeEgGaAcCsSpn%]"#)
        func formatSignature(in value: String) -> (specifiers: [String], hasInvalidPercent: Bool) {
            guard let expression else { return ([], true) }
            let range = NSRange(value.startIndex..., in: value)
            let matches = expression.matches(in: value, range: range)
            let starts = Set(matches.map(\.range.location))
            let invalidPercent = value.indices.contains { index in
                value[index] == "%" && !starts.contains(NSRange(index..<value.index(after: index), in: value).location)
            }
            let specifiers = matches.compactMap { match in
                Range(match.range, in: value).map { String(value[$0]) }
            }
            return (specifiers, invalidPercent)
        }
        return strings.filter { key, value in
            let source = formatSignature(in: key)
            let translation = formatSignature(in: value)
            return !key.isEmpty && !value.isEmpty && source.specifiers == translation.specifiers
                && (source.specifiers.isEmpty || !translation.hasInvalidPercent)
        }
    }

    private static func validLanguages(in manifest: LanguageManifest) -> [AppLanguage] {
        guard manifest.schemaVersion == 1 else { return [] }
        var codes: Set<String> = []
        var valid: [AppLanguage] = []
        for language in manifest.languages where valid.count < maximumRemoteLanguages {
            let normalizedCode = language.code.lowercased()
            guard isValidRemoteLanguage(language), codes.insert(normalizedCode).inserted else { continue }
            valid.append(language)
        }
        return valid
    }

    private static func usableCachedLanguages(from manifest: LanguageManifest?, in directory: URL) -> [AppLanguage] {
        guard let manifest else { return [] }
        return validLanguages(in: manifest).filter { (try? readPack(for: $0, from: directory)) != nil }
    }

    /// Valid language packs may be installed manually without a manifest. The file name is the language code, while
    /// the display name is the language's own localized name (with stable built-in names for the bootstrap languages).
    private static func standaloneLanguages(in directory: URL, excluding excludedCodes: Set<String>) -> [AppLanguage] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: Array(keys),
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        var languages: [AppLanguage] = []
        var codes = excludedCodes
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where languages.count < maximumRemoteLanguages && file.pathExtension.lowercased() == "json" {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, (values.fileSize ?? 5_000_001) <= 5_000_000,
                  let data = try? Data(contentsOf: file, options: [.mappedIfSafe]), data.count <= 5_000_000,
                  let pack = try? JSONDecoder().decode(LanguagePack.self, from: data), pack.schemaVersion == 1,
                  pack.revision > 0, isValidLanguageCode(pack.language),
                  file.deletingPathExtension().lastPathComponent == pack.language,
                  pack.language.lowercased() != AppLanguage.english.code,
                  !sanitizedStrings(pack.strings).isEmpty,
                  codes.insert(pack.language.lowercased()).inserted else { continue }
            let displayName = AppLanguage.initialChoices.first { $0.code == pack.language }?.displayName
                ?? Locale(identifier: pack.language).localizedString(forIdentifier: pack.language)
                ?? pack.language
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let language = AppLanguage(code: pack.language, displayName: displayName,
                                       file: file.lastPathComponent, sha256: checksum, revision: pack.revision)
            guard isValidRemoteLanguage(language), (try? decodePack(data, for: language)) != nil else { continue }
            languages.append(language)
        }
        return languages
    }

    private static func merging(_ primary: [AppLanguage], _ additional: [AppLanguage]) -> [AppLanguage] {
        var codes: Set<String> = []
        return (primary + additional).filter { codes.insert($0.code.lowercased()).inserted }
    }

    private static func cachedManifest(from directory: URL) -> LanguageManifest? {
        guard let data = try? Data(contentsOf: directory.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(LanguageManifest.self, from: data),
              manifest.schemaVersion == 1 else { return nil }
        return manifest
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
        let alphanumeric = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        guard !code.isEmpty, code.count <= 32 else { return false }
        var previousWasSeparator = true
        for scalar in code.unicodeScalars {
            if alphanumeric.contains(scalar) {
                previousWasSeparator = false
            } else if scalar == "-" || scalar == "_" {
                guard !previousWasSeparator else { return false }
                previousWasSeparator = true
            } else {
                return false
            }
        }
        return !previousWasSeparator
    }

    private static func isValidRemoteLanguage(_ language: AppLanguage) -> Bool {
        guard language.code.lowercased() != AppLanguage.english.code,
              isValidLanguageCode(language.code), language.revision > 0,
              !language.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              language.displayName.count <= 100,
              let file = language.file, !file.isEmpty, file.count <= 255,
              file == language.code + ".json", file == URL(fileURLWithPath: file).lastPathComponent,
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
