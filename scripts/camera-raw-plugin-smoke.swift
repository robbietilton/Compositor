import AppKit
import CameraRawHostContract
import Foundation

// Compiled with CameraRawLocalization.swift and the plugin's draft/model sources, but linked
// only to the public contract framework. The bundle check exercises the separately built UI.
// Run fresh processes for each language (language changes require a restart):
//   camera-raw-plugin-smoke <CameraRawPlugin.framework> en -AppleLanguages '(en)'
//   camera-raw-plugin-smoke <CameraRawPlugin.framework> zh-Hans -AppleLanguages '(zh-Hans)'
private enum SmokeError: LocalizedError {
    case expected, timeout(String), missingBundle

    var errorDescription: String? {
        switch self {
        case .expected: "smoke failure: %1$@ / 测试"
        case .timeout(let label): "Timed out: \(label)"
        case .missingBundle: "Missing plugin bundle or expected language (en or zh-Hans)"
        }
    }
}

@MainActor
private final class SmokeHost: CameraRawEditingHost {
    let controls: [CameraRawControl] = [
        .init(id: "exposure", title: "Exposure", group: "Light", lowerBound: -5, upperBound: 5, defaultValue: 0),
        .init(id: "detail.sharpenAmount", title: "Sharpening", group: "Detail", lowerBound: 0, upperBound: 150, defaultValue: 0)
    ]
    let initialPayload = Data(#"{"exposure":0,"detail":{"sharpenAmount":25,"unknown":true},"future":{"version":9}}"#.utf8)
    let sourceImage = SmokeHost.image(width: 1)
    var previewCount = 0
    var finishedPreviews = 0
    var applied: Data?
    var cancelCount = 0
    var failApply = false

    static func image(width: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: 1))
        return context.makeImage()!
    }

    func preview(payload: Data) async throws -> CGImage {
        previewCount += 1
        let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let exposure = (object["exposure"] as! NSNumber).doubleValue
        // Deliberately ignore cancellation so the older image can finish after the newer image.
        await Task.detached { try? await Task.sleep(for: .milliseconds(exposure == 0 ? 600 : 20)) }.value
        finishedPreviews += 1
        return Self.image(width: exposure == 0 ? 1 : 2)
    }

    func apply(payload: Data) async throws {
        if failApply { throw SmokeError.expected }
        applied = payload
    }

    func cancel() { cancelCount += 1 }
}

