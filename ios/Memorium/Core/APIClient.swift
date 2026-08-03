import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case unauthorized
    case offline
    case server(status: Int, detail: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No server configured yet."
        case .unauthorized:
            "The server rejected the token. Check it in Settings."
        case .offline:
            "Can't reach the server."
        case let .server(status, detail):
            detail.isEmpty ? "Server error (\(status))." : detail
        case let .decoding(detail):
            "Unexpected response: \(detail)"
        }
    }

    /// Offline is normal on a train; it should queue work, not show an error.
    var isTransient: Bool {
        if case .offline = self { return true }
        if case let .server(status, _) = self { return status >= 500 }
        return false
    }
}

struct APIClient: Sendable {
    let baseURL: URL
    let token: String

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DateCoding.formatter.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = DateCoding.parse(raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(raw)")
                )
            }
            return date
        }
        return decoder
    }()

    private func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        guard !token.isEmpty else { throw APIError.notConfigured }

        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 401, 403:
            throw APIError.unauthorized
        default:
            let detail =
                (try? Self.decoder.decode([String: String].self, from: data))?["detail"]
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw APIError.server(status: http.statusCode, detail: String(detail.prefix(300)))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error).prefix(200).description)
        }
    }

    // MARK: - Health & profile

    func health() async throws -> HealthStatus {
        try decode(HealthStatus.self, from: await request("GET", "health"))
    }

    func profile() async throws -> Profile {
        try decode(Profile.self, from: await request("GET", "profile"))
    }

    @discardableResult
    func updateProfile(_ update: ProfileUpdate) async throws -> Profile {
        let body = try Self.encoder.encode(update)
        return try decode(Profile.self, from: await request("PATCH", "profile", body: body))
    }

    // MARK: - Deck

    func words(search: String? = nil) async throws -> [Word] {
        var query: [URLQueryItem] = []
        if let search, !search.isEmpty { query.append(.init(name: "q", value: search)) }
        return try decode([Word].self, from: await request("GET", "words", query: query))
    }

    func addWord(_ word: WordCreate) async throws -> Word {
        let body = try Self.encoder.encode(word)
        return try decode(Word.self, from: await request("POST", "words", body: body))
    }

    func addWords(_ words: [WordCreate]) async throws -> WordBatchResult {
        let body = try Self.encoder.encode(WordBatchCreate(words: words))
        return try decode(WordBatchResult.self, from: await request("POST", "words/batch", body: body))
    }

    func deleteWord(id: String) async throws {
        _ = try await request("DELETE", "words/\(id)")
    }

    func mnemonic(wordId: String) async throws -> String {
        let data = try await request("POST", "words/\(wordId)/mnemonic")
        return try decode([String: String].self, from: data)["mnemonic"] ?? ""
    }

    // MARK: - Study

    func queue() async throws -> StudyQueue {
        try decode(StudyQueue.self, from: await request("GET", "study/queue"))
    }

    func submit(grades: [GradeIn]) async throws -> [GradeResult] {
        struct Batch: Encodable { let grades: [GradeIn] }
        let body = try Self.encoder.encode(Batch(grades: grades))
        let data = try await request("POST", "study/grade", body: body)
        return try decode(GradeBatchResult.self, from: data).results
    }

    func leeches() async throws -> [StudyCard] {
        try decode([StudyCard].self, from: await request("GET", "leeches"))
    }

    // MARK: - Content

    func gradeAnswer(prompt: String, expected: String, given: String) async throws
        -> GradeAnswerResponse
    {
        let body = try Self.encoder.encode(
            GradeAnswerRequest(prompt: prompt, expected: expected, given: given)
        )
        return try decode(GradeAnswerResponse.self, from: await request("POST", "grade", body: body))
    }

    func enrichmentStatus() async throws -> EnrichStatus {
        try decode(EnrichStatus.self, from: await request("GET", "enrich/status"))
    }

    func enrichAllPending() async throws {
        struct Body: Encodable { let allPending = true }
        _ = try await request("POST", "enrich", body: try Self.encoder.encode(Body()))
    }

    func story() async throws -> StoryResponse {
        try decode(StoryResponse.self, from: await request("GET", "story"))
    }
}

/// The server emits ISO-8601 with microsecond precision; the stock
/// `.iso8601` strategy rejects fractional seconds outright.
enum DateCoding {
    // `nonisolated(unsafe)` is sound here: both formatters are fully
    // configured at initialisation and never mutated afterwards, and
    // ISO8601DateFormatter's parsing is documented as thread-safe.
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        formatter.date(from: raw) ?? plain.date(from: raw)
    }
}
