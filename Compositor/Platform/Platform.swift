#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

// The few things the document model, the file formats and the renderers need from the platform's UI framework, kept
// here so the rest of Document, IO and Rendering builds for macOS and iPadOS alike. The Mac's behavior is exactly
// what it was when those files called AppKit themselves.

#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
#else
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage

extension UIColor {
    /// AppKit's sRGB initializer. UIKit's own takes extended sRGB, which is the same color for components in 0...1.
    nonisolated convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif

enum Platform {
    /// The system's accent color, for the transform box and the lines a move snaps to.
    static var accentColor: PlatformColor {
        #if os(macOS)
        .controlAccentColor
        #else
        .tintColor
        #endif
    }

    /// The alert sound for a command that can't run just now. iPadOS has no alert sound; it taps instead.
    static func beep() {
        #if os(macOS)
        NSSound.beep()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    /// Makes `context` the one text and images are drawn into, drawing y down with glyphs upright, as a flipped
    /// view does — the way UIKit always draws. Balance with `popGraphicsContext()`.
    static func pushGraphicsContext(_ context: CGContext) {
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        #else
        UIGraphicsPushContext(context)
        #endif
    }

    static func popGraphicsContext() {
        #if os(macOS)
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPopContext()
        #endif
    }

    /// `image` shown `size` points across, as the panels draw their pictures.
    static func image(_ image: CGImage, size: CGSize) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: image, size: size)
        #else
        UIImage(cgImage: image, scale: CGFloat(image.width) / max(1, size.width), orientation: .up)
        #endif
    }

    /// A picture of nothing, `size` points across, for when one can't be drawn.
    static func emptyImage(size: CGSize) -> PlatformImage {
        #if os(macOS)
        NSImage(size: size)
        #else
        UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }
}

/// The pasteboard pixels are copied to for other apps and pasted from, and the marker a copied layer leaves so Paste
/// in another project knows where it came from: the system's, except under the Mac's tests, where each test process
/// gets one of its own, so tests running in parallel processes don't copy over each other's pixels. The iPad's tests
/// run one at a time, and write to the general pasteboard themselves.
enum SystemPasteboard {
    static let layerType = "com.compositor.copied-layer"

    #if os(macOS)
    static let pasteboard: NSPasteboard = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? .general : .withUniqueName()
    #else
    static let pasteboard = UIPasteboard.general
    #endif

    /// Counts every change to the pasteboard, by any app: a copy made here is still the latest while it's unchanged.
    static var changeCount: Int { pasteboard.changeCount }

    /// Replaces the pasteboard's contents with a copied layer's marker, and returns the new change count.
    static func writeLayer(_ id: UUID) -> Int {
        #if os(macOS)
        pasteboard.clearContents()
        pasteboard.setString(id.uuidString, forType: NSPasteboard.PasteboardType(layerType))
        #else
        pasteboard.setItems([[layerType: id.uuidString]])
        #endif
        return pasteboard.changeCount
    }

    /// Replaces the pasteboard's contents with `image` as PNG, for other apps, and returns the new change count.
    static func writeImage(_ image: CGImage) -> Int {
        #if os(macOS)
        pasteboard.clearContents()
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        #else
        if let png = UIImage(cgImage: image).pngData() {
            pasteboard.setItems([[UTType.png.identifier: png]])
        } else {
            pasteboard.setItems([])
        }
        #endif
        return pasteboard.changeCount
    }

    static var hasImage: Bool {
        #if os(macOS)
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        #else
        pasteboard.hasImages
        #endif
    }

    /// The image another app copied, if there is one. On iPad it's turned upright first: a photo copied in Photos comes
    /// as the camera stored it, with the turn that shows it upright kept beside the pixels rather than in them.
    static func image() -> CGImage? {
        #if os(macOS)
        NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        guard let image = pasteboard.image else { return nil }
        guard image.imageOrientation != .up else { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
        #endif
    }

    /// The pasteboard's plain text, if there is any: a size copied as text, on the New canvas screen.
    static var string: String? {
        #if os(macOS)
        pasteboard.string(forType: .string)
        #else
        pasteboard.string
        #endif
    }

    /// The files on the pasteboard, as copying files in the Finder puts them there.
    static func fileURLs() -> [URL] {
        #if os(macOS)
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #else
        (pasteboard.urls ?? []).filter(\.isFileURL)
        #endif
    }

    /// Whether the pasteboard holds an image as PNG or TIFF data, the forms an image copied in another app takes.
    static var hasImageData: Bool {
        #if os(macOS)
        pasteboard.availableType(from: [.png, .tiff]) != nil
        #else
        pasteboard.contains(pasteboardTypes: [UTType.png.identifier, UTType.tiff.identifier])
        #endif
    }

    /// An image copied in another app as PNG or TIFF data, with the extension a file of it takes.
    static func imageData() -> (data: Data, pathExtension: String)? {
        #if os(macOS)
        guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else { return nil }
        return (data, type == .png ? "png" : "tiff")
        #else
        for type in [UTType.png, .tiff] {
            if let data = pasteboard.data(forPasteboardType: type.identifier) { return (data, type == .png ? "png" : "tiff") }
        }
        return nil
        #endif
    }
}
