import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var deleting: UUID?

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            List(selection: $library.selection) {
                ForEach(library.projects) { project in
                    ProjectRow(project: project, running: library.jobs[project.id] != nil)
                        .tag(project.id)
                        .contextMenu {
                            Button("Rename…") {
                                newName = project.name
                                renaming = project.id
                            }
                            Button("Suggest a Name") { library.suggestName(project.id) }
                                .disabled(project.analyzedAt == nil)
                            Button("Show Photos in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    project.folders.map { URL(fileURLWithPath: $0) })
                            }
                            Divider()
                            Button("Delete Project…", role: .destructive) { deleting = project.id }
                        }
                }
            }
            // let the translucent window background show through the sidebar
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
            .onDeleteCommand { deleting = library.selection }
            .toolbar {
                ToolbarItem {
                    Button { newProject(library) } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .help("Create a project from a folder of photos")
                }
            }
            .overlay {
                if library.projects.isEmpty {
                    Text("No Projects")
                        .foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let id = library.selection, library.project(id) != nil {
                ProjectDetailView(projectID: id)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Project Selected", systemImage: "map")
                } description: {
                    Text("Choose a folder of trip photos, or drop one here, to build a report from the best shots.")
                } actions: {
                    Button("New Project…") { newProject(library) }
                        .prominentActionStyle()
                        .controlSize(.large)
                }
            }
        }
        // translucent window: the desktop shows through, blurred
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .dropDestination(for: URL.self) { urls, _ in
            guard let id = library.createProject(from: urls) else { return false }
            library.analyze(id)
            return true
        }
        .alert("Rename Project", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { library.rename(renaming, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(library.project(deleting)?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Project", role: .destructive) {
                if let deleting { library.delete(deleting) }
            }
        } message: {
            Text("The saved report is removed. Your original photos are not touched.")
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let running: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if running {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if running { return "Analyzing…" }
        guard project.analyzedAt != nil else { return "Not analyzed yet" }
        return GuideSummary(photos: project.guidePhotos).dateRange ?? "No dated photos"
    }
}
