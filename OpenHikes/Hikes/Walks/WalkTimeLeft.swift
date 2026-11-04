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
//  ``WalkingTimeEstimate`` — over the distance from the hiker to the end they
//  are going for, and what the line climbs and drops on the way there. Then,
//  once the walk has covered enough to say, it is scaled by how this hiker
//  compares with the signposts *today*: the active time they have spent over
//  what the same rule says the covered stretches should have taken. The
//  hiker's own pace beats any formula, and it beats it most on exactly the
//  days — tired, heavily laden, in snow — when the time left matters.
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
//  two differently, so both have to turn round. Which way is ahead is
//  ``TrailWalkCoverage/direction``: the way the walk's matches last moved a
//  turn's length, in the order they landed.
//
//  Not the stretches covered, which keep no order. A hiker who walked 8 km up
//  and turned back has most of that ground on the side they are walking
//  towards for kilometres, and it read as carrying on, with the summit still
//  to climb (#1195). Only a walk that has not yet moved a turn's length has
//  nothing better than the coverage, and there it is behind the hiker
//  whichever way they set off.
//
//  The way ahead is the distance as well as the climb —
//  ``metersAhead(position:coverage:routeMeters:)`` — and not the ground the
//  walk has yet to cover. The same hiker, turned back at 8 km of 10 and now
//  at 6.5 km, has 6.5 km to the start and none of the 2 km beyond the turn:
//  timed over those 2 km, the signposts said 40 minutes for a walk of 107,
//  and the after-dark warning, which reads this figure, could stay quiet for
//  a hiker who will be out after dark (#1304). The readout beside the figure
//  states the same distance, ``TrailWalkSession/metersLeft``, and leaves the
//  coverage to the percentage hiked.
//
//  What is behind needs no guess. The coverage keeps which way each stretch
//  was walked (#1012), so the calibration measures the signposts' time for
//  each one the way the hiker climbed it — ``RouteProfile/climb(walking:)``,
//  the share card's figure — over the length of those directed stretches.
//  Turning the whole union round by the way ahead timed a walk that turned
//  back against a climb it never made, and a stretch walked there and back
//  counted once against twice the time (#1039).
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

    /// Seconds to the end the walk is going for, or `nil` when there is
    /// nothing honest to say — see the file header.
    ///
    /// - Parameters:
    ///   - position: where the hiker was last matched, in metres along the
    ///     route. The distance and the climb still to come are both measured
    ///     from here to the end the walk is going for.
    ///   - coverage: the stretches this walk has actually spanned, each the
    ///     way it was walked, and the way it is going now.
    ///   - activeSeconds: the walk's clock with its pauses taken out.
    static func seconds(
        profile: RouteProfile,
        position: Double,
        coverage: TrailWalkCoverage,
        activeSeconds: TimeInterval
    ) -> TimeInterval? {
        let remainingMeters = metersAhead(
            position: position,
            coverage: coverage,
            routeMeters: profile.totalDistanceMeters
        )
        guard remainingMeters.isFinite, remainingMeters > 0 else { return nil }
        let ahead = climbAhead(profile: profile, position: position, coverage: coverage)
        let pace = paceFactor(profile: profile, coverage: coverage, activeSeconds: activeSeconds)
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

    /// What the line climbs and drops between `position` and the end the walk
    /// is going for, as the hiker will meet it, or `nil` with no heights
    /// there — see the file header.
    static func climbAhead(
        profile: RouteProfile,
        position: Double,
        coverage: TrailWalkCoverage
    ) -> (gainMeters: Double, lossMeters: Double)? {
        isGoingToStart(position: position, coverage: coverage, routeMeters: profile.totalDistanceMeters)
            ? climb(profile, from: 0, to: position, reversed: true)
            : climb(profile, from: position, to: profile.totalDistanceMeters, reversed: false)
    }

    /// How far it is along the route from `position` to the end the walk is
    /// going for: the distance the time left is for, and the one the readout
    /// beside it states — see the file header.
    static func metersAhead(position: Double, coverage: TrailWalkCoverage, routeMeters: Double) -> Double {
        max(0, isGoingToStart(position: position, coverage: coverage, routeMeters: routeMeters)
            ? position
            : routeMeters - position)
    }

    /// Whether the end the walk is going for is the route's stored start:
    /// ``TrailWalkCoverage/direction`` once the matches have said, and
    /// ``isReversed(position:covered:routeMeters:)``'s guess until then.
    static func isGoingToStart(position: Double, coverage: TrailWalkCoverage, routeMeters: Double) -> Bool {
        coverage.direction.map { $0 == .towardsStart }
            ?? isReversed(position: position, covered: coverage.ranges, routeMeters: routeMeters)
    }

    /// How this walk compares with the signposts so far, as a factor on their
    /// time, or `nil` until it has walked ``calibrationMeters`` in
    /// ``calibrationSeconds``.
    ///
    /// Against each stretch the way it was walked, over the stretches' own
    /// lengths, ``TrailWalkCoverage/walkedMeters`` — see the file header. A
    /// stretch walked there and back is walked twice, as the time spent on it
    /// was.
    static func paceFactor(
        profile: RouteProfile,
        coverage: TrailWalkCoverage,
        activeSeconds: TimeInterval
    ) -> Double? {
        let walkedMeters = coverage.walkedMeters
        guard walkedMeters >= calibrationMeters,
              activeSeconds >= calibrationSeconds else { return nil }
        let walked = profile.climb(walking: coverage)
        let expected = WalkingTimeEstimate.seconds(
            distanceMeters: walkedMeters,
            ascentMeters: walked?.gainMeters ?? 0,
            descentMeters: walked?.lossMeters ?? 0
        )
        guard expected > 0 else { return nil }
        return min(max(activeSeconds / expected, paceFactorBounds.lowerBound), paceFactorBounds.upperBound)
    }

    /// The best guess at whether a walk is heading for the route's stored
    /// start, until ``TrailWalkCoverage/direction`` can say — see the file
    /// header.
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
        profile.climb(from: start, to: end).map { turned($0, reversed: reversed) }
    }

    /// A climb as the hiker meets it — see ``climb(_:from:to:reversed:)``.
    private static func turned(
        _ climb: (gainMeters: Double, lossMeters: Double),
        reversed: Bool
    ) -> (gainMeters: Double, lossMeters: Double) {
        reversed ? (climb.lossMeters, climb.gainMeters) : climb
    }
}
