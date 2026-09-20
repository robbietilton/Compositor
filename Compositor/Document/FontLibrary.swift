import AppKit
import CoreText
import Observation

nonisolated struct FontFace: Identifiable, Equatable, Sendable {
    let postScriptName: String
    let displayName: String
    var id: String { postScriptName }
}

nonisolated enum FontLibraryError: LocalizedError {
    case unsupported, empty, tooLarge, damaged, copy, registration
    var errorDescription: String? {
        switch self {
        case .unsupported: "Choose one OTF, TTF, or TTC font file.".localized
        case .empty: "The font file is empty.".localized
        case .tooLarge: "The font file is larger than 100 MB.".localized
        case .damaged: "The font file is damaged or contains no usable faces.".localized
        case .copy: "The font could not be copied into Compositor’s font library.".localized
        case .registration: "The font could not be registered for this app.".localized
        }
    }
}

@MainActor @Observable
final class FontLibrary {
    static let shared = FontLibrary()
    static let bundledNames = ["SourceHanSansSC-Regular", "SourceHanSerifSC-Regular"]
    static let supportedExtensions = ["otf", "ttf", "ttc"]
    private(set) var availableFaces: [FontFace] = []
    let fontsDirectory: URL
    private let bundledURLs: [URL]
    private var registeredFaces: [String: FontFace] = [:]

    init(fontsDirectory: URL? = nil, bundledURLs: [URL]? = nil) {
        self.fontsDirectory = fontsDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Compositor/Fonts", isDirectory: true)
        if let bundledURLs { self.bundledURLs = bundledURLs }
        else {
            self.bundledURLs = Self.bundledNames.compactMap {
                Bundle.main.url(forResource: $0, withExtension: "otf", subdirectory: "Fonts")
                    ?? Bundle.main.url(forResource: $0, withExtension: "otf")
            }
        }
        refreshFaces()
    }

    func registerBundledAndImportedFonts() {
        try? FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        let imported = (try? FileManager.default.contentsOfDirectory(at: fontsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        for url in bundledURLs + imported where Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            _ = try? register(url)
        }
        refreshFaces()
    }

    @discardableResult
    func importFont(from source: URL) throws -> [FontFace] {
        guard Self.supportedExtensions.contains(source.pathExtension.lowercased()) else { throw FontLibraryError.unsupported }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw FontLibraryError.empty }
        guard size <= 100 * 1024 * 1024 else { throw FontLibraryError.tooLarge }
        let faces = try Self.faces(in: source)
        try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        let sourceData = try Data(contentsOf: source, options: .mappedIfSafe)
        if let duplicate = try FileManager.default.contentsOfDirectory(at: fontsDirectory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]).first(where: {
                (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size
                    && (try? Data(contentsOf: $0, options: .mappedIfSafe)) == sourceData
            }) {
            _ = try register(duplicate)
            refreshFaces()
            return faces
        }
        var destination = fontsDirectory.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = fontsDirectory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(suffix).\(source.pathExtension)")
            suffix += 1
        }
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { throw FontLibraryError.copy }
        do { _ = try register(destination) }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        refreshFaces()
        return faces
    }

    func contains(_ postScriptName: String) -> Bool { NSFont(name: postScriptName, size: 12) != nil }

    private func register(_ url: URL) throws -> [FontFace] {
        let faces = try Self.faces(in: url)
        guard faces.allSatisfy({
            NSFont(name: $0.postScriptName, size: 12) == nil || Self.isRegistered($0, from: url)
        }) else {
            throw FontLibraryError.registration
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
           !faces.allSatisfy({ Self.isRegistered($0, from: url) }) {
            throw FontLibraryError.registration
        }
        for face in faces { registeredFaces[face.postScriptName] = face }
        return faces
    }

    private static func isRegistered(_ face: FontFace, from url: URL) -> Bool {
        let font = CTFontCreateWithName(face.postScriptName as CFString, 12, nil)
        let descriptor = CTFontCopyFontDescriptor(font)
        guard CTFontCopyPostScriptName(font) as String == face.postScriptName,
              let registered = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL else { return false }
        let lhs = registered.resolvingSymlinksInPath().standardizedFileURL
        let rhs = url.resolvingSymlinksInPath().standardizedFileURL
        return lhs == rhs || FileManager.default.contentsEqual(atPath: lhs.path, andPath: rhs.path)
    }

    private static func faces(in url: URL) throws -> [FontFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else { throw FontLibraryError.damaged }
        let faces = descriptors.compactMap { descriptor -> FontFace? in
            guard let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  !postScript.isEmpty else { return nil }
            let display = (CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontDisplayNameAttribute, nil) as? String)
                ?? postScript
            return FontFace(postScriptName: postScript, displayName: display)
        }
        guard !faces.isEmpty else { throw FontLibraryError.damaged }
        return faces
    }

    private func refreshFaces() {
        var faces = registeredFaces
        for name in NSFontManager.shared.availableFonts {
            if let font = NSFont(name: name, size: 12) {
                faces[name] = FontFace(postScriptName: name, displayName: font.displayName ?? name)
            }
        }
        availableFaces = faces.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
