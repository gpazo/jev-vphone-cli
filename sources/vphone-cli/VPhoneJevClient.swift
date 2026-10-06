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

    func replacingInstructions(_ instructions: String) -> JevQuestion {
        JevQuestion(type: type, instructions: instructions, options: options, levels: levels)
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

    /// Check a Choice answer against the options that were actually offered.
    ///
    /// Typed output guarantees the shape of the interface, not that the
    /// contents make sense. Acting on a malformed distribution — one that
    /// names an option nobody offered, or whose mass does not sum to one —
    /// means acting on something that is not a judgment at all, so the caller
    /// is told rather than left to act on it.
    func validated(against offered: some Collection<String>) -> ValidationFailure? {
        guard type == "choice", let confidence, confidence.isFinite, (0...1).contains(confidence) else { return .invalidConfidence }
        guard let choice else { return .missingChoice }
        guard offered.contains(choice) else { return .unofferedOption(choice) }
        guard let probabilities else { return .missingProbabilities }
        guard Set(probabilities.keys) == Set(offered) else { return .mismatchedOptions }

        let values = probabilities.values
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            return .probabilityOutOfRange
        }
        guard abs(values.reduce(0, +) - 1) < 0.02 else { return .probabilitiesDoNotSum }
        guard let top = values.max(), (probabilities[choice] ?? 0) >= top - 1e-6 else {
            return .choiceIsNotArgmax
        }
        return nil
    }

    enum ValidationFailure: CustomStringConvertible {
        case invalidConfidence
        case missingChoice
        case unofferedOption(String)
        case missingProbabilities
        case mismatchedOptions
        case probabilityOutOfRange
        case probabilitiesDoNotSum
        case choiceIsNotArgmax

        var description: String {
            switch self {
            case .invalidConfidence: "invalid choice type or confidence"
            case .missingChoice: "answer carried no choice"
            case let .unofferedOption(option): "chose \"\(option)\", which was not offered"
            case .missingProbabilities: "answer carried no probabilities"
            case .mismatchedOptions: "probabilities do not cover exactly the offered options"
            case .probabilityOutOfRange: "a probability was not a finite value in 0...1"
            case .probabilitiesDoNotSum: "probabilities do not sum to 1"
            case .choiceIsNotArgmax: "the chosen option is not the most probable one"
            }
        }
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

/// System One client. Provider selection changes transport, not controller policy.
struct VPhoneJevClient: Sendable {
    static let defaultModel = "jev-latest"
    static let apiKeyEnvVar = "TYPESAFE_API_KEY"

    enum Provider: String, CaseIterable, Sendable {
        case typesafe, cloudflare
    }

    let provider: Provider
    let model: String
    let endpoint: URL
    let cloudflareAccountID: String?
    private let apiKey: String
    private let session: URLSession

    var displayName: String { "\(provider.rawValue) (\(model))" }

    enum ClientError: Error, CustomStringConvertible {
        case configuration(String)
        case http(status: Int, body: String)
        case malformedResponse(String)
        case rejected(String)

        var description: String {
            switch self {
            case let .configuration(detail): detail
            case let .http(status, body):
                "Decision API returned HTTP \(status): \(body)"
            case let .malformedResponse(detail):
                "Could not decode decision response: \(detail)"
            case let .rejected(detail): "Decision API rejected the request: \(detail)"
            }
        }
    }

    /// Reads the key from the environment when one is not supplied.
    init(apiKey: String? = nil, model: String? = nil, provider: Provider = .typesafe,
         accountID: String? = nil, timeout: TimeInterval = 30,
         environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.provider = provider
        self.model = model ?? (provider == .typesafe ? Self.defaultModel : "clef")
        let resolved: String?
        switch provider {
        case .typesafe:
            cloudflareAccountID = nil
            endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
            resolved = apiKey ?? environment[Self.apiKeyEnvVar]
        case .cloudflare:
            guard ["clef", "clef-flash"].contains(self.model) else {
                throw ClientError.configuration("Cloudflare --model must be clef or clef-flash.")
            }
            guard let account = accountID ?? environment["CLOUDFLARE_ACCOUNT_ID"],
                  account.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else {
                throw ClientError.configuration("Set CLOUDFLARE_ACCOUNT_ID or --cloudflare-account-id to your 32-character account ID.")
            }
            endpoint = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/run/@cf/cloudflare/\(self.model)")!
            cloudflareAccountID = account
            // Never fall back to the TypeSafe key on a different provider.
            resolved = apiKey ?? environment["CLOUDFLARE_API_TOKEN"] ?? environment["CLOUDFLARE_AUTH_TOKEN"]
        }
        guard let resolved, !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let variable = provider == .typesafe ? Self.apiKeyEnvVar : "CLOUDFLARE_API_TOKEN"
            throw ClientError.configuration("Set \(variable) or --api-key for \(provider.rawValue).")
        }
        self.apiKey = resolved

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config)
    }

    /// Establish the provider connection without submitting an inference request.
    func prepareConnection() async {
        // Establish DNS/TLS without submitting a goal or inference request.
        // HEAD may return 405; only transport readiness matters here.
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        _ = try? await session.data(for: request)
    }

    func ask(state: some Encodable, questions: [String: JevQuestion]) async throws -> JevResponse {
        let request = try makeRequest(state: state, questions: questions)

        // Optional exact replay evidence. Persist payloads only, never headers
        // or the API key. Tests enable this explicitly in their artifact folder.
        let trace = ProcessInfo.processInfo.environment["JEV_TRACE_DIR"].map { URL(fileURLWithPath: $0) }
        let traceID = UUID().uuidString
        if let trace {
            try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: true)
            try request.httpBody?.write(to: trace.appendingPathComponent(traceID + "-request.json"))
        }

        let (data, response) = try await session.data(for: request)
        if let trace { try data.write(to: trace.appendingPathComponent(traceID + "-response.json")) }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformedResponse("Missing HTTP response")
        }
        return try decodeResponse(data, status: http.statusCode)
    }

    func makeRequest(state: some Encodable, questions: [String: JevQuestion]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: model, state: state, questions: questions))
        return request
    }

    func decodeResponse(_ data: Data, status: Int) throws -> JevResponse {
        if !(200 ..< 300).contains(status) {
            throw ClientError.http(
                status: status,
                body: (String(data: data.prefix(4096), encoding: .utf8) ?? "<non-UTF8 body>")
                    .replacingOccurrences(of: apiKey, with: "<redacted>")
            )
        }

        do {
            if provider == .cloudflare {
                let envelope = try JSONDecoder().decode(CloudflareResponse.self, from: data)
                guard envelope.success, envelope.errors.isEmpty else {
                    throw ClientError.rejected(envelope.errors.map { "\($0.code): \($0.message)" }
                        .joined(separator: "; ").replacingOccurrences(of: apiKey, with: "<redacted>"))
                }
                guard let result = envelope.result else { throw ClientError.malformedResponse("Missing Cloudflare result") }
                return result
            }
            return try JSONDecoder().decode(JevResponse.self, from: data)
        } catch let error as ClientError {
            throw error
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

    private struct CloudflareResponse: Decodable {
        struct APIError: Decodable {
            let code: Int
            let message: String
        }
        let success: Bool
        let errors: [APIError]
        let result: JevResponse?
    }
}
