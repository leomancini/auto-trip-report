import SwiftUI

/// Which photo the reader is currently looking at. Kept in its own
/// observable so scrolling only re-renders the info panel, not the feed.
@Observable
final class GuideFocus {
    var currentID: String?
}

/// Tracks where each on-screen card sits in the scroll view.
final class CardTracker {
    var tops: [Int: CGFloat] = [:]
    var viewport: CGFloat = 800

    /// The last card whose top edge has passed 55% of the way down the view.
    func current() -> Int? {
        let line = viewport * 0.55
        var best: Int?
        for (index, top) in tops where top < line {
            if best == nil || index > best! { best = index }
        }
        return best ?? tops.keys.min()
    }
}

struct GuideView: View {
    @Environment(Library.self) private var library
    let project: Project
    @Binding var preview: URL?

    @State private var focus = GuideFocus()
    @State private var tracker = CardTracker()

    var body: some View {
        let photos = project.guidePhotos
        if photos.isEmpty {
            ContentUnavailableView(
                "No Photos Made the Guide", systemImage: "photo.on.rectangle.angled",
                description: Text("Lower the minimum score in Settings and analyze again, or add photos from Photos."))
        } else {
            let summary = GuideSummary(photos: photos)
            let blocks = GuideBlock.blocks(from: photos)
            let order = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.id, $0) })
            let ids = photos.map(\.id)
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        if geo.size.width >= 760 {
                            InfoPanel(photos: photos, title: project.tripName ?? summary.title, summary: summary, focus: focus)
                                .frame(width: min(max(geo.size.width * 0.34, 300), 540))
                                .padding([.leading, .vertical], Metrics.gap)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                        if geo.size.width < 760 {
                            // no left column in a narrow window: keep the title above the photos
                            GuideTitle(title: project.tripName ?? summary.title, summary: summary)
                                .padding([.horizontal, .top], Metrics.gap)
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Metrics.gap) {
                            ForEach(blocks) { block in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(block.title)
                                        .font(.title2.bold())
                                    Text(block.date)
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, block.id == blocks.first?.id ? 0 : Metrics.gap)

                                if let hero = block.hero {
                                    card(hero, order: order, ids: ids)
                                        .aspectRatio(min(max(hero.aspect, 1.2), 2.2), contentMode: .fit)
                                }
                                if !block.primaries.isEmpty {
                                    JustifiedLayout(columns: 2.4, spacing: Metrics.gap) {
                                        ForEach(block.primaries) { card($0, order: order, ids: ids) }
                                    }
                                }
                                if !block.secondaries.isEmpty {
                                    JustifiedLayout(columns: 3.4, spacing: Metrics.gap) {
                                        ForEach(block.secondaries) { card($0, order: order, ids: ids) }
                                    }
                                }
                            }
                            }
                            .padding(.horizontal, Metrics.gap)
                            // a little extra so the first section title sits on the
                            // same baseline as the larger trip title in the left column
                            .padding(.top, Metrics.gap + 8)
                            .padding(.bottom, Metrics.gap)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            tracker.viewport = height
                        }
                        }
                    }
                }
            }
        }
    }

    private func card(_ photo: Photo, order: [String: Int], ids: [String]) -> some View {
        let index = order[photo.id] ?? 0
        return ThumbnailImage(photo: photo, projectID: project.id,
                              maxPixel: ThumbnailStore.size(for: photo.effectiveShot))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .cardShadow()
            .contentShape(Rectangle())
            .layoutValue(key: JustifiedLayout.Aspect.self, value: photo.aspect)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .scrollView).minY.rounded()
            } action: { top in
                tracker.tops[index] = top
                refocus(ids)
            }
            .onDisappear {
                tracker.tops[index] = nil
                refocus(ids)
            }
            .onTapGesture { preview = photo.url }
            .contextMenu { PhotoMenu(photo: photo, projectID: project.id, preview: $preview) }
            .accessibilityLabel(photo.caption ?? photo.name)
    }

    private func refocus(_ ids: [String]) {
        guard let index = tracker.current(), index < ids.count else { return }
        if focus.currentID != ids[index] { focus.currentID = ids[index] }
    }
}

struct GuideTitle: View {
    let title: String
    let summary: GuideSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.bold())
            ForEach(summary.subtitleLines, id: \.self) { line in
                Text(line)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
