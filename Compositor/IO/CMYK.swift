import AppKit
import ColorSync
import UniformTypeIdentifiers

/// A CMYK output profile: how a press or printer turns ink amounts into color, read from an ICC file.
nonisolated struct CMYKProfile: Hashable, Identifiable, @unchecked Sendable {
    let name: String
    let data: Data
    let space: CGColorSpace
    var id: String { name }
    static func == (a: CMYKProfile, b: CMYKProfile) -> Bool { a.name == b.name && a.data == b.data }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// The profile in `data`, if it is a CMYK output profile.
    init?(name: String, data: Data) {
        guard let space = CGColorSpace(iccData: data as CFData), space.model == .cmyk else { return nil }
        self.name = name
        self.data = data
        self.space = space
    }
}

/// CMYK for print, from documents that stay RGB: a proof of the chosen profile on the canvas (View › CMYK › Proof Colors) and
/// export through it (Export As, JPEG, TIFF or PDF). Ink values are never edited directly; what printing changes is
/// mostly how saturated a color can be, which the proof shows on the RGB screen.
nonisolated enum CMYK {
    /// Where macOS keeps its color profiles that the app can read, and where profiles loaded with Load Profile go.
    private static var folders: [URL] {
        [URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"), URL(fileURLWithPath: "/Library/ColorSync/Profiles"), loadedFolder]
    }
    /// Profiles loaded with Load Profile, copied into the app's own storage so they stay readable.
    static var loadedFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CMYK Profiles", isDirectory: true)
    }

    /// Every CMYK profile there is to choose, by name.
    static func installed() -> [CMYKProfile] {
        var found: [String: CMYKProfile] = [:]
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["icc", "icm"].contains(file.pathExtension.lowercased()) {
                guard let data = try? Data(contentsOf: file),
                      let profile = CMYKProfile(name: file.deletingPathExtension().lastPathComponent, data: data) else { continue }
                found[profile.name] = profile
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Takes in a profile picked with Load Profile: kept as a copy, and chosen.
    static func load(_ url: URL) throws -> CMYKProfile {
        let data = try Data(contentsOf: url)
        guard let profile = CMYKProfile(name: url.deletingPathExtension().lastPathComponent, data: data) else {
            throw CMYKError.notCMYK
        }
        try FileManager.default.createDirectory(at: loadedFolder, withIntermediateDirectories: true)
        try data.write(to: loadedFolder.appendingPathComponent(url.lastPathComponent), options: .atomic)
        chosen = profile
        return profile
    }

    /// A CMYK profile embedded in a file (a CMYK PSD, JPEG or TIFF), named as it names itself; nil when it isn't one.
    static func embedded(_ data: Data) -> CMYKProfile? {
        var name: String?
        if let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue(),
           let described = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() {
            name = (described as String).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return CMYKProfile(name: name?.isEmpty == false ? name! : "Embedded CMYK Profile", data: data)
    }

    /// A file came in as CMYK through `profile`: kept, as Load Profile keeps one, and chosen, so proofing and CMYK
    /// export go back to the inks it was made for.
    static func adopt(_ profile: CMYKProfile) -> CMYKProfile {
        if let known = installed().first(where: { $0.data == profile.data }) {
            chosen = known
            return known
        }
        try? FileManager.default.createDirectory(at: loadedFolder, withIntermediateDirectories: true)
        let file = profile.name.replacingOccurrences(of: "/", with: "-")
        try? profile.data.write(to: loadedFolder.appendingPathComponent(file).appendingPathExtension("icc"), options: .atomic)
        chosen = profile
        return profile
    }

    /// The CMYK profile an image file (a CMYK JPEG, TIFF or flattened PSD) was made in: its own, or Generic CMYK when it
    /// names none; nil for any other file.
    static func profile(ofImageAt url: URL) -> CMYKProfile? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelCMYK as String else { return nil }
        let space = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)?.colorSpace
        return space?.copyICCData().flatMap { embedded($0 as Data) } ?? generic
    }

    /// macOS's own Generic CMYK, for a CMYK file that names no profile.
    static var generic: CMYKProfile? { installed().first { $0.name == "Generic CMYK Profile" } }

    private static let chosenKey = "cmykProfile"
    /// The profile proofing and CMYK export use: the one last chosen, or macOS's own Generic CMYK.
    static var chosen: CMYKProfile? {
        get {
            let all = installed()
            let name = UserDefaults.standard.string(forKey: chosenKey)
            return all.first { $0.name == name } ?? all.first { $0.name == "Generic CMYK Profile" } ?? all.first
        }
        set { UserDefaults.standard.set(newValue?.name, forKey: chosenKey) }
    }

    /// `image` in the profile's inks, over `matte` where it's clear (ink has no transparency; paper shows): relative
    /// colorimetric, as Photoshop converts by default, so colors the press can't reach go to the nearest it can.
    static func convert(_ image: CGImage, to profile: CMYKProfile, over matte: CGColor) throws -> CGImage {
        let width = image.width, height = image.height
        // Flattened over the matte in RGB first: the CMYK context takes no alpha.
        guard let flat = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let ink = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: profile.space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        flat.setFillColor(matte)
        flat.fill(bounds)
        flat.draw(image, in: bounds)
        guard let flattened = flat.makeImage() else { throw ExportError.render }
        ink.setRenderingIntent(.relativeColorimetric)
        ink.draw(flattened, in: bounds)
        guard let result = ink.makeImage() else { throw ExportError.render }
        return result
    }

    // MARK: Proofing

    /// Points along each side of the proof's color lookups.
    static let dimension = 33
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lookups: [String: ProofLookups] = [:]

    /// Color lookups for the canvas, made once a profile: `proof` takes each RGB color to the one printing it through the
    /// profile gives back; `warning` is the same, but marks gray the colors it can't print as they are; `marked` leaves
    /// colors as they are and marks those gray (the gamut warning without the proof).
    struct ProofLookups { let proof: Data, warning: Data, marked: Data }
    static func proofLookups(_ profile: CMYKProfile) -> ProofLookups? {
        if let known = lock.withLock({ lookups[profile.name] }) { return known }
        let n = dimension, count = n * n * n
        // Every lattice color, a pixel each, red fastest as the lookup reads them.
        var lattice = [UInt8](repeating: 255, count: count * 4)
        func level(_ i: Int) -> UInt8 { UInt8((Double(i) * 255 / Double(n - 1)).rounded()) }
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * n + g) * n + r) * 4
            lattice[i] = level(r); lattice[i + 1] = level(g); lattice[i + 2] = level(b)
        } } }
        guard let provider = CGDataProvider(data: Data(lattice) as CFData),
              let colors = CGImage(width: count, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: count * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                   decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let printed = try? convert(colors, to: profile, over: CGColor(gray: 1, alpha: 1)),
              let back = CGContext(data: nil, width: count, height: 1, bitsPerComponent: 8, bytesPerRow: count * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        back.setRenderingIntent(.relativeColorimetric)
        back.draw(printed, in: CGRect(x: 0, y: 0, width: count, height: 1))
        guard let data = back.data else { return nil }
        let shown = data.assumingMemoryBound(to: UInt8.self)
        var proof = [Float](repeating: 1, count: count * 4), warning = proof, marked = proof
        for i in 0..<count {
            var off = 0
            for c in 0..<3 {
                proof[i * 4 + c] = Float(shown[i * 4 + c]) / 255
                off = max(off, abs(Int(shown[i * 4 + c]) - Int(lattice[i * 4 + c])))
            }
            // Out of gamut: printing moves it further than its own rounding there and back would.
            let outside = off > 10
            for c in 0..<3 {
                warning[i * 4 + c] = outside ? 0.5 : proof[i * 4 + c]
                marked[i * 4 + c] = outside ? 0.5 : Float(lattice[i * 4 + c]) / 255
            }
        }
        func packed(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
        let made = ProofLookups(proof: packed(proof), warning: packed(warning), marked: packed(marked))
        lock.withLock { lookups[profile.name] = made }
        return made
    }
}

nonisolated enum CMYKError: LocalizedError {
    case notCMYK
    var errorDescription: String? { "That profile isn’t a CMYK output profile." }
}
