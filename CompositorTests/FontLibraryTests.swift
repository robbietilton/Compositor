import AppKit
import Testing
@testable import Compositor

@MainActor
struct FontLibraryTests {
    private var bundledSans: URL {
        Bundle.main.url(forResource: "SourceHanSansSC-Regular", withExtension: "otf")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Compositor/Resources/Fonts/SourceHanSansSC-Regular.otf")
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FontLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func validFontImportsOnceAndRestoresFromApplicationSupport() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = FontLibrary(fontsDirectory: directory, bundledURLs: [])
        let faces = try library.importFont(from: bundledSans)
        #expect(faces.contains { $0.postScriptName == "SourceHanSansSC-Regular" })
        _ = try library.importFont(from: bundledSans)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1)
        let restored = FontLibrary(fontsDirectory: directory, bundledURLs: [])
        restored.registerBundledAndImportedFonts()
        #expect(restored.contains("SourceHanSansSC-Regular"))
    }

    @Test func registeredBundledFacesRemainVisibleAfterFontManagerWasRead() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSFontManager.shared.availableFonts
        let library = FontLibrary(fontsDirectory: directory, bundledURLs: [bundledSans])
        library.registerBundledAndImportedFonts()
        #expect(library.availableFaces.contains { $0.postScriptName == "SourceHanSansSC-Regular" })
    }

    @Test func differentFileWithAnExistingPostScriptNameIsRejected() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Conflict-\(UUID()).otf")
        defer { try? FileManager.default.removeItem(at: source) }
        var data = try Data(contentsOf: bundledSans)
        data.append(0)
        try data.write(to: source)
        let library = FontLibrary(fontsDirectory: directory, bundledURLs: [bundledSans])
        library.registerBundledAndImportedFonts()
        do {
            _ = try library.importFont(from: source)
            Issue.record("A different file with an existing PostScript name was accepted")
        } catch FontLibraryError.registration {
        } catch {
            Issue.record("Expected a registration conflict, got \(error)")
        }
    }

    @Test func wrongExtensionEmptyAndDamagedFilesNeverLandInLibrary() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = FontLibrary(fontsDirectory: directory, bundledURLs: [])
        for (name, data) in [("font.zip", Data([1])), ("empty.otf", Data()), ("damaged.ttf", Data("no font".utf8))] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())-\(name)")
            try data.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            #expect(throws: (any Error).self) { try library.importFont(from: source) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func ttcExposesEveryFontFaceWhenSystemFixtureExists() throws {
        let system = URL(fileURLWithPath: "/System/Library/Fonts/Helvetica.ttc")
        guard FileManager.default.fileExists(atPath: system.path) else { return }
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faces = try FontLibrary(fontsDirectory: directory, bundledURLs: []).importFont(from: system)
        #expect(faces.count > 1)
    }
}
