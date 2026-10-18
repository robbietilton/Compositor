import AppKit
import CoreGraphics
import Foundation

/// UI metadata only. The host owns adjustment semantics and payload validation.
public struct CameraRawControl: Sendable {
    public let id: String
    public let title: String
    public let group: String
    public let lowerBound: Double
    public let upperBound: Double
    public let defaultValue: Double

    public init(
        id: String,
        title: String,
        group: String,
        lowerBound: Double,
        upperBound: Double,
        defaultValue: Double
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.defaultValue = defaultValue
    }
}

@MainActor
public protocol CameraRawEditingHost: AnyObject {
    var controls: [CameraRawControl] { get }
    var initialPayload: Data { get }
    var sourceImage: CGImage { get }

    func preview(payload: Data) async throws -> CGImage
    func apply(payload: Data) async throws
    func cancel()
}

/// Loaded through Bundle.principalClass; the host and plugin share this framework's identity.
@MainActor
public protocol CameraRawPluginPrincipal: AnyObject {
    init()
    func makePanel(host: any CameraRawEditingHost) -> NSWindowController
}
