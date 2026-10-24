//
//  HikeAutoFollow.swift
//  OpenHikes
//
//  Support types for HikeDetailView's auto-follow feature.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesData

/// The elevation graph's tracker positions, held in a reference type so a
/// published location fix moves the chart without re-rendering the rest of
/// `HikeDetailView` (header, stats grid, buttons) — the same technique
/// `RouteHighlight`/`SheetMetrics` use for the map. `HikeDetailView` passes
/// this object down and only touches its properties from event handlers,
/// never from `body`, so mutating them invalidates the views that do read
/// them in their bodies — the graph's moving marks (`ElevationChartMarks`),
/// the position it speaks (`ElevationChartSpokenPosition`), and
/// `TrailProgressView` — and nothing above them, `ElevationChartView`
/// included.
@Observable
final class TrackerState {
    /// Persistent tracker position along the route (metres from start). Starts
    /// at the GPX start, follows the finger while scrubbing, and stays where
    /// it's left.
    var trackerDistance: Double = 0
    /// The user's live GPS fix projected onto the route (metres from start), or
    /// `nil` when auto-follow is off, there's no fix, or the fix is too far
    /// from the trail to match.
    var liveTrackerDistance: Double?
}

/// Matching history changes per fix and is never drawn. Holding it by
/// reference keeps those writes from invalidating the detail screen's body;
/// only `TrackerState` publishes the resulting chart position.
@Observable
final class FollowState {
    /// Independent of the finger-driven tracker: a scrub must not choose the
    /// leg the next fix is matched onto. `nil` lets the first fix seed it.
    @ObservationIgnored var anchor: FollowAnchor?
    @ObservationIgnored var search = OffRouteSearchPolicy()
}

/// The tie-break anchor auto-follow carries from one fix to the next: where
/// the last fix matched along the route, and whether that match was settled
/// by a real direction of travel or merely assumed.
///
/// A value type rather than two `@State` properties so the rule it encodes —
/// when a match may be re-decided from scratch — is one testable thing
/// instead of a condition spread across a SwiftUI view's body.
struct FollowAnchor: Equatable {
    /// Distance along the route of the last match, in metres.
    var distance: Double
    /// Whether that match was settled by a usable course.
    ///
    /// `false` while it rests on nothing better than
    /// ``RouteProfile/nearestPoint(to:near:heading:headingOverridesReference:scope:)``'s assumption that
    /// a hike starts at its start — which is what a hiker gets if they open
    /// the app *standing still* halfway round an out-and-back. They'd be
    /// placed on the outbound leg, and continuity would then hold them there
    /// for the rest of the walk however far they went.
    var isCourseConfirmed: Bool
    /// Consecutive fixes whose course picked a different leg than continuity
    /// did. A hiker who has turned round keeps producing them; one who stopped
    /// to look back down the trail produces a few and then stops.
    var contraryFixes = 0
    /// UI events can ask about the cached fix again. Only a newer receiver
    /// timestamp supplies another piece of evidence about the hiker's course.
    private var lastFixTimestamp: Date?

    /// Fixes whose course must keep contradicting continuity before the
    /// course wins. These must be distinct fixes: finishing a chart scrub or
    /// enabling following can re-read the same cached location.
    static let contraryFixesToSwitch = 3

    /// The distance a fix carrying `course` should be matched against, or
    /// `nil` to work the leg out from scratch.
    ///
    /// An unconfirmed anchor yields to the first fix that actually carries a
    /// course: direction of travel is evidence, and the anchor it would be
    /// replacing is only an assumption. Giving up continuity for that one fix
    /// is the price of getting the leg right, and it's paid at most once —
    /// ``matched(at:course:from:contraryFixes:)`` confirms the anchor from then on.
    static func tieBreak(_ anchor: Self?, course: CLLocationDirection?) -> Double? {
        guard let anchor else { return nil }
        if !anchor.isCourseConfirmed, course != nil { return nil }
        return anchor.distance
    }

