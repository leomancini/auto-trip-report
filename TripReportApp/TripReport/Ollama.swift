import Foundation

/// One photo's verdict from the vision model. Field names match analyze.py's
/// cache.json so the two caches are interchangeable.
struct Analysis: Codable, Sendable {
    var score: Int
    var scene_tag: String
    var description: String
    var shot_type: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .score) {
            score = i
        } else {
            score = Int(try c.decode(Double.self, forKey: .score).rounded())
        }
        score = min(10, max(1, score))
        scene_tag = try c.decode(String.self, forKey: .scene_tag)
        description = try c.decode(String.self, forKey: .description)
        shot_type = try c.decode(String.self, forKey: .shot_type)
    }
}

enum OllamaError: LocalizedError {
    case unreachable(URL)
    case missingModel(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let url):
            return "Can't reach Ollama at \(url.absoluteString). Start it with “brew services start ollama” or check the address in Settings."
        case .missingModel(let model):
            return "The model “\(model)” isn't installed. Run “ollama pull \(model)” or choose another model in Settings."
        case .http(let code, let message):
            return "Ollama returned an error (\(code)): \(message)"
        }
    }
}

struct OllamaClient: Sendable {
    var baseURL: URL
    var model: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    static let analysisPrompt = """
    You are curating photos from a multi-day trip for a travel report.
    Analyze this photo and respond with JSON:

    - score: 1-10 photo quality. Judge sharpness, exposure, composition, and how
      interesting/evocative it is. Blurry, badly exposed, dark, or accidental
      shots score 1-3. Competent snapshots 4-6. Great shots 7-8. Standouts 9-10.
    - scene_tag: a kebab-case slug identifying the PLACE or SUBJECT, chosen so
      that any two photos of the same place or subject get the SAME tag. Base it
      ONLY on the most prominent, permanent thing actually visible — the venue,
      room, landmark, artwork, or dish. Do NOT invent creative or specific names,
      do NOT guess a city or business name, and do NOT tag by incidental details,
      passing people, or your interpretation. Prefer broad, stable, reusable tags
      ("antique-store-interior", "lakefront-boardwalk", "art-museum-gallery",
      "mexican-lunch") over unique ones. When two shots show the same room or
      scene from a slightly different angle or step, they MUST share one tag.
    - description: one sentence describing only what is literally visible.
    - shot_type: "primary" if it genuinely works as a large hero image (sharp,
      well-exposed, striking wide scenic view, landmark, or strong composition
      that tells the story of the place); "secondary" if it is a supporting
      detail (food, signs, close-ups, textures, small moments) or is dark,
      cluttered, or unremarkable and better shown small. A dark, blurry, or
      accidental photo is never primary.
    """

    static let sameSubjectPrompt = """
    You are deduplicating photos for a travel report. Answer true ONLY if these \
    two photos clearly show the same specific subject or place — the same \
    landmark, the same storefront, the same room, the same artwork — shot more \
    than once (different angles or times still count). Two different shops, \
    streets, rooms, or meals that merely look similar are NOT the same subject. \
    If you are not certain they are the same, answer false. \
    Respond with JSON: {"same_subject": true or false}
    """

    private static var analysisSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "score": ["type": "integer", "minimum": 1, "maximum": 10],
                "scene_tag": ["type": "string"],
                "description": ["type": "string"],
                "shot_type": ["type": "string", "enum": ["primary", "secondary"]],
            ],
            "required": ["score", "scene_tag", "description", "shot_type"],
        ]
    }

    private static var sameSubjectSchema: [String: Any] {
        [
            "type": "object",
            "properties": ["same_subject": ["type": "boolean"]],
            "required": ["same_subject"],
        ]
    }

    private func chat(prompt: String, images: [String], schema: [String: Any],
                      temperature: Double) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt, "images": images]],
            "format": schema,
            "stream": false,
            "options": ["temperature": temperature],
        ] as [String: Any])
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OllamaError.http(http.statusCode, message ?? String(decoding: data, as: UTF8.self))
        }
        struct Reply: Decodable {
            struct Message: Decodable { var content: String }
            var message: Message
        }
        return Data(try JSONDecoder().decode(Reply.self, from: data).message.content.utf8)
    }

    func analyze(imageBase64: String) async throws -> Analysis {
        let data = try await chat(prompt: Self.analysisPrompt, images: [imageBase64],
                                  schema: Self.analysisSchema, temperature: 0.1)
        return try JSONDecoder().decode(Analysis.self, from: data)
    }

    func sameSubject(_ a: String, _ b: String) async throws -> Bool {
        let data = try await chat(prompt: Self.sameSubjectPrompt, images: [a, b],
                                  schema: Self.sameSubjectSchema, temperature: 0)
        struct Verdict: Decodable { var same_subject: Bool }
        return try JSONDecoder().decode(Verdict.self, from: data).same_subject
    }

    struct TripName: Sendable {
        /// Regular-length title for the guide itself.
        var title: String
        /// Very short version for the sidebar.
        var short: String
    }

    /// Ask the model to name the trip: a regular title and a very short one.
    func tripName(places: [String], countries: [String], dates: String?, scenes: [String],
                  captions: [String]) async throws -> TripName? {
        var facts: [String] = []
        if !places.isEmpty { facts.append("Where the photos were taken, most photos first: " + places.joined(separator: ", ")) }
        if !countries.isEmpty { facts.append("Countries: " + countries.joined(separator: ", ")) }
        if let dates { facts.append("Dates: " + dates) }
        if !scenes.isEmpty { facts.append("Most common subjects in the photos: " + scenes.joined(separator: ", ")) }
        if !captions.isEmpty { facts.append("Some of the best photos:\n- " + captions.joined(separator: "\n- ")) }
        let prompt = """
        Name this trip for a photo album, the way a person would title it. Give two versions:

        - title: 3 to 6 words, title case. Name the main place or region and, if it fits, \
        what the trip was about.
        - short_title: a very short version, 1 to 3 words, title case, for a narrow list.

        The name must be about the place with the most photos; that is where the trip mostly \
        happened. Only mention another place if it has a large share of the photos. Never \
        name the trip after a place with few photos.

        No quotes, no emoji, no year or dates, no words like "Photos", "Album" or "Trip Report". \
        Do not invent places that are not listed.

        \(facts.joined(separator: "\n"))

        Respond with JSON: {"title": "...", "short_title": "..."}
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["title": ["type": "string"], "short_title": ["type": "string"]],
            "required": ["title", "short_title"],
        ]
        let data = try await chat(prompt: prompt, images: [], schema: schema, temperature: 0.3)
        struct Reply: Decodable {
            var title: String
            var short_title: String
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”."))
        let title = reply.title.trimmingCharacters(in: junk)
        let short = reply.short_title.trimmingCharacters(in: junk)
        guard !title.isEmpty, title.count <= 70 else { return nil }
        return TripName(title: title, short: short.isEmpty || short.count > 30 ? title : short)
    }

    /// Names of the models installed in Ollama.
    static func models(baseURL: URL) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        struct Tags: Decodable {
            struct Model: Decodable { var name: String }
            var models: [Model]
        }
        do {
            let (data, _) = try await session.data(for: request)
            return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
        } catch {
            throw OllamaError.unreachable(baseURL)
        }
    }
}
