import Foundation
import CoreGraphics
import ColorSync

nonisolated enum CMYKError: LocalizedError {
    case profile, conversion
    var errorDescription: String? {
        switch self {
        case .profile: "Choose a valid CMYK output ICC profile supplied for your printing conditions."
        case .conversion: "The selected profile could not convert these colors."
        }
    }
}

nonisolated struct CMYKProfile: Equatable, Sendable {
    let id = UUID()
    let data: Data
    let name: String
    let supportsGamutWarning: Bool

    init(data: Data) throws {
        guard data.count >= 128, data.count <= 16 * 1024 * 1024,
              String(decoding: data[12..<16], as: UTF8.self) == "prtr",
              CGColorSpace(iccData: data as CFData)?.model == .cmyk,
              let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue(),
              ColorSyncProfileVerify(profile, nil, nil) else { throw CMYKError.profile }
        self.data = data
        name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String? ?? "CMYK"
        let tags = ColorSyncProfileCopyTagSignatures(profile)?.takeRetainedValue() as? [String] ?? []
        supportsGamutWarning = tags.contains("gamt")
    }
}

nonisolated enum CMYKIntent: String, CaseIterable, Sendable {
    case relative = "Relative Colorimetric", perceptual = "Perceptual"
    var value: CFString {
        switch self {
        case .relative: kColorSyncRenderingIntentRelative.takeUnretainedValue()
        case .perceptual: kColorSyncRenderingIntentPerceptual.takeUnretainedValue()
        }
    }
}

/// View-only settings, shared by the canvas proof and TIFF export. The document stays in sRGB.
nonisolated struct PrintSettings: Equatable, Sendable {
    var profile: CMYKProfile?
    var intent = CMYKIntent.relative
    var background = PaletteColor.white
}

/// Each renderer owns its transforms: they are reused across frames, never shared between threads.
nonisolated final class CMYKConversion {
    let space: CGColorSpace
    private let forward: ColorSyncTransform
    private let gamut: ColorSyncTransform?

    init(profile: CMYKProfile, intent: CMYKIntent) throws {
        guard let space = CGColorSpace(iccData: profile.data as CFData),
              let rgb = ColorSyncProfileCreateWithName(kColorSyncSRGBProfile.takeUnretainedValue())?.takeRetainedValue(),
              let cmyk = ColorSyncProfileCreate(profile.data as CFData, nil)?.takeRetainedValue() else { throw CMYKError.profile }
        self.space = space
        func stage(_ profile: ColorSyncProfile, _ tag: Unmanaged<CFString>, _ intent: CFString) -> [String: Any] {
            [kColorSyncProfile.takeUnretainedValue() as String: profile,
             kColorSyncTransformTag.takeUnretainedValue() as String: tag.takeUnretainedValue(),
             kColorSyncRenderingIntent.takeUnretainedValue() as String: intent,
             kColorSyncBlackPointCompensation.takeUnretainedValue() as String: false]
        }
        guard let forward = ColorSyncTransformCreate([
            stage(rgb, kColorSyncTransformDeviceToPCS, intent.value),
            stage(cmyk, kColorSyncTransformPCSToDevice, intent.value)
        ] as CFArray, nil)?.takeRetainedValue() else { throw CMYKError.conversion }
        self.forward = forward
        gamut = profile.supportsGamutWarning ? ColorSyncTransformCreate([
            stage(rgb, kColorSyncTransformDeviceToPCS, CMYKIntent.relative.value),
            stage(cmyk, kColorSyncTransformGamutCheck, CMYKIntent.relative.value)
        ] as CFArray, nil)?.takeRetainedValue() : nil
    }

    /// Flatten before conversion: CMYK TIFF has four ink channels and no alpha channel.
    private func rgb(_ image: CGImage, background: PaletteColor) throws -> CGContext {
        guard image.width * image.height <= DocumentLimits.maxSurfacePixels,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ExportError.render }
        context.setFillColor(CGColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    private func inks(_ rgb: CGContext) throws -> Data {
        var data = Data(count: rgb.width * rgb.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            // Bounded batches let a superseded Export As preview release the exporter promptly.
            for y in stride(from: 0, to: rgb.height, by: 128) {
                try Task.checkCancellation()
                guard ColorSyncTransformConvert(forward, rgb.width, min(128, rgb.height - y),
                    bytes.baseAddress!.advanced(by: y * rgb.width * 4), kColorSync8BitInteger,
                    kColorSyncAlphaNone.rawValue, rgb.width * 4, rgb.data!.advanced(by: y * rgb.bytesPerRow),
                    kColorSync8BitInteger, kColorSyncAlphaNoneSkipLast.rawValue, rgb.bytesPerRow, nil)
                else { throw CMYKError.conversion }
            }
        }
        return data
    }

    func image(_ image: CGImage, background: PaletteColor) throws -> CGImage {
        try self.image(inks(rgb(image, background: background)), width: image.width, height: image.height)
    }

    private func image(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .relativeColorimetric) else { throw CMYKError.conversion }
        return result
    }

    private func display(_ image: CGImage) throws -> CGContext {
        guard let output = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ExportError.render }
        output.setRenderingIntent(.relativeColorimetric)
        output.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return output
    }

    /// Used for the decoded TIFF too, so its preview uses the same display conversion as the canvas.
    func preview(_ image: CGImage) throws -> CGImage {
        guard let result = try display(image).makeImage() else { throw ExportError.render }
        return result
    }

    /// Round-trip the actual ink values through the output profile, then let AppKit color-manage sRGB to the display.
    /// This is a relative-colorimetric proof, without paper-white or black-ink simulation.
    func proof(_ image: CGImage, background: PaletteColor, warning: Bool = false) throws -> CGImage {
        let input = try rgb(image, background: background)
        let data = try inks(input)
        let output = try display(self.image(data, width: image.width, height: image.height))
        if warning {
            guard let gamut else { throw CMYKError.conversion }
            // Request ColorSync's gamut-check format, which yields scalar flags: 0 inside, 1 outside.
            // Work a row at a time so the warning doesn't allocate another full image.
            // Reserve scalar-float space too: newer ColorSync versions return float flags
            // even for the gamut format. Untouched NaNs distinguish packed-bit output.
            var row = [Float](repeating: .nan, count: image.width)
            for y in 0..<image.height {
                let success = row.withUnsafeMutableBytes { bytes in
                    ColorSyncTransformConvert(gamut, image.width, 1, bytes.baseAddress!, kColorSync1BitGamut,
                        kColorSyncAlphaNone.rawValue, image.width * 4, input.data!.advanced(by: y * input.bytesPerRow),
                        kColorSync8BitInteger, kColorSyncAlphaNoneSkipLast.rawValue, input.bytesPerRow, nil)
                }
                guard success else { throw CMYKError.conversion }
                let pixels = output.data!.advanced(by: y * output.bytesPerRow).assumingMemoryBound(to: UInt8.self)
                row.withUnsafeBytes { bytes in
                    let packed = !row[image.width - 1].isFinite
                    for x in 0..<image.width {
                        let outside = packed ? bytes[x / 8] & (0x80 >> (x % 8)) != 0 : row[x] > 0.5
                        if outside {
                            pixels[x * 4] = 128; pixels[x * 4 + 1] = 128; pixels[x * 4 + 2] = 128
                        }
                    }
                }
            }
        }
        guard let result = output.makeImage() else { throw ExportError.render }
        return result
    }
}
