import CameraRawHostContract
import CoreFoundation
import Foundation

/// Changes only declared control paths, leaving all other JSON members intact.
struct CameraRawDraft {
    private var object: [String: Any]

    init(payload: Data, controls: [CameraRawControl]) throws {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw DraftError.invalidPayload
        }
        self.object = object
        var ids = Set<String>()
        for control in controls {
            guard ids.insert(control.id).inserted,
                  !control.id.split(separator: ".", omittingEmptySubsequences: false).contains(""),
                  control.lowerBound.isFinite, control.upperBound.isFinite,
                  control.defaultValue.isFinite,
                  control.lowerBound < control.upperBound,
                  (control.lowerBound...control.upperBound).contains(control.defaultValue) else {
                throw DraftError.invalidControl(control.title)
            }
            guard !controls.contains(where: { $0.id != control.id && $0.id.hasPrefix(control.id + ".") }) else {
                throw DraftError.invalidControl(control.title)
            }
            let value = try value(for: control)
            guard (control.lowerBound...control.upperBound).contains(value) else {
                throw DraftError.invalidValue(control.title)
            }
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DraftError.invalidPayload
        }
    }

    func value(for control: CameraRawControl) throws -> Double {
        let path = control.id.components(separatedBy: ".")
        var dictionary = object
        for (index, key) in path.enumerated() {
            guard let value = dictionary[key] else { return control.defaultValue }
            if index == path.count - 1 {
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else {
                    throw DraftError.invalidValue(control.title)
                }
                return number.doubleValue
            }
            guard let nested = value as? [String: Any] else {
                throw DraftError.invalidValue(control.title)
            }
            dictionary = nested
        }
        return control.defaultValue
    }

    mutating func set(_ value: Double, for control: CameraRawControl) throws {
        guard value.isFinite, (control.lowerBound...control.upperBound).contains(value) else {
            throw DraftError.invalidValue(control.title)
        }
        try Self.set(value, path: ArraySlice(control.id.components(separatedBy: ".")), in: &object)
    }

    func payload() throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw DraftError.invalidPayload }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func set(_ value: Double, path: ArraySlice<String>, in object: inout [String: Any]) throws {
        guard let key = path.first else { throw DraftError.invalidPayload }
        if path.count == 1 {
            object[key] = value
        } else {
            var nested: [String: Any]
            if let existing = object[key] {
                guard let dictionary = existing as? [String: Any] else { throw DraftError.invalidPayload }
                nested = dictionary
            } else {
                nested = [:]
            }
            try set(value, path: path.dropFirst(), in: &nested)
            object[key] = nested
        }
    }

    enum DraftError: LocalizedError {
        case invalidPayload
        case invalidControl(String)
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .invalidPayload: CameraRawLocalization.string("The Camera Raw settings must be a valid JSON object.")
            case .invalidControl(let title): CameraRawLocalization.format("The host supplied an invalid control: %1$@.", title)
            case .invalidValue(let title): CameraRawLocalization.format("The setting for %1$@ must be a finite JSON number.", title)
            }
        }
    }
}
