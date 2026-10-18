import Foundation

/// A recipe is defined over the layer's original pixels. Source-changing edits must not silently rebase it.
nonisolated enum CameraRawSourceEditError: LocalizedError {
    case protectedSource

    var errorDescription: String? {
        AppLocalization.string("This edit would change the source pixels of a Camera Raw operation. Remove the Camera Raw operation before editing its source pixels.")
    }
}
