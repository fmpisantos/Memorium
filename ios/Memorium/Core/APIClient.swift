import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case unauthorized
    /// Signed in, verified, and still not allowed: the address is not on the
    /// server's list. Signing in again cannot fix it, so it is kept separate
    /// from `unauthorized` and carries the server's own wording.
    case notAllowed(String)
    case offline
    case server(status: Int, detail: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No server configured yet."
        case .unauthorized:
            "Your Google session has expired. Sign in again in Settings."
        case let .notAllowed(detail):
            detail.isEmpty
                ? "This Google account isn't allowed to use that server."
                : detail
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

    /// Asked for on every request rather than captured once: a Google ID token
    /// is good for an hour, and `AuthService` renews it underneath us.
    /// Returning "" sends the request unauthenticated, which is what /health
    /// wants during setup.
    let token: @Sendable () async throws -> String

    init(baseURL: URL, token: @escaping @Sendable () async throws -> String) {
        self.baseURL = baseURL
        self.token = token
    }

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

    /// Enough for a deck request that only reads the database.
    private static let quickTimeout: TimeInterval = 30

    /// Enough for anything that waits on Claude.
    ///
    /// These calls are not slow in the way a big download is slow: the server
    /// spawns a CLI subprocess per generation, and a batch of sentences takes
    /// well over a minute of it. Thirty seconds is not a cautious limit for
    /// them, it is one that can never be met -- and giving up early is worse
    /// than waiting, because the server treats the dropped connection as a
    /// cancelled request and throws away the work it had already done. Set
    /// above the server's own ceiling (`MEMORIUM_CLAUDE_TIMEOUT_SECONDS`,
    /// 180s) so the server is always the one that decides to stop.
    private static let generationTimeout: TimeInterval = 240

    /// A session of our own rather than `URLSession.shared`, whose
    /// configuration caps a request at 60 seconds regardless of what the
    /// request itself asks for. The ceiling here is the longest any single
    /// call is allowed to take; each request still sets its own, shorter,
    /// `timeoutInterval` underneath it.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = generationTimeout
        configuration.timeoutIntervalForResource = generationTimeout
        return URLSession(configuration: configuration)
    }()

    private func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval = quickTimeout
    ) async throws -> Data {
        let bearer = try await token()

        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        let detail = {
            (try? Self.decoder.decode([String: String].self, from: data))?["detail"]
                ?? String(data: data, encoding: .utf8)
                ?? ""
        }
        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.notAllowed(String(detail().prefix(300)))
        default:
            throw APIError.server(status: http.statusCode, detail: String(detail().prefix(300)))
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

    /// Whether this server accepts the signed-in account. Throws
    /// `.notAllowed` naming the address when it doesn't.
    func me() async throws -> String {
        try decode(MeResponse.self, from: await request("GET", "me")).email
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

    @discardableResult
    func updateWord(id: String, _ update: WordUpdate) async throws -> Word {
        let body = try Self.encoder.encode(update)
        return try decode(Word.self, from: await request("PATCH", "words/\(id)", body: body))
    }

    func deleteWord(id: String) async throws {
        _ = try await request("DELETE", "words/\(id)")
    }

    func mnemonic(wordId: String) async throws -> String {
        let data = try await request(
            "POST", "words/\(wordId)/mnemonic", timeout: Self.generationTimeout
        )
        return try decode([String: String].self, from: data)["mnemonic"] ?? ""
    }

    // MARK: - Study

    /// The day's queue, or -- with `extra` -- another round on top of it, which
    /// the server is always willing to hand out.
    func queue(extra: Bool = false) async throws -> StudyQueue {
        let query = extra ? [URLQueryItem(name: "extra", value: "true")] : []
        return try decode(StudyQueue.self, from: await request("GET", "study/queue", query: query))
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

    func gradeAnswer(
        prompt: String, expected: String, given: String, kind: GradeKind = .word
    ) async throws -> GradeAnswerResponse {
        let body = try Self.encoder.encode(
            GradeAnswerRequest(prompt: prompt, expected: expected, given: given, kind: kind)
        )
        return try decode(
            GradeAnswerResponse.self,
            from: await request("POST", "grade", body: body, timeout: Self.generationTimeout)
        )
    }

    // MARK: - Phrase practice

    /// A session's worth of sentences built from words already in the deck.
    ///
    /// Served from a pool the server writes in the background, so this is an
    /// ordinary request rather than a wait on Claude. Sentences you have not
    /// answered yet come back first; one you answered correctly does not come
    /// back at all. `refresh` asks for material never served before.
    func phrases(count: Int = 10, refresh: Bool = false) async throws -> PhraseSet {
        var query = [URLQueryItem(name: "count", value: String(count))]
        if refresh { query.append(URLQueryItem(name: "refresh", value: "true")) }
        return try decode(
            PhraseSet.self,
            from: await request(
                "GET", "practice/phrases", query: query, timeout: Self.generationTimeout
            )
        )
    }

    /// Report how a set of phrases went.
    ///
    /// This is what takes a sentence out of the rotation: the server keeps
    /// serving one until it has been answered correctly. Safe to replay, so
    /// the caller can queue results on the device and flush them late.
    func submit(phraseResults: [PhraseResultIn]) async throws -> [PhraseResultOut] {
        guard !phraseResults.isEmpty else { return [] }
        struct Batch: Encodable { let results: [PhraseResultIn] }
        let body = try Self.encoder.encode(Batch(results: phraseResults))
        let data = try await request("POST", "practice/phrases/results", body: body)
        return try decode(PhraseResultBatchResult.self, from: data).results
    }

    /// Fills the other half of a word being added. Returns the translation
    /// alone -- an empty one is a server error, not a result.
    func translate(_ text: String, into: TranslationDirection) async throws -> String {
        let body = try Self.encoder.encode(TranslateRequest(text: text, into: into))
        let data = try await request(
            "POST", "translate", body: body, timeout: Self.generationTimeout
        )
        return try decode(TranslateResponse.self, from: data).translation
    }

    /// Fills many halves at once, for a screenshot import.
    ///
    /// Duolingo prints a translation under only about half the words it lists,
    /// so an import arrives with dozens of blanks. One request each would be
    /// dozens of round trips before the deck appears; this is one.
    ///
    /// The result is positional -- one entry per word sent, nil where the server
    /// had no answer -- so the caller can zip it straight back onto its words.
    func translateBatch(_ texts: [String], into: TranslationDirection) async throws -> [String?] {
        guard !texts.isEmpty else { return [] }
        let body = try Self.encoder.encode(TranslateBatchRequest(texts: texts, into: into))
        let data = try await request(
            "POST", "translate/batch", body: body, timeout: Self.generationTimeout
        )
        let response = try decode(TranslateBatchResponse.self, from: data)
        // Position is the only thing tying a translation to its word, so a
        // list of the wrong length is unusable rather than partly usable.
        guard response.translations.count == texts.count else {
            throw APIError.decoding(
                "The server sent \(response.translations.count) translations for \(texts.count) words."
            )
        }
        return response.translations
    }

    func enrichmentStatus() async throws -> EnrichStatus {
        try decode(EnrichStatus.self, from: await request("GET", "enrich/status"))
    }

    /// Re-runs the words whose generation failed, and nothing else.
    ///
    /// Returns the queue as it stands afterwards, so the caller can show the
    /// retry taking effect without a second round trip.
    @discardableResult
    func retryFailedEnrichments() async throws -> EnrichStatus {
        struct Body: Encodable { let allFailed = true }
        let data = try await request("POST", "enrich", body: try Self.encoder.encode(Body()))
        return try decode(EnrichStatus.self, from: data)
    }

    func story() async throws -> StoryResponse {
        try decode(
            StoryResponse.self,
            from: await request("GET", "story", timeout: Self.generationTimeout)
        )
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
