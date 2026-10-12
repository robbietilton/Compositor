import CryptoKit
import Foundation
import Testing
@testable import Compositor

private actor LanguageRefreshRace {
    private let manifestURL: URL
    private let oldManifest: Data
    private let newManifest: Data
    private let oldPack: Data
    private let newPack: Data
    private var manifestRequests = 0
    private var packRequests = 0
    private var firstManifestStarted = false
    private var firstManifestObserver: CheckedContinuation<Void, Never>?
    private var firstManifestRelease: CheckedContinuation<Void, Never>?

    init(manifestURL: URL, oldManifest: Data, newManifest: Data, oldPack: Data, newPack: Data) {
        self.manifestURL = manifestURL
        self.oldManifest = oldManifest
        self.newManifest = newManifest
        self.oldPack = oldPack
        self.newPack = newPack
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let data: Data
        if url == manifestURL {
            manifestRequests += 1
            if manifestRequests == 1 {
                firstManifestStarted = true
                firstManifestObserver?.resume()
                firstManifestObserver = nil
                await withCheckedContinuation { firstManifestRelease = $0 }
                data = oldManifest
            } else {
                data = newManifest
            }
        } else {
            packRequests += 1
            data = packRequests == 1 ? newPack : oldPack
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    func waitForFirstManifest() async {
        if firstManifestStarted { return }
        await withCheckedContinuation { firstManifestObserver = $0 }
    }

    func releaseFirstManifest() {
        firstManifestRelease?.resume()
        firstManifestRelease = nil
    }

    var packRequestCount: Int { packRequests }
}

@MainActor
struct LocalizationTests {
    @Test func bootstrapLanguagesHaveStableCodesAndNames() {
        #expect(AppLanguage.initialChoices == [.english, .simplifiedChinese, .traditionalChinese])
        #expect(AppLanguage.english.rawValue == "en")
        #expect(AppLanguage.english.displayName == "English")
        #expect(AppLanguage.simplifiedChinese.rawValue == "zh-Hans")
        #expect(AppLanguage.simplifiedChinese.displayName == "简体中文")
        #expect(AppLanguage.traditionalChinese.rawValue == "zh-Hant")
        #expect(AppLanguage.traditionalChinese.displayName == "繁體中文")
    }

    @Test func unknownLanguageFallsBackToEnglish() {
        #expect(AppLanguage.resolved(nil) == .english)
        #expect(AppLanguage.resolved("unsupported") == .english)
    }

    @Test func offlineWithoutLocalPacksOffersEnglishOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let offline: LanguageManager.Loader = { _, _ in throw URLError(.notConnectedToInternet) }
        let manager = LanguageManager(directory: root, defaults: defaults, loader: offline)

        #expect(manager.availableLanguages == [.english])
        await manager.prepare()
        #expect(manager.availableLanguages == [.english])
    }

    @Test func standaloneLocalPackWorksWithoutAManifestOrNetwork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pack = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "language": "zh-Hans",
            "revision": 3,
            "strings": [
                "Language": "语言",
                "Gaussian Blur": "高斯模糊",
                "Zoom in to %@. At 100%% pixels match.": "放大到 %@。在 100%% 时像素一致。",
            ],
        ], options: [.sortedKeys])
        try pack.write(to: root.appending(path: "zh-Hans.json"), options: .atomic)
        let offline: LanguageManager.Loader = { _, _ in throw URLError(.notConnectedToInternet) }
        defaults.set("zh-Hans", forKey: AppLanguage.storageKey)

        let manager = LanguageManager(directory: root, defaults: defaults, loader: offline)

        #expect(manager.availableLanguages.map(\.code) == ["en", "zh-Hans"])
        #expect(manager.activeLanguage.code == "zh-Hans")
        #expect(manager.string("Gaussian Blur") == "高斯模糊")
        #expect(manager.string("Zoom in to %@. At 100%% pixels match.") == "放大到 %@。在 100%% 时像素一致。")
        await manager.prepare()
        #expect(manager.activeLanguage.code == "zh-Hans")
    }

    @Test func cachedFileSizeLimitsPreventOversizedStartupReads() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1_000_001)
            .write(to: root.appending(path: "manifest.json"), options: .atomic)
        try Data(repeating: 0, count: 5_000_001)
            .write(to: root.appending(path: "zh-Hans.json"), options: .atomic)
        let offline: LanguageManager.Loader = { _, _ in throw URLError(.notConnectedToInternet) }

        let manager = LanguageManager(directory: root, defaults: defaults, loader: offline)

        #expect(manager.availableLanguages == [.english])
        #expect(manager.activeLanguage == .english)
    }

    @Test func replacingAnActivePacksRevisionActuallyLoadsItsNewStrings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func pack(revision: Int, value: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "language": "zh-Hans", "revision": revision,
                "strings": ["Language": value],
            ], options: [.sortedKeys])
        }
        func manifest(revision: Int, pack: Data) throws -> Data {
            let checksum = SHA256.hash(data: pack).map { String(format: "%02x", $0) }.joined()
            return try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "languages": [[
                    "code": "zh-Hans", "displayName": "简体中文", "file": "zh-Hans.json",
                    "sha256": checksum, "revision": revision,
                ]],
            ], options: [.sortedKeys])
        }
        let oldPack = try pack(revision: 1, value: "旧语言")
        let oldManifest = try manifest(revision: 1, pack: oldPack)
        try oldPack.write(to: root.appending(path: "zh-Hans.json"), options: .atomic)
        try oldManifest.write(to: root.appending(path: "manifest.json"), options: .atomic)
        defaults.set("zh-Hans", forKey: AppLanguage.storageKey)

        let newPack = try pack(revision: 2, value: "新语言")
        let newManifest = try manifest(revision: 2, pack: newPack)
        let manifestURL = try #require(URL(string: "https://languages.example/manifest.json"))
        let packURL = manifestURL.deletingLastPathComponent().appending(path: "zh-Hans.json")
        let responses = [manifestURL: newManifest, packURL: newPack]
        let loader: LanguageManager.Loader = { request, _ in
            let url = try #require(request.url)
            let data = try #require(responses[url])
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                                                        httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        let manager = LanguageManager(manifestURL: manifestURL, directory: root,
                                      defaults: defaults, loader: loader)
        #expect(manager.activeLanguage.revision == 1)
        #expect(manager.string("Language") == "旧语言")
        try Data("damaged".utf8).write(to: root.appending(path: "zh-Hans.json"), options: .atomic)
        let chinese = try #require(manager.availableLanguages.first { $0.code == "zh-Hans" })

        await manager.select(chinese)

        #expect(manager.selectedLanguage.revision == 2)
        #expect(manager.activeLanguage.revision == 2)
        #expect(manager.string("Language") == "新语言")
    }

    @Test func slowerOldRefreshCannotOverwriteANewerLanguageRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        func pack(revision: Int, value: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "language": "zh-Hans", "revision": revision,
                "strings": ["Language": value],
            ], options: [.sortedKeys])
        }
        func manifest(revision: Int, pack: Data) throws -> Data {
            let checksum = SHA256.hash(data: pack).map { String(format: "%02x", $0) }.joined()
            return try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "languages": [[
                    "code": "zh-Hans", "displayName": "简体中文", "file": "zh-Hans.json",
                    "sha256": checksum, "revision": revision,
                ]],
            ], options: [.sortedKeys])
        }
        let oldPack = try pack(revision: 1, value: "旧语言")
        let newPack = try pack(revision: 2, value: "新语言")
        let oldManifest = try manifest(revision: 1, pack: oldPack)
        let newManifest = try manifest(revision: 2, pack: newPack)
        let manifestURL = try #require(URL(string: "https://languages.example/manifest.json"))
        let race = LanguageRefreshRace(manifestURL: manifestURL, oldManifest: oldManifest,
                                       newManifest: newManifest, oldPack: oldPack, newPack: newPack)
        let loader: LanguageManager.Loader = { request, _ in try await race.load(request) }
        let manager = LanguageManager(manifestURL: manifestURL, directory: root,
                                      defaults: defaults, loader: loader)

        let oldRefresh = Task { await manager.prepare() }
        await race.waitForFirstManifest()
        let newRefresh = Task { await manager.prepare() }
        await newRefresh.value
        await race.releaseFirstManifest()
        await oldRefresh.value

        let chinese = try #require(manager.availableLanguages.first { $0.code == "zh-Hans" })
        #expect(chinese.revision == 2)
        #expect(await race.packRequestCount == 0)
        await manager.select(chinese)
        #expect(await race.packRequestCount == 1)
        #expect(manager.activeLanguage.revision == 2)
        #expect(manager.string("Language") == "新语言")
    }

    @Test func successfulRemoteRefreshKeepsStandaloneLocalPacks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localPack = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "language": "fr", "revision": 1,
            "strings": ["Language": "Langue"],
        ], options: [.sortedKeys])
        try localPack.write(to: root.appending(path: "fr.json"), options: .atomic)
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "languages": [],
        ], options: [.sortedKeys])
        let manifestURL = try #require(URL(string: "https://languages.example/manifest.json"))
        let loader: LanguageManager.Loader = { request, _ in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                                                        httpVersion: nil, headerFields: nil))
            return (manifest, response)
        }
        let manager = LanguageManager(manifestURL: manifestURL, directory: root,
                                      defaults: defaults, loader: loader)

        await manager.prepare()

        #expect(manager.availableLanguages.contains { $0.code == "fr" })
        #expect(manager.lastError == nil)
        let french = try #require(manager.availableLanguages.first { $0.code == "fr" })
        await manager.select(french)
        #expect(manager.activeLanguage.code == "fr")
        #expect(manager.string("Language") == "Langue")
    }

    @Test func invalidStandalonePacksLeaveOnlyEnglishAvailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wrongName = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "language": "de", "revision": 1,
            "strings": ["Language": "Sprache"],
        ], options: [.sortedKeys])
        try wrongName.write(to: root.appending(path: "renamed.json"), options: .atomic)
        let unsafeFormat = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "language": "es", "revision": 1,
            "strings": ["Current: %lld pixels": "Actual: %@ píxeles"],
        ], options: [.sortedKeys])
        try unsafeFormat.write(to: root.appending(path: "es.json"), options: .atomic)
        let offline: LanguageManager.Loader = { _, _ in throw URLError(.notConnectedToInternet) }

        let manager = LanguageManager(directory: root, defaults: defaults, loader: offline)

        #expect(manager.availableLanguages == [.english])
    }

    @Test func unavailableRemotePackIsAdvertisedButDoesNotActivate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(AppLanguage.english.code, forKey: AppLanguage.storageKey)
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "languages": [[
                "code": "zh-Hans", "displayName": "简体中文", "file": "zh-Hans.json",
                "sha256": String(repeating: "0", count: 64), "revision": 1,
            ]],
        ], options: [.sortedKeys])
        let manifestURL = try #require(URL(string: "https://languages.example/manifest.json"))
        let loader: LanguageManager.Loader = { request, _ in
            let url = try #require(request.url)
            let status = url == manifestURL ? 200 : 404
            let data = url == manifestURL ? manifest : Data()
            let response = try #require(HTTPURLResponse(url: url, statusCode: status,
                                                        httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        let manager = LanguageManager(manifestURL: manifestURL, directory: root, defaults: defaults, loader: loader)

        await manager.prepare()

        #expect(manager.availableLanguages.contains { $0.code == "zh-Hans" })
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "manifest.json").path))
        await manager.select(.simplifiedChinese)
        #expect(defaults.string(forKey: AppLanguage.storageKey) == AppLanguage.english.code)
        #expect(manager.activeLanguage == .english)
    }

    @Test func cachedManifestWithoutVerifiedPackOffersEnglishOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "languages": [[
                "code": "zh-Hant", "displayName": "繁體中文", "file": "zh-Hant.json",
                "sha256": String(repeating: "a", count: 64), "revision": 1,
            ]],
        ], options: [.sortedKeys])
        try manifest.write(to: root.appending(path: "manifest.json"), options: .atomic)
        let offline: LanguageManager.Loader = { _, _ in throw URLError(.notConnectedToInternet) }

        let manager = LanguageManager(directory: root, defaults: defaults, loader: offline)

        #expect(manager.availableLanguages == [.english])
        await manager.prepare()
        #expect(manager.availableLanguages == [.english])
    }

    @Test func downloadedPackIsVerifiedStoredAndAvailableOffline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CompositorLanguages-\(UUID())", directoryHint: .isDirectory)
        let suite = "CompositorLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let pack = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "language": "zh-Hans",
            "revision": 7,
            "strings": [
                "Language": "语言",
                "Gaussian Blur": "高斯模糊",
                "Current: %lld pixels": "当前：%@ 像素",
                "Blank translation": "",
            ],
        ], options: [.sortedKeys])
        let checksum = SHA256.hash(data: pack).map { String(format: "%02x", $0) }.joined()
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "languages": [[
                "code": "zh-Hans", "displayName": "简体中文", "file": "zh-Hans.json",
                "sha256": checksum, "revision": 7,
            ]],
        ], options: [.sortedKeys])
        let manifestURL = try #require(URL(string: "https://languages.example/manifest.json"))
        let responses = [manifestURL: manifest,
                         manifestURL.deletingLastPathComponent().appending(path: "zh-Hans.json"): pack]
        let loader: LanguageManager.Loader = { request, _ in
            let url = try #require(request.url)
            let data = try #require(responses[url])
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        let manager = LanguageManager(manifestURL: manifestURL, directory: root, defaults: defaults, loader: loader)
        #expect(manager.availableLanguages == [.english])
        await manager.prepare()
        #expect(manager.availableLanguages.contains { $0.code == "zh-Hans" })
        let chinese = try #require(manager.availableLanguages.first { $0.code == "zh-Hans" })
        await manager.select(chinese)
        #expect(manager.string("Language") == "语言")
        #expect(manager.string("Gaussian Blur") == "高斯模糊")
        #expect(manager.string("Current: %lld pixels") == "Current: %lld pixels")
        #expect(manager.string("Blank translation") == "Blank translation")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "zh-Hans.json").path))

        let onlineRelaunch = LanguageManager(manifestURL: manifestURL, directory: root,
                                             defaults: defaults, loader: loader)
        #expect(onlineRelaunch.activeLanguage.code == "zh-Hans")
        let unchangedRevision = onlineRelaunch.revision
        await onlineRelaunch.prepare()
        #expect(onlineRelaunch.revision == unchangedRevision)

        let unavailableUpdate = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "languages": [[
                "code": "zh-Hans", "displayName": "简体中文", "file": "zh-Hans.json",
                "sha256": String(repeating: "f", count: 64), "revision": 8,
            ]],
        ], options: [.sortedKeys])
        let updateLoader: LanguageManager.Loader = { request, _ in
            let url = try #require(request.url)
            let status = url == manifestURL ? 200 : 404
            let data = url == manifestURL ? unavailableUpdate : Data()
            let response = try #require(HTTPURLResponse(url: url, statusCode: status,
                                                        httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        let updateFallback = LanguageManager(manifestURL: manifestURL, directory: root,
                                             defaults: defaults, loader: updateLoader)
        await updateFallback.prepare()
        #expect(updateFallback.activeLanguage.revision == 7)
        #expect(updateFallback.string("Language") == "语言")

        let offline: LanguageManager.Loader = { _, _ in throw URLError(.notConnectedToInternet) }
        let relaunched = LanguageManager(manifestURL: manifestURL, directory: root, defaults: defaults, loader: offline)
        #expect(relaunched.activeLanguage.code == "zh-Hans")
        #expect(relaunched.string("Language") == "语言")
        await relaunched.prepare()
        #expect(relaunched.string("Gaussian Blur") == "高斯模糊")

        try Data("corrupted".utf8).write(to: root.appending(path: "zh-Hans.json"), options: .atomic)
        let corrupted = LanguageManager(manifestURL: manifestURL, directory: root, defaults: defaults,
                                        loader: offline)
        #expect(corrupted.availableLanguages == [.english])
        #expect(corrupted.activeLanguage == .english)
        #expect(corrupted.string("Language") == "Language")
    }

    @Test func repositoryLanguageFilesMatchManifestAndTranslationTemplate() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let languagesDirectory = repository.appending(path: "Languages", directoryHint: .isDirectory)
        let manifestData = try Data(contentsOf: languagesDirectory.appending(path: "manifest.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        #expect(manifest["schemaVersion"] as? Int == 1)
        let languages = try #require(manifest["languages"] as? [[String: Any]])

        let templateData = try Data(contentsOf: languagesDirectory.appending(path: "translation-template.json"))
        let template = try #require(JSONSerialization.jsonObject(with: templateData) as? [String: Any])
        let templateStrings = try #require(template["strings"] as? [String: String])
        let catalogData = try Data(contentsOf: repository.appending(path: "Compositor/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalogStrings = try #require(catalog["strings"] as? [String: Any])
        #expect(Set(templateStrings.keys) == Set(catalogStrings.keys))

        var codes: Set<String> = []
        for language in languages {
            let code = try #require(language["code"] as? String)
            let file = try #require(language["file"] as? String)
            let checksum = try #require(language["sha256"] as? String)
            let revision = try #require(language["revision"] as? Int)
            #expect(codes.insert(code.lowercased()).inserted)

            let packData = try Data(contentsOf: languagesDirectory.appending(path: file))
            let actualChecksum = SHA256.hash(data: packData).map { String(format: "%02x", $0) }.joined()
            #expect(actualChecksum == checksum.lowercased())
            let pack = try #require(JSONSerialization.jsonObject(with: packData) as? [String: Any])
            #expect(pack["schemaVersion"] as? Int == 1)
            #expect(pack["language"] as? String == code)
            #expect(pack["revision"] as? Int == revision)
            let strings = try #require(pack["strings"] as? [String: String])
            #expect(Set(strings.keys).isSubset(of: Set(templateStrings.keys)))
            #expect(strings.values.allSatisfy { !$0.isEmpty })
        }

        let suite = "CompositorRepositoryLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let offline: LanguageManager.Loader = { _, _ in throw URLError(.notConnectedToInternet) }
        let runtime = LanguageManager(directory: languagesDirectory, defaults: defaults, loader: offline)
        #expect(Set(runtime.availableLanguages.map(\.code)) == Set(["en", "zh-Hans", "zh-Hant"]))
    }
}
