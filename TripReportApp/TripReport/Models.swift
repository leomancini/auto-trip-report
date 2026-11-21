import CoreLocation
import Foundation

enum ShotType: String, Codable, Sendable {
    case primary, secondary
}

struct Weather: Codable, Hashable, Sendable {
    var tempC: Double
    var code: Int
    var isDay: Bool

    /// SF Symbol for the WMO weather code.
    var symbol: String {
        if !isDay && code <= 1 { return "moon.stars.fill" }
        switch code {
        case 0, 1: return "sun.max.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    var summary: String {
        if !isDay && code <= 1 { return "Clear night" }
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45: return "Fog"
        case 48: return "Icy fog"
        case 51: return "Light drizzle"
        case 53: return "Drizzle"
        case 55: return "Heavy drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80, 81: return "Showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return ""
        }
    }

    var temperature: String {
        Measurement(value: tempC, unit: UnitTemperature.celsius).formatted(
            .measurement(width: .abbreviated, usage: .weather,
                         numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}

struct Photo: Codable, Identifiable, Hashable, Sendable {
    /// Content key: sha256 of the first 1 MB plus the file size (same key
    /// analyze.py uses, so its cache.json can be imported).
    var id: String
    var path: String
    var name: String
    /// Local wall-clock time the photo was taken, "yyyy-MM-dd'T'HH:mm:ss".
    var datetime: String?
    var lat: Double?
    var lng: Double?
    var heading: Double?
    var phash: UInt64
    var aspect: Double

    // model analysis
    var score: Int?
    var sceneTag: String?
    var caption: String?
    var shotType: ShotType?

    // selection
    var selected = false
    var droppedReason: String?

    // user choices
    var hidden = false
    var pinned = false
    var shotOverride: ShotType?

    // enrichment
    var city: String?
    var country: String?
    var zone: String?
    var tzAbbrev: String?
    var utc: Double?
    var weather: Weather?

    var url: URL { URL(fileURLWithPath: path) }
    /// Undated photos never appear in the guide: they can't be placed on its timeline.
    var inGuide: Bool { (selected || pinned) && !hidden && datetime != nil }
    var effectiveShot: ShotType { shotOverride ?? shotType ?? .secondary }
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
    var whyLeftOut: String? {
        if hidden { return "Hidden by you" }
        if datetime == nil { return "No date in the photo's metadata" }
        if inGuide { return nil }
        return droppedReason
    }
}

struct Project: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var created = Date()
    var folders: [String]
    var photos: [Photo] = []
    var analyzedAt: Date?
    var model: String?
    /// Regular-length trip title suggested by the local model (shown in the guide).
    var tripName: String?
    /// Its very short version (shown in the sidebar unless the user renamed the project).
    var shortName: String?
    /// True once the user has typed their own name; the model then leaves it alone.
    var userRenamed: Bool?

    var guidePhotos: [Photo] {
        photos.filter(\.inGuide).sorted {
            ($0.utc ?? .infinity, $0.name) < ($1.utc ?? .infinity, $1.name)
        }
    }
}

/// Helpers for the "naive" local timestamps stored on photos. They are parsed
/// as if they were UTC so differences and calendar fields come out right
/// without knowing the real timezone.
enum NaiveTime {
    static let utc = TimeZone(identifier: "UTC")!

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let exif: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s)
    }

    static func fromExif(_ s: String) -> String? {
        guard let d = exif.date(from: s) else { return nil }
        return iso.string(from: d)
    }

    /// Interpret a naive timestamp in a real timezone.
    static func instant(_ s: String, in zone: TimeZone) -> Date? {
        guard let naive = iso.date(from: s) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: naive)
        comps.timeZone = zone
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = zone
        return zoned.date(from: comps)
    }
}

// MARK: - Guide structure

struct GuideSummary {
    var cities: [String] = []
    var countries: [String] = []
    var start: Date?
    var end: Date?
    var days = 0
    var count = 0

    var title: String {
        if cities.isEmpty { return "Trip report" }
        if cities.count <= 6 { return cities.joined(separator: " → ") }
        return "\(cities[0]) → \(cities[1]) → … → \(cities[cities.count - 1])"
    }