    /// Matches one fix and carries its evidence into the next anchor. An
    /// unusable or off-trail fix breaks the run without losing continuity.
    ///
    /// Continuity settles which leg a fix is on, so noise can't flip a hiker
    /// between two. But on a trail that retraces itself the two legs are
    /// equidistant from the anchor at the turn, and continuity then keeps the
    /// hiker on the outbound leg for the whole way home. So once the anchor is
    /// confirmed, the course is asked as a second opinion; it takes over only
    /// after ``contraryFixesToSwitch`` fixes in a row have disagreed.
    static func advance(
        _ anchor: inout Self?,
        on profile: RouteProfile,
        to fix: RouteFix?,
        scope: RouteProfile.SearchScope
    ) -> (distanceAlongRoute: Double, offRouteMeters: Double)? {
        guard let fix else {
            anchor?.contraryFixes = 0
            return nil
        }
        let steady = profile.nearestPoint(
            to: fix.coordinate,
            near: tieBreak(anchor, course: fix.course),
            heading: fix.course,
            scope: scope
        )
        guard let steady,
              steady.offRouteMeters <= RouteProfile.followMatchThresholdMeters else {
            anchor?.contraryFixes = 0
            return steady
        }
        if let previousTimestamp = anchor?.lastFixTimestamp, fix.timestamp <= previousTimestamp {
            return steady
        }

        var match = steady
        var count = 0
        if let previous = anchor, previous.isCourseConfirmed, let course = fix.course {
            let opinion = profile.nearestPoint(
                to: fix.coordinate,
                near: previous.distance,
                heading: course,
                headingOverridesReference: true,
                scope: scope
            )
            if let opinion,
               opinion.offRouteMeters <= RouteProfile.followMatchThresholdMeters,
               abs(opinion.distanceAlongRoute - steady.distanceAlongRoute) > contraryDistanceMeters {
                count = previous.contraryFixes + 1
                if count >= contraryFixesToSwitch {
                    match = opinion
                    count = 0
                }
            }
        }
        var next = matched(at: match.distanceAlongRoute, course: fix.course, from: anchor, contraryFixes: count)
        next.lastFixTimestamp = fix.timestamp
        anchor = next
        return match
    }

    /// How far apart the two answers must be to count as different legs. Two
    /// projections on the same leg differ by metres of noise; two legs of a
    /// retraced stretch differ by twice the distance to the turn.
    private static let contraryDistanceMeters = 5.0

    /// The anchor left behind by a fix that matched at `distance`.
    ///
    /// Confirmation is sticky: once a course has settled which leg the hiker
    /// is on, later fixes without one — they stopped for a photo — can't
    /// unsettle it and start the re-seeding over.
    static func matched(
        at distance: Double,
        course: CLLocationDirection?,
        from previous: Self?,
        contraryFixes: Int = 0
    ) -> Self {
        Self(
            distance: distance,
            isCourseConfirmed: previous?.isCourseConfirmed == true || course != nil,
            contraryFixes: contraryFixes
        )
    }
}

/// Decides how much of the route each live-follow fix is searched against.
///
/// Bounding the search to a window around the last match is what keeps a fix
/// from costing a full-route scan — but a fix with nothing on-route inside the
/// window falls back to scanning the rest of the route, and a hiker who has
/// simply stepped off the trail produces one of those every second. Left
/// alone, being off-route costs exactly what the window was introduced to
/// avoid, for as long as it lasts.
///
/// So the fallback is latched off once it has already come up empty, and
/// re-armed every ``rearmIntervalFixes`` fixes: a hiker who really did rejoin
/// somewhere else — driven round to the far trailhead — is found within half a
/// minute instead of within a second, and the intervening fixes cost a window.
struct OffRouteSearchPolicy: Equatable {
    /// Fixes to spend inside the window before the whole route is searched
    /// again. At the one-a-second publish rate this is about half a minute.
    static let rearmIntervalFixes = 30

    /// Fixes searched against the window since the last whole-route scan came
    /// up empty, or `nil` when the next fix should search the whole route.
    private var fixesSinceEmptyWholeRouteSearch: Int?

    /// The scope the next fix should be searched with.
    var scope: RouteProfile.SearchScope {
        fixesSinceEmptyWholeRouteSearch == nil ? .wholeRoute : .continuityWindow
    }

    init() {
        // The memberwise initialiser is private, since the counter is.
    }

    /// Folds in the outcome of a fix that was searched with `scope`.
    mutating func record(matched: Bool, scope: RouteProfile.SearchScope) {
        guard !matched else {
            fixesSinceEmptyWholeRouteSearch = nil
            return
        }
        switch scope {
        case .wholeRoute: fixesSinceEmptyWholeRouteSearch = 0
        case .continuityWindow:
            let elapsed = (fixesSinceEmptyWholeRouteSearch ?? 0) + 1
            fixesSinceEmptyWholeRouteSearch =
                elapsed < Self.rearmIntervalFixes ? elapsed : nil
        }
    }
}

enum FollowHighlightUpdate {
    case clear
    case move(CLLocationCoordinate2D)
    case unchanged
}

enum FollowInteractionPolicy {
    static func highlightUpdate(
        autoFollowEnabled: Bool,
        isScrubbing: Bool,
        profile: RouteProfile?,
        trackerDistance: Double
    ) -> FollowHighlightUpdate {
        guard !isScrubbing else { return .unchanged }
        if autoFollowEnabled { return .clear }
        guard let coordinate = profile?.coordinate(
            atDistance: trackerDistance
        ) else { return .unchanged }
        return .move(coordinate)
    }

    static func appliesMatchToPersistentTracker(
        isScrubbing: Bool
    ) -> Bool {
        !isScrubbing
    }
}
