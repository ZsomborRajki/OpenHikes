//
//  SeededWatchFixture.swift
//  OpenHikesWatch
//
//  A watch with a phone's worth of state on it, and no phone.
//
//  ## What this stands in for
//
//  Everything on this app's screens arrives over `WCSession`: the library is
//  an application context, the trail is a transfer, the phone's recording is a
//  message. A watch simulator has no paired phone, so every one of those is
//  permanently absent and the app draws its empty state — correctly, and
//  uselessly for a screenshot.
//
//  So this builds the same payloads the phone would have sent and hands them
//  to ``WatchModel`` directly. They are the real types, not stand-ins for
//  them: a fixture that built its own shapes would be a second definition of
//  the link's payloads, and the screens would be drawing something no phone
//  can produce.
//
//  ## The position is matched, not invented
//
//  ``WatchFollowState`` holds a `WatchRouteTracker.Position`, and this does
//  not construct one — it runs a coordinate taken off the seeded route through
//  the real ``WatchRouteTracker``, which is the same call `WatchModel` makes
//  for a real fix. The figures on the screen are therefore the figures that
//  trail and that place genuinely produce, down to the off-trail distance.
//  There is no other way in any case: `Position`'s memberwise initialiser is
//  internal to the shared package.
//
//  ## Why the recording is not a real one
//
//  Because a real one is an `HKWorkoutSession` and a Core Location feed, and
//  both are wrong here for the same reason: a screenshot wants a walk four
//  kilometres in, and neither can be asked for one — a session started now
//  reads zero, and waiting for it to read anything else is waiting for a
//  simulator to be walked. ``WatchRecorder/applySeededRecording(_:stats:)``
//  sets the phase and the figures and starts neither.
//

#if DEBUG
import Foundation
import OpenHikesShared

/// The state a `--ui-test-*` launch asked the watch to be in.
///
/// Built once, from ``WatchLaunchEnvironment/configuration``, and applied by
/// ``WatchModel/applySeededFixture()``.
@MainActor
struct SeededWatchFixture {
    /// The trails the list shows. Real Bavarian walks around the seeded
    /// route's own valley, for the reason `SeededCuratedTrailSource` was given
    /// plausible names on the phone: "Seeded Valley Path" in a store listing
    /// reads as a screenshot somebody forgot to replace.
    private static let names = [
        "Rinnkendlsteig",
        "Kührointalm and Back",
        "Malerwinkel Loop",
        "Jenner Summit",
        "Hintersee to Klausbachtal",
        "Obersee and Röthbachfall",
        "Soleleitungsweg",
        "Grünstein via the Kühroint",
        "Watzmannhaus Approach",
        "Almbachklamm",
        "Hochkalter Ridge",
        "Wimbachgries",
    ]