    var dateRange: String? {
        guard let start, let end else { return nil }
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = NaiveTime.utc
        return f.string(from: start, to: end)
    }

    var subtitle: String { subtitleLines.joined(separator: " · ") }

    var subtitleLines: [String] {
        var bits: [String] = []
        if let dateRange { bits.append(dateRange) }
        if countries.count > 1 { bits.append(countries.joined(separator: " · ")) }
        return bits
    }

    init(photos: [Photo]) {
        count = photos.count
        struct Stat { var first: Double; var last: Double; var n: Int }
        var stats: [String: Stat] = [:]
        var firstSeen: [String: Double] = [:]
        for p in photos {
            guard p.lat != nil, let utc = p.utc else { continue }
            if let city = p.city, !city.isEmpty {
                var s = stats[city] ?? Stat(first: utc, last: utc, n: 0)
                s.last = utc
                s.n += 1
                stats[city] = s
            }
            if let country = p.country, !country.isEmpty, firstSeen[country] == nil {
                firstSeen[country] = utc
            }
        }
        // keep places where the trip lingered, not drive-through waypoints
        let significant = stats.filter { $0.value.last - $0.value.first >= 2700 || $0.value.n >= 8 }
        cities = (significant.isEmpty ? stats : significant).keys
            .sorted { stats[$0]!.first < stats[$1]!.first }
        countries = firstSeen.keys.sorted { firstSeen[$0]! < firstSeen[$1]! }

        let days = photos.compactMap { $0.datetime.map { String($0.prefix(10)) } }.sorted()
        if let first = days.first, let last = days.last,
           let s = NaiveTime.date(first + "T00:00:00"), let e = NaiveTime.date(last + "T00:00:00") {
            start = s
            end = e
            self.days = Int((e.timeIntervalSince(s) / 86400).rounded()) + 1
        }
    }
}

struct GuideBlock: Identifiable {
    let id: String
    let title: String
    let date: String
    /// The one photo shown full width: the block's best landscape shot.
    var hero: Photo?
    var primaries: [Photo] = []
    var secondaries: [Photo] = []

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = NaiveTime.utc
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = NaiveTime.utc
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static func label(_ datetime: String?) -> (title: String, date: String) {
        guard let d = NaiveTime.date(datetime) else { return ("Undated", "") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = NaiveTime.utc
        let h = cal.component(.hour, from: d)
        let part = (5..<12).contains(h) ? "Morning" : (12..<17).contains(h) ? "Afternoon"
            : (17..<21).contains(h) ? "Evening" : "Night"
        return ("\(weekday.string(from: d)) \(part)", shortDate.string(from: d))
    }

    /// Group photos by day, then into contiguous time-of-day blocks.
    static func blocks(from photos: [Photo]) -> [GuideBlock] {
        let byDay = Dictionary(grouping: photos) { String(($0.datetime ?? "unknown").prefix(10)) }
        var out: [GuideBlock] = []
        for day in byDay.keys.sorted() {
            let dayPhotos = byDay[day]!.sorted { ($0.utc ?? .infinity) < ($1.utc ?? .infinity) }
            var lastTitle: String?
            for p in dayPhotos {
                let (title, date) = label(p.datetime)
                if title != lastTitle {
                    out.append(GuideBlock(id: "\(day)-\(out.count)", title: title, date: date))
                    lastTitle = title
                }
                if p.effectiveShot == .primary {
                    out[out.count - 1].primaries.append(p)
                } else {
                    out[out.count - 1].secondaries.append(p)
                }
            }
        }
        // one full-width photo per block at most, and only when the block has
        // enough other large photos to fill rows beneath it
        for i in out.indices where out[i].primaries.count >= 4 {
            var best: Int?
            for (n, p) in out[i].primaries.enumerated() where p.aspect > 1.2 {
                if best == nil || (p.score ?? 0) > (out[i].primaries[best!].score ?? 0) { best = n }
            }
            if let best { out[i].hero = out[i].primaries.remove(at: best) }
        }
        return out
    }
}
