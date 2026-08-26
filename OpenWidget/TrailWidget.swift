//
//  TrailWidget.swift
//  OpenWidget
//
//  Shows the shape of whichever trail is currently selected in OpenHikes,
//  plus your last-known position along it. During an active recording it may
//  request one coarse location anchor on a sparse WidgetKit timeline; all
//  displayed state still comes from SharedStore (see OpenHikesShared).
//

import AppIntents
import CoreLocation
import OpenHikesShared
import RelevanceKit
import SwiftUI
import WidgetKit

struct TrailWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedTrailSnapshot?
    let recordingSnapshot: SharedRecordingSnapshot?
    /// The map images the app rendered for `snapshot`'s trail, if any — see
    /// `TrailBasemapRenderer` in the app target. Only the manifest is carried
    /// here; the image itself is read at render time by whichever view ends
    /// up needing it, so an entry never holds a decoded bitmap.
    var basemaps: TrailBasemapSet?

    /// Pairs a stored snapshot with its basemaps, which are only ever valid
    /// for the hike they were rendered for.
    init(
        date: Date,
        snapshot: SharedTrailSnapshot?,
        recordingSnapshot: SharedRecordingSnapshot? = nil
    ) {
        self.date = date
        self.recordingSnapshot = recordingSnapshot
        self.snapshot = recordingSnapshot == nil ? snapshot : nil
        basemaps = self.snapshot.flatMap { snapshot in
            SharedStore.loadBasemapSet(for: snapshot.hikeID)
        }
    }

    /// Where tapping the widget goes. Absent in the empty state, where there
    /// is no trail to open and a plain launch is the right outcome.
    var deepLinkURL: URL? {
        if recordingSnapshot != nil { return TrailWidgetDeepLink.recordingURL() }
        return snapshot.flatMap { snapshot in
            TrailWidgetDeepLink.url(hikeID: snapshot.hikeID)
        }
    }
}

nonisolated enum WidgetRecordingFixPolicy {
    static let maximumAge: TimeInterval = 5 * 60
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 200

    static func accepts(_ location: CLLocation, now: Date) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return age >= 0
            && age <= maximumAge
            && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= maximumHorizontalAccuracy
            && Mercator.isRepresentable(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
    }
}

@MainActor
final class WidgetRecordingRequest {
    typealias Completion = () -> Void

    let sessionID: UUID
    private var completion: Completion?

    init(sessionID: UUID, completion: @escaping Completion) {
        self.sessionID = sessionID
        self.completion = completion
    }

    func consume() -> (sessionID: UUID, completion: Completion)? {
        guard let completion else { return nil }
        self.completion = nil
        return (sessionID, completion)
    }
}

/// The widget's configuration, which is deliberately empty.
///
/// There is nothing for a walker to choose here: the widget shows whatever
/// hike the app has selected, and an active recording always wins. Picking a
/// hike in two places would be one place too many.
///
/// It exists because `AppIntentConfiguration` is what gives
/// ``TrailWidgetProvider`` an `async` timeline and a `relevance()` the Smart
/// Stack reads — see the provider. Migrating from `StaticConfiguration` keeps
/// widgets already on a home screen exactly where they are, because
/// ``TrailWidgetKind/id`` is unchanged; that identifier is the migration, so
/// it must stay stable.
struct TrailWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Trail"
    static let description = IntentDescription(
        "Shows your selected trail or a hike currently being recorded."
    )
}

struct TrailWidgetProvider: AppIntentTimelineProvider {
    /// How far ahead the timeline schedules its self-healing reload.
    ///
    /// Freshness is driven by the app's explicit `reloadTimelines` calls
    /// (selection changes, the foreground follow loop, and background
    /// significant-location-change events) — not by a fixed schedule. This
    /// distant `.after` is only a safety net in case a reload call is ever
    /// missed (e.g. the app is killed mid-write); it costs four extra reloads
    /// a day against the system's daily budget.
    static let safetyNetHours = 6
    static let recordingRefreshMinutes = 20

    func placeholder(in context: Context) -> TrailWidgetEntry {
        Self.placeholderEntry()
    }

