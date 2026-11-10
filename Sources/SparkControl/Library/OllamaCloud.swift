import AmpText
import Foundation

/// A chat message for Ollama's `/api/chat`.
public struct OllamaChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// A minimal client for Ollama's cloud API (https://ollama.com), used only to turn a description into a sound recipe.
/// The app makes this request when the user asks for an AI Sound, and nothing else.
///
/// What leaves the Mac: the model name, the chat messages (rules, catalog, the user's wish and, for a follow-up, the
/// recipe being adjusted) and the temperature. The API key goes only into the Authorization header. The user agent is
/// a fixed name, so the request does not carry the app's or the system's build numbers.
public enum OllamaCloud {
    public static let endpoint = URL(string: "https://ollama.com/api/chat")!
    public static let userAgent = "AmpBench"
    /// How long one request may take before it counts as failed. Without streaming the cloud sends nothing until the
    /// answer is complete, so this is the time for the whole answer.
    public static let requestTimeout: TimeInterval = 120

    /// Sends a request and returns the body and the response. Injected so tests run without a network.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let urlSession: Transport = { request in try await URLSession.shared.data(for: request) }

    /// How often a request is repeated after a network problem or an overloaded server, and how long it waits first.
    public struct Retry: Sendable {
        /// Seconds to wait before each repeat; its count is the number of repeats.
        public var delays: [Double]

        public init(delays: [Double]) { self.delays = delays }

        public static let standard = Retry(delays: [1.5, 4])
        public static let none = Retry(delays: [])
    }

    public enum Error: LocalizedError, Equatable {
        case missingAPIKey
        case unauthorized
        case modelNotFound(String)
        case rateLimited
        case http(Int, String)
        case noContent
        case unreadableResponse
        case timeout
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return tr("No Ollama API key. Get one at ollama.com/settings/keys and enter it.")
            case .unauthorized:
                return tr("Ollama refused the API key. Check it at ollama.com/settings/keys and enter it again (Advanced → Remove key).")
            case .modelNotFound(let model):
                return tr("Ollama Cloud has no model “%@”. Choose another one under “Advanced”.", model)
            case .rateLimited:
                return tr("Ollama is busy right now or your quota is used up. Wait a moment and try again.")
            case .http(let status, let detail):
                let body = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? tr("Ollama answered with status %d.", status)
                                    : tr("Ollama answered with status %d: %@", status, body)
            case .noContent:
                return tr("Ollama answered without content. Try again.")
            case .unreadableResponse:
                return tr("The answer from Ollama could not be read. Try again.")
            case .timeout:
                return tr("Ollama did not answer in time (time limit %d s). Try again or choose a faster model under “Advanced”.", Int(OllamaCloud.requestTimeout))
            case .transport(let message):
                return tr("No connection to Ollama: %@", message)
            }
        }

        /// Worth repeating by itself: the network dropped or the server is busy. A wrong key or model is not.
        public var isTransient: Bool {
            switch self {
            case .transport, .rateLimited: true
            case .http(let status, _): status >= 500
            default: false
            }
        }
    }

    private struct Request: Codable {
        var model: String
        var messages: [OllamaChatMessage]
        var stream: Bool
        var format: String
        var options: Options
        struct Options: Codable { var temperature: Double }
    }

    private struct Response: Codable {
        var message: Message
        struct Message: Codable { var content: String }
    }

    private struct ErrorResponse: Codable { var error: String? }

    /// The models the cloud offers right now (public list, no key needed).
    public static func availableModels(transport: Transport = urlSession) async throws -> [String] {
        struct Tags: Codable { var models: [Model]; struct Model: Codable { var name: String } }
        var request = URLRequest(url: URL(string: "https://ollama.com/api/tags")!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, _) = try await transport(request)
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name).sorted()
    }

    /// The HTTP request for one chat answer.
    static func makeRequest(model: String, apiKey: String, messages: [OllamaChatMessage],
                            temperature: Double) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Error.missingAPIKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: messages, stream: false,
                                                           format: "json",
                                                           options: .init(temperature: temperature)))
        return request
    }

    /// Sends one chat request and returns the assistant's text. Network problems and a busy server are repeated as
    /// `retry` says; cancelling the task stops at once with `CancellationError`.
    public static func complete(model: String, apiKey: String, messages: [OllamaChatMessage],
                                temperature: Double = 0.4, transport: Transport = urlSession,
                                retry: Retry = .standard) async throws -> String {
        let request = try makeRequest(model: model, apiKey: apiKey, messages: messages, temperature: temperature)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await send(request, model: model, transport: transport)
            } catch let error as Error where error.isTransient && attempt < retry.delays.count {
                let delay = retry.delays[attempt]
                attempt += 1
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
        }
    }

    private static func send(_ request: URLRequest, model: String, transport: Transport) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw Error.timeout
            default: throw Error.transport(error.localizedDescription)
            }
        } catch {
            throw Error.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Error.unreadableResponse }
        guard http.statusCode == 200 else {
            let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let detail = String((errorBody?.error ?? String(data: data, encoding: .utf8) ?? "").prefix(200))
            switch http.statusCode {
            case 401, 403: throw Error.unauthorized
            case 404: throw Error.modelNotFound(model)
            case 429: throw Error.rateLimited
            default: throw Error.http(http.statusCode, detail)
            }
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw Error.unreadableResponse }
        guard !decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.noContent
        }
        return decoded.message.content
    }
}
