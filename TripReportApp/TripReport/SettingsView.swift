import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.urlKey) private var url = Prefs.defaultURL
    @AppStorage(Prefs.modelKey) private var model = Prefs.defaultModel
    @AppStorage(Prefs.minScoreKey) private var minScore = 5

    @State private var installed: [String] = []
    @State private var reachable: Bool?
    @State private var importNote: String?

    var body: some View {
        Form {
            Section {
                TextField("Ollama address", text: $url, prompt: Text(Prefs.defaultURL))
                Picker("Vision model", selection: $model) {
                    ForEach(Array(Set(installed + [model])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Status") {
                    switch reachable {
                    case .some(true):
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .some(false):
                        Label("Can't reach Ollama", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    case .none:
                        ProgressView().controlSize(.small)
                    }
                }
            } header: {
                Text("Analysis")
            } footer: {
                Text("Photos are scored on this Mac by a vision model running in Ollama. Nothing is uploaded.")
            }

            Section {
                Stepper("Minimum score: \(minScore)", value: $minScore, in: 1...10)
            } footer: {
                Text("Photos scoring below this are left out of guides. Applies the next time you analyze.")
            }

            Section {
                LabeledContent("Results from analyze.py") {
                    Button("Import cache.json…") {
                        guard let file = Panels.chooseJSON(message: "Choose the cache.json written by analyze.py")
                        else { return }
                        Task {
                            let added = await Caches.analysis.merge(from: file)
                            importNote = "Imported \(added) new result\(added == 1 ? "" : "s")."
                        }
                    }
                }
                if let importNote {
                    Text(importNote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Photos the Python script already scored are then skipped instead of being analyzed again.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: url) {
            reachable = nil
            do {
                try await Task.sleep(for: .milliseconds(300))
                installed = try await OllamaClient.models(baseURL: Prefs.ollamaURL)
                reachable = true
            } catch is CancellationError {
            } catch {
                installed = []
                reachable = false
            }
        }
    }
}