    /// `async` with nothing to await, because the protocol says so and both
    /// answers are already in memory — hence the inline disable rather than a
    /// contrived suspension.
    func snapshot(
        for configuration: TrailWidgetConfiguration,
        in context: Context
    ) async -> TrailWidgetEntry { // swiftlint:disable:this async_without_await
        context.isPreview ? Self.placeholderEntry() : Self.currentEntry()
    }

    /// An `async` requirement rather than the completion-handler pair
    /// `TimelineProvider` declares. That protocol has no async form, which is
    /// most of why this widget is `AppIntentTimelineProvider`: the recording
    /// branch below has to reach a `@MainActor` sampler and wait for a fix, so
    /// under the old shape the escaping completion was handed into a
    /// `Task { @MainActor in … }` and had to be `@Sendable` to survive
    /// crossing the isolation boundary — a constraint the code carried a
    /// comment to explain. Awaiting is the same thing without the boundary.
    func timeline(
        for configuration: TrailWidgetConfiguration,
        in context: Context
    ) async -> Timeline<TrailWidgetEntry> {
        let entry = Self.currentEntry()
        guard let recording = entry.recordingSnapshot,
              recording.isCapturingFixes else {
            return Self.currentTimeline()
        }
        // Best-effort: the sampler answers whether or not it got a fix, and a
        // timeline is owed either way. Whatever it managed to write is picked
        // up by re-reading the store below.
        await WidgetRecordingLocationSampler.shared.fix(for: recording.sessionID)
        return Self.currentTimeline()
    }

    /// What the Smart Stack ranks this widget by.
    ///
    /// A recording in progress is the one moment this widget is the most
    /// useful thing on the stack — the walker is outdoors, moving, and looking
    /// at a wrist or a lock screen rather than unlocking the phone.
    /// `.fitness(.workoutActive)` is exactly that condition, and the system
    /// already knows when it holds.
    ///
    /// No attributes otherwise: a trail sitting selected for a fortnight is
    /// not a reason to promote anything, and claiming relevance the user
    /// doesn't feel is how a widget gets removed from the stack for good.
    ///
    /// `async` for the protocol's sake; reading the shared store is a file
    /// read on the calling thread, as everywhere else in this provider.
    func relevance() async -> WidgetRelevance<TrailWidgetConfiguration> { // swiftlint:disable:this async_without_await
        guard Self.currentEntry().recordingSnapshot?.isCapturingFixes == true else {
            return WidgetRelevance([])
        }
        return WidgetRelevance([
            WidgetRelevanceAttribute(
                configuration: TrailWidgetConfiguration(),
                context: .fitness(.workoutActive)
            ),
        ])
    }

    // The three below take the date rather than reading the clock, and are
    // separate from the protocol methods above, because `TimelineProviderContext`
    // has no initializer available outside WidgetKit — so this is the widest
    // surface a test can reach at all.

    /// Whatever the app most recently wrote, with its basemaps if it has any.
    static func currentEntry(date: Date = .now) -> TrailWidgetEntry {
        TrailWidgetEntry(
            date: date,
            snapshot: SharedStore.load(),
            recordingSnapshot: SharedStore.loadRecording()
        )
    }

    static func placeholderEntry(date: Date = .now) -> TrailWidgetEntry {
        TrailWidgetEntry(date: date, snapshot: placeholderSnapshot)
    }

    static func currentTimeline(date: Date = .now) -> Timeline<TrailWidgetEntry> {
        let entry = currentEntry(date: date)
        return Timeline(
            entries: [entry],
            policy: .after(
                nextReload(
                    after: date,
                    recording:
                        entry.recordingSnapshot?.isCapturingFixes == true
                )
            )
        )
    }

    static func nextReload(
        after date: Date,
        recording: Bool = false
    ) -> Date {
        if recording {
            return Calendar.current.date(
                byAdding: .minute,
                value: recordingRefreshMinutes,
                to: date
            ) ?? date.addingTimeInterval(
                Double(recordingRefreshMinutes) * 60
            )
        }
        return Calendar.current.date(
            byAdding: .hour,
            value: safetyNetHours,
            to: date
        )
            ?? date.addingTimeInterval(Double(safetyNetHours) * 3600)
    }