@main
private struct CameraRawPluginSmoke {
    @MainActor
    static func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SmokeError.timeout(label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    static func verifyLocalization(bundle: Bundle, expectedLanguage: String) throws {
        guard let path = bundle.path(forResource: expectedLanguage, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else { throw SmokeError.missingBundle }
        precondition(CameraRawLocalization.bundle.bundleURL.resolvingSymlinksInPath()
                     == bundle.bundleURL.resolvingSymlinksInPath(), "Smoke model must use framework resources")
        let keys: [(String, String)] = [
            ("Camera Raw", "Camera Raw"),
            ("Compare with Original", "与原图对比"),
            ("Original", "原图"),
            ("Preview", "预览"),
            ("Rendering Preview…", "正在渲染预览…"),
            ("Retry Preview", "重试预览"),
            ("Reset Sliders", "重置滑块"),
            ("Applying…", "正在应用…"),
            ("Cancel", "取消"),
            ("Apply", "应用"),
            ("%1$@ image", "%1$@图像"),
            ("%1$@ must be a number from %2$@ to %3$@.", "%1$@必须是 %2$@ 到 %3$@ 之间的数字。"),
            ("Could not apply Camera Raw settings: %1$@", "无法应用 Camera Raw 设置：%1$@"),
            ("Could not preview Camera Raw settings: %1$@", "无法预览 Camera Raw 设置：%1$@"),
            ("The Camera Raw settings must be a valid JSON object.", "Camera Raw 设置必须是有效的 JSON 对象。"),
            ("The host supplied an invalid control: %1$@.", "主程序提供了无效的控件：%1$@。"),
            ("The setting for %1$@ must be a finite JSON number.", "%1$@的设置必须是有限的 JSON 数字。")
        ]
        for (key, chinese) in keys {
            let expected = expectedLanguage == "zh-Hans" ? chinese : key
            precondition(languageBundle.localizedString(forKey: key, value: nil, table: nil) == expected,
                         "Missing framework translation: \(key)")
            precondition(CameraRawLocalization.string(key) == expected,
                         "Unexpected process language for \(key); launch with -AppleLanguages")
        }
        let title = "Host title 100% %1$@"
        let expectedError = expectedLanguage == "zh-Hans"
            ? "\(title)的设置必须是有限的 JSON 数字。"
            : "The setting for \(title) must be a finite JSON number."
        precondition(CameraRawDraft.DraftError.invalidValue(title).errorDescription == expectedError)
        precondition(CameraRawLocalization.string("unknown.plugin.key") == "unknown.plugin.key")
        print("PASS: independent framework catalog, all localized strings and complete templates (\(expectedLanguage))")
    }

    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count >= 3,
              ["en", "zh-Hans"].contains(CommandLine.arguments[2]),
              let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1])) else { throw SmokeError.missingBundle }
        _ = NSApplication.shared
        try bundle.loadAndReturnError()
        try verifyLocalization(bundle: bundle, expectedLanguage: CommandLine.arguments[2])
        guard let principal = bundle.principalClass as? any CameraRawPluginPrincipal.Type else { throw SmokeError.missingBundle }
        let panelHost = SmokeHost()
        let panel = principal.init().makePanel(host: panelHost)
        precondition(panel.window?.title == CameraRawLocalization.string("Camera Raw"))
        panel.close()
        panel.close()
        precondition(panelHost.cancelCount == 1)
        print("PASS: load independent bundle, resolve shared protocol, create panel, cancel exactly once")

        let host = SmokeHost()
        var draft = try CameraRawDraft(payload: host.initialPayload, controls: host.controls)
        try draft.set(50, for: host.controls[1])
        let object = try JSONSerialization.jsonObject(with: draft.payload()) as! [String: Any]
        precondition((object["detail"] as! [String: Any])["unknown"] as! Bool)
        precondition((object["future"] as! [String: Any])["version"] as! Int == 9)
        precondition((object["detail"] as! [String: Any])["sharpenAmount"] as! Double == 50)
        do { try draft.set(.infinity, for: host.controls[0]); fatalError("Accepted infinite value") } catch {}
        do {
            _ = try CameraRawDraft(payload: Data(#"{"exposure":true}"#.utf8), controls: host.controls)
            fatalError("Accepted Boolean")
        } catch {}

        let model = CameraRawPanelModel(host: host)
        try await wait("first preview starts") { host.previewCount == 1 }
        model.setSlider(1, for: host.controls[0])
        try await wait("both preview requests finish") { host.finishedPreviews == 2 && !model.isPreviewing }
        precondition(model.previewImage.width == 2, "Obsolete preview replaced latest image")
        model.setNumericText("nan", for: host.controls[0])
        precondition(!model.canApply)
        precondition(model.errorMessage == CameraRawLocalization.format(
            "%1$@ must be a number from %2$@ to %3$@.", "Exposure", "-5.0", "5.0"
        ))
        model.setNumericText("1,5", for: host.controls[0])
        precondition(!model.canApply, "Numeric parsing must remain Double-based in every language")
        model.setSlider(2, for: host.controls[0])
        try await wait("valid preview") { model.canApply }
        host.failApply = true
        model.apply()
        try await wait("apply failure") { !model.isApplying }
        precondition(!model.canApply && model.canRetryPreview)
        precondition(model.errorMessage == CameraRawLocalization.format(
            "Could not apply Camera Raw settings: %1$@", SmokeError.expected.localizedDescription
        ))
        host.failApply = false
        model.retryPreview()
        try await wait("retry preview") { model.canApply }
        model.apply()
        try await wait("successful apply") { model.isFinished }
        precondition(host.applied != nil)
        model.cancel()
        precondition(host.cancelCount == 0, "Cancelled after successful apply")
        let resetHost = SmokeHost()
        let resetModel = CameraRawPanelModel(host: resetHost)
        resetModel.reset()
        precondition(resetModel.value(for: resetHost.controls[1]) == 0)
        resetModel.cancel()
        resetModel.cancel()
        precondition(resetHost.cancelCount == 1)
        print("PASS: unknown JSON fields, numeric validation, stale preview rejection, Apply retry, Reset and Cancel")
    }
}
