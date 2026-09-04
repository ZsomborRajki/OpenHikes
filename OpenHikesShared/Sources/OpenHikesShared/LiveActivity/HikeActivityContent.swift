//
//  HikeActivityContent.swift
//  OpenHikesShared
//
//  Turns the two payloads the home screen widget already reads into a Live
//  Activity's attributes and content state.
//
//  These are the whole reason the activity shows "very similar data" to the
//  widget rather than merely similar-looking data: there is no second path
//  that computes an ascent or a percentage complete. Both surfaces are built
//  from ``SharedRecordingSnapshot`` and ``SharedTrailSnapshot``, so a change
//  to how a distance is derived reaches both or neither.
//

import Foundation

public extension HikeActivityAttributes {
    /// The fixed half of a recording's activity.
    ///
    /// A recording has no route and therefore no ``routeDistanceMeters``:
    /// nothing knows how far this walk is going to be, which is why its
    /// presentation leads with elapsed time and distance walked rather than
    /// with a percentage.
    static func recording(
        sessionID: UUID,
        title: String,
        tintHex: String,
        startedAt: Date
    ) -> Self {
        Self(
            subject: .recording(sessionID: sessionID),
            title: title,
            tintHex: tintHex,
            startedAt: startedAt
        )
    }

    /// The fixed half of a recording's activity, taken from the payload the
    /// widget is already being handed.
    static func recording(
        from snapshot: SharedRecordingSnapshot,
        title: String,
        tintHex: String
    ) -> Self {
        recording(
            sessionID: snapshot.sessionID,
            title: title,
            tintHex: tintHex,
            startedAt: snapshot.startedAt
        )
    }

    /// The fixed half of a followed trail's activity.
    ///
    /// - Parameter startedAt: what to order the activity by when the trail
    ///   is merely being followed. A walk under way carries its own start,
    ///   and that one wins: it is the instant the walk's clock counts from.
    static func following(
        from snapshot: SharedTrailSnapshot,
        startedAt: Date = .now
    ) -> Self {
        Self(
            subject: .following(hikeID: snapshot.hikeID),
            title: snapshot.title,
            tintHex: snapshot.tintHex,
            startedAt: snapshot.walk?.startedAt ?? startedAt,
            routeDistanceMeters: snapshot.totalDistanceMeters
        )
    }

    /// Whether `other` describes the same walk as this — which is what decides
    /// between updating a running activity and ending it to start another.
    ///
    /// Compares the subject alone. A trail renamed or re-tinted mid-walk is
    /// still the same walk, and ending a Live Activity to restart it would
    /// cost the walker their place on the Lock Screen for a cosmetic change
    /// ActivityKit cannot deliver any other way.
    func describesSameWalk(as other: Self) -> Bool {
        subject == other.subject
    }
}

public extension HikeActivityAttributes.ContentState {
    /// A recording's live figures.
    ///
    /// - Parameter elapsedSeconds: the recorder's monotonic elapsed time.
    ///   Passed in rather than derived from the snapshot's dates because the
    ///   recorder measures from system uptime — so a clock correction mid-hike
    ///   cannot make the Lock Screen timer jump — and subtracting two wall
    ///   clock dates here would throw that away. Defaults to the wall clock
    ///   arithmetic for callers that have no better answer, which is the same
    ///   fallback `HikeRecorder.elapsedSeconds()` uses for a recovered session.
    init(
        recording snapshot: SharedRecordingSnapshot,
        elapsedSeconds: TimeInterval? = nil
    ) {
        self.init(
            distanceMeters: snapshot.distanceMeters,
            elevationGainMeters: snapshot.elevationGainMeters,
            averageSpeedMetersPerSecond: snapshot.averageSpeedMetersPerSecond,
            pointCount: snapshot.pointCount,
            runState: snapshot.isCapturingFixes ? .running : .paused,
            elapsedSeconds: elapsedSeconds ?? max(
                0,
                snapshot.updatedAt.timeIntervalSince(snapshot.startedAt)
            ),
            updatedAt: snapshot.updatedAt
        )
    }

    /// A followed trail's live figures.
    ///
    /// A snapshot with no ``SharedTrailSnapshot/liveFix`` is not an error and
    /// not a reason to end the activity — it is a walker who has stepped off
    /// the trail or lost signal, and the right thing to show is the trail's
    /// own numbers with the position withheld. That is exactly what leaving
    /// `offRouteMeters` and `currentElevationMeters` `nil` says.
    ///
    /// A walk under way brings three more: its coverage, its run state and
    /// its clock. Without one the state reads as it always did — running,
    /// with a clock at zero that the presentation never draws.
    init(following snapshot: SharedTrailSnapshot) {
        self.init(
            distanceMeters: snapshot.liveFix?.distanceAlongRouteMeters ?? 0,
            elevationGainMeters: snapshot.elevationGainMeters,
            currentElevationMeters: snapshot.liveFix?.elevationMeters,
            offRouteMeters: snapshot.liveFix?.offRouteMeters,
            coveredFractionComplete: snapshot.walk?.coveredFraction,
            runState: snapshot.walk.map { walk in RunState(walkState: walk.state) } ?? .running,
            elapsedSeconds: snapshot.walk?.activeSeconds ?? 0,
            updatedAt: snapshot.updatedAt
        )
    }

    /// Whether this differs from `other` by enough to be worth an update.
    ///
    /// ActivityKit throttles an app that updates too often, and the budget is
    /// shared with everything else the app puts on the Lock Screen. Distance
    /// under the threshold is invisible at the width these numbers are drawn
    /// at, so an update carrying only that is spent budget and nothing else —
    /// whereas pausing, resuming, or stepping off the trail changes what the
    /// activity *says* and must never be throttled away.
    ///
    /// The elapsed clock is deliberately not a reason: it ticks by itself
    /// through ``timerStart``.
    func warrantsUpdate(
        comparedTo other: Self,
        distanceThresholdMeters: Double = 25
    ) -> Bool {
        if runState != other.runState { return true }
        if (offRouteMeters == nil) != (other.offRouteMeters == nil) { return true }
        return abs(distanceMeters - other.distanceMeters) >= distanceThresholdMeters
    }

    /// The same figures, marked as a walk that has ended.
    ///
    /// What a saved recording leaves on the Lock Screen for a few minutes
    /// afterwards: a stopped clock and a total. A marker rather than a
    /// recalculation — the caller that knows the walk is over also knows its
    /// final figures, and deriving them a second time here is how the panel
    /// and the saved hike would come to disagree.
    func finished() -> Self {
        var copy = self
        copy.runState = .finished
        return copy
    }
}

public extension HikeActivityAttributes.ContentState.RunState {
    /// The walk's own three words, as the activity says them.
    init(walkState: SharedTrailSnapshot.Walk.State) {
        switch walkState {
        case .active: self = .running
        case .paused: self = .paused
        case .finished: self = .finished
        }
    }
}
