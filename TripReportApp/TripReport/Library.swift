import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AnalysisJob {
    var phase = "Starting"
    var detail = ""
    var done = 0
    var total = 0
    var task: Task<Void, Never>?
}

/// All saved projects. Each lives in its own folder under Application Support.
@MainActor @Observable
final class Library {
    var projects: [Project] = []
    var selection: UUID?
    var jobs: [UUID: AnalysisJob] = [:]
    var errors: [UUID: String] = [:]

    init() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Storage.projects, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        projects = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")) else { return nil }
            return try? decoder.decode(Project.self, from: data)
        }.sorted { $0.created > $1.created }
        selection = projects.first?.id
        // name guides that were built before trip naming existed
        for project in projects where project.analyzedAt != nil && project.tripName == nil {
            suggestName(project.id)
        }

        // `Trip Report --open <folder>` creates a project and starts analyzing.
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--open"), flag + 1 < args.count {
            let url = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
            if let known = projects.first(where: { $0.folders == [url.path] }) {
                selection = known.id
                if known.analyzedAt == nil { analyze(known.id) }
            } else if let id = createProject(from: [url]) {
                analyze(id)
            }
        }
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    private func save(_ project: Project) {
        let dir = Storage.projectDir(project.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(project) {
            try? data.write(to: dir.appendingPathComponent("project.json"), options: .atomic)
        }
    }

    func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
        save(projects[i])
    }

    // MARK: Projects

    @discardableResult
    func createProject(from urls: [URL]) -> UUID? {
        let sources = Self.usable(urls)
        guard let first = sources.first else { return nil }
        var name = first.hasDirectoryPath ? first.lastPathComponent
            : first.deletingLastPathComponent().lastPathComponent
        if ["photos", "pictures", "images", "originals"].contains(name.lowercased()) {
            name = first.deletingLastPathComponent().lastPathComponent
        }
        let project = Project(name: name, folders: sources.map(\.path))
        projects.insert(project, at: 0)
        save(project)
        selection = project.id
        return project.id
    }

    func addSources(_ urls: [URL], to id: UUID) {
        let sources = Self.usable(urls).map(\.path)
        guard !sources.isEmpty else { return }
        update(id) { project in
            for s in sources where !project.folders.contains(s) { project.folders.append(s) }
        }
    }

    private static func usable(_ urls: [URL]) -> [URL] {
        urls.filter { $0.hasDirectoryPath || PhotoLoader.extensions.contains($0.pathExtension.lowercased()) }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) {
            $0.name = trimmed
            $0.userRenamed = true
        }
    }

    func delete(_ id: UUID) {
        cancel(id)
        projects.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Storage.projectDir(id))
        if selection == id { selection = projects.first?.id }
    }

    // MARK: Analysis

    func analyze(_ id: UUID) {
        guard jobs[id] == nil, let snapshot = project(id) else { return }
        let job = AnalysisJob()
        jobs[id] = job
        errors[id] = nil
        let config = Pipeline.Config(baseURL: Prefs.ollamaURL, model: Prefs.model, minScore: Prefs.minScore)
        let dir = Storage.projectDir(id)
        job.task = Task { [weak self] in
            do {
                let result = try await Pipeline.run(project: snapshot, config: config, dir: dir) { update in
                    Task { @MainActor in
                        job.phase = update.phase
                        job.detail = update.detail
                        job.done = update.done
                        job.total = update.total
                    }
                }
                self?.update(id) { project in
                    project.photos = result.photos
                    project.analyzedAt = result.analyzedAt
                    project.model = result.model
                    Self.apply(title: result.tripName, short: result.shortName, to: &project)
                }
            } catch {
                if !(error is CancellationError) && !Task.isCancelled {
                    self?.errors[id] = error.localizedDescription
                }
            }
            self?.jobs[id] = nil
        }
    }

    private static func apply(title: String?, short: String?, to project: inout Project) {
        guard let title else { return }
        project.tripName = title
        project.shortName = short ?? title
        if project.userRenamed != true { project.name = short ?? title }
    }

    /// Have the local model (re)name the trip.
    func suggestName(_ id: UUID) {
        guard let photos = project(id)?.photos else { return }
        let client = OllamaClient(baseURL: Prefs.ollamaURL, model: Prefs.model)
        Task {
            guard let name = await Pipeline.suggestName(for: photos, client: client) else { return }
            update(id) { project in
                project.userRenamed = nil
                Self.apply(title: name.title, short: name.short, to: &project)
            }
        }
    }

    func cancel(_ id: UUID) {
        jobs[id]?.task?.cancel()
    }

    // MARK: Curating

    func removeFromGuide(_ photoID: String, in id: UUID) {
        update(id) { project in
            guard let i = project.photos.firstIndex(where: { $0.id == photoID }) else { return }
            project.photos[i].hidden = true
            project.photos[i].pinned = false
        }
    }

    func addToGuide(_ photoID: String, in id: UUID) {
        update(id) { project in
            guard let i = project.photos.firstIndex(where: { $0.id == photoID }) else { return }
            project.photos[i].hidden = false
            if !project.photos[i].selected { project.photos[i].pinned = true }
        }
        refreshEnrichment(id)
    }

    func setShot(_ shot: ShotType, for photoID: String, in id: UUID) {
        update(id) { project in
            guard let i = project.photos.firstIndex(where: { $0.id == photoID }) else { return }
            project.photos[i].shotOverride = shot == project.photos[i].shotType ? nil : shot
        }
    }

    /// Re-run places / timezones / weather after the guide's contents change.
    private func refreshEnrichment(_ id: UUID) {
        guard let photos = project(id)?.photos else { return }
        Task {
            let enriched = await Enricher.enrich(photos)
            let byID = Dictionary(enriched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            update(id) { project in
                for i in project.photos.indices {
                    guard let e = byID[project.photos[i].id] else { continue }
                    project.photos[i].city = e.city
                    project.photos[i].country = e.country
                    project.photos[i].zone = e.zone
                    project.photos[i].tzAbbrev = e.tzAbbrev
                    project.photos[i].utc = e.utc
                    project.photos[i].weather = e.weather
                }
            }
        }
    }

    // MARK: Export

    /// Copies the guide's original files into primary/ and secondary/ and
    /// writes a report.json in the same shape analyze.py produces.
    func exportPicks(_ id: UUID, into parent: URL) throws -> URL {
        guard let project = project(id) else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let dest = parent.appendingPathComponent("\(project.name) Picks", isDirectory: true)
        let guide = project.guidePhotos
        for kind in [ShotType.primary, .secondary] {
            try fm.createDirectory(at: dest.appendingPathComponent(kind.rawValue), withIntermediateDirectories: true)
        }
        for p in guide {
            let target = dest.appendingPathComponent(p.effectiveShot.rawValue).appendingPathComponent(p.name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: p.url, to: target)
        }
        func row(_ p: Photo) -> [String: Any] {
            [
                "name": p.name, "path": p.path,
                "datetime": p.datetime ?? NSNull(),
                "lat": p.lat ?? NSNull(), "lng": p.lng ?? NSNull(),
                "score": p.score ?? NSNull(),
                "scene_tag": p.sceneTag ?? "", "description": p.caption ?? "",
                "shot_type": p.effectiveShot.rawValue,
            ]
        }
        let report: [String: Any] = [
            "generated": ISO8601DateFormatter().string(from: Date()),
            "model": project.model ?? "",
            "total_photos": project.photos.count,
            "selected": guide.map(row),
            "all_photos": project.photos
                .sorted { ($0.datetime ?? "9999") < ($1.datetime ?? "9999") }.map(row),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
        try data.write(to: dest.appendingPathComponent("report.json"), options: .atomic)
        return dest
    }
}

/// Native open panels.
@MainActor
enum Panels {
    static func choosePhotos(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .image]
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseJSON(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
