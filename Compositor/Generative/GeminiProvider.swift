import Foundation

/// Google's Gemini image models over plain HTTPS, with the user's own key.
///
/// `generateContent` is used rather than the newer Interactions API because it is stateless: Interactions
/// keeps requests on Google's side by default, and what is sent here is part of someone's picture.
///
/// What is known about the wire format, and how (2026-09): the request's field names and types were checked
/// against the live service, which validates a body before it looks at the key — `imageConfig` and
/// `inlineData` are accepted, while `responseFormat.image`, which the documentation shows, rejects the plain
/// "1:1" and "1K" values. The service does not check `imageConfig`'s values before the key, and no real key
/// was available, so whether the ratio and size are honoured, and the shape of a successful answer, follow
/// the documentation and are unconfirmed. `GenerativePlan.source(in:)` copes with an answer of another shape.
nonisolated struct GeminiProvider: GenerativeImageProvider {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    var transport: Transport = GeminiProvider.session
    /// Pauses between attempts. Tests pass none.
    var backoff: [Duration] = [.seconds(1), .seconds(3)]

    private static let base = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
    /// A 4K image with the model's thinking can take minutes; URLSession's 60 s default would cut it off.
    private static let timeout: TimeInterval = 180

    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral // No cache or cookies on disk: requests carry image data.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: configuration)
    }()

    private static let session: Transport = { request in
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerativeError.network("The server’s answer was not understood.") }
        return (data, http)
    }

    func generate(_ request: GenerativeRequest, key: String) async throws -> Data {
        guard !key.isEmpty else { throw GenerativeError.missingKey }
        let body = try JSONEncoder().encode(Self.body(for: request))
        var call = URLRequest(url: Self.base.appendingPathComponent("\(request.model.rawValue):generateContent"))
        call.httpMethod = "POST"
        call.httpBody = body
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await send(call, key: key)
        return try Self.image(in: data)
    }

    func verify(key: String) async throws {
        guard !key.isEmpty else { throw GenerativeError.missingKey }
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        let data = try await send(URLRequest(url: components.url!), key: key)
        let listed = (try? JSONDecoder().decode(ModelList.self, from: data))?.models?.map(\.name) ?? []
        // A key the service accepts may still belong to a project the image models are not offered to.
        guard listed.contains(where: { name in GenerativeModel.allCases.contains { name.hasSuffix($0.rawValue) } }) else { throw GenerativeError.billing }
    }

    /// The key travels in a header, never the URL, so it stays out of logs and error messages.
    private func send(_ request: URLRequest, key: String) async throws -> Data {
        var request = request
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = Self.timeout
        var attempt = 0
        while true {
            do {
                let (data, response) = try await perform(request)
                guard (200..<300).contains(response.statusCode) else { throw Self.failure(status: response.statusCode, body: data) }
                return data
            } catch let error as GenerativeError where error.isTransient && attempt < backoff.count {
                try await Task.sleep(for: backoff[attempt])
                attempt += 1
            }
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport(request) }
        catch let error as GenerativeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw GenerativeError.network(error.localizedDescription) }
    }

    // MARK: Wire format

    struct Body: Encodable, Equatable {
        struct Content: Encodable, Equatable { let parts: [Part] }
        struct Part: Encodable, Equatable {
            var text: String?
            var inlineData: Inline?
        }
        struct Inline: Encodable, Equatable { let mimeType: String; let data: String }
        struct Config: Encodable, Equatable {
            let responseModalities: [String]
            let imageConfig: ImageConfig
        }
        struct ImageConfig: Encodable, Equatable { let aspectRatio: String; let imageSize: String }
        let contents: [Content]
        let generationConfig: Config
    }

    /// Words first, then the picture to change, its hint, and any references, in the order the prompt names them.
    static func body(for request: GenerativeRequest) -> Body {
        let pictures = [request.image] + (request.hint.map { [$0] } ?? []) + request.references
        let parts = [Body.Part(text: request.prompt)] + pictures.map {
            Body.Part(inlineData: Body.Inline(mimeType: $0.mimeType, data: $0.data.base64EncodedString()))
        }
        return Body(contents: [Body.Content(parts: parts)],
                    generationConfig: Body.Config(responseModalities: ["TEXT", "IMAGE"],
                        imageConfig: Body.ImageConfig(aspectRatio: request.ratio.label, imageSize: request.size.rawValue)))
    }

    private struct Answer: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable { let parts: [Part]? }
            let content: Content?
            let finishReason: String?
        }
        struct Part: Decodable {
            struct Inline: Decodable { let mimeType: String?; let data: String? }
            let text: String?
            let inlineData: Inline?
            /// Set on the drafts a thinking model shows on its way to the answer.
            let thought: Bool?
        }
        struct Feedback: Decodable { let blockReason: String? }
        let candidates: [Candidate]?
        let promptFeedback: Feedback?
    }
    private struct ModelList: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]?
    }
    private struct Failure: Decodable {
        struct Detail: Decodable { let reason: String? }
        struct Info: Decodable { let message: String?; let status: String?; let details: [Detail]? }
        let error: Info
    }

    /// The finished image in an answer. Thinking models send drafts before it; the last picture that is not
    /// marked as a thought is the answer.
    static func image(in data: Data) throws -> Data {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw GenerativeError.service("Its answer was not understood.") }
        if let block = answer.promptFeedback?.blockReason, answer.candidates?.isEmpty != false { throw GenerativeError.refused(reason(block)) }
        let candidate = answer.candidates?.first
        let parts = candidate?.content?.parts ?? []
        if let encoded = parts.last(where: { $0.thought != true && $0.inlineData?.data != nil })?.inlineData?.data,
           let image = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !image.isEmpty { return image }
        switch candidate?.finishReason {
        case "SAFETY", "IMAGE_SAFETY", "PROHIBITED_CONTENT", "IMAGE_PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_RECITATION":
            throw GenerativeError.refused(reason(candidate?.finishReason ?? ""))
        default:
            // Declining in words is the model's other way of saying no.
            let said = parts.filter { $0.thought != true }.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { throw GenerativeError.refused(String(said.prefix(240))) }
            throw GenerativeError.noImage
        }
    }

    private static func reason(_ code: String) -> String {
        switch code {
        case "SAFETY", "IMAGE_SAFETY": "its safety filter stopped the image."
        case "PROHIBITED_CONTENT", "IMAGE_PROHIBITED_CONTENT", "BLOCKLIST": "the request or the image is not allowed by the service."
        case "RECITATION", "IMAGE_RECITATION": "the image came too close to existing material."
        case "SPII": "it involved personal information."
        default: ""
        }
    }

    static func failure(status: Int, body: Data) -> GenerativeError {
        let info = (try? JSONDecoder().decode(Failure.self, from: body))?.error
        let reasons = Set(info?.details?.compactMap(\.reason) ?? [])
        let message = info?.message ?? ""
        if reasons.contains("API_KEY_INVALID") || message.localizedCaseInsensitiveContains("reported as leaked") { return .invalidKey }
        switch (status, info?.status) {
        case (401, _), (_, "UNAUTHENTICATED"): return .invalidKey
        case (402, _), (_, "FAILED_PRECONDITION"): return .billing // A 403 has several causes; the service's own words say which.
        case (429, _): return .quota
        case (408, _), (500..., _): return .unavailable
        default: return .service(message.isEmpty ? "HTTP \(status)." : String(message.prefix(300)))
        }
    }
}
