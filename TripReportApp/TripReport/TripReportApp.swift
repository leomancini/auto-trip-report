import SwiftUI

@main
struct TripReportApp: App {
    @State private var library = Library()

    var body: some Scene {
        Window("Trip Report", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1360, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { newProject(library) }
                    .keyboardShortcut("n")
            }
            CommandMenu("Project") {
                let id = library.selection
                let busy = id.map { library.jobs[$0] != nil } ?? true
                Button(library.project(id)?.analyzedAt == nil ? "Analyze Photos" : "Analyze Again") {
                    if let id { library.analyze(id) }
                }
                .keyboardShortcut("r")
                .disabled(id == nil || busy)
                Button("Add Photos…") {
                    if let id { library.addSources(Panels.choosePhotos(message: "Add folders or photos to this project"), to: id) }
                }
                .disabled(id == nil || busy)
                Divider()
                Button("Export Picks…") {
                    if let id { exportPicks(library, id) }
                }
                .keyboardShortcut("e")
                .disabled(id == nil || busy || library.project(id)?.analyzedAt == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
func newProject(_ library: Library) {
    let urls = Panels.choosePhotos(message: "Choose a folder of trip photos")
    if let id = library.createProject(from: urls) { library.analyze(id) }
}

@MainActor
func exportPicks(_ library: Library, _ id: UUID) {
    guard let parent = Panels.chooseFolder(
        message: "Choose where to save the picked photos", prompt: "Export") else { return }
    do {
        let dest = try library.exportPicks(id, into: parent)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    } catch {
        library.errors[id] = "Export failed: \(error.localizedDescription)"
    }
}
