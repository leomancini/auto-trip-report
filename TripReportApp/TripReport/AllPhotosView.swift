import SwiftUI

/// Every photo in the project with its score, for reviewing what was left out.
struct AllPhotosView: View {
    @Environment(Library.self) private var library
    let project: Project
    @Binding var preview: URL?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case inGuide = "In Guide"
        case leftOut = "Left Out"
        var id: Self { self }
    }

    enum Order: String, CaseIterable, Identifiable {
        case time = "Time"
        case score = "Score"
        var id: Self { self }
    }

    @State private var filter: Filter = .all
    @State private var order: Order = .time

    private var photos: [Photo] {
        let filtered = project.photos.filter {
            switch filter {
            case .all: return true
            case .inGuide: return $0.inGuide
            case .leftOut: return !$0.inGuide
            }
        }
        switch order {
        case .time:
            return filtered.sorted { ($0.datetime ?? "9999", $0.name) < ($1.datetime ?? "9999", $1.name) }
        case .score:
            return filtered.sorted { ($1.score ?? 0, $0.name) < ($0.score ?? 0, $1.name) }
        }
    }

    var body: some View {
        let photos = photos
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)], spacing: 12) {
                ForEach(photos) { photo in
                    cell(photo)
                }
            }
            .padding(Metrics.gap)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 14) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Sort by", selection: $order) {
                    ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Spacer()
                Text("\(photos.count) photo\(photos.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func cell(_ photo: Photo) -> some View {
        ThumbnailImage(photo: photo, projectID: project.id, maxPixel: 400)
            .aspectRatio(1, contentMode: .fit)
            .opacity(photo.inGuide ? 1 : 0.45)
            .overlay(alignment: .bottomLeading) {
                Text(photo.score.map(String.init) ?? "–")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassBadge()
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if photo.inGuide {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .font(.title3)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .cardShadow()
            .contentShape(Rectangle())
            .onTapGesture { preview = photo.url }
            .contextMenu { PhotoMenu(photo: photo, projectID: project.id, preview: $preview) }
            .accessibilityLabel(photo.caption ?? photo.name)
    }
}
