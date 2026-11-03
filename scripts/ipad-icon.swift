#!/usr/bin/env swift
// Draws the iPad app's icon from the Mac's. A Mac icon is a rounded square with a transparent margin around it, on the
// macOS icon grid; iPadOS takes a full, opaque square and rounds its corners itself. So the iPad icon is the Mac's whole
// rounded square, its opaque pixels' bounding box, scaled to 1.05 times the canvas and centered: what's in the Mac's
// corners stays, as the curl of the page in the lower right does, and iPadOS's rounding, nearly the Mac's own curve,
// falls inside the opaque pixels, with none of the Mac's rounding left to show beside it. Run it again whenever the Mac
// icon changes:
//
//     swift scripts/ipad-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Compositor/Assets.xcassets/AppIcon.appiconset")
let side = 1024
/// How far past the canvas the Mac's rounded square reaches, so its soft edge and its rounding are cut off.
let overscan: CGFloat = 1.05
/// The radius iPadOS rounds a 1024 px icon by, 22.37% of its side.
let cornerRadius: CGFloat = 229

guard let source = CGImageSourceCreateWithURL(icons.appending(path: "app-icon-1024.png") as CFURL, nil),
      let mac = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("No Mac icon in \(icons.path)") }

// The opaque pixels' bounding box, rows counted from the top.
let rgba = CGContext(data: nil, width: mac.width, height: mac.height, bitsPerComponent: 8, bytesPerRow: mac.width * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rgba.draw(mac, in: CGRect(x: 0, y: 0, width: mac.width, height: mac.height))
let pixels = rgba.data!.assumingMemoryBound(to: UInt8.self)
func alpha(_ x: Int, _ y: Int) -> UInt8 {
    guard (0..<mac.width).contains(x), (0..<mac.height).contains(y) else { return 0 }
    return pixels[(y * mac.width + x) * 4 + 3]
}
var minX = mac.width, maxX = -1, minY = mac.height, maxY = -1
for y in 0..<mac.height {
    for x in 0..<mac.width where alpha(x, y) == 255 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else { fatalError("The Mac icon has no opaque rounded square") }
let boxWidth = CGFloat(maxX - minX + 1), boxHeight = CGFloat(maxY - minY + 1)
let center = CGPoint(x: CGFloat(minX) + boxWidth / 2, y: CGFloat(minY) + boxHeight / 2)
let scale = CGFloat(side) * overscan / max(boxWidth, boxHeight)
let middle = CGFloat(side) / 2

// Opaque, as iPadOS wants its icons.
let ipad = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ipad.interpolationQuality = .high
ipad.draw(mac, in: CGRect(x: middle - center.x * scale, y: middle - (CGFloat(mac.height) - center.y) * scale,
                          width: CGFloat(mac.width) * scale, height: CGFloat(mac.height) * scale))

// Every pixel inside iPadOS's rounding has to come from the Mac's opaque ones: checked along its edge, which is the
// furthest out they reach, for each source pixel the drawing could have read there.
func checkOpaque(_ x: CGFloat, _ y: CGFloat) {
    let sourceX = center.x + (x - middle) / scale, sourceY = center.y + (y - middle) / scale
    for row in Int(sourceY.rounded(.down))...Int(sourceY.rounded(.up)) {
        for column in Int(sourceX.rounded(.down))...Int(sourceX.rounded(.up)) where alpha(column, row) != 255 {
            fatalError("iPadOS's rounding reaches past the Mac icon's opaque pixels at (\(x), \(y)), its (\(column), \(row))")
        }
    }
}
let far = CGFloat(side) - cornerRadius
for offset in stride(from: cornerRadius, through: far, by: 1) {
    for (x, y) in [(offset, 0), (offset, CGFloat(side)), (0, offset), (CGFloat(side), offset)] { checkOpaque(x, y) }
}
for step in 0...360 {
    let angle = CGFloat(step) / 360 * .pi / 2
    let dx = cos(angle) * cornerRadius, dy = sin(angle) * cornerRadius
    for (x, y) in [(far + dx, far + dy), (cornerRadius - dx, far + dy), (far + dx, cornerRadius - dy), (cornerRadius - dx, cornerRadius - dy)] {
        checkOpaque(x, y)
    }
}

let output = icons.appending(path: "app-icon-ipad-1024.png")
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Couldn't write \(output.path)")
}
CGImageDestinationAddImage(destination, ipad.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(output.path)") }
print("Wrote \(output.path) from the Mac icon's \(Int(boxWidth)) × \(Int(boxHeight)) px of opaque pixels, scaled \(scale)")
