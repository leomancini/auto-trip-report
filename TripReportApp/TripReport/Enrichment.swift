import CoreLocation
import Foundation

struct GeoInfo: Codable, Sendable {
    var city: String
    var country: String
    var zone: String
}

struct HourlyWeather: Codable, Sendable {
    var time: [String]
    var temperature_2m: [Double?]
    var weather_code: [Double?]
    var is_day: [Double?]?
}

/// Adds place names, timezones, absolute times and weather to guide photos.
enum Enricher {
    private static func cell(_ lat: Double, _ lng: Double) -> String {
        String(format: "%.1f,%.1f", lat, lng)
    }

    static func enrich(_ input: [Photo], progress: @Sendable (String) -> Void = { _ in }) async -> [Photo] {
        var photos = input
        let indices = photos.indices.filter { photos[$0].selected || photos[$0].pinned }

        // --- reverse geocode one point per ~10 km cell (cached) ---
        progress("Looking up places")
        let geocoder = CLGeocoder()
        var cells: [String: GeoInfo] = [:]
        for i in indices {
            guard let lat = photos[i].lat, let lng = photos[i].lng else { continue }
            let key = cell(lat, lng)
            if cells[key] == nil {
                if let cached = await Caches.geo.get(key) {
                    cells[key] = cached
                } else if !Task.isCancelled {
                    let info = await geocode(geocoder, lat: lat, lng: lng)
                    cells[key] = info ?? GeoInfo(city: "", country: "", zone: "")
                    if let info { await Caches.geo.set(key, info) }
                }
            }
            if let info = cells[key] {
                photos[i].city = info.city
                photos[i].country = info.country
                photos[i].zone = info.zone.isEmpty ? nil : info.zone
            }
        }
        await Caches.geo.flush()

        // --- timezones: photos without GPS inherit from the nearest in time ---
        let ordered = indices.sorted { (photos[$0].datetime ?? "9999", $0) < (photos[$1].datetime ?? "9999", $1) }
        for i in ordered where photos[i].lat == nil { photos[i].zone = nil }
        var last: String?
        for i in ordered {
            if let zone = photos[i].zone { last = zone } else { photos[i].zone = last }
        }
        last = nil
        for i in ordered.reversed() {
            if let zone = photos[i].zone { last = zone } else { photos[i].zone = last }
        }
        for i in ordered {
            photos[i].utc = nil
            photos[i].tzAbbrev = nil
            guard let datetime = photos[i].datetime else { continue }
            let zone = photos[i].zone.flatMap(TimeZone.init(identifier:))
            if let instant = NaiveTime.instant(datetime, in: zone ?? .current) {
                photos[i].utc = instant.timeIntervalSince1970
                if let zone { photos[i].tzAbbrev = zone.abbreviation(for: instant) }
            }
        }

        // --- hourly weather from Open-Meteo, one request per cell (cached) ---
        progress("Fetching weather")
        var groups: [String: [Int]] = [:]
        for i in indices {
            photos[i].weather = nil
            guard let lat = photos[i].lat, let lng = photos[i].lng, photos[i].datetime != nil else { continue }
            groups[cell(lat, lng), default: []].append(i)
        }
        for (key, members) in groups {
            if Task.isCancelled { break }
            let days = members.map { String(photos[$0].datetime!.prefix(10)) }
            guard let start = days.min(), let end = days.max(),
                  let hourly = await weather(cell: key, start: start, end: end) else { continue }
            var slot: [String: Int] = [:]
            for (n, t) in hourly.time.enumerated() { slot[t] = n }
            for i in members {
                let hour = String(photos[i].datetime!.prefix(14)) + "00"
                guard let n = slot[hour],
                      n < hourly.temperature_2m.count, let temp = hourly.temperature_2m[n],
                      n < hourly.weather_code.count, let code = hourly.weather_code[n] else { continue }
                var isDay = true
                if let flags = hourly.is_day, n < flags.count, let flag = flags[n] { isDay = flag != 0 }
                photos[i].weather = Weather(tempC: temp, code: Int(code), isDay: isDay)
            }
        }
        await Caches.weather.flush()
        return photos
    }

    private static func geocode(_ geocoder: CLGeocoder, lat: Double, lng: Double) async -> GeoInfo? {
        for attempt in 0..<2 {
            do {
                let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng))
                try? await Task.sleep(for: .milliseconds(250))
                guard let mark = marks.first else { return nil }
                return GeoInfo(
                    city: mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea ?? "",
                    country: mark.country ?? "",
                    zone: mark.timeZone?.identifier ?? "")
            } catch {
                // most likely throttled; back off once, then give up on this cell
                if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        return nil
    }

    private static func weather(cell: String, start: String, end: String) async -> HourlyWeather? {
        let key = "\(cell),\(start),\(end)"
        if let cached = await Caches.weather.get(key) { return cached }
        let parts = cell.split(separator: ",")
        // the forecast endpoint only reaches back ~3 months; older trips use the archive
        let old = (NaiveTime.date(start + "T00:00:00") ?? .distantPast) < Date().addingTimeInterval(-80 * 86400)
        var comps = URLComponents(string: old ? "https://archive-api.open-meteo.com/v1/archive"
                                              : "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(parts[0])),
            .init(name: "longitude", value: String(parts[1])),
            .init(name: "start_date", value: start),
            .init(name: "end_date", value: end),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "timezone", value: "auto"),
        ]
        struct Response: Decodable { var hourly: HourlyWeather? }
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let hourly = (try? JSONDecoder().decode(Response.self, from: data))?.hourly else { return nil }
        await Caches.weather.set(key, hourly)
        return hourly
    }
}
