//
//  HikeActivityTests.swift
//  OpenHikesSharedTests
//
//  The Live Activity's payload and everything it says, pinned here because
//  this is the widest surface a test can reach: `ActivityConfiguration` is a
//  view tree the system renders out of process, and `Activity` and
//  `ActivityContent` are `@available(macOS, unavailable)` — so the presentation
//  is deliberately a plain value, and this is what checks it.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Hike activity payload")
struct HikeActivityPayloadTests {
    private static func recordingSnapshot(
        distance: Double = 4200,
        points: Int = 812,
        capturing: Bool = true,
        startedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_003_600)
    ) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: startedAt,
            distanceMeters: distance,
            pointCount: points,
            polyline: [],
            elevationGainMeters: 320,
            averageSpeedMetersPerSecond: 1.17,
            isCapturingFixes: capturing,
            updatedAt: updatedAt
        )
    }

    private static func trailSnapshot(
        liveFix: SharedTrailSnapshot.LiveFix? = nil
    ) -> SharedTrailSnapshot {
        SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Thumsee Loop",
            tintHex: "#FF9500",
            totalDistanceMeters: 10_000,
            polyline: [.init(latitude: 47.7, longitude: 12.8)],
            elevationGainMeters: 540,
            liveFix: liveFix
        )
    }

    private static func walk(
        state: SharedTrailSnapshot.Walk.State = .active,
        covered: Double = 0.5,
        activeSeconds: TimeInterval = 2700
    ) -> SharedTrailSnapshot.Walk {
        SharedTrailSnapshot.Walk(
            state: state,
            coveredFraction: covered,
            furthestDistanceMeters: 6200,
            activeSeconds: activeSeconds,
            startedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private static func liveFix(
        distance: Double = 6200,
        offRoute: Double = 8,
        elevation: Double? = 780
    ) -> SharedTrailSnapshot.LiveFix {
        SharedTrailSnapshot.LiveFix(
            coordinate: .init(latitude: 47.7, longitude: 12.8),
            distanceAlongRouteMeters: distance,
            offRouteMeters: offRoute,
            timestamp: .now,
            elevationMeters: elevation
        )
    }

    @Test("a recording's activity is built from the widget's own snapshot")
    func recordingIsBuiltFromTheWidgetSnapshot() {
        let snapshot = Self.recordingSnapshot()
        let attributes = HikeActivityAttributes.recording(
            from: snapshot,
            title: "Morning walk",
            tintHex: "#34C759"
        )

        #expect(attributes.subject == .recording(sessionID: snapshot.sessionID))
        #expect(attributes.startedAt == snapshot.startedAt)
        // No end to measure against; the presentation's whole shape follows.
        #expect(attributes.routeDistanceMeters == nil)

        let state = HikeActivityAttributes.ContentState(recording: snapshot)
        #expect(state.distanceMeters == snapshot.distanceMeters)
        #expect(state.elevationGainMeters == snapshot.elevationGainMeters)
        #expect(state.pointCount == snapshot.pointCount)
        #expect(state.averageSpeedMetersPerSecond == snapshot.averageSpeedMetersPerSecond)
        #expect(!state.isPaused)
    }

    /// `isCapturingFixes` is the recorder's own word for it, and the activity
    /// must not invent a second definition of paused.
    @Test("a recording that stopped capturing reads as paused")
    func pausedFollowsIsCapturingFixes() {
        let state = HikeActivityAttributes.ContentState(
            recording: Self.recordingSnapshot(capturing: false)
        )
        #expect(state.isPaused)
    }

    /// The elapsed figure is carried as a duration precisely so this holds:
    /// the view anchors a self-ticking timer at `timerStart`, and it has to
    /// read back the number the recorder measured.
    @Test("the timer anchor reproduces the elapsed time at the update instant")
    func timerAnchorReproducesElapsed() {
        let updatedAt = Date(timeIntervalSince1970: 1_003_600)
        let state = HikeActivityAttributes.ContentState(
            distanceMeters: 100,
            elapsedSeconds: 3600,
            updatedAt: updatedAt
        )
        #expect(state.timerStart == updatedAt.addingTimeInterval(-3600))
        #expect(updatedAt.timeIntervalSince(state.timerStart) == 3600)
    }

    /// The recorder measures from system uptime so a clock correction can't
    /// make the Lock Screen jump; passing it in is what preserves that.
    @Test("an explicit elapsed time wins over wall-clock arithmetic")
    func explicitElapsedWins() {
        let snapshot = Self.recordingSnapshot()
        let derived = HikeActivityAttributes.ContentState(recording: snapshot)
        #expect(derived.elapsedSeconds == 3600)

        let measured = HikeActivityAttributes.ContentState(
            recording: snapshot,
            elapsedSeconds: 2950
        )
        #expect(measured.elapsedSeconds == 2950)
    }

    @Test("a followed trail's activity is built from the widget's own snapshot")
    func followingIsBuiltFromTheWidgetSnapshot() {
        let snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        let attributes = HikeActivityAttributes.following(from: snapshot)

        #expect(attributes.subject == .following(hikeID: snapshot.hikeID))
        #expect(attributes.title == snapshot.title)
        #expect(attributes.tintHex == snapshot.tintHex)
        #expect(attributes.routeDistanceMeters == snapshot.totalDistanceMeters)

        let state = HikeActivityAttributes.ContentState(following: snapshot)
        #expect(state.distanceMeters == 6200)
        #expect(state.offRouteMeters == 8)
        #expect(state.currentElevationMeters == 780)
        #expect(state.elevationGainMeters == 540)
    }

    /// A hiker who has stepped off the trail is not an error state and not a
    /// reason to end the activity — the trail's own numbers stay, and only the
    /// position is withheld.
    @Test("no live fix withholds the position rather than reporting zero")
    func noLiveFixWithholdsPosition() {
        let state = HikeActivityAttributes.ContentState(
            following: Self.trailSnapshot(liveFix: nil)
        )
        #expect(state.offRouteMeters == nil)
        #expect(state.currentElevationMeters == nil)
        // Still the trail's ascent: that fact doesn't depend on where the
        // hiker is.
        #expect(state.elevationGainMeters == 540)
    }

    /// A walk brings its coverage, its run state and its clock across, and
    /// the trail's own start date gives way to the walk's — that is the
    /// instant the Lock Screen clock has to count from.
    @Test("a walk under way is carried whole into the activity")
    func walkIsCarriedIntoTheActivity() {
        var snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        snapshot.walk = Self.walk(state: .paused)
        let attributes = HikeActivityAttributes.following(from: snapshot, startedAt: .now)
        let state = HikeActivityAttributes.ContentState(following: snapshot)

        #expect(attributes.startedAt == Date(timeIntervalSince1970: 1_000_000))
        #expect(state.coveredFractionComplete == 0.5)
        #expect(state.runState == .paused)
        #expect(state.elapsedSeconds == 2700)
        // Position is still the position: coverage does not replace it.
        #expect(state.distanceMeters == 6200)
    }

    /// A plain follow has no walk state.
    @Test("a state written without walk keys decodes as a plain follow")
    func stateWithoutWalkKeysDecodes() throws {
        let data = Data(
            #"{"distanceMeters":6200,"runState":"running","elapsedSeconds":0,"updatedAt":0}"#.utf8
        )
        let decoded = try JSONDecoder().decode(HikeActivityAttributes.ContentState.self, from: data)
        #expect(decoded.coveredFractionComplete == nil)
        #expect(decoded.runState == .running)
        #expect(decoded.distanceMeters == 6200)
    }

    /// The progress arithmetic has to agree with the widget's, which is what
    /// this compares it against rather than against a hand-computed constant.
    @Test("progress agrees with the widget snapshot it was built from")
    func progressAgreesWithTheWidget() {
        let snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        let attributes = HikeActivityAttributes.following(from: snapshot)
        let state = HikeActivityAttributes.ContentState(following: snapshot)

        #expect(attributes.fractionComplete(for: state) == snapshot.fractionComplete)
        #expect(
            attributes.remainingDistanceMeters(for: state)
                == snapshot.remainingDistanceMeters
        )
    }

    @Test("progress is absent without a fix and clamped past the end")
    func progressIsAbsentOrClamped() {
        let attributes = HikeActivityAttributes.following(
            from: Self.trailSnapshot()
        )
        #expect(attributes.fractionComplete(for: .init(distanceMeters: 0)) == nil)

        let overshot = HikeActivityAttributes.ContentState(
            distanceMeters: 12_000,
            offRouteMeters: 4
        )
        #expect(attributes.fractionComplete(for: overshot) == 1)
        #expect(attributes.remainingDistanceMeters(for: overshot) == 0)
    }

    /// A recording deep-links to the recording screen and a follow to its
    /// hike, through the very functions the widget uses — so a tap lands in
    /// the same place from either surface.
    @Test("the tap target matches the widget's")
    func deepLinksMatchTheWidget() {
        let hikeID = UUID()
        let following = HikeActivityAttributes(
            subject: .following(hikeID: hikeID),
            title: "Ridge",
            tintHex: "#000000",
            startedAt: .now
        )
        #expect(following.deepLink == TrailWidgetDeepLink.url(hikeID: hikeID))
        #expect(following.subject.hikeID == hikeID)
        #expect(!following.subject.isRecording)

        let recording = HikeActivityAttributes(
            subject: .recording(sessionID: UUID()),
            title: "Recording",
            tintHex: "#000000",
            startedAt: .now
        )
        #expect(recording.deepLink == TrailWidgetDeepLink.recordingURL())
        #expect(recording.subject.hikeID == nil)
        #expect(recording.subject.isRecording)
    }

    /// ActivityKit's combined budget for an activity's attributes and its
    /// content state.
    private static let activityBudgetBytes = 4096

    /// What the worst case is allowed to spend of that budget: nine
    /// thirty-seconds — a quarter, plus the one field a walk added to the
    /// content state — so well over two thirds of it stay unspent.
    ///
    /// The limit itself is the wrong threshold to test against. This payload's
    /// whole reason for existing is that the route polyline was left out of
    /// it, and the widget's decimated route is 180 coordinates — kilobytes on
    /// its own. A test that only asked "under 4096?" would pass with fifty
    /// coordinates smuggled back in, which is precisely the regression it is
    /// here to catch, so the useful threshold is one that has no room for
    /// geometry at all. A single `CodableCoordinate` encodes to roughly forty
    /// bytes; the margin left under this ceiling is a handful of them.
    ///
    /// The fit is deliberately tight rather than lucky: ``worstCaseState``
    /// inflates every field to the most its type can print, so the payload
    /// sits just under this line and *any* new field has to come here and
    /// argue for itself. Raising the ceiling is a legitimate answer to that
    /// argument. Not noticing is not.
    ///
    /// The three spare kilobytes are also what covers the title's missing
    /// bound below: they absorb a name several times longer than the one this
    /// test defends, so a hiker who types an unusually long one does not
    /// depend on anybody having re-run these numbers.
    private static let worstCaseCeilingBytes = activityBudgetBytes * 9 / 32

    /// What a single update may cost: an eighth of the budget.
    ///
    /// The attributes are fixed for an activity's whole life, so what actually
    /// crosses to the system every twenty seconds for the length of a walk is
    /// the content state alone. That marginal figure is worth its own bound —
    /// it is the one that recurs, and the one a geometry-carrying field on
    /// ``HikeActivityAttributes/ContentState`` would show up in first.
    private static let updateCeilingBytes = activityBudgetBytes / 8

    /// A trail name at the worst case: 128 characters in a script where they
    /// cost three and four UTF-8 bytes each, rather than 128 bytes of ASCII.
    ///
    /// 128 was this test's own bound for as long as the app had none — the
    /// rename field trimmed whitespace and stored whatever was left, and an
    /// imported GPX `<name>` arrived unbounded. The answer to a hostile
    /// hundred-kilobyte title was always a bound on the title rather than a
    /// smaller payload, and the app now has one: `HikeTitle` bounds every
    /// entry point — the rename field, the Stop alert and the importer — at
    /// 128 characters *and* 512 UTF-8 bytes, the second because a grapheme
    /// cluster has no length limit and a character count alone therefore
    /// bounds nothing about what crosses to the system.
    ///
    /// So this is no longer a hypothesis about what a title might cost. The
    /// 498 bytes below are within a rounding error of the most one can, and
    /// the numbers have to stay in step — the shared package cannot import the
    /// app, so nothing but this sentence connects them. Raising the app's
    /// bound without raising this leaves the payload defended at a case that
    /// can no longer occur.
    private static let worstCaseTitle: String = {
        let name = "北アルプス表銀座縦走路 🏔"
        return name + String(repeating: "🏔", count: 128 - name.count)
    }()

    /// Every optional populated, each at the largest value its type plausibly
    /// takes — `Int.max` points, doubles that print to seventeen significant
    /// digits, and the longest ``RunState`` raw value.
    ///
    /// Assembled by hand because no builder produces it: `init(following:)`
    /// leaves the recording fields `nil` and `init(recording:)` leaves the
    /// trail ones `nil`, so the union of the two is a state the type can
    /// express and nothing constructs. The budget has to hold for that, not
    /// for whichever half today's two call sites happen to build.
    private static let worstCaseState = HikeActivityAttributes.ContentState(
        distanceMeters: 12_345.678901234567,
        elevationGainMeters: 1234.5678901234567,
        currentElevationMeters: 2345.6789012345678,
        averageSpeedMetersPerSecond: 1.2345678901234567,
        pointCount: Int.max,
        offRouteMeters: 3456.789012345678,
        coveredFractionComplete: 0.12345678901234567,
        runState: .finished,
        elapsedSeconds: 456_789.01234567891,
        updatedAt: Date(timeIntervalSinceReferenceDate: 781_234_567.8912345)
    )

    /// Both subjects, because they encode differently: `sessionID` is three
    /// characters longer than `hikeID`, so whichever is larger is not obvious
    /// and neither is worth guessing at.
    private static let worstCaseSubjects: [HikeActivityAttributes.Subject] = [
        .recording(sessionID: UUID()),
        .following(hikeID: UUID()),
    ]

    private static func worstCaseAttributes(
        subject: HikeActivityAttributes.Subject
    ) -> HikeActivityAttributes {
        HikeActivityAttributes(
            subject: subject,
            title: worstCaseTitle,
            // The longest form `Color(hex:)` accepts: "#RRGGBBAA".
            tintHex: "#FF9500FF",
            startedAt: Date(timeIntervalSinceReferenceDate: 781_234_567.8912345),
            routeDistanceMeters: 123_456.78901234567
        )
    }

    /// ActivityKit gives an activity's attributes and content state a combined
    /// 4 KB. That budget is the reason the route polyline was left out, and a
    /// budget nothing checks is a budget that gets spent — a future field that
    /// carries geometry has to fail here rather than on a device.
    ///
    /// Measured at the worst case rather than at a typical one, and against
    /// ``worstCaseCeilingBytes`` rather than against the limit: a twelve
    /// character title tested against 4096 has thousands of bytes of headroom,
    /// which is another way of saying it would not notice the thing it exists
    /// to notice.
    @Test("the worst-case payload spends under a third of ActivityKit's 4 KB budget")
    func payloadFitsTheActivityBudget() throws {
        // The worst case has to still be one. A source file that lost the
        // multi-byte characters would quietly shrink it to a quarter the size
        // and take the assertions below with it.
        #expect(Self.worstCaseTitle.count == 128)
        #expect(Self.worstCaseTitle.utf8.count >= 480)

        let encoder = JSONEncoder()
        let stateBytes = try encoder.encode(Self.worstCaseState).count
        var largestTotal = 0

        for subject in Self.worstCaseSubjects {
            let attributeBytes = try encoder.encode(
                Self.worstCaseAttributes(subject: subject)
            ).count
            let total = attributeBytes + stateBytes
            #expect(total < Self.activityBudgetBytes, "\(subject) encoded to \(total) bytes")
            #expect(total <= Self.worstCaseCeilingBytes, "\(subject) encoded to \(total) bytes")
            largestTotal = max(largestTotal, total)
        }

        // And it has to still *be* a worst case. A field added to
        // `ContentState(following:)` and left `nil` up there would otherwise
        // be weighed at nothing at all.
        let snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        let built = try encoder.encode(HikeActivityAttributes.following(from: snapshot)).count
            + encoder.encode(HikeActivityAttributes.ContentState(following: snapshot)).count
        #expect(built < largestTotal, "the builders encode \(built) bytes to the worst case's \(largestTotal)")
    }

    /// The attributes are fixed for an activity's whole life, so what recurs
    /// on the wire every 20 seconds for the length of a walk is the content
    /// state alone. That marginal figure is the one a geometry-carrying field
    /// would show up in first, and it is bounded well under the total.
    @Test("an update carries the content state alone, at a fraction of the budget")
    func everyUpdateStaysFarInsideTheBudget() throws {
        let stateBytes = try JSONEncoder().encode(Self.worstCaseState).count
        #expect(stateBytes <= Self.updateCeilingBytes, "\(stateBytes) bytes")
    }

    @Test("the payload survives a round trip")
    func payloadRoundTrips() throws {
        let snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        let attributes = HikeActivityAttributes.following(from: snapshot)
        let state = HikeActivityAttributes.ContentState(following: snapshot)

        let decodedAttributes = try JSONDecoder().decode(
            HikeActivityAttributes.self,
            from: JSONEncoder().encode(attributes)
        )
        let decodedState = try JSONDecoder().decode(
            HikeActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decodedAttributes == attributes)
        #expect(decodedState == state)
    }
}
