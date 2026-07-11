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
    /// Drives one-shot map commands (the Zoom button).
    let mapController: MapController
    /// Collapses the sheet so the map is visible when zooming to the route.
    var onZoomToRoute: () -> Void = {}

    /// The active tile source, mirrored from Settings so offline downloads use the
    /// same provider (and API key) the map is currently drawing.
    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id
    @Environment(\.displayScale) private var displayScale
    @State private var downloader = OfflineTileDownloader()

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
                actionBar
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

    // MARK: Actions

    /// Trailing row of actions: zoom the map to the route, save it for offline use,
    /// and recolor the route line + elevation graph.
    private var actionBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                zoomButton
                downloadButton
                colorControl
            }
            widthSlider
            if let note = downloadNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(downloader.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var zoomButton: some View {
        Button {
            onZoomToRoute()
            mapController.fitToRoute()
        } label: {
            actionTile(icon: "scope", title: "Zoom")
        }
        .buttonStyle(.plain)
        .disabled(hike.coordinates.count < 2)
    }

    @ViewBuilder
    private var downloadButton: some View {
        Button {
            if downloader.phase == .downloading {
                downloader.cancel()
            } else {
                downloader.start(route: hike.coordinates, source: activeTileSource, scale: displayScale)
            }
        } label: {
            downloadTile
        }
        .buttonStyle(.plain)
        .disabled(!canDownload && downloader.phase != .downloading)
    }

    @ViewBuilder
    private var downloadTile: some View {
        switch downloader.phase {
        case .downloading:
            tile {
                ProgressView().controlSize(.small)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .finished:
            actionTile(icon: "checkmark.circle.fill", title: "Saved", tint: .green)
        default:
            actionTile(icon: "arrow.down.circle", title: "Offline",
                       tint: canDownload ? Color.accentColor : .secondary)
        }
    }

    private var colorControl: some View {
        tile {
            // `supportsOpacity` lets the user set the line's transparency here; the
            // alpha is applied to the map polyline only (other UI uses `tintOpaque`).
            ColorPicker("Route color", selection: tintBinding, supportsOpacity: true)
                .labelsHidden()
            Text("Color")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Reads the hike's tint and writes the picked color (with alpha) back as
    /// "#RRGGBBAA", which live-updates the map polyline.
    private var tintBinding: Binding<Color> {
        Binding(get: { hike.tint }, set: { hike.tintHex = $0.hexRGBA })
    }

    private var widthSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label("Line width", systemImage: "lineweight")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(hike.routeWidth)) pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: widthBinding, in: 1...12, step: 1)
                .tint(hike.tintOpaque)
        }
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { hike.routeWidth }, set: { hike.routeWidth = $0 })
    }

    private var canDownload: Bool {
        activeProvider.supportsBulkDownload && hike.coordinates.count > 1
    }

    private var downloadNote: String? {
        switch downloader.phase {
        case .failed(let message): return message
        case .finished: return "Saved for offline use."
        case .downloading: return "Saving \(downloader.total) tiles…"
        case .idle:
            return activeProvider.supportsBulkDownload
                ? nil
                : "Offline saving needs a downloadable map (Stadia) — pick it in Settings."
        }
    }

    private func actionTile(icon: String, title: String, tint: Color = .accentColor) -> some View {
        tile {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 5) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var activeProvider: TileProvider { .provider(id: tileProviderID) }

    private var activeTileSource: ActiveTileSource {
        let provider = activeProvider
        let key = provider.apiKeyDefaultsKey == SettingsKey.stadiaAPIKey ? (Secrets.stadiaAPIKey ?? "") : ""
        return ActiveTileSource(
            providerID: provider.id,
            urlTemplate: provider.resolvedTemplate(apiKey: key),
            maximumZ: provider.maximumZ
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: hike.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(hike.tintOpaque, in: RoundedRectangle(cornerRadius: 14))

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
                        colors: [hike.tintOpaque.opacity(0.45), hike.tintOpaque.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Distance", sample.distanceMeters),
                    y: .value("Elevation", sample.elevation)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(hike.tintOpaque)
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
                .foregroundStyle(hike.tintOpaque)
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
                .fill(hike.tintOpaque.opacity(0.12))
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.largeTitle)
                    .foregroundStyle(hike.tintOpaque)
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
