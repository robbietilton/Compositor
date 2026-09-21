import Foundation
import Testing
@testable import Compositor

/// The answers and failures below are written by hand from the service's documentation: no real key was
/// available to record them. They show the provider handles the documented shapes, not that the service
/// keeps to them. The invalid-key failure is the exception only in part: its HTTP status, `status`, `message`
/// and `reason` are what the live service returned (2026-09-21); the JSON around them follows the documentation.
struct GeminiProviderTests {
    /// Answers requests from a script, and keeps what it was sent.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [(Int, Data)]
        private(set) var requests: [URLRequest] = []
        init(_ replies: [(Int, String)]) { self.replies = replies.map { ($0.0, Data($0.1.utf8)) } }
        var transport: GeminiProvider.Transport {
            { [self] request in
                lock.lock(); defer { lock.unlock() }
                requests.append(request)
                let (status, body) = replies.isEmpty ? (500, Data()) : replies.removeFirst()
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }
    private func provider(_ wire: Wire) -> GeminiProvider { GeminiProvider(transport: wire.transport, backoff: [.zero, .zero]) }

    private let request = GenerativeRequest(model: .flash, prompt: "Make the jacket red.",
        image: GenerativeAttachment(data: Data([1, 2, 3]), mimeType: "image/jpeg"),
        hint: GenerativeAttachment(data: Data([4, 5]), mimeType: "image/png"),
        references: [GenerativeAttachment(data: Data([6]), mimeType: "image/png")],
        ratio: GenerativeAspectRatio(width: 3, height: 2), size: .k2)
    private let picture = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
    private func answer(_ parts: String, finish: String = "STOP") -> String {
        #"{"candidates":[{"content":{"parts":[\#(parts)]},"finishReason":"\#(finish)"}]}"#
    }
    private let invalidKey = #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}"#

    @Test func theRequestCarriesWordsThenPicturesInTheFormTheServiceAccepts() async throws {
        let wire = Wire([(200, answer(#"{"inlineData":{"mimeType":"image/png","data":"\#(picture)"}}"#))])
        _ = try await provider(wire).generate(request, key: "secret")
        let sent = try #require(wire.requests.first)
        #expect(sent.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent")
        #expect(sent.httpMethod == "POST" && sent.value(forHTTPHeaderField: "x-goog-api-key") == "secret")
        #expect(sent.url?.absoluteString.contains("secret") == false) // The key stays out of the URL.
        let payload = try #require(sent.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let parts = try #require(((body["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
        #expect(parts.count == 4 && parts[0]["text"] as? String == "Make the jacket red." && parts[0]["inlineData"] == nil)
        let inline = parts.dropFirst().compactMap { $0["inlineData"] as? [String: String] }
        #expect(inline.map { $0["mimeType"] } == ["image/jpeg", "image/png", "image/png"])
        #expect(inline.map { $0["data"] } == [Data([1, 2, 3]), Data([4, 5]), Data([6])].map { $0.base64EncodedString() })
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["responseModalities"] as? [String] == ["TEXT", "IMAGE"])
        #expect(config["imageConfig"] as? [String: String] == ["aspectRatio": "3:2", "imageSize": "2K"])
        #expect(config["responseFormat"] == nil) // The live service rejects "3:2" and "2K" there.
    }

    @Test func theAnswerIsTheLastPictureThatIsNotADraft() throws {
        let final = Data([9, 9, 9]).base64EncodedString()
        let body = answer(#"{"text":"Thinking…","thought":true},{"inlineData":{"mimeType":"image/png","data":"\#(picture)"},"thought":true},{"text":"Here you go."},{"inlineData":{"mimeType":"image/png","data":"\#(final)"}}"#)
        #expect(try GeminiProvider.image(in: Data(body.utf8)) == Data([9, 9, 9]))
    }

    @Test func refusalsAndEmptyAnswersSayWhatHappened() {
        func failure(_ body: String) -> GenerativeError? {
            do { _ = try GeminiProvider.image(in: Data(body.utf8)); return nil } catch { return error as? GenerativeError }
        }
        #expect(failure(answer("", finish: "IMAGE_SAFETY")) == .refused("its safety filter stopped the image."))
        #expect(failure(answer(#"{"text":"I can’t edit images of real people."}"#)) == .refused("I can’t edit images of real people."))
        #expect(failure(answer("", finish: "NO_IMAGE")) == .noImage)
        #expect(failure(answer(#"{"inlineData":{"mimeType":"image/png","data":"\#(picture)"},"thought":true}"#)) == .noImage) // Only a draft.
        #expect(failure(#"{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}"#) == .refused("the request or the image is not allowed by the service."))
        #expect(failure("{}") == .noImage)
        #expect(failure("not json") == .service("Its answer was not understood."))
    }

    @Test func failuresAreToldApartByWhatTheUserCanDoAboutThem() {
        func error(_ status: Int, _ body: String) -> GenerativeError { GeminiProvider.failure(status: status, body: Data(body.utf8)) }
        #expect(error(400, invalidKey) == .invalidKey) // A bad key is a 400 here, not a 401.
        #expect(error(403, #"{"error":{"code":403,"message":"Your API key was reported as leaked. Please use another API key.","status":"PERMISSION_DENIED"}}"#) == .invalidKey)
        #expect(error(400, #"{"error":{"code":400,"message":"Free tier is not available.","status":"FAILED_PRECONDITION"}}"#) == .billing)
        #expect(error(402, "{}") == .billing)
        #expect(error(429, #"{"error":{"code":429,"message":"Quota exceeded.","status":"RESOURCE_EXHAUSTED"}}"#) == .quota)
        #expect(error(503, "") == .unavailable && error(500, "") == .unavailable)
        #expect(error(403, #"{"error":{"code":403,"message":"Requests from this client are blocked.","status":"PERMISSION_DENIED"}}"#) == .service("Requests from this client are blocked."))
        #expect(error(400, #"{"error":{"code":400,"message":"Invalid value at 'generation_config'.","status":"INVALID_ARGUMENT"}}"#) == .service("Invalid value at 'generation_config'."))
        #expect(error(418, "") == .service("HTTP 418."))
    }

    @Test func aBusyServiceIsTriedAgainButABadKeyIsNot() async throws {
        let busy = Wire([(503, ""), (429, ""), (200, answer(#"{"inlineData":{"mimeType":"image/png","data":"\#(picture)"}}"#))])
        #expect(try await provider(busy).generate(request, key: "k") == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(busy.requests.count == 3)
        let down = Wire([(503, ""), (503, ""), (503, ""), (200, "")])
        await #expect(throws: GenerativeError.unavailable) { try await provider(down).generate(request, key: "k") }
        #expect(down.requests.count == 3) // Two more tries, then it gives up.
        let refused = Wire([(400, invalidKey), (200, "")])
        await #expect(throws: GenerativeError.invalidKey) { try await provider(refused).generate(request, key: "k") }
        #expect(refused.requests.count == 1)
        await #expect(throws: GenerativeError.missingKey) { try await provider(Wire([])).generate(request, key: "") }
    }

    @Test func verifyingAKeyListsModelsWithoutGeneratingAnything() async throws {
        let good = Wire([(200, #"{"models":[{"name":"models/gemini-3-flash"},{"name":"models/gemini-3.1-flash-image"}]}"#)])
        try await provider(good).verify(key: "secret")
        let sent = try #require(good.requests.first)
        #expect(sent.url?.path == "/v1beta/models" && sent.httpMethod == "GET" && sent.httpBody == nil)
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "secret" && sent.url?.query?.contains("secret") == false)
        // Accepted, but the project is not offered the image models.
        await #expect(throws: GenerativeError.billing) { try await provider(Wire([(200, #"{"models":[{"name":"models/gemini-3-flash"}]}"#)])).verify(key: "k") }
        await #expect(throws: GenerativeError.invalidKey) { try await provider(Wire([(400, invalidKey)])).verify(key: "k") }
    }

    @Test func aDroppedConnectionIsReportedAndACancelledOneIsNot() async {
        let offline = GeminiProvider(transport: { _ in throw URLError(.notConnectedToInternet) }, backoff: [])
        await #expect(throws: GenerativeError.self) { try await offline.generate(request, key: "k") }
        let cancelled = GeminiProvider(transport: { _ in throw URLError(.cancelled) }, backoff: [])
        await #expect(throws: CancellationError.self) { try await cancelled.generate(request, key: "k") }
    }
}
