import Foundation

enum Storage {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("TripReport", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let projects: URL = {
        let url = root.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func projectDir(_ id: UUID) -> URL {
        projects.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

enum Prefs {
    static let urlKey = "ollamaURL"
    static let modelKey = "ollamaModel"
    static let minScoreKey = "minScore"
    static let defaultURL = "http://localhost:11434"
    static let defaultModel = "qwen2.5vl:7b"

    static var ollamaURL: URL {
        let raw = UserDefaults.standard.string(forKey: urlKey) ?? ""
        return URL(string: raw.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(string: defaultURL)!
    }

    static var model: String {
        let raw = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return raw.isEmpty ? defaultModel : raw
    }

    static var minScore: Int {
        let value = UserDefaults.standard.integer(forKey: minScoreKey)
        return value == 0 ? 5 : value
    }
}

/// A small JSON-file-backed dictionary shared across projects.
actor JSONStore<Value: Codable & Sendable> {
    private let file: URL
    private var entries: [String: Value]
    private var dirty = 0

    init(file: URL) {
        self.file = file
        entries = (try? JSONDecoder().decode([String: Value].self, from: Data(contentsOf: file))) ?? [:]
    }

    func get(_ key: String) -> Value? { entries[key] }

    func set(_ key: String, _ value: Value) {
        entries[key] = value
        dirty += 1
        if dirty >= 10 { flush() }
    }

    /// Merge entries from another file in the same format; returns how many were new.
    func merge(from url: URL) -> Int {
        guard let other = try? JSONDecoder().decode([String: Value].self, from: Data(contentsOf: url))
        else { return 0 }
        var added = 0
        for (key, value) in other where entries[key] == nil {
            entries[key] = value
            added += 1
        }
        if added > 0 { dirty += 1; flush() }
        return added
    }

    func flush() {
        guard dirty > 0 else { return }
        dirty = 0
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

enum Caches {
    /// Per-photo model results, keyed by content key (analyze.py's cache.json format).
    static let analysis = JSONStore<Analysis>(file: Storage.root.appendingPathComponent("cache.json"))
    /// "Same subject?" verdicts for photo pairs, keyed "idA|idB".
    static let pairs = JSONStore<Bool>(file: Storage.root.appendingPathComponent("pairs.json"))
    static let geo = JSONStore<GeoInfo>(file: Storage.root.appendingPathComponent("geo.json"))
    static let weather = JSONStore<HourlyWeather>(file: Storage.root.appendingPathComponent("weather.json"))
}

actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { self.permits = permits }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
