import Foundation

enum PipelineError: LocalizedError {
    case noPhotos
    case modelFailing(String)

    var errorDescription: String? {
        switch self {
        case .noPhotos:
            return "No photos were found in this project's folders. They may have been moved or the drive may be offline."
        case .modelFailing(let message):
            return "The vision model keeps failing: \(message)"
        }
    }
}

/// The whole analyze → select → enrich run for one project.
enum Pipeline {
    struct Config: Sendable {
        var baseURL: URL
        var model: String
        var minScore: Int
    }

    struct Update: Sendable {
        var phase: String
        var detail = ""
        var done = 0
        var total = 0
    }

    static func run(project: Project, config: Config, dir: URL,
                    progress: @escaping @Sendable (Update) -> Void) async throws -> Project {
        var project = project

        // --- 1. find files ---
        progress(Update(phase: "Scanning folders"))
        let urls = PhotoLoader.findPhotos(in: project.folders.map { URL(fileURLWithPath: $0) })
        guard !urls.isEmpty else { throw PipelineError.noPhotos }

        // pick up results from the Python script if its cache.json sits above the photos
        for folder in project.folders {
            var dir = URL(fileURLWithPath: folder)
            for _ in 0..<4 {
                dir = dir.deletingLastPathComponent()
                let candidate = dir.appendingPathComponent("cache.json")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    _ = await Caches.analysis.merge(from: candidate)
                }
            }
        }

        // --- 2. read metadata + perceptual hashes (parallel) ---
        let existing = Dictionary(project.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var slots = [Photo?](repeating: nil, count: urls.count)
        try await withThrowingTaskGroup(of: (Int, Photo?).self) { group in
            var next = 0
            var done = 0
            let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
            while next < min(workers, urls.count) {
                let i = next
                next += 1
                group.addTask { (i, loadOne(urls[i], existing: existing)) }
            }
            while let (i, photo) = try await group.next() {
                try Task.checkCancellation()
                slots[i] = photo
                done += 1
                if done % 5 == 0 || done == urls.count {
                    progress(Update(phase: "Reading photos", detail: urls[i].lastPathComponent,
                                    done: done, total: urls.count))
                }
                if next < urls.count {
                    let j = next
                    next += 1
                    group.addTask { (j, loadOne(urls[j], existing: existing)) }
                }
            }
        }
        var seen = Set<String>()
        var photos = slots.compactMap { $0 }.filter { seen.insert($0.id).inserted }
        guard !photos.isEmpty else { throw PipelineError.noPhotos }

        // --- 3. score with the vision model (cached per photo) ---
        var pending: [Int] = []
        for i in photos.indices {
            if let cached = await Caches.analysis.get(photos[i].id) {
                apply(cached, to: &photos[i])
            } else {
                pending.append(i)
            }
        }
        let client = OllamaClient(baseURL: config.baseURL, model: config.model)
        if !pending.isEmpty {
            progress(Update(phase: "Connecting to Ollama"))
            let installed = try await OllamaClient.models(baseURL: config.baseURL)
            if !installed.contains(config.model) && !installed.contains(config.model + ":latest") {
                throw OllamaError.missingModel(config.model)
            }
            var failures = 0
            for (n, i) in pending.enumerated() {
                try Task.checkCancellation()
                progress(Update(phase: "Scoring photos with \(config.model)", detail: photos[i].name,
                                done: n, total: pending.count))
                guard let image = PhotoLoader.modelImage(photos[i].url) else { continue }
                do {
                    let analysis = try await client.analyze(imageBase64: image)
                    await Caches.analysis.set(photos[i].id, analysis)
                    apply(analysis, to: &photos[i])
                    failures = 0
                } catch {
                    try Task.checkCancellation()
                    failures += 1
                    if failures >= 3 {
                        await Caches.analysis.flush()
                        throw PipelineError.modelFailing(error.localizedDescription)
                    }
                }
            }
            await Caches.analysis.flush()
        }

        // --- 4. de-duplicate and select ---
        progress(Update(phase: "Choosing the best photos"))
        var encoded: [String: String] = [:]
        var checks = 0
        var considered = (done: 0, total: 0)
        var comparing = ""
        try await SelectionEngine.select(&photos, minScore: config.minScore, progress: { done, total in
            considered = (done, total)
            progress(Update(phase: "Choosing the best photos", detail: comparing, done: done, total: total))
        }) { a, b in
            let key = [a.id, b.id].sorted().joined(separator: "|")
            if let cached = await Caches.pairs.get(key) { return cached }
            checks += 1
            comparing = "Comparing \(a.name) with \(b.name) · \(checks) look-alike pairs checked"
            progress(Update(phase: "Choosing the best photos", detail: comparing,
                            done: considered.done, total: considered.total))
            for p in [a, b] where encoded[p.id] == nil {
                encoded[p.id] = PhotoLoader.modelImage(p.url)
            }
            guard let ia = encoded[a.id], let ib = encoded[b.id],
                  let same = try? await client.sameSubject(ia, ib) else { return nil }
            await Caches.pairs.set(key, same)
            return same
        }
        await Caches.pairs.flush()
        try Task.checkCancellation()

        // --- 5. places, timezones, weather ---
        photos = await Enricher.enrich(photos) { progress(Update(phase: $0)) }
        try Task.checkCancellation()

        // --- 6. guide thumbnails ---
        let guide = photos.filter(\.inGuide)
        var made = 0
        await withTaskGroup(of: Void.self) { group in
            var iterator = guide.makeIterator()
            func job(_ p: Photo) -> @Sendable () async -> Void {
                {
                    let size = ThumbnailStore.size(for: p.effectiveShot)
                    ThumbnailStore.ensureFile(
                        source: p.url,
                        dest: ThumbnailStore.fileURL(projectDir: dir, id: p.id, maxPixel: size),
                        maxPixel: size)
                }
            }
            for _ in 0..<4 {
                if let p = iterator.next() { group.addTask(operation: job(p)) }
            }
            while await group.next() != nil {
                made += 1
                progress(Update(phase: "Building the report", done: made, total: guide.count))
                if Task.isCancelled { continue }
                if let p = iterator.next() { group.addTask(operation: job(p)) }
            }
        }
        try Task.checkCancellation()

        // --- 7. name the trip (kept once set, so re-analyzing doesn't rename it) ---
        if project.tripName == nil {
            progress(Update(phase: "Naming the trip"))
            if let name = await suggestName(for: photos, client: client) {
                project.tripName = name.title
                project.shortName = name.short
            }
        }
        try Task.checkCancellation()

        project.photos = photos
        project.analyzedAt = Date()
        project.model = config.model
        return project
    }