    @MainActor
    private final class WidgetRecordingLocationSampler: NSObject,
        CLLocationManagerDelegate {
        static let shared = WidgetRecordingLocationSampler()
        private static let minimumSamplingInterval: TimeInterval = 15 * 60

        private let manager = CLLocationManager()
        private var request: WidgetRecordingRequest?
        private var timeoutTask: Task<Void, Never>?

        override private init() {
            super.init()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        }

        /// `requestFix` as an `await`. The callback is invoked exactly once on
        /// every path — `WidgetRecordingRequest.consume()` is what guarantees
        /// it for the two that race (a fix arriving and the timeout firing) —
        /// which is the precondition a checked continuation needs.
        func fix(for sessionID: UUID) async {
            await withCheckedContinuation { continuation in
                requestFix(for: sessionID) { continuation.resume() }
            }
        }

        func requestFix(for sessionID: UUID, completion: @escaping () -> Void) {
            guard request == nil else {
                completion()
                return
            }
            guard manager.isAuthorizedForWidgetUpdates else {
                completion()
                return
            }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: break
            case .notDetermined, .restricted, .denied:
                completion()
                return
            @unknown default:
                completion()
                return
            }
            guard (
                try? SharedStore.claimRecordingWidgetSample(
                    sessionID: sessionID,
                    minimumInterval: Self.minimumSamplingInterval
                )
            ) == true else {
                completion()
                return
            }

            request = WidgetRecordingRequest(
                sessionID: sessionID,
                completion: completion
            )
            manager.requestLocation()
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(8))
                } catch { return }
                self?.finish()
            }
        }

        nonisolated func locationManager(
            _ manager: CLLocationManager,
            didUpdateLocations locations: [CLLocation]
        ) {
            let now = Date()
            let location = locations
                .filter { $0.timestamp <= now }
                .max { $0.timestamp < $1.timestamp }
            Task { @MainActor [weak self] in
                self?.finish(with: location, now: now)
            }
        }

        nonisolated func locationManager(
            _ manager: CLLocationManager,
            didFailWithError error: Error
        ) {
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }

        private func finish(
            with location: CLLocation? = nil,
            now: Date = Date()
        ) {
            timeoutTask?.cancel()
            timeoutTask = nil
            let completedRequest = request?.consume()
            request = nil
            let requestedSessionID = completedRequest?.sessionID

            if let location,
               let requestedSessionID,
               let recording = SharedStore.loadRecording(),
               recording.sessionID == requestedSessionID,
               recording.isCapturingFixes,
               WidgetRecordingFixPolicy.accepts(
                   location,
                   now: now
               ) {
                let elevation: Double?
                if location.verticalAccuracy >= 0,
                   location.verticalAccuracy <= 30 {
                    elevation = location.altitude
                } else {
                    elevation = nil
                }
                _ = try? SharedStore.appendPendingRecordingFix(
                    SharedRecordingFix(
                        sessionID: requestedSessionID,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        timestamp: location.timestamp,
                        horizontalAccuracy: location.horizontalAccuracy,
                        elevation: elevation,
                        course: location.course >= 0 ? location.course : nil,
                        speed: location.speed >= 0 ? location.speed : nil
                    )
                )
            }
            completedRequest?.completion()
        }
    }
}

struct TrailWidgetEntryView: View {
    @Environment(\.widgetFamily)
    private var family
    let entry: TrailWidgetEntry

    var body: some View {
        content
            // Whole-widget tap target: opens the app on the live recording,
            // or on this trail's detail view.
            .widgetURL(entry.deepLinkURL)
    }

    @ViewBuilder private var content: some View {
        if let recording = entry.recordingSnapshot {
            RecordingWidgetContent(snapshot: recording, family: family)
        } else if let snapshot = entry.snapshot {
            TrailWidgetContent(snapshot: snapshot, basemaps: entry.basemaps, family: family)
        } else {
            emptyState
        }
    }

    private struct RecordingWidgetContent: View {
        let snapshot: SharedRecordingSnapshot
        let family: WidgetFamily

