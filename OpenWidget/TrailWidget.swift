//
//  TrailWidget.swift
//  OpenWidget
//
//  Shows the shape of whichever trail is currently selected in OpenHikes,
//  plus your last-known position along it. Holds the timeline provider, the
//  entry and the recording half of the drawing; the trail half is in
//  TrailWidgetTrailContent.swift. During an active recording it may
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
    /// `var` only so ``droppingWeather(at:)`` can move a copy forward to the
    /// moment the temperature goes off. Nothing else assigns it.
    var date: Date
    let snapshot: SharedTrailSnapshot?
    let recordingSnapshot: SharedRecordingSnapshot?
    /// The map images the app rendered for `snapshot`'s trail, if any — see
    /// `TrailBasemapRenderer` in the app target. Only the manifest is carried
    /// here; the image itself is read at render time by whichever view ends
    /// up needing it, so an entry never holds a decoded bitmap.
    var basemaps: TrailBasemapSet?
    /// The temperature the app's weather badge was last showing, if there is
    /// one and it is still worth drawing.
    ///
    /// Read here rather than in the view for the reason the basemaps are:
    /// building the entry is the moment the store is read, and a view that
    /// reached for the App Group would be doing it once per family per
    /// appearance. Unlike the basemaps it is **not** tied to the trail — it
    /// belongs to whatever the badge is pointed at — so it survives the
    /// recording takeover below and is the one thing both states draw the
    /// same way.
    var weather: SharedWeatherReading?

    /// Pairs a stored snapshot with its basemaps, which are only ever valid
    /// for the hike they were rendered for — and settles the one contention
    /// this widget has.
    ///
    /// **A live recording always outranks the selected trail, and takes the
    /// whole widget rather than a badge or a second line.** They genuinely
    /// overlap: a hiker records their own track along an imported route. The
    /// recording wins because it is the thing that would be *lost* — a follow
    /// is re-derived from the trail and the next fix, a recording is not —
    /// and it is the only one of the two that is happening *now*. It is the
    /// same rule `HikeLiveActivityController.accepts(_:)` applies to the Lock
    /// Screen, applied here so the two surfaces cannot disagree about which
    /// walk is under way. A badge was the alternative and it loses twice
    /// over: the small family has room for the trace or for a trail, not
    /// both, and a secondary state is a second thing to keep fresh on a
    /// budget the recording feed is already spending.
    ///
    /// Total, not conditional. A *paused* recording takes the widget too — it
    /// is a walk the hiker will come back to, and handing the screen back to
    /// a trail mid-hike would be the takeover flickering. The three questions
    /// this payload is asked are therefore deliberately different, and the
    /// difference is the policy rather than an oversight:
    ///
    /// - *Who owns the widget* — a recording exists. Here.
    /// - *Whether it is worth spending on* — the recording is capturing
    ///   fixes. `TrailWidgetProvider.nextReload(after:recording:)` and
    ///   `relevance()`: a paused walk holds the screen but is not worth a
    ///   location sample, a Smart Stack promotion, or a twenty-minute
    ///   timeline.
    /// - *What the Control Center button does* — a recording exists.
    ///   `HikeRecordingControlState`, which is this same question and gives
    ///   this same answer.
    ///
    /// The stored trail is *kept*, not cleared, throughout — nothing here
    /// writes — so the moment the recorder clears its payload the widget's
    /// next timeline has the hiker's selection back untouched, basemaps
    /// included. The takeover is a projection, and only a projection.
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
        // Dropped here rather than at the draw, so the entry is the whole
        // truth about what this timeline shows and a test can ask it.
        weather = SharedStore.loadWeatherReading().flatMap { reading in
            reading.isExpired(asOf: date) ? nil : reading
        }
    }

    /// This same entry at `date`, with the temperature gone.
    ///
    /// The second half of how a reading stops being drawn. The first is the
    /// refresh date — see ``TrailWidgetProvider/nextReload(after:recording:weatherExpiresAt:)``
    /// — and on its own it is a *request*: WidgetKit defers a reload for a
    /// widget that has overrun its budget, or a device in Low Power Mode, and
    /// a single-entry timeline then keeps rendering the expired number for as
    /// long as the deferral lasts. An entry already in the timeline needs no
    /// permission to be shown, so this is what actually empties the corner on
    /// time. It costs no reload: the entries of one timeline are built once.
    func droppingWeather(at date: Date) -> Self {
        var dropped = self
        dropped.date = date
        dropped.weather = nil
        return dropped
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
        context.isPreview
            ? Self.placeholderEntry()
            : Self.currentEntry(pinnedTo: configuration.hike?.id)
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
        let pinned = configuration.hike?.id
        let entry = Self.currentEntry(pinnedTo: pinned)
        guard let recording = entry.recordingSnapshot,
              recording.isCapturingFixes else {
            return Self.currentTimeline(pinnedTo: pinned)
        }
        // Best-effort: the sampler answers whether or not it got a fix, and a
        // timeline is owed either way. Whatever it managed to write is picked
        // up by re-reading the store below.
        await WidgetRecordingLocationSampler.shared.fix(for: recording.sessionID)
        return Self.currentTimeline(pinnedTo: pinned)
    }

    /// What the Smart Stack ranks this widget by.
    ///
    /// A recording in progress is the one moment this widget is the most
    /// useful thing on the stack — the hiker is outdoors, moving, and looking
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
    ///
    /// - Parameter pinnedHikeID: the trail this widget was configured for, or
    ///   `nil` to follow the app's selection — which is what every widget
    ///   placed before #468 decodes as, and what must keep working unchanged.
    ///
    /// **A pinned widget whose trail has no snapshot draws nothing rather than
    /// the selected trail.** Falling back to the selection would be the widget
    /// silently showing a different hike from the one its own settings name,
    /// which is worse than an empty state: it is wrong without saying so.
    ///
    /// The recording is read the same way whatever is pinned, which is the
    /// takeover rule surviving the change — see ``TrailWidgetEntry/init``.
    /// Pinning a trail does not buy a widget an exemption from it.
    static func currentEntry(
        date: Date = .now,
        pinnedTo pinnedHikeID: UUID? = nil
    ) -> TrailWidgetEntry {
        TrailWidgetEntry(
            date: date,
            snapshot: pinnedHikeID.map(SharedStore.loadTrailSnapshot(for:)) ?? SharedStore.load(),
            recordingSnapshot: SharedStore.loadRecording()
        )
    }

    /// The gallery entry and the redacted placeholder.
    ///
    /// Carries the basemaps shipped in the asset catalogue rather than the
    /// nothing the App Group has for a trail that does not exist — see
    /// ``TrailWidgetPlaceholderBasemaps``. Assigned after the fact rather than
    /// taken by ``TrailWidgetEntry/init``, because the initializer's job is to
    /// pair a *stored* snapshot with the images rendered for it, and widening
    /// it to take either would put the one case that has no store into the
    /// path every real entry goes down.
    static func placeholderEntry(date: Date = .now) -> TrailWidgetEntry {
        entry(for: placeholderSnapshot, date: date)
    }

    /// The same trail, part-walked: the one arrangement in which every element
    /// is drawn at once — the chips, the temperature beside them, and the bar
    /// along the bottom.
    static func followedPlaceholderEntry(date: Date = .now) -> TrailWidgetEntry {
        entry(for: followedPlaceholderSnapshot, date: date)
    }

    private static func entry(
        for snapshot: SharedTrailSnapshot,
        date: Date
    ) -> TrailWidgetEntry {
        var entry = TrailWidgetEntry(date: date, snapshot: snapshot)
        entry.basemaps = TrailWidgetPlaceholderBasemaps.set
        return entry
    }

    static func currentTimeline(
        date: Date = .now,
        pinnedTo pinnedHikeID: UUID? = nil
    ) -> Timeline<TrailWidgetEntry> {
        let entry = currentEntry(date: date, pinnedTo: pinnedHikeID)
        let expiry = entry.weather?.expiresAt
        var entries = [entry]
        // The entry that draws no temperature, scheduled for the moment the
        // one above stops being true. See ``TrailWidgetEntry/droppingWeather(at:)``.
        if let expiry, expiry > date {
            entries.append(entry.droppingWeather(at: expiry))
        }
        return Timeline(
            entries: entries,
            policy: .after(
                nextReload(
                    after: date,
                    recording:
                        entry.recordingSnapshot?.isCapturingFixes == true,
                    weatherExpiresAt: expiry
                )
            )
        )
    }

    /// When this timeline asks to be rebuilt.
    ///
    /// - Parameter weatherExpiresAt: when the drawn temperature stops counting
    ///   as current. Brought forward to here rather than left to whichever
    ///   reload happens next, because the two cadences above are wrong for it
    ///   in opposite directions: the safety net would leave a three-hour-old
    ///   reading on screen for another three, and nothing at all would leave
    ///   it there until the hiker next opened the app. One reload, at the
    ///   moment the number goes off, draws the corner empty instead. It can
    ///   only ever move the date *earlier* — a reading that expires next week
    ///   does not buy the widget a week of silence.
    static func nextReload(
        after date: Date,
        recording: Bool = false,
        weatherExpiresAt: Date? = nil
    ) -> Date {
        let scheduled = scheduledReload(after: date, recording: recording)
        guard let weatherExpiresAt, weatherExpiresAt > date else { return scheduled }
        return min(scheduled, weatherExpiresAt)
    }

    private static func scheduledReload(
        after date: Date,
        recording: Bool
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

    /// The Lock Screen families are branched on first because they share none
    /// of the Home Screen drawing — no map, no chips, no container background.
    /// Each of them applies the same recording-outranks-trail precedence the
    /// branches below do; see `TrailWidgetAccessorySubject`.
    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: AccessoryCircularContent(entry: entry)
        case .accessoryRectangular: AccessoryRectangularContent(entry: entry)
        case .accessoryInline: AccessoryInlineContent(entry: entry)
        default: systemContent
        }
    }

    @ViewBuilder private var systemContent: some View {
        if let recording = entry.recordingSnapshot {
            RecordingWidgetContent(
                snapshot: recording,
                weather: entry.weather,
                family: family
            )
        } else if let snapshot = entry.snapshot {
            TrailWidgetContent(
                snapshot: snapshot,
                basemaps: entry.basemaps,
                weather: entry.weather,
                family: family
            )
        } else {
            emptyState
        }
    }

    /// A recording in progress: the trace over a plain fill, with the same
    /// top line a trail draws and deliberately nothing along the bottom.
    ///
    /// **No progress bar, because there is no progress to report.** A trail
    /// has a length to be a fraction of; a recording is a walk of unknown
    /// extent, and every bar that could be drawn for it would be inventing a
    /// denominator — an elapsed-time stripe measures against nothing, and a
    /// filled bar says "done" about a walk that is still happening. The line
    /// on the map is the honest picture of how far it has come, and the
    /// distance chip in the corner is the number.
    private struct RecordingWidgetContent: View {
        let snapshot: SharedRecordingSnapshot
        let weather: SharedWeatherReading?
        let family: WidgetFamily

        private static let glyphSpacing: Double = 5

        private var layout: TrailWidgetLayout {
            TrailWidgetLayout(family: family)
        }

        private var metrics: [TrailWidgetMetric] {
            snapshot.metrics(limit: layout.metricLimit)
        }

        /// What is spoken after the trail's name: how the recording is going,
        /// then the conditions it is going in.
        ///
        /// ``SharedRecordingSnapshot/pointCountText`` rather than
        /// `statusText`, whose other half is the distance — which is a chip
        /// here now and would otherwise be read out twice.
        private var accessibilityValue: String {
            TrailWidgetSpeech.value(
                status: snapshot.pointCountText,
                metrics: snapshot.metricsAccessibilityText(limit: layout.metricLimit),
                weather: weather
            )
        }

        /// The one thing the removed title row still had to say: whether fixes
        /// are still arriving. A different shape rather than only a different
        /// colour, so a paused recording reads as paused without the reader
        /// having to tell red from grey.
        ///
        /// It survives the status line it used to sit beside, and leads the
        /// top row instead. The words are gone from the widget but not from
        /// VoiceOver, which still speaks `statusText`; this is the only thing
        /// left that says "paused" to someone looking at it.
        private var stateGlyph: some View {
            Image(systemName: snapshot.isCapturingFixes ? "circle.fill" : "pause.fill")
                .font(.caption2)
                .foregroundStyle(snapshot.isCapturingFixes ? Color.red : Color.secondary)
                .accessibilityHidden(true)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                TrailWidgetHeaderRow(metrics: metrics, onMap: false) {
                    HStack(spacing: Self.glyphSpacing) {
                        stateGlyph
                        if let weather {
                            TrailWidgetTemperature(text: weather.formatted(), onMap: false)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            // Read as one thing: whether a recording is running, then how it
            // is going. The title is no longer drawn, but VoiceOver still
            // leads with it — it is the only place the paused state is put
            // into words. See ``View/trailWidgetCanvas(padding:label:value:background:)``.
            .trailWidgetCanvas(
                padding: layout.padding,
                label: snapshot.title,
                value: accessibilityValue
            ) {
                // Never a rendered basemap: the recording map is the raw
                // trace over a plain fill, so the text above is on a light
                // surface, takes the standard label colours, and needs no
                // scrim — unlike a trail's.
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

struct TrailWidget: Widget {
    /// The Home Screen sizes: a map between a line of figures and a progress
    /// hairline. Named rather than inlined so a test can check that each one
    /// has a ``TrailWidgetLayout`` to draw with — which is a question only
    /// these three are asked, because they are the only ones that draw a map.
    ///
    /// `.systemExtraLarge` is deliberately absent: it exists on iPad and the
    /// Mac, and every target here declares `TARGETED_DEVICE_FAMILY = 1`, so
    /// offering it advertised a size no hiker could ever place.
    static let systemFamilies: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]

    /// The Lock Screen sizes, drawn by `TrailWidgetAccessories.swift`. They
    /// share the entry and the deep link and none of the drawing: no map, no
    /// chips, and therefore no `TrailWidgetLayout`.
    static let accessoryFamilies: [WidgetFamily] = [
        .accessoryCircular,
        .accessoryRectangular,
        .accessoryInline,
    ]

    /// Every size this widget offers.
    static let supportedFamilies: [WidgetFamily] = systemFamilies + accessoryFamilies

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
    TrailWidgetProvider.followedPlaceholderEntry()
    TrailWidgetProvider.placeholderEntry()
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
    TrailWidgetProvider.followedPlaceholderEntry()
}

#Preview("Following a trail", as: .systemLarge) {
    TrailWidget()
} timeline: {
    TrailWidgetProvider.followedPlaceholderEntry()
}

#Preview("Lock Screen, circular", as: .accessoryCircular) {
    TrailWidget()
} timeline: {
    TrailWidgetProvider.followedPlaceholderEntry()
    TrailWidgetProvider.placeholderEntry()
    TrailWidgetEntry(date: .now, snapshot: nil)
}

#Preview("Lock Screen, rectangular", as: .accessoryRectangular) {
    TrailWidget()
} timeline: {
    TrailWidgetProvider.followedPlaceholderEntry()
    TrailWidgetEntry(date: .now, snapshot: nil)
}

#Preview("Lock Screen, inline", as: .accessoryInline) {
    TrailWidget()
} timeline: {
    TrailWidgetProvider.followedPlaceholderEntry()
    TrailWidgetEntry(date: .now, snapshot: nil)
}