    /// Stable identifiers, so two launches of the same frame produce the same
    /// trail — a fixture built on `UUID()` would hand the map screen a
    /// different hike every run, and `WatchModel.selectTrail` compares them.
    private static func identifier(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "6F1B7C3A-0000-4000-8000-%012d", index))
            // Unreachable: the format above is a well-formed UUID for every
            // `Int` this is called with. Spelled out rather than forced,
            // because a `!` in a fixture is a crash in a debug build.
            ?? UUID()
    }

    /// The one the trail screens open. First, so the list's top row and the
    /// map frame are the same walk — two frames of one trail read as an app,
    /// two frames of two read as a gallery.
    ///
    /// Exposed so `WatchRootView` can seed a navigation path with it without
    /// reading the model, which its body is not allowed to do.
    static var openTrail: (id: UUID, name: String) { (openTrailID, names[0]) }

    private static let openTrailID = identifier(1)

    let library: WatchLibraryDigest
    let trail: WatchTrailPackage?
    let position: WatchRouteTracker.Position?
    let recording: (phase: WatchRecorder.Phase, stats: WatchWalkAccumulatorSnapshot)?
    let heartRateBPM: Double?
    let phoneRecording: WatchPhoneRecording?
    let queuedWalkCount: Int

    init(configuration: WatchLaunchEnvironment.Configuration) {
        library = Self.library(count: configuration.seededTrailCount)
        trail = configuration.holdsTrail ? Self.trail : nil
        position = configuration.followFraction.flatMap { Self.position(at: $0) }
        recording = configuration.watchRecording.map(Self.recording(_:))
        // Only while a recording is running: the heart rate is a live sample
        // from the workout session, and a figure on screen with no session
        // behind it would be the one number here that could not happen.
        heartRateBPM = configuration.watchRecording == nil ? nil : Self.seededHeartRateBPM
        phoneRecording = configuration.phoneRecording.map(Self.phoneRecording(_:))
        queuedWalkCount = configuration.queuedWalkCount
    }

    // MARK: The library

    private static func library(count: Int) -> WatchLibraryDigest {
        guard count > 0 else { return .empty }
        let hikes = (0..<min(count, names.count)).map { index in
            let shape = dayShapes[index % dayShapes.count]
            return SharedHikeSummary(
                id: identifier(index + 1),
                name: names[index],
                date: sentAt.addingTimeInterval(Double(index) * -daysBetweenWalks * secondsPerDay),
                distanceMeters: shape.distanceMeters,
                durationSeconds: shape.durationSeconds
            )
        }
        return WatchLibraryDigest(hikes: hikes, sentAt: sentAt)
    }

    /// When the phone last sent anything.
    ///
    /// A fixed morning rather than `.now`, because the rows print a date: a
    /// fixture anchored to the clock gives a different set of dates every run,
    /// which is a screenshot that cannot be compared with the one it replaces.
    private static let sentAt = Date(timeIntervalSince1970: fixtureEpoch)
    /// 2026-09-06, the morning the seeded GPX sets off on.
    private static let fixtureEpoch = 1_788_768_000.0
    private static let secondsPerDay = 86_400.0
    /// Far enough apart that no two rows print the same date, close enough
    /// that the list reads as one season rather than one a year.
    private static let daysBetweenWalks = 9.0
    private static let seededHeartRateBPM = 118.0

    /// One day out: how far it went and how long it took.
    private struct DayShape {
        let distanceMeters: Double
        let durationSeconds: TimeInterval
    }

    /// Lengths and times that read as a list of real days out — a short
    /// afternoon, a full day, several in between — rather than one number
    /// repeated down the screen.
    ///
    /// Text for the reason ``SeededWatchRoute/table`` is: `no_magic_numbers`
    /// flags every element of a numeric array literal, named constant or not.
    private static let dayShapes: [DayShape] = """
        10600 17100
        7400 11700
        3200 4500
        12900 21600
        6100 9900
        9800 15300
        4500 6300
        8200 13500
        """
        .split(separator: "\n")
        .compactMap { row in
            let field = row.split(separator: " ")
            guard field.count == 2,
                  let distance = Double(field[0]),
                  let duration = Double(field[1])
            else { return nil }
            return DayShape(distanceMeters: distance, durationSeconds: duration)
        }

    // MARK: The trail

    private static var trail: WatchTrailPackage {
        WatchTrailPackage(
            hikeID: openTrailID,
            title: names[0],
            // The app's own default green, so the line on the watch is the
            // line the phone draws for a hike nobody has restyled.
            tintHex: "#1B7F3B",
            totalDistanceMeters: SeededWatchRoute.totalDistanceMeters,
            points: SeededWatchRoute.points,
            elevationGainMeters: SeededWatchRoute.elevationGainMeters,
            elevationLossMeters: SeededWatchRoute.elevationLossMeters,
            sentAt: sentAt
        )
    }

    /// A fix a little way off the route, matched through the real tracker.
    ///
    /// Off the line rather than on it, by about the width of a path, because
    /// the figure it produces — "12 m off" — is the one the screen exists to
    /// show. A fix placed exactly on a route point reads "0 m off", which is
    /// a number no receiver has ever reported.
    private static func position(at fraction: Double) -> WatchRouteTracker.Position? {
        let points = SeededWatchRoute.points
        guard points.count > 1 else { return nil }
        var tracker = WatchRouteTracker(trail)
        let index = min(Int((Double(points.count - 1) * fraction).rounded()), points.count - 1)
        let point = points[index]
        // East rather than north, so the offset is the same size wherever on
        // the route it lands.
        let offset = offRouteMeters / (metersPerDegreeLongitude * cos(point.latitude * .pi / 180))
        return tracker.advance(
            latitude: point.latitude,
            longitude: point.longitude + offset,
            courseDegrees: nil
        )
    }

    /// How far off the line the seeded fix falls.
    ///
    /// About the width of a path, and well inside
    /// ``WatchRouteTracker/matchThresholdMeters`` — so the screen reads "On",
    /// which is the state a listing wants, arrived at by matching rather than
    /// by being told. A fix placed exactly on a route point would match too,
    /// and would do it from a coordinate no receiver has ever reported.
    private static let offRouteMeters = 12.0
    private static let metersPerDegreeLongitude = 111_320.0

    // MARK: The recordings

    /// Four kilometres and change, an hour and a half in, 342 m of climb: a
    /// walk far enough along that every figure on the screen has something in
    /// it, and not so far that the pace reads as a run.
    private static let walkedMeters = 4180.0
    private static let walkedSeconds = 5460.0
    private static let climbedMeters = 342.0
    private static let keptFixes = 1143

    private static func recording(
        _ state: WatchLaunchEnvironment.RecordingState
    ) -> (phase: WatchRecorder.Phase, stats: WatchWalkAccumulatorSnapshot) {
        let stats = WatchWalkAccumulatorSnapshot(
            distanceMeters: walkedMeters,
            activeSeconds: walkedSeconds,
            elevationGainMeters: climbedMeters,
            averageSpeedMetersPerSecond: walkedMeters / walkedSeconds,
            fixCount: keptFixes
        )
        return (state == .paused ? .paused : .recording, stats)
    }

    private static func phoneRecording(
        _ state: WatchLaunchEnvironment.RecordingState
    ) -> WatchPhoneRecording {
        WatchPhoneRecording(
            state: state == .paused ? .paused : .recording,
            elapsedSeconds: walkedSeconds,
            distanceMeters: walkedMeters,
            trailName: names[0],
            isTrailNameStale: false,
            updatedAt: .now
        )
    }
}
#endif