        private static let stackSpacing: Double = 4

        private var layout: TrailWidgetLayout {
            TrailWidgetLayout(family: family)
        }

        private var metrics: [TrailWidgetMetric] {
            snapshot.metrics(limit: layout.metricLimit)
        }

        /// The recording map is the raw trace over a plain fill, never a
        /// rendered basemap, so the text is on a light surface and takes the
        /// standard label colors.
        private var accessibilityValue: String {
            let spoken = snapshot.metricsAccessibilityText(limit: layout.metricLimit)
            return spoken.isEmpty
                ? snapshot.statusText
                : "\(snapshot.statusText), \(spoken)"
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if layout.showsTitle {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(snapshot.isCapturingFixes ? .red : .secondary)
                            .frame(width: 8, height: 8)
                        Text(snapshot.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(snapshot.startedAt, style: .timer)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: Self.stackSpacing) {
                    TrailWidgetMetricRow(metrics: metrics, onMap: false)
                    Text(snapshot.statusText)
                        .font(
                            family == .systemSmall
                                ? .caption.weight(.semibold)
                                : .caption
                        )
                        .foregroundStyle(.secondary)
                }
            }
            .padding(layout.padding)
            // The whole widget is one tap target, so it is read as one thing:
            // the trail's name, then how the recording is going. The map
            // behind it is a drawing of the same facts.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.title)
            .accessibilityValue(accessibilityValue)
            .containerBackground(for: .widget) {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    TrailMapView(
                        polyline: snapshot.polyline,
                        basemaps: nil,
                        tint: .red,
                        liveFix: snapshot.polyline.last,
                        lineWidth: layout.routeLineWidth
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.hiking")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Select a trail in OpenHikes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TrailWidgetContent: View {
    let snapshot: SharedTrailSnapshot
    let basemaps: TrailBasemapSet?
    let family: WidgetFamily

    /// Text treatment for the light-on-map case, the companion to ``Scrim``:
    /// the scrim darkens the map, these keep the glyphs legible on top of it.
    private enum MapTextStyle {
        static let shadowOpacity: Double = 0.35
        static let timestampOpacity: Double = 0.7
    }

    private enum Scrim {
        static let topOpacity: Double = 0.45
        static let topClearLocation: Double = 0.3
        static let bottomClearLocation: Double = 0.6
        /// The stat chips and the progress hairline push the text band taller,
        /// so the darkened part starts higher when they are drawn — otherwise
        /// the top chip sits on undimmed map.
        static let bottomClearLocationWithMetrics: Double = 0.48
        static let bottomOpacity: Double = 0.55
    }

    private enum Stack {
        static let spacing: Double = 4
        static let progressTopPadding: Double = 1
    }

    private var layout: TrailWidgetLayout { TrailWidgetLayout(family: family) }
    private var tint: Color { Color(hex: snapshot.tintHex) ?? .green }
    private var showsTitle: Bool { layout.showsTitle }
    private var metrics: [TrailWidgetMetric] { snapshot.metrics(limit: layout.metricLimit) }

    /// Whether a rendered map is actually behind the text, which is what
    /// decides between light-on-map and standard label colors.
    ///
    /// Any non-empty set resolves to *some* image for any size and
    /// appearance — that's what `image(forAspectRatio:appearance:)`'s
    /// fallback chain guarantees — so this needs no size math of its own. In
    /// the one case where it can be optimistic (the manifest survived but its
    /// files didn't, which the renderer actively prevents), the scrim below
    /// is drawn anyway and the text stays legible against it.
    private var hasMap: Bool { !(basemaps?.images.isEmpty ?? true) }

    /// Everything the one accessibility element says after the trail's name:
    /// how far along it the walker is, then each chip in words. The glyphs
    /// themselves are hidden, so this is the only place the numbers are said.
    private var accessibilityValue: String {
        let spoken = snapshot.metricsAccessibilityText(limit: layout.metricLimit)
        return spoken.isEmpty ? snapshot.statusText : "\(snapshot.statusText), \(spoken)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text(snapshot.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(hasMap ? Color.white : .primary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: Stack.spacing) {
                TrailWidgetMetricRow(metrics: metrics, onMap: hasMap)
                statLine
                if let fraction = snapshot.fractionComplete {
                    TrailWidgetProgressBar(fraction: fraction, tint: tint, onMap: hasMap)
                        .padding(.top, Stack.progressTopPadding)
                }
            }
        }
        .shadow(color: .black.opacity(hasMap ? MapTextStyle.shadowOpacity : 0), radius: 2, y: 1)
        .padding(layout.padding)
        // One tap target, so one element — and the title is spoken on every
        // family, including the small one that has no room to draw it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(accessibilityValue)
        // The map is the widget's background rather than a subview, so it
        // runs edge to edge under the text and the system rounds it to the
        // widget's own corner radius. It also means the system can drop it
        // wherever container backgrounds don't belong — StandBy, tinted
        // Home Screens — and the text still stands on its own.
        .containerBackground(for: .widget) {
            ZStack {
                // Shows through only until the first render lands, or if one
                // never does: the fallback glyph needs something behind it.
                Rectangle().fill(.fill.tertiary)

                TrailMapView(
                    polyline: snapshot.polyline,
                    basemaps: basemaps,
                    tint: tint,
                    liveFix: snapshot.liveFix?.coordinate,
                    lineWidth: layout.routeLineWidth
                )

                if hasMap { scrim }
            }
        }
    }

    /// Darkens only the bands the text occupies, so the middle of the map —
    /// where the trail is — keeps its own contrast. The top band is dropped
    /// entirely on sizes with no title to darken it for.
    private var scrim: some View {
        let bottomClear = metrics.isEmpty
            ? Scrim.bottomClearLocation
            : Scrim.bottomClearLocationWithMetrics
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(showsTitle ? Scrim.topOpacity : 0), location: 0),
                .init(color: .clear, location: showsTitle ? Scrim.topClearLocation : 0),
                .init(color: .clear, location: bottomClear),
                .init(color: .black.opacity(Scrim.bottomOpacity), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder private var statLine: some View {
        HStack {
            Text(snapshot.statusText)
                .font(family == .systemSmall ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(hasMap ? Color.white : .secondary)
            Spacer()
            // Only where there's width for it without crowding the status.
            if showsTitle, let timestamp = snapshot.liveFix?.timestamp {
                Text(timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(
                        hasMap
                            ? AnyShapeStyle(Color.white.opacity(MapTextStyle.timestampOpacity))
                            : AnyShapeStyle(.tertiary)
                    )
            }
        }
    }
}

struct TrailWidget: Widget {
    /// Every size this widget offers. Named rather than inlined so a test can
    /// check that each one has a layout to draw with.
    static let supportedFamilies: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]

    var body: some WidgetConfiguration {
        // `AppIntentConfiguration`, not `StaticConfiguration` — the kind is
        // unchanged, which is what carries already-placed widgets across.
        AppIntentConfiguration(
            kind: TrailWidgetKind.id,
            intent: TrailWidgetConfiguration.self,
            provider: TrailWidgetProvider()
        ) { entry in
            TrailWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Trail")
        .description("Shows your selected trail or a hike currently being recorded.")
        .supportedFamilies(Self.supportedFamilies)
    }
}

#Preview(as: .systemSmall) {
    TrailWidget()
} timeline: {
    TrailWidgetEntry(date: .now, snapshot: TrailWidgetProvider.placeholderSnapshot)
    TrailWidgetEntry(
        date: .now,
        snapshot: nil,
        recordingSnapshot: SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: .now.addingTimeInterval(-1200),
            distanceMeters: 1400,
            pointCount: 320,
            polyline: TrailWidgetProvider.placeholderSnapshot.polyline,
            elevationGainMeters: 180,
            averageSpeedMetersPerSecond: 1.2
        )
    )
    TrailWidgetEntry(date: .now, snapshot: nil)
}

#Preview("Following a trail", as: .systemMedium) {
    TrailWidget()
} timeline: {
    TrailWidgetEntry(date: .now, snapshot: TrailWidgetProvider.followedPlaceholderSnapshot)
}
