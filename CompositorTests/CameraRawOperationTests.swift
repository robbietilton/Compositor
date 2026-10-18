import AppKit
import Testing
@testable import Compositor

@MainActor
struct CameraRawOperationTests {
    @Test func settingsRoundTripIncludesEveryPanelAndOnlyStoredFields() throws {
        let settings = editedSettings()
        let payload = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CameraRawSettings.self, from: payload)
        #expect(decoded == settings)
        let operation = CameraRawOperation(payload: payload, seed: .max)
        #expect(operation.pluginID == "compositor.camera-raw")
        #expect(operation.schemaVersion == 1)
        #expect(operation.isValid)
        #expect(operation.settings == settings)
        #expect(try JSONDecoder().decode(CameraRawOperation.self, from: JSONEncoder().encode(operation)) == operation)

        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["isIdentity"] == nil)
        #expect(object["isValid"] == nil)
        #expect(object["normalized"] == nil)
        #expect(object["grainKernelSize"] == nil)
        let grading = try #require(object["grading"] as? [String: Any])
        #expect(grading["wheels"] == nil)
        let geometry = try #require(object["geometry"] as? [String: Any])
        let guide = try #require((geometry["guides"] as? [[String: Any]])?.first)
        #expect(guide["start"] == nil && guide["end"] == nil)
        #expect(guide["startX"] as? Double == settings.geometry.guides.first?.startX)
    }

    @Test func defaultSettingsAndBoundaryValuesAreValid() throws {
        #expect(try operation(CameraRawSettings()).settings == CameraRawSettings())
        var settings = CameraRawSettings()
        settings.exposure = 5
        settings.contrast = -100
        settings.glow = 100
        settings.curve.shadowSplit = 90
        settings.curve.darkSplit = 95
        settings.curve.lightSplit = 98
        settings.mixer.points = [CameraRawPointColor(hue: 360, saturation: 1, luminance: 1,
            hueShift: -100, saturationShift: 100, luminanceShift: -100, hueRange: 180,
            saturationRange: 0.05, luminanceRange: 1)]
        settings.grading.global = CameraRawGradeWheel(hue: 360, saturation: 100, luminance: -100)
        settings.detail.sharpenAmount = 150
        settings.optics.purpleHueLow = 360
        settings.optics.purpleHueHigh = 360
        settings.geometry.rotate = -45
        settings.geometry.guides = [CameraRawGeometryGuide(startX: 0, startY: 0, endX: 1, endY: 1)]
        settings.calibration.redHue = -100
        #expect(try operation(settings).settings == settings)
    }

    @Test func malformedKnownPayloadsAreNeverNormalized() throws {
        for bytes in [Data(), Data("{}".utf8), Data("not json".utf8), Data("[]".utf8)] {
            let operation = CameraRawOperation(payload: bytes)
            #expect(operation.settings == nil)
            #expect(!operation.isValid)
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraRawSettings())) as? [String: Any])
        object["whiteBalance"] = "Unknown balance"
        #expect(!CameraRawOperation(payload: try JSONSerialization.data(withJSONObject: object)).isValid)
        object["whiteBalance"] = "Custom"
        object.removeValue(forKey: "calibration")
        #expect(!CameraRawOperation(payload: try JSONSerialization.data(withJSONObject: object)).isValid)

        let mutations: [(inout CameraRawSettings) -> Void] = [
            { $0.exposure = 6 }, { $0.temperature = -101 }, { $0.grainRoughness = 101 },
            { $0.curve.shadows = 101 }, { $0.curve.refineSaturation = -101 },
            { $0.curve.shadowSplit = 91 }, { $0.curve.darkSplit = 26 }, { $0.curve.lightSplit = 51 },
            { $0.curve.rgb = [] },
            { $0.curve.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 1)] },
            { $0.curve.green[0].y = -0.1 }, { $0.curve.blue[1].x = 0.9 },
            { $0.mixer.hue.removeLast() }, { $0.mixer.saturation.append(0) }, { $0.mixer.luminance[0] = 101 },
            { $0.mixer.points = Array(repeating: CameraRawPointColor(), count: 9) },
            { $0.mixer.points = [CameraRawPointColor(hue: -1)] },
            { $0.mixer.points = [CameraRawPointColor(saturation: 1.1)] },
            { $0.mixer.points = [CameraRawPointColor(luminanceShift: 101)] },
            { $0.mixer.points = [CameraRawPointColor(hueRange: 4)] },
            { $0.mixer.points = [CameraRawPointColor(saturationRange: 0.04)] },
            { $0.grading.blending = 101 }, { $0.grading.balance = -101 },
            { $0.grading.shadows.hue = 361 }, { $0.grading.midtones.saturation = -1 },
            { $0.grading.highlights.luminance = 101 }, { $0.grading.global.hue = -1 },
            { $0.detail.sharpenAmount = 151 }, { $0.detail.sharpenRadius = -1 },
            { $0.detail.noiseColorSmoothness = 101 },
            { $0.optics.profileDistortion = 101 }, { $0.optics.distortion = -101 },
            { $0.optics.purpleHueLow = 311 }, { $0.optics.greenHueHigh = 59 }, { $0.optics.vignetteMidpoint = -1 },
            { $0.geometry.rotate = 46 }, { $0.geometry.offsetX = 101 },
            { $0.geometry.guides = [CameraRawGeometryGuide(endX: 1.01)] },
            { $0.calibration.shadowTint = -101 }, { $0.calibration.blueSaturation = 101 }
        ]
        for mutate in mutations {
            var settings = CameraRawSettings()
            mutate(&settings)
            let operation = try operation(settings)
            #expect(operation.settings == nil)
            #expect(!operation.isValid)
        }
    }

    @Test func nonFiniteValuesCannotBecomePersistedSettings() throws {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let fields: [WritableKeyPath<CameraRawSettings, Double>] = [
            \.exposure, \.curve.highlights, \.grading.global.hue, \.detail.noiseColor,
            \.optics.purpleHueLow, \.geometry.offsetY, \.calibration.redSaturation
        ]
        for field in fields {
            for value in [Double.nan, .infinity, -.infinity] {
                var settings = CameraRawSettings()
                settings[keyPath: field] = value
                #expect(throws: (any Error).self) { try JSONEncoder().encode(settings) }
                let operation = CameraRawOperation(payload: try encoder.encode(settings))
                #expect(operation.settings == nil)
                #expect(!operation.isValid)
            }
        }
    }

    @Test func metadataAndPayloadLimitsApplyEvenToUnknownPlugins() {
        let bytes = Data(repeating: 0xff, count: CameraRawOperation.maximumPayloadBytes)
        #expect(CameraRawOperation(payload: bytes, pluginID: "other.camera").isValid)
        #expect(!CameraRawOperation(payload: bytes + Data([0]), pluginID: "other.camera").isValid)
        for id in ["", " ", " compositor.camera-raw", "plugin\nname", String(repeating: "a", count: 257)] {
            #expect(!CameraRawOperation(payload: Data(), pluginID: id).isValid)
        }
        #expect(!CameraRawOperation(payload: Data(), pluginID: "other.camera", schemaVersion: 0).isValid)
        #expect(!CameraRawOperation(payload: Data(), pluginID: "other.camera", schemaVersion: -1).isValid)
    }

    @Test func version14AndMissingOperationOpenWithoutAGrade() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try imageSession()
        let snapshot = try #require(session.projectSnapshot())
        var manifest = snapshot.manifest
        manifest.version = 14
        let url = folder.appendingPathComponent("Old.comp")
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: manifest, images: snapshot.images), to: url)
        let bytes = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("cameraRawOperation"))
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 14)
        #expect(loaded.manifest.layers.first?.cameraRawOperation == nil)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.document?.layers.first?.cameraRawOperation == nil)
        #expect(try #require(reopened.projectSnapshot()).manifest.version == 15)
    }

    @Test func packageRoundTripKeepsKnownExtrasAndUnknownPayloadBytesExactly() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(editedSettings())) as? [String: Any])
        object["futurePanel"] = ["amount": 0.123456789, "name": "untouched"]
        var detail = try #require(object["detail"] as? [String: Any])
        detail["futureDetail"] = [1, 2, 3]
        object["detail"] = detail
        var knownBytes = Data(" \n".utf8)
        knownBytes.append(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
        knownBytes.append(Data("\n ".utf8))
        let opaqueBytes = Data([0, 0xff, 10, 32, 123, 0x80, 125])
        let operations = [
            CameraRawOperation(payload: knownBytes, seed: 314159),
            CameraRawOperation(payload: opaqueBytes, seed: .max, schemaVersion: 2),
            CameraRawOperation(payload: opaqueBytes, seed: 17, pluginID: "another.camera-raw")
        ]
        for (index, operation) in operations.enumerated() {
            #expect(operation.isValid)
            #expect((operation.settings != nil) == (index == 0))
            let session = try imageSession()
            session.document?.layers[0].cameraRawOperation = operation
            let snapshot = try #require(session.projectSnapshot())
            #expect(snapshot.manifest.layers.first?.cameraRawOperation == operation)
            let url = folder.appendingPathComponent("Operation-\(index).comp")
            try await ProjectStore.shared.save(snapshot, to: url)
            let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("manifest.json"))) as? [String: Any])
            let record = try #require((manifest["layers"] as? [[String: Any]])?.first)
            let stored = try #require(record["cameraRawOperation"] as? [String: Any])
            #expect(stored["payload"] as? String == operation.payload.base64EncodedString())
            let loaded = try await ProjectStore.shared.load(from: url)
            #expect(loaded.manifest.layers.first?.cameraRawOperation == operation)
            let reopened = EditorSession()
            reopened.installProject(loaded, from: url)
            #expect(reopened.document?.layers.first?.cameraRawOperation == operation)
            let resaved = folder.appendingPathComponent("Resaved-\(index).comp")
            try await ProjectStore.shared.save(try #require(reopened.projectSnapshot()), to: resaved)
            let reloaded = try await ProjectStore.shared.load(from: resaved)
            #expect(reloaded.manifest.layers.first?.cameraRawOperation?.payload == operation.payload)
        }
    }

    @Test func packageValidationRejectsBadOperationsAndNonRasterLayers() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try imageSession()
        let snapshot = try #require(session.projectSnapshot())
        var valid = snapshot.manifest
        valid.layers[0].cameraRawOperation = try operation(CameraRawSettings())
        let url = folder.appendingPathComponent("Valid.comp")
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: valid, images: snapshot.images), to: url)
        let badOperations = [
            CameraRawOperation(payload: Data("{}".utf8)),
            CameraRawOperation(payload: Data(), pluginID: ""),
            CameraRawOperation(payload: Data(), schemaVersion: 0),
            CameraRawOperation(payload: Data(repeating: 0, count: 65537), schemaVersion: 2)
        ]
        var invalidManifests: [ProjectManifest] = []
        for operation in badOperations {
            var manifest = valid
            manifest.layers[0].cameraRawOperation = operation
            invalidManifests.append(manifest)
        }
        var old = valid
        old.version = 14
        invalidManifests.append(old)
        let base = try #require(valid.layers.first)
        for kind in 0..<5 {
            var record = ProjectLayerRecord(id: base.id, name: base.name, isVisible: true, transform: base.transform,
                imageFile: kind < 3 ? nil : base.imageFile, cameraRawOperation: base.cameraRawOperation)
            if kind == 1 { record.isGroup = true }
            if kind == 2 { record.adjustment = LayerAdjustment(kind: .invert) }
            if kind == 3 { record.text = LayerTextStyle() }
            if kind == 4 { record.shape = LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0, cornerRadius: 0) }
            var manifest = valid
            manifest.layers = [record]
            invalidManifests.append(manifest)
        }
        let metadata = url.appendingPathComponent("manifest.json")
        for manifest in invalidManifests {
            do {
                try await ProjectStore.shared.save(ProjectSnapshot(manifest: manifest, images: snapshot.images),
                    to: folder.appendingPathComponent("Rejected.comp"))
                Issue.record("Invalid plugin metadata was saved")
            } catch ProjectError.invalid {} catch { Issue.record("Unexpected save error: \(error)") }
            try JSONEncoder().encode(manifest).write(to: metadata)
            do {
                _ = try await ProjectStore.shared.load(from: url)
                Issue.record("Invalid plugin metadata was loaded")
            } catch ProjectError.invalid {} catch { Issue.record("Unexpected load error: \(error)") }
        }
    }

    private func operation(_ settings: CameraRawSettings) throws -> CameraRawOperation {
        CameraRawOperation(payload: try JSONEncoder().encode(settings))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CameraRawOperationTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func imageSession() throws -> EditorSession {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: 4, height: 3)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Source"))
        return session
    }

    private func editedSettings() -> CameraRawSettings {
        var settings = CameraRawSettings()
        settings.whiteBalance = .auto
        settings.temperature = 11; settings.tint = -12; settings.exposure = 1.25
        settings.contrast = 13; settings.highlights = -14; settings.shadows = 15; settings.whites = -16; settings.blacks = 17
        settings.vibrance = 18; settings.saturation = -19; settings.texture = 20; settings.clarity = -21; settings.dehaze = 22
        settings.glow = 23; settings.glowStyle = .bloom; settings.glowRange = 24; settings.glowSpread = -25; settings.glowWarmth = 26
        settings.vignetteAmount = -27; settings.vignetteStyle = .paintOverlay; settings.vignetteMidpoint = 28
        settings.vignetteRoundness = -29; settings.vignetteFeather = 30; settings.vignetteHighlights = 31
        settings.grainAmount = 32; settings.grainSize = 33; settings.grainRoughness = 34
        settings.curve = CameraRawCurveSettings(shadows: -11, darks: 12, lights: -13, highlights: 14,
            shadowSplit: 20, darkSplit: 45, lightSplit: 80, rgb: CameraRawCurveSettings.mediumContrast,
            red: CameraRawCurveSettings.strongContrast, green: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)],
            blue: [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 0.8)], refineSaturation: 15)
        settings.mixer = CameraRawMixerSettings(hue: [1, 2, 3, 4, 5, 6, 7, 8], saturation: [-1, -2, -3, -4, -5, -6, -7, -8],
            luminance: [8, 7, 6, 5, 4, 3, 2, 1], points: [CameraRawPointColor(hue: 120, saturation: 0.5, luminance: 0.6,
                hueShift: 12, saturationShift: -13, luminanceShift: 14, hueRange: 45, saturationRange: 0.3,
                luminanceRange: 0.2, visualize: true)])
        settings.grading = CameraRawGradingSettings(shadows: CameraRawGradeWheel(hue: 10, saturation: 20, luminance: -30),
            midtones: CameraRawGradeWheel(hue: 40, saturation: 50, luminance: 60),
            highlights: CameraRawGradeWheel(hue: 70, saturation: 80, luminance: -90),
            global: CameraRawGradeWheel(hue: 100, saturation: 90, luminance: 80), blending: 35, balance: -36)
        settings.detail = CameraRawDetailSettings(sharpenAmount: 120, sharpenRadius: 11, sharpenDetail: 26, sharpenMasking: 37,
            noiseLuminance: 38, noiseLuminanceDetail: 51, noiseLuminanceContrast: 39, noiseColor: 40,
            noiseColorDetail: 52, noiseColorSmoothness: 53)
        settings.optics = CameraRawOpticsSettings(removeChromaticAberration: true, enableLensProfile: true,
            profileDistortion: 90, profileVignetting: 80, distortion: -10, purpleAmount: 41, purpleHueLow: 260,
            purpleHueHigh: 320, greenAmount: 42, greenHueLow: 55, greenHueHigh: 125, vignetteAmount: 43, vignetteMidpoint: 44)
        settings.geometry = CameraRawGeometrySettings(upright: .guided, projection: .rectilinear, vertical: 45, horizontal: -46,
            rotate: 7, aspect: 48, scale: 49, offsetX: -50, offsetY: 51, constrainCrop: true,
            guides: [CameraRawGeometryGuide(startX: 0.1, startY: 0.2, endX: 0.8, endY: 0.9)])
        settings.calibration = CameraRawCalibrationSettings(process: .version3, shadowTint: 52, redHue: -53,
            redSaturation: 54, greenHue: -55, greenSaturation: 56, blueHue: -57, blueSaturation: 58)
        return settings
    }
}
