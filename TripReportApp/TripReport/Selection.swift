import Foundation

/// Port of analyze.py's de-duplication and selection logic.
enum SelectionEngine {
    // Two photos are "same scene" candidates within this many minutes/meters.
    static let sceneMinutes = 12.0
    static let sceneMeters = 150.0
    // pHash hamming distance at or below this = near-identical frame.
    static let phashNearDup = 12
    // Rapid-succession shots count as the same moment even if the frame shifted.
    static let burstSeconds = 30.0
    static let burstMeters = 25.0
    // Same scene tag within this distance counts as the same place across days.
    static let landmarkMeters = 500.0
    // Photos this close in time and space always get compared image-to-image.
    static let proximityMinutes = 15.0
    static let proximityMeters = 250.0
    static let tagSimStrong = 0.75
    static let tagSimMaybe = 0.35

    static let genericTokens: Set<String> = [
        "interior", "exterior", "urban", "street", "scene", "shop", "store",
        "storefront", "building", "city", "view", "photo", "outdoor", "indoor",
        "room", "display", "sign", "wall", "area", "district", "market", "vintage",
        "art", "small", "big", "old", "new", "the", "a", "of", "in", "at",
    ]

    static func haversine(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lng2 - lng1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(sqrt(a))
    }

    /// Fuzzy match scene tags on their distinctive words only.
    static func tagSimilarity(_ a: String, _ b: String) -> Double {
        let ta = Set(a.lowercased().components(separatedBy: "-")).subtracting(genericTokens)
        let tb = Set(b.lowercased().components(separatedBy: "-")).subtracting(genericTokens)
        if ta.isEmpty || tb.isEmpty {
            return a.lowercased() == b.lowercased() ? 1 : 0
        }
        let jaccard = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        let na = Array(ta.sorted().joined()), nb = Array(tb.sorted().joined())
        return max(jaccard, sequenceRatio(na, nb))
    }

    /// difflib.SequenceMatcher.ratio (Ratcliff/Obershelp).
    static func sequenceRatio(_ a: [Character], _ b: [Character]) -> Double {
        let total = a.count + b.count
        if total == 0 { return 1 }
        return 2 * Double(matchCount(a[...], b[...])) / Double(total)
    }

    private static func matchCount(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>) -> Int {
        var best = (i: 0, j: 0, k: 0)
        for i in a.indices {
            for j in b.indices {
                var k = 0
                while i + k < a.endIndex, j + k < b.endIndex, a[i + k] == b[j + k] { k += 1 }
                if k > best.k { best = (i, j, k) }
            }
        }
        if best.k == 0 { return 0 }
        return best.k
            + matchCount(a[a.startIndex..<best.i], b[b.startIndex..<best.j])
            + matchCount(a[(best.i + best.k)...], b[(best.j + best.k)...])
    }

    private struct Candidate {
        var index: Int
        var time: Double?
        var lat: Double?
        var lng: Double?
        var phash: UInt64
        var score: Int
        var tag: String
    }

    private static func sameMoment(_ a: Candidate, _ b: Candidate) -> Bool {
        if (a.phash ^ b.phash).nonzeroBitCount <= phashNearDup { return true }
        if let ta = a.time, let tb = b.time, abs(ta - tb) <= burstSeconds {
            guard let la = a.lat, let ga = a.lng, let lb = b.lat, let gb = b.lng else { return true }
            return haversine(la, ga, lb, gb) <= burstMeters
        }
        return false
    }

    /// Marks `selected` / `droppedReason` on every photo. `sameSubject` asks
    /// the vision model to compare two photos; nil means the check failed.
    static func select(_ photos: inout [Photo], minScore: Int,
                       progress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
                       sameSubject: (Photo, Photo) async -> Bool?) async throws {
        for i in photos.indices {
            photos[i].selected = false
            photos[i].droppedReason = photos[i].score == nil ? "Couldn't be analyzed" : nil
        }

        let ordered: [Candidate] = photos.indices
            .filter { photos[$0].score != nil }
            .sorted { (photos[$0].datetime ?? "9999", $0) < (photos[$1].datetime ?? "9999", $1) }
            .map { i in
                let p = photos[i]
                return Candidate(index: i, time: NaiveTime.date(p.datetime)?.timeIntervalSince1970,
                                 lat: p.lat, lng: p.lng, phash: p.phash,
                                 score: p.score ?? 0, tag: p.sceneTag ?? "")
            }

        // 1. Scene clusters: photos taken close together in time and space.
        var clusters: [[Candidate]] = []
        var current: [Candidate] = []
        for c in ordered {
            if let prev = current.last {
                var same = false
                if let t = c.time, let pt = prev.time {
                    same = abs(t - pt) / 60 <= sceneMinutes
                    if same, let la = c.lat, let ga = c.lng, let lb = prev.lat, let gb = prev.lng {
                        same = haversine(la, ga, lb, gb) <= sceneMeters
                    }
                }
                if !same {
                    clusters.append(current)
                    current = []
                }
            }
            current.append(c)
        }
        if !current.isEmpty { clusters.append(current) }

        // 2. Within each cluster keep the best frame of every burst / retake.
        var survivors: [Candidate] = []
        for cluster in clusters {
            var groups: [[Candidate]] = []
            for c in cluster {
                if let g = groups.firstIndex(where: { $0.contains { sameMoment(c, $0) } }) {
                    groups[g].append(c)
                } else {
                    groups.append([c])
                }
            }
            for group in groups {
                var best = group[0]
                for c in group.dropFirst() where c.score > best.score { best = c }
                for c in group where c.index != best.index {
                    photos[c.index].droppedReason = "Near-duplicate of \(photos[best.index].name)"
                }
                survivors.append(best)
            }
        }

        // 3. Same place on other days / from other angles: fuzzy tag match
        //    when nearby, confirmed by the model for borderline pairs.
        let ranked = survivors.enumerated()
            .sorted { ($1.element.score, $0.offset) < ($0.element.score, $1.offset) }
            .map(\.element)
        var tagMemo: [String: Double] = [:]
        var selected: [Candidate] = []
        for (position, p) in ranked.enumerated() {
            try Task.checkCancellation()
            progress(position, ranked.count)
            if p.score < minScore {
                photos[p.index].droppedReason = "Scored \(p.score), below the minimum of \(minScore)"
                continue
            }
            var dupeOf: Candidate?
            for s in selected {
                let memoKey = p.tag + "|" + s.tag
                let sim: Double
                if let cached = tagMemo[memoKey] {
                    sim = cached
                } else {
                    sim = tagSimilarity(p.tag, s.tag)
                    tagMemo[memoKey] = sim
                }
                var distance: Double?
                if let la = p.lat, let ga = p.lng, let lb = s.lat, let gb = s.lng {
                    distance = haversine(la, ga, lb, gb)
                }
                var proximate = false
                if let distance, let tp = p.time, let ts = s.time {
                    proximate = abs(tp - ts) / 60 <= proximityMinutes && distance <= proximityMeters
                }
                if sim < tagSimMaybe && !proximate { continue }
                if !proximate, let distance, distance > landmarkMeters { continue }

                var dupe = sim >= tagSimStrong
                if !dupe {
                    try Task.checkCancellation()
                    dupe = await sameSubject(photos[p.index], photos[s.index]) ?? (sim >= 0.5)
                }
                if dupe {
                    dupeOf = s
                    break
                }
            }
            if let dupeOf {
                photos[p.index].droppedReason = "Same subject as \(photos[dupeOf.index].name)"
            } else {
                selected.append(p)
                photos[p.index].selected = true
            }
        }
    }
}
