import Foundation

// MARK: - Questions

/// One System One question. Jev answers every question in a request in
/// parallel; questions cannot see each other's answers.
struct JevQuestion: Encodable {
    enum Kind: String, Encodable {
        case choice, noul, score
    }

    let type: Kind
    let instructions: String

    /// Choice criteria: option name → description (nil sends `null`).
    private let options: [String: String?]?
    /// Score criteria: ordered level descriptions, lowest first.
    private let levels: [String]?

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(instructions, forKey: .instructions)
        if let options {
            try c.encode(options, forKey: .criteria)
        } else if let levels {
            try c.encode(levels, forKey: .criteria)
        }
    }

    // MARK: Constructors

    /// Pick exactly one of `options`. Include a no-match option when nothing
    /// may fit — the model cannot choose a value that was not offered.
    static func choice(_ instructions: String, _ options: [String: String?]) -> JevQuestion {
        JevQuestion(type: .choice, instructions: instructions, options: options, levels: nil)
    }

    /// Probability that a condition holds. Nouls carry no confidence — the
    /// probability *is* the answer.
    static func noul(_ instructions: String) -> JevQuestion {
        JevQuestion(type: .noul, instructions: instructions, options: nil, levels: nil)
    }

    /// Position along an ordered dimension. Levels must describe concrete
    /// situations and stand on their own.
    static func score(_ instructions: String, _ levels: [String]) -> JevQuestion {
        JevQuestion(type: .score, instructions: instructions, options: nil, levels: levels)
    }
}

// MARK: - Answers

/// One answer. Fields are populated according to the question type: `noul`
/// for nouls, `choice`/`probabilities`/`confidence` for choices, and
/// `score`/`legend`/`probabilities`/`confidence` for scores.
struct JevAnswer: Decodable {
    let type: String
    let noul: Double?
    let choice: String?
    let score: Double?
    let probabilities: [String: Double]?
    let confidence: Double?

    /// Confidence, or 0 when the answer type does not carry one.
    var confidenceOrZero: Double { confidence ?? 0 }

    /// Probability assigned to the winning option, independent of `confidence`
    /// (which describes the shape of the whole distribution).
    var topProbability: Double {
        guard let choice, let probabilities else { return 0 }
        return probabilities[choice] ?? 0
    }
}

struct JevUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int

    // Spelled out rather than using `.convertFromSnakeCase`: that strategy
    // also rewrites dictionary keys, which would mangle question ids and
    // option names containing underscores (`text_span`, `swipe_up`).
    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct JevResponse: Decodable {
    let model: String
    let answers: [String: JevAnswer]
    let usage: JevUsage?

    subscript(id: String) -> JevAnswer? { answers[id] }
}

// MARK: - Client

/// Minimal client for the TypeSafe System One endpoint.
///
/// There is no official Swift SDK, so this speaks the documented HTTP
/// contract directly: `POST /v1/systemone` with a bearer token, a `state`
/// payload, and a map of questions answered in one round trip.
struct VPhoneJevClient: Sendable {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let defaultModel = "jev-latest"
    static let apiKeyEnvVar = "TYPESAFE_API_KEY"

    let apiKey: String
    let model: String
    private let session: URLSession

    enum ClientError: Error, CustomStringConvertible {
        case missingAPIKey
        case http(status: Int, body: String)
        case malformedResponse(String)

        var description: String {
            switch self {
            case .missingAPIKey:
                """
                No TypeSafe API key. Set \(VPhoneJevClient.apiKeyEnvVar) in the environment, \
                or pass --api-key. Keys come from https://console.typesafe.ai/
                """
            case let .http(status, body):
                "TypeSafe API returned HTTP \(status): \(body)"
            case let .malformedResponse(detail):
                "Could not decode TypeSafe response: \(detail)"
            }
        }
    }

    /// Reads the key from the environment when one is not supplied.
    init(apiKey: String? = nil, model: String = defaultModel, timeout: TimeInterval = 30) throws {
        let resolved = apiKey ?? ProcessInfo.processInfo.environment[Self.apiKeyEnvVar]
        guard let resolved, !resolved.isEmpty else { throw ClientError.missingAPIKey }

        self.apiKey = resolved
        self.model = model

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config)
    }

    /// Ask a batch of questions about one state. All questions run in
    /// parallel, so speculative questions whose answers may go unused cost a
    /// round trip only in tokens, not latency.
    func ask(state: some Encodable, questions: [String: JevQuestion]) async throws -> JevResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: model, state: state, questions: questions))

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw ClientError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            )
        }

        do {
            return try JSONDecoder().decode(JevResponse.self, from: data)
        } catch {
            throw ClientError.malformedResponse("\(error)")
        }
    }

    // MARK: Wire

    private struct Request<S: Encodable>: Encodable {
        let model: String
        let state: S
        let questions: [String: JevQuestion]
    }
}
