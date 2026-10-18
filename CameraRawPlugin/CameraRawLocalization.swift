import Foundation

// Bundle(for:) keeps framework UI independent of the host's catalog. The identifier fallback
// also supports the standalone smoke executable's directly compiled draft/model sources once
// it has loaded the real framework. Neither path maintains a separate language preference.
private final class CameraRawLocalizationBundle: NSObject {}

nonisolated enum CameraRawLocalization {
    static var bundle: Bundle {
        let definingBundle = Bundle(for: CameraRawLocalizationBundle.self)
        let identifier = "com.wonderassembly.compositor.CameraRawPlugin"
        if definingBundle.bundleIdentifier == identifier { return definingBundle }
        return Bundle(identifier: identifier) ?? definingBundle
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}
