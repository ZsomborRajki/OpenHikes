//
//  WalkTimeLeft.swift
//  OpenHikes
//
//  How long the rest of a followed trail takes, which is the half of "how far
//  is left" a hiker late in the afternoon actually wants.
//
//  ## The signposts first, then the hiker
//
//  The rest of the route is estimated the way a planned one is — DIN 33466,
//  ``WalkingTimeEstimate`` — over the distance left and what the line climbs
//  and drops between the hiker and its end. Then, once the walk has covered
//  enough to say, it is scaled by how this hiker compares with the signposts
//  *today*: the active time they have spent over what the same rule says the
//  covered stretches should have taken. The hiker's own pace beats any
//  formula, and it beats it most on exactly the days — tired, heavily laden,
//  in snow — when the time left matters.
//
//  The scale is bounded both ways. A hiker who sprinted the first kilometre,
//  or stood at a viewpoint for twenty minutes of it, is not going to walk the
//  rest at twice or half the signposts' pace, and an estimate that swung that
//  far on the first stretch would be the least trustworthy figure on screen.
//
//  ## When there is no figure
//
//  With no heights on the route and no calibration yet there is nothing to
//  say but the flat pace, which is out by a factor of two on an alpine route —
//  so that case answers `nil` rather than a figure. Once the walk has
//  calibrated itself the flat estimate is scaled by a pace that already
//  includes whatever the hiker has been climbing, and is worth showing.
//
//  ## Which way the walk is going
//
//  A walk can cover the route from its stored end back to its start —
//  ``TrailWalkRecord/reachesEnd(atMatch:)`` finishes either way — and a loop
//  is walked backwards as often as not. Then what is ahead is the stretch from
//  the start to the hiker, and its climbs are descents: DIN 33466 times the
//  two differently, so both have to turn round. The direction is read off the
//  coverage, which lies behind the hiker whichever way they walk.
//

import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated enum WalkTimeLeft {
    /// How much of the route a walk has to have covered before its own pace
    /// is trusted over the signposts'.
    static let calibrationMeters = 1000.0
    /// How long it has to have been walking, for the same reason: a kilometre
    /// in four minutes is a downhill jog, not a pace.
    static let calibrationSeconds: TimeInterval = 15 * 60
    /// How far the hiker's own pace may move the estimate, as a factor on the
    /// signposts'.
    static let paceFactorBounds = 0.5...2.0

    /// Seconds to the end of the route, or `nil` when there is nothing honest
    /// to say — see the file header.
    ///
    /// - Parameters:
    ///   - position: where the hiker was last matched, in metres along the
    ///     route. The climb still to come is measured from here to the end.
    ///   - remainingMeters: the distance left, as the readout beside this
    ///     figure states it — coverage rather than position, for a walk.
    ///   - covered: the stretches this walk has actually spanned.
    ///   - activeSeconds: the walk's clock with its pauses taken out.
    static func seconds(
        profile: RouteProfile,
        position: Double,
        remainingMeters: Double,
        covered: [ClosedRange<Double>],
        activeSeconds: TimeInterval
    ) -> TimeInterval? {
        guard remainingMeters.isFinite, remainingMeters > 0 else { return nil }
        let reversed = isReversed(position: position, covered: covered, routeMeters: profile.totalDistanceMeters)
        let ahead = reversed
            ? climb(profile, from: 0, to: position, reversed: true)
            : climb(profile, from: position, to: profile.totalDistanceMeters, reversed: false)
        let pace = paceFactor(profile: profile, covered: covered, activeSeconds: activeSeconds, reversed: reversed)
        // Neither heights nor a calibrated pace: a flat figure is the error
        // this exists to correct.
        guard ahead != nil || pace != nil else { return nil }
        let signposts = WalkingTimeEstimate.seconds(
            distanceMeters: remainingMeters,
            ascentMeters: ahead?.gainMeters ?? 0,
            descentMeters: ahead?.lossMeters ?? 0
        )
        return signposts * (pace ?? 1)
    }

    /// How this walk compares with the signposts so far, as a factor on their
    /// time, or `nil` until it has covered ``calibrationMeters`` in
    /// ``calibrationSeconds``. `reversed` is a walk from the stored end
    /// towards the start, whose covered stretches were climbed the other way.
    static func paceFactor(
        profile: RouteProfile,
        covered: [ClosedRange<Double>],
        activeSeconds: TimeInterval,
        reversed: Bool = false
    ) -> Double? {
        let coveredMeters = covered.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard coveredMeters >= calibrationMeters,
              activeSeconds >= calibrationSeconds else { return nil }
        var gain = 0.0
        var loss = 0.0
        for stretch in covered {
            guard let stretchClimb = climb(
                profile,
                from: stretch.lowerBound,
                to: stretch.upperBound,
                reversed: reversed
            ) else { continue }
            gain += stretchClimb.gainMeters
            loss += stretchClimb.lossMeters
        }
        let expected = WalkingTimeEstimate.seconds(
            distanceMeters: coveredMeters,
            ascentMeters: gain,
            descentMeters: loss
        )
        guard expected > 0 else { return nil }
        return min(max(activeSeconds / expected, paceFactorBounds.lowerBound), paceFactorBounds.upperBound)
    }

    /// Whether the walk is heading for the route's stored start — see the
    /// file header.
    ///
    /// More coverage beyond the hiker than before them means they came from
    /// the far end. With none either side yet, the first fix of a walk, the
    /// nearer end is where they set off from.
    static func isReversed(position: Double, covered: [ClosedRange<Double>], routeMeters: Double) -> Bool {
        var behind = 0.0
        var beyond = 0.0
        for stretch in covered {
            behind += max(0, min(stretch.upperBound, position) - stretch.lowerBound)
            beyond += max(0, stretch.upperBound - max(stretch.lowerBound, position))
        }
        guard behind == beyond else { return beyond > behind }
        return position > routeMeters / 2
    }

    /// ``RouteProfile/climb(from:to:)`` walked the way the hiker walks it:
    /// towards the stored start, a stretch's ascents are its descents.
    private static func climb(
        _ profile: RouteProfile,
        from start: Double,
        to end: Double,
        reversed: Bool
    ) -> (gainMeters: Double, lossMeters: Double)? {
        guard let climb = profile.climb(from: start, to: end) else { return nil }
        return reversed ? (climb.lossMeters, climb.gainMeters) : climb
    }
}
