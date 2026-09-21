import CoreGraphics
import Foundation

/// The image models on offer. Raw values are the identifiers the service knows them by; they are retired
/// on the service's schedule, so this list is the one place to change when that happens.
nonisolated enum GenerativeModel: String, CaseIterable, Codable, Sendable {
    case flash = "gemini-3.1-flash-image"
    case flashLite = "gemini-3.1-flash-lite-image"
    case pro = "gemini-3-pro-image"

    var title: String { self == .flash ? "Nano Banana 2" : self == .flashLite ? "Nano Banana 2 Lite" : "Nano Banana Pro" }
    var detail: String {
        self == .flash ? "Fast, up to 4K. A good default." : self == .flashLite ? "Fastest and cheapest, 1K only." : "Slowest and most capable, up to 4K."
    }
    var largestSize: GenerativeSize { self == .flashLite ? .k1 : .k4 }
    /// How many extra pictures may guide a request, beside the one being changed and its hint.
    static let referenceLimit = 3
}

/// One picture going to the model, already encoded.
nonisolated struct GenerativeAttachment: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

/// Everything a provider needs for one generated image. Built on the main actor from the document, then
/// handed off: nothing in it refers back to the session.
nonisolated struct GenerativeRequest: Equatable, Sendable {
    let model: GenerativeModel
    let prompt: String
    /// The part of the document to change, with its surroundings.
    let image: GenerativeAttachment
    /// White where the change is wanted. Nil for providers that are told where in words only.
    let hint: GenerativeAttachment?
    let references: [GenerativeAttachment]
    let ratio: GenerativeAspectRatio
    let size: GenerativeSize
}

nonisolated enum GenerativeError: LocalizedError, Equatable {
    case missingKey, invalidKey, billing, quota, refused(String), noImage, unavailable, network(String), service(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your API key in Settings to use generative features."
        case .invalidKey: "The API key was not accepted. Check it in Settings."
        case .billing: "This API key cannot generate images yet. Image models need billing enabled on the key’s Google project."
        case .quota: "The API key has reached its rate limit or quota. Wait a moment, or check the limits on your Google project."
        case .refused(let reason): "The model declined this request\(reason.isEmpty ? "." : ": \(reason)") Try rewording it, or a different selection."
        case .noImage: "The model answered without an image. Try again, or reword the request."
        case .unavailable: "The image service is busy or unavailable. Try again shortly."
        case .network(let detail): "The request could not be sent. \(detail)"
        case .service(let detail): "The image service reported a problem. \(detail)"
        }
    }

    /// Worth another attempt without the user doing anything.
    var isTransient: Bool { self == .unavailable || self == .quota }
}

/// A service that turns a request into image bytes. Kept this small so that masked-fill services can be
/// added beside the first one without the editor knowing which it is talking to.
nonisolated protocol GenerativeImageProvider: Sendable {
    /// The generated image, encoded as the service returned it.
    func generate(_ request: GenerativeRequest, key: String) async throws -> Data
    /// Confirms the key is accepted and can reach the image models, without generating (or charging for) anything.
    func verify(key: String) async throws
}
