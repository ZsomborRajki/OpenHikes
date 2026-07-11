//
//  HikeDetailView.swift
//  OpenTrails
//
//  Pushed when a hike is selected. Surfaces every stat we can derive from the
//  GPX file, with a placeholder elevation graph pinned to the bottom.
//

import SwiftUI
import Charts
import CoreLocation

struct HikeDetailView: View {
    let hike: Hike
    /// Reference type the map observes directly — writing to it doesn't re-render this view.
    let highlight: RouteHighlight

    /// Built once per view identity in `.task`, never in `init` (which re-runs on every
    /// struct recreation). Scrubbing then resolves points in O(log n).
    @State private var profile: RouteProfile?
    /// Persistent tracker position along the route (metres from start). Starts at the
    /// GPX start, follows the finger while scrubbing, and stays where it's left.
    @State private var trackerDistance: Double = 0
    /// Live chart selection under the finger, if any (transient).
    @State private var selectedDistance: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                elevationSection
                header
                statsGrid
                if hasMetadata { metadataSection }
            }
            .padding()
        }
        .navigationTitle(hike.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: hike.id) {
            let built = RouteProfile(route: hike.route)
            profile = built
            // Place the tracker at the start of the track, on both graph and map.
            trackerDistance = 0
            highlight.coordinate = built.coordinate(atDistance: 0)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: hike.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(hike.tint, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(hike.title)
                    .font(.title2.bold())
                Text(hike.date.formatted(date: .complete, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: Stats

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            ForEach(stats) { stat in
                StatTile(label: stat.label, value: stat.value)
            }
        }
    }

    private var stats: [Stat] {
        var items: [Stat] = [
            Stat("Distance", hike.distance.formatted(.measurement(width: .abbreviated, usage: .road)))
        ]
        if let duration = hike.duration { items.append(Stat("Duration", Self.durationString(duration))) }
        if let gain = hike.elevationGain { items.append(Stat("Elevation Gain", Self.lengthString(gain))) }
        if let loss = hike.elevationLoss { items.append(Stat("Elevation Loss", Self.lengthString(loss))) }
        if let maxEl = hike.maxElevation { items.append(Stat("Max Elevation", Self.lengthString(maxEl))) }
        if let minEl = hike.minElevation { items.append(Stat("Min Elevation", Self.lengthString(minEl))) }
        if let avg = hike.averageSpeed { items.append(Stat("Avg Speed", Self.speedString(avg))) }
        if let maxSpeed = hike.maxSpeed { items.append(Stat("Max Speed", Self.speedString(maxSpeed))) }
        items.append(Stat("Track Points", hike.pointCount.formatted()))
        if let start = hike.startDate {
            items.append(Stat("Start", start.formatted(date: .abbreviated, time: .shortened)))
        }
        if let end = hike.endDate {
            items.append(Stat("End", end.formatted(date: .abbreviated, time: .shortened)))
        }
        return items
    }

    // MARK: Metadata

    private var hasMetadata: Bool {
        hike.trackDescription != nil || hike.author != nil || hike.keywords != nil
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Details")
            if let description = hike.trackDescription { DetailRow(label: "Description", value: description) }
            if let author = hike.author { DetailRow(label: "Author", value: author) }
            if let keywords = hike.keywords { DetailRow(label: "Keywords", value: keywords) }
        }
    }

    // MARK: Elevation

    @ViewBuilder
    private var elevationSection: some View {
        if let profile, profile.samples.count > 1 {
            elevationChart(profile)
        } else {
            elevationPlaceholder
        }
    }

    private func elevationChart(_ profile: RouteProfile) -> some View {
        let domain = elevationDomain(profile)
        let tracker = profile.sample(atDistance: trackerDistance)
        return Chart {
            ForEach(profile.samples) { sample in
                AreaMark(
                    x: .value("Distance", sample.distanceMeters),
                    yStart: .value("Base", domain.lowerBound),
                    yEnd: .value("Elevation", sample.elevation)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [hike.tint.opacity(0.45), hike.tint.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Distance", sample.distanceMeters),
                    y: .value("Elevation", sample.elevation)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(hike.tint)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            if let tracker {
                RuleMark(x: .value("Distance", tracker.distanceMeters))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))

                PointMark(
                    x: .value("Distance", tracker.distanceMeters),
                    y: .value("Elevation", tracker.elevation)
                )
                .foregroundStyle(hike.tint)
                .symbolSize(90)
                .annotation(position: .top, spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    calloutLabel(tracker)
                }
            }
        }
        .chartXSelection(value: $selectedDistance)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(Measurement(value: meters, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(Measurement(value: meters, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .asProvided)))
                    }
                }
            }
        }
        .frame(height: 200)
        .onChange(of: selectedDistance) { _, distance in
            // While scrubbing, move the persistent tracker; keep it put on release.
            guard let distance else { return }
            trackerDistance = distance
            // O(log n) lookup, then the map moves one annotation off SwiftUI's path.
            highlight.coordinate = profile.coordinate(atDistance: distance)
        }
    }

    private func calloutLabel(_ sample: ElevationSample) -> some View {
        VStack(spacing: 1) {
            Text(Self.lengthString(Measurement(value: sample.elevation, unit: .meters)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(Measurement(value: sample.distanceMeters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Opaque (not a material) so it never picks up the graph colours behind it.
        .background(Self.calloutBackground, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    /// Solid, mode-adaptive callout background.
    private static let calloutBackground: Color = {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }()

    /// A y-range fitted to the actual elevation data (with a little headroom),
    /// so flat-ish profiles aren't squashed against a 0-based axis.
    private func elevationDomain(_ profile: RouteProfile) -> ClosedRange<Double> {
        guard let range = profile.elevationRange else { return 0...1 }
        let low = range.lowerBound, high = range.upperBound
        guard high > low else { return (low - 10)...(high + 10) }
        let padding = (high - low) * 0.15
        return (low - padding)...(high + padding)
    }

    private var elevationPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(hike.tint.opacity(0.12))
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.largeTitle)
                    .foregroundStyle(hike.tint)
                Text("No elevation data in this file")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 180)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }
}

// MARK: - Building blocks

private struct Stat: Identifiable {
    let id = UUID()
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Formatting

private extension HikeDetailView {
    static func durationString(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "—"
    }

    static func lengthString(_ measurement: Measurement<UnitLength>) -> String {
        let rounded = Measurement(value: measurement.value.rounded(), unit: measurement.unit)
        return rounded.formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    static func speedString(_ measurement: Measurement<UnitSpeed>) -> String {
        measurement.converted(to: .kilometersPerHour)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
    }
}
