import CryptoKit
import Foundation
import Testing
@testable import Compositor

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
            "strings": ["Language": "语言", "Gaussian Blur": "高斯模糊"],
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
        let loader: LanguageManager.Loader = { request in
            let url = try #require(request.url)
            let data = try #require(responses[url])
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        let manager = LanguageManager(manifestURL: manifestURL, directory: root, defaults: defaults, loader: loader)
        await manager.prepare()
        let chinese = try #require(manager.availableLanguages.first { $0.code == "zh-Hans" })
        await manager.select(chinese)
        #expect(manager.string("Language") == "语言")
        #expect(manager.string("Gaussian Blur") == "高斯模糊")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "zh-Hans.json").path))

        let offline: LanguageManager.Loader = { _ in throw URLError(.notConnectedToInternet) }
        let relaunched = LanguageManager(manifestURL: manifestURL, directory: root, defaults: defaults, loader: offline)
        #expect(relaunched.activeLanguage.code == "zh-Hans")
        #expect(relaunched.string("Language") == "语言")
        await relaunched.prepare()
        #expect(relaunched.string("Gaussian Blur") == "高斯模糊")

        try Data("corrupted".utf8).write(to: root.appending(path: "zh-Hans.json"), options: .atomic)
        let corrupted = LanguageManager(manifestURL: manifestURL, directory: root, defaults: defaults,
                                        loader: offline)
        #expect(corrupted.activeLanguage == .english)
        #expect(corrupted.string("Language") == "Language")
    }
}
