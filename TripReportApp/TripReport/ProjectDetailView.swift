import QuickLook
import SwiftUI

struct ProjectDetailView: View {
    @Environment(Library.self) private var library
    let projectID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case guide = "Guide"
        case all = "Photos"
        var id: Self { self }
    }

    @State private var tab: Tab = .guide
    @State private var preview: URL?

    var body: some View {
        if let project = library.project(projectID) {
            let job = library.jobs[projectID]
            Group {
                if let job {
                    AnalysisProgressView(job: job) { library.cancel(projectID) }
                } else if project.analyzedAt == nil {
                    ContentUnavailableView {
                        Label("Ready to Analyze", systemImage: "sparkles")
                    } description: {
                        Text("Every photo is scored on this Mac by \(Prefs.model) through Ollama. The best shots become your guide.")
                    } actions: {
                        Button("Analyze Photos") { library.analyze(projectID) }
                            .prominentActionStyle()
                            .controlSize(.large)
                    }
                } else {
                    switch tab {
                    case .guide: GuideView(project: project, preview: $preview)
                    case .all: AllPhotosView(project: project, preview: $preview)
                    }
                }
            }
            .navigationTitle(project.name)
            // the name still labels the window, but isn't drawn in the toolbar
            .toolbar(removing: .title)
            .quickLookPreview($preview)
            .toolbar {
                if project.analyzedAt != nil && job == nil {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $tab) {
                            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        library.addSources(
                            Panels.choosePhotos(message: "Add folders or photos to this project"), to: projectID)
                    } label: {
                        Label("Add Photos", systemImage: "photo.badge.plus")
                    }
                    .help("Add more folders or photos, then analyze again")
                    .disabled(job != nil)

                    Button { library.analyze(projectID) } label: {
                        Label("Analyze Again", systemImage: "arrow.clockwise")
                    }
                    .help("Re-run the analysis. Photos already scored are reused.")
                    .disabled(job != nil)

                    Button { exportPicks(library, projectID) } label: {
                        Label("Export Picks", systemImage: "square.and.arrow.up")
                    }
                    .help("Copy the guide's original photos into a folder")
                    .disabled(job != nil || project.analyzedAt == nil)
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { library.errors[projectID] != nil },
                set: { if !$0 { library.errors[projectID] = nil } })) {
                Button("OK") {}
            } message: {
                Text(library.errors[projectID] ?? "")
            }
        }
    }
}

private struct AnalysisProgressView: View {
    let job: AnalysisJob
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if job.total > 0 {
                ProgressView(value: Double(min(job.done, job.total)), total: Double(job.total))
                    .frame(width: 320)
            } else {
                ProgressView()
            }
            Text(job.total > 0 ? "\(job.phase) · \(job.done) of \(job.total)" : job.phase)
                .font(.headline)
                .monospacedDigit()
            Text(job.detail.isEmpty ? " " : job.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 460)
            Button("Stop", action: cancel)
                .secondaryActionStyle()
                .padding(.top, 4)
            Text("Progress is kept. Scored photos aren't analyzed twice.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared photo pieces

struct ThumbnailImage: View {
    let photo: Photo
    let projectID: UUID
    let maxPixel: Int
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: "\(photo.id)/\(maxPixel)") {
                let loaded = await ThumbnailStore.shared.image(
                    photo: photo, projectDir: Storage.projectDir(projectID), maxPixel: maxPixel)
                if !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.15)) { image = loaded }
                }
            }
    }
}

struct PhotoMenu: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let projectID: UUID
    @Binding var preview: URL?

    var body: some View {
        if photo.inGuide {
            if photo.effectiveShot == .primary {
                Button("Show Small", systemImage: "rectangle.grid.2x2") {
                    library.setShot(.secondary, for: photo.id, in: projectID)
                }
            } else {
                Button("Show Large", systemImage: "rectangle.inset.filled") {
                    library.setShot(.primary, for: photo.id, in: projectID)
                }
            }
            Button("Remove from Guide", systemImage: "eye.slash") {
                library.removeFromGuide(photo.id, in: projectID)
            }
        } else {
            if let reason = photo.whyLeftOut {
                Text("Left out: \(reason)")
            }
            Button("Add to Guide", systemImage: "plus.circle") {
                library.addToGuide(photo.id, in: projectID)
            }
            .disabled(photo.datetime == nil)
        }
        Divider()
        Button("Quick Look", systemImage: "eye") { preview = photo.url }
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([photo.url])
        }
    }
}
