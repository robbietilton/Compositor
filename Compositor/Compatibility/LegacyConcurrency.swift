import Foundation

enum LegacyDelay {
    static func milliseconds(_ value: UInt64) -> UInt64 {
        guard value <= UInt64.max / 1_000_000 else { return UInt64.max }
        return value * 1_000_000
    }
}
