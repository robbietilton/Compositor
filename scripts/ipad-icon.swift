#!/usr/bin/env swift
// Draws the iPad app's icon from the Mac's. A Mac icon is a rounded square with a transparent margin around it, on the
// macOS icon grid; iPadOS takes a full, opaque square and rounds its corners itself. So the iPad icon is the largest
// square of the Mac artwork that lies wholly inside its rounded square, scaled to fill the canvas: opaque throughout,
// with no edge of the Mac's rounding left for iPadOS's to show beside. Run it again whenever the Mac icon changes:
//
//     swift scripts/ipad-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Compositor/Assets.xcassets/AppIcon.appiconset")
let side = 1024

guard let source = CGImageSourceCreateWithURL(icons.appending(path: "app-icon-1024.png") as CFURL, nil),
      let mac = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("No Mac icon in \(icons.path)") }

// The largest centered square whose corners, and so all of it, lie inside the opaque rounded square.
let rgba = CGContext(data: nil, width: mac.width, height: mac.height, bitsPerComponent: 8, bytesPerRow: mac.width * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rgba.draw(mac, in: CGRect(x: 0, y: 0, width: mac.width, height: mac.height))
let pixels = rgba.data!.assumingMemoryBound(to: UInt8.self)
func opaque(_ x: Int, _ y: Int) -> Bool { pixels[(y * mac.width + x) * 4 + 3] == 255 }
let last = min(mac.width, mac.height) - 1
guard let inset = (0..<last / 2).first(where: { d in
    opaque(d, d) && opaque(last - d, d) && opaque(d, last - d) && opaque(last - d, last - d)
}), let artwork = mac.cropping(to: CGRect(x: inset, y: inset, width: last - 2 * inset + 1, height: last - 2 * inset + 1)) else {
    fatalError("The Mac icon has no opaque rounded square")
}

// Opaque, as iPadOS wants its icons.
let ipad = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ipad.interpolationQuality = .high
ipad.draw(artwork, in: CGRect(x: 0, y: 0, width: side, height: side))
let output = icons.appending(path: "app-icon-ipad-1024.png")
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Couldn't write \(output.path)")
}
CGImageDestinationAddImage(destination, ipad.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(output.path)") }
print("Wrote \(output.path) from the Mac icon's middle \(artwork.width) × \(artwork.height) px")
