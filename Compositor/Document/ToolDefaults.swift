import Foundation

/// Toggles that belong to the person rather than to a document: Auto Select, the transform box,
/// rulers, guides, the grid and the snapping switches. They keep whatever they were last set to,
/// across tabs and across launches, the way Photoshop's tool options do.
///
/// Tests get the compiled defaults instead, so one test flipping a switch can't reach another —
/// or the app the person is actually using.
nonisolated enum ToolDefaults {
    private static let prefix = "tool."
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard !isTesting else { return fallback }
        return UserDefaults.standard.object(forKey: prefix + key) as? Bool ?? fallback
    }

    static func set(_ value: Bool, _ key: String) {
        guard !isTesting else { return }
        UserDefaults.standard.set(value, forKey: prefix + key)
    }
}
