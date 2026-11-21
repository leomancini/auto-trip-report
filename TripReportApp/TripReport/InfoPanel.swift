import MapKit
import SwiftUI

/// Left column: date / time / weather cards and a map that all follow the
/// photo in view.
struct InfoPanel: View {
    let photos: [Photo]
    let title: String
    let summary: GuideSummary
    let focus: GuideFocus

    @State private var camera: MapCameraPosition = .automatic
    @State private var dot: CLLocationCoordinate2D?
    @State private var showCone = false
    @State private var coneAngle = 0.0

    private var current: Photo? {
        photos.first { $0.id == focus.currentID } ?? photos.first
    }

    var body: some View {
        let photo = current
        VStack(alignment: .leading, spacing: Metrics.gap) {
            GuideTitle(title: title, summary: summary)

            GlassGroup(spacing: Metrics.gap) {
                VStack(spacing: Metrics.gap) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(dateText(photo))
                            .font(.title2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        TripTimeline(segments: timeline(photo))
                            .padding(.bottom, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .tintedCard(.white, foreground: .black)

                    HStack(spacing: Metrics.gap) {
                        VStack(alignment: .leading, spacing: 16) {
                            AnalogClock(time: NaiveTime.date(photo?.datetime))
                            cardLines(timeText(photo), photo?.tzAbbrev ?? " ")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(16)
                        .tintedCard(timeTint(photo))

                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: photo?.weather?.symbol ?? "cloud.slash")
                                .symbolRenderingMode(.hierarchical)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 40, alignment: .leading)
                                .accessibilityHidden(true)
                            cardLines(photo?.weather?.summary ?? "—", photo?.weather?.temperature ?? " ")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(16)
                        .tintedCard(weatherTint(photo?.weather))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Map(position: $camera, interactionModes: []) {
                if let dot {
                    Annotation("", coordinate: dot, anchor: .center) {
                        LocationDot(angle: coneAngle, showCone: showCone)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .cardShadow()
        }
        .animation(.easeInOut(duration: 0.4), value: photo?.id)
        .onChange(of: photo?.id, initial: true) { old, _ in
            follow(photo, animated: old != nil)
        }
    }

    /// Sky color that shifts continuously through the day.
    private static let sky: [(hour: Double, rgb: (Double, Double, Double))] = [
        (0, (0.07, 0.08, 0.24)),    // deep night
        (4.5, (0.16, 0.14, 0.36)),  // pre-dawn
        (6, (0.90, 0.45, 0.35)),    // sunrise
        (7.5, (0.95, 0.65, 0.30)),  // golden morning
        (10, (0.25, 0.60, 0.95)),   // morning blue
        (13, (0.10, 0.48, 0.95)),   // midday
        (16.5, (0.30, 0.50, 0.88)), // late afternoon
        (18.5, (0.96, 0.55, 0.25)), // golden hour
        (20, (0.88, 0.32, 0.45)),   // sunset
        (21, (0.42, 0.22, 0.58)),   // dusk
        (22.5, (0.13, 0.13, 0.38)), // night
        (24, (0.07, 0.08, 0.24)),
    ]

    private func timeTint(_ photo: Photo?) -> Color {
        guard let date = NaiveTime.date(photo?.datetime) else { return .gray }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NaiveTime.utc
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        let next = Self.sky.firstIndex { $0.hour > hour } ?? Self.sky.count - 1
        let from = Self.sky[max(next - 1, 0)], to = Self.sky[next]
        let t = to.hour > from.hour ? (hour - from.hour) / (to.hour - from.hour) : 0
        return Color(red: from.rgb.0 + (to.rgb.0 - from.rgb.0) * t,
                     green: from.rgb.1 + (to.rgb.1 - from.rgb.1) * t,
                     blue: from.rgb.2 + (to.rgb.2 - from.rgb.2) * t)
    }

    private func weatherTint(_ weather: Weather?) -> Color {
        guard let weather else { return .gray }
        if !weather.isDay { return Color(red: 0.2, green: 0.2, blue: 0.45) }
        switch weather.code {
        case 0, 1: return .orange
        case 2: return .cyan
        case 3, 45, 48: return .gray
        case 71, 73, 75, 77, 85, 86: return .mint
        case 95, 96, 99: return .purple
        default: return .teal
        }
    }

    private func follow(_ photo: Photo?, animated: Bool) {
        guard let photo, let target = photo.coordinate else { return }
        let hop = dot.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        }
        let position = MapCameraPosition.camera(MapCamera(centerCoordinate: target, distance: 3200))
        // nearby: glide. A big hop (new area or day): jump, don't fly across the map.
        if animated, let hop, hop < 4000 {
            withAnimation(.easeOut(duration: 0.5)) {
                camera = position
                dot = target
            }
        } else {
            camera = position
            dot = target
        }
        if let heading = photo.heading {
            // rotate along the shortest arc so 350° → 10° doesn't spin backwards
            let now = (coneAngle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            let delta = (heading - now + 540).truncatingRemainder(dividingBy: 360) - 180
            withAnimation(animated ? .easeOut(duration: 0.5) : nil) {
                coneAngle += delta
                showCone = true
            }
        } else {
            showCone = false
        }
    }

    /// One segment per day of the trip. Days already passed are full, later
    /// days empty, and the current day fills by how many of that day's photos
    /// the reader has reached.
    private func timeline(_ photo: Photo?) -> [Double] {
        guard let photo, let today = photo.datetime?.prefix(10),
              let index = photos.firstIndex(where: { $0.id == photo.id }),
              let start = summary.start, summary.days > 0 else { return [] }
        // long trips get one continuous bar instead of dozens of slivers
        if summary.days > 21 {
            return [Double(index + 1) / Double(photos.count)]
        }
        let sameDay = photos.filter { $0.datetime?.prefix(10) == today }
        let reached = (sameDay.firstIndex { $0.id == photo.id } ?? 0) + 1
        let todayIndex = NaiveTime.date(today + "T00:00:00")
            .map { Int(($0.timeIntervalSince(start) / 86400).rounded()) } ?? 0
        return (0..<summary.days).map { day in
            day < todayIndex ? 1 : day > todayIndex ? 0 : Double(reached) / Double(sameDay.count)
        }
    }

    /// The two text lines shared by the time and weather cards.
    private func cardLines(_ first: String, _ second: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(first)
                .font(.title2.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(second)
                .font(.title3)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func dateText(_ photo: Photo?) -> String {
        guard let date = NaiveTime.date(photo?.datetime) else { return "Undated" }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.timeZone = NaiveTime.utc
        return date.formatted(style)
    }

    private func timeText(_ photo: Photo?) -> String {
        guard let date = NaiveTime.date(photo?.datetime) else { return "—" }
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = NaiveTime.utc
        return date.formatted(style)
    }
}

private struct AnalogClock: View {
    let time: Date?

    var body: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NaiveTime.utc
        let parts = time.map { calendar.dateComponents([.hour, .minute], from: $0) }
        let minute = Double(parts?.minute ?? 0)
        let hour = Double((parts?.hour ?? 0) % 12) + minute / 60
        return ZStack {
            Circle()
                .strokeBorder(.secondary.opacity(0.6), lineWidth: 2)
            ClockHands(hour: hour * 30, minute: minute * 6)
                .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .animation(.easeOut(duration: 0.4), value: minute + hour * 60)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    /// Both hands as one line (hour tip → center → minute tip), so they share a
    /// single rounded joint at the pivot.
    private struct ClockHands: Shape {
        var hour: Double
        var minute: Double

        var animatableData: AnimatablePair<Double, Double> {
            get { AnimatablePair(hour, minute) }
            set { (hour, minute) = (newValue.first, newValue.second) }
        }

        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            func tip(_ degrees: Double, _ length: CGFloat) -> CGPoint {
                let angle = CGFloat((degrees - 90) * .pi / 180)
                return CGPoint(x: center.x + CoreGraphics.cos(angle) * length,
                               y: center.y + CoreGraphics.sin(angle) * length)
            }
            var path = Path()
            path.move(to: tip(hour, radius * 0.45))
            path.addLine(to: center)
            path.addLine(to: tip(minute, radius * 0.68))
            return path
        }
    }
}

/// The blue "you are here" dot with a cone showing which way the camera faced.
private struct LocationDot: View {
    let angle: Double
    let showCone: Bool

    var body: some View {
        ZStack {
            Cone()
                .fill(RadialGradient(colors: [.blue.opacity(0.5), .blue.opacity(0)],
                                     center: .center, startRadius: 6, endRadius: 55))
                .rotationEffect(.degrees(angle))
                .opacity(showCone ? 1 : 0)
            Circle()
                .fill(.blue)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .frame(width: 110, height: 110)
        .allowsHitTesting(false)
    }

    private struct Cone: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            path.move(to: center)
            path.addArc(center: center, radius: rect.width / 2,
                        startAngle: .degrees(-120), endAngle: .degrees(-60), clockwise: false)
            path.closeSubpath()
            return path
        }
    }
}

/// One capsule per day of the trip, filling up as the reader moves through the photos.
private struct TripTimeline: View {
    let segments: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, fill in
                Capsule()
                    .fill(.primary.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.primary)
                            .scaleEffect(x: fill, y: 1, anchor: .leading)
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: 6)
        .opacity(segments.isEmpty ? 0 : 1)
        .accessibilityHidden(true)
    }
}
