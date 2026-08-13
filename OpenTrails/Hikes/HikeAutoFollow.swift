//
//  HikeAutoFollow.swift
//  OpenTrails
//
//  Support types for HikeDetailView's auto-follow feature.
//

import CoreLocation
import Observation

/// The elevation graph's tracker positions, held in a reference type so the
/// once-a-second auto-follow poll moves the chart without re-rendering the
/// rest of `HikeDetailView` (header, stats grid, buttons) — the same
/// technique `RouteHighlight`/`SheetMetrics` use for the map. `HikeDetailView`
/// only ever passes this object down; it never reads its properties directly,
/// so mutating them invalidates `ElevationChartView` (which does read them)
/// and nothing above it.
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
    /// ``RouteProfile/nearestPoint(to:near:heading:)``'s assumption that a
    /// hike starts at its start — which is what a walker gets if they open
    /// the app *standing still* halfway round an out-and-back. They'd be
    /// placed on the outbound leg, and continuity would then hold them there
    /// for the rest of the walk however far they went.
    var isCourseConfirmed: Bool

    /// The distance a fix carrying `course` should be matched against, or
    /// `nil` to work the leg out from scratch.
    ///
    /// An unconfirmed anchor yields to the first fix that actually carries a
    /// course: direction of travel is evidence, and the anchor it would be
    /// replacing is only an assumption. Giving up continuity for that one fix
    /// is the price of getting the leg right, and it's paid at most once —
    /// ``matched(at:course:from:)`` confirms the anchor from then on.
    static func tieBreak(_ anchor: Self?, course: CLLocationDirection?) -> Double? {
        guard let anchor else {
            return nil
        }
        if !anchor.isCourseConfirmed, course != nil {
            return nil
        }
        return anchor.distance
    }

    /// The anchor left behind by a fix that matched at `distance`.
    ///
    /// Confirmation is sticky: once a course has settled which leg the walker
    /// is on, later fixes without one — they stopped for a photo — can't
    /// unsettle it and start the re-seeding over.
    static func matched(
        at distance: Double,
        course: CLLocationDirection?,
        from previous: Self?
    ) -> Self {
        Self(
            distance: distance,
            isCourseConfirmed: previous?.isCourseConfirmed == true || course != nil
        )
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
        guard !isScrubbing else {
            return .unchanged
        }
        if autoFollowEnabled {
            return .clear
        }
        guard let coordinate = profile?.coordinate(
            atDistance: trackerDistance
        ) else {
            return .unchanged
        }
        return .move(coordinate)
    }

    static func appliesMatchToPersistentTracker(
        isScrubbing: Bool
    ) -> Bool {
        !isScrubbing
    }
}
