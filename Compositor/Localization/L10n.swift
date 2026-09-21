import Foundation
import SwiftUI

enum L10n {
    static func key(_ value: String) -> LocalizedStringKey {
        LocalizedStringKey(value)
    }

    static func text(_ key: String, locale: Locale = .current) -> String {
        let bundle = localizedBundle(for: locale)
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    private static func localizedBundle(for locale: Locale) -> Bundle {
        guard let languageCode = locale.languageCode,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main
        }
        return bundle
    }
}