    /// Ask the local model to name the trip from what's in the guide.
    static func suggestName(for photos: [Photo], client: OllamaClient) async -> OllamaClient.TripName? {
        let guide = photos.filter(\.inGuide)
        guard !guide.isEmpty else { return nil }
        let summary = GuideSummary(photos: guide)
        var counts: [String: Int] = [:]
        for p in guide { if let tag = p.sceneTag { counts[tag, default: 0] += 1 } }
        let scenes = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(20)
            .map { $0.key.replacingOccurrences(of: "-", with: " ") }
        let captions = guide.sorted { ($1.score ?? 0, $0.name) < ($0.score ?? 0, $1.name) }
            .prefix(15).compactMap(\.caption)
        // weight places by how many guide photos were taken there, biggest first
        var perCity: [String: Int] = [:]
        for p in guide { if let city = p.city, !city.isEmpty { perCity[city, default: 0] += 1 } }
        let located = max(perCity.values.reduce(0, +), 1)
        let ranked = perCity.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
        // drop brief stops (under 10% of the photos) so they can't end up in the name
        let places = ranked.enumerated().filter { $0.offset == 0 || $0.element.value * 10 >= located }
            .map(\.element)
            .map { "\($0.key) (\($0.value) of \(guide.count) photos)" }
        return try? await client.tripName(places: places, countries: summary.countries,
                                          dates: summary.dateRange, scenes: Array(scenes), captions: Array(captions))
    }

    private static func loadOne(_ url: URL, existing: [String: Photo]) -> Photo? {
        guard let key = PhotoLoader.fileKey(url) else { return nil }
        if var known = existing[key] {
            known.path = url.path
            known.name = url.lastPathComponent
            return known
        }
        return PhotoLoader.load(url, key: key)
    }

    private static func apply(_ analysis: Analysis, to photo: inout Photo) {
        photo.score = analysis.score
        photo.sceneTag = analysis.scene_tag
        photo.caption = analysis.description
        photo.shotType = ShotType(rawValue: analysis.shot_type) ?? .secondary
    }
}
