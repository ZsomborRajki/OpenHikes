//
//  TrailMatcherLegs.swift
//  OpenHikes
//
//  Turning the Viterbi path into legs: what each stretch between two
//  consecutive fixes was matched to, what it draws, and what else it could
//  have drawn. Split from `TrailMatcher.swift`, which owns the model and the
//  Viterbi pass that produces the input to this.
//

import CoreLocation
import Foundation

nonisolated extension TrailMatcher {
    static func buildMatchingLegs(
        points: [RecordingPoint],
        selection: ViterbiSelection,
        gapDistances: [Int: Double],
        index: inout GraphIndex
    ) -> MatchingLegsResult {
        var legs: [MatchLeg] = []
        var stats = LegStats()
        for indexInPoints in 1..<points.count {
            legs.append(matchLeg(
                points: points,
                at: indexInPoints,
                selection: selection,
                evidenceDistance: gapDistances[indexInPoints],
                index: &index,
                stats: &stats
            ))
        }
        return MatchingLegsResult(
            legs: legs,
            matchedCount: stats.matchedCount,
            ambiguousCount: stats.ambiguousCount,
            trailNameCounts: stats.trailNameCounts,
            didMoveRoute: stats.didMoveRoute
        )
    }

    /// One leg of the walk: the stretch between two consecutive fixes, matched
    /// onto the graph if it can be, and folded into the run-wide `stats` as a
    /// side effect so the caller stays a loop rather than a second accumulator.
    ///
    /// Both abstain paths deliberately leave the counts alone. A leg with no
    /// usable pair of candidates, or one the router could not connect, is not
    /// an ambiguity the walker can be asked about — there is nothing to choose
    /// between — so it is neither matched nor ambiguous, only reported.
    private static func matchLeg(
        points: [RecordingPoint],
        at indexInPoints: Int,
        selection: ViterbiSelection,
        evidenceDistance: Double?,
        index: inout GraphIndex,
        stats: inout LegStats
    ) -> MatchLeg {
        let previousIndex = indexInPoints - 1
        let gap = isGap(from: points[previousIndex], to: points[indexInPoints])
        guard let previous = selection.selected[previousIndex],
              let current = selection.selected[indexInPoints],
              selection.blockIDs[previousIndex] == selection.blockIDs[indexInPoints],
              !points[indexInPoints].flags.contains(.resumed)
        else {
            return MatchLeg(
                transition: nil,
                isConfident: false,
                isSparse: false,
                isGap: gap
            )
        }
        let parameters = transitionParameters(
            from: points[previousIndex],
            to: points[indexInPoints],
            evidenceDistance: evidenceDistance
        )
        guard let transition = index.transition(
            from: previous,
            to: current,
            parameters: parameters
        ) else {
            return MatchLeg(
                transition: nil,
                isConfident: false,
                isSparse: parameters.isSparse,
                isGap: gap
            )
        }
        let confident =
            selection.scoreMargins[previousIndex] >= confidenceLogMargin
            && selection.scoreMargins[indexInPoints] >= confidenceLogMargin
            && (!parameters.isSparse || transition.likelihoodMargin >= confidenceLogMargin)
        if confident {
            stats.matchedCount += 1
            updateConfidentLegStats(
                from: previous,
                to: current,
                transition: transition,
                trailNameCounts: &stats.trailNameCounts,
                didMoveRoute: &stats.didMoveRoute
            )
        } else if parameters.isSparse {
            stats.ambiguousCount += 1
        }
        return MatchLeg(
            transition: transition,
            isConfident: confident,
            isSparse: parameters.isSparse,
            isGap: gap
        )
    }

    static func buildAnchoredPoints(
        points: [RecordingPoint],
        legs: [MatchLeg],
        selected: [Candidate?]
    ) -> [RecordingPoint] {
        var usesMatchedAnchor = [Bool](repeating: false, count: points.count)
        for (indexInLegs, leg) in legs.enumerated() where leg.isConfident {
            usesMatchedAnchor[indexInLegs] = true
            usesMatchedAnchor[indexInLegs + 1] = true
        }
        return zip(points, zip(usesMatchedAnchor, selected))
            .map { rawPoint, anchorState -> RecordingPoint in
                let (isAnchored, candidate) = anchorState
                guard isAnchored, let candidate else { return rawPoint }
                return point(rawPoint, movedTo: candidate.projectedCoordinate)
            }
    }

    static func buildOutputSegments(
        points: [RecordingPoint],
        legs: [MatchLeg],
        anchors: [RecordingPoint]
    ) -> (
        output: [RecordingPoint],
        matchLegs: [TrailMatchLeg],
        ambiguities: [TrailMatchAmbiguity]
    ) {
        var output: [RecordingPoint] = []
        var matchLegs: [TrailMatchLeg] = []
        var ambiguities: [TrailMatchAmbiguity] = []
        for indexInPoints in 1..<points.count {
            let previousIndex = indexInPoints - 1
            let leg = legs[previousIndex]
            let coordinates: [CLLocationCoordinate2D]
            let trailNames: [String]
            if leg.isConfident, let transition = leg.transition {
                coordinates = transition.coordinates
                trailNames = transition.trailNames
            } else {
                coordinates = [
                    anchors[previousIndex].coordinate,
                    anchors[indexInPoints].coordinate,
                ]
                trailNames = []
            }
            let segment = recordingPoints(
                along: coordinates,
                from: anchors[previousIndex],
                to: anchors[indexInPoints],
                inferred: leg.isGap
            )
            let alternatives = buildAlternatives(
                legIndex: previousIndex,
                legs: legs,
                fromAnchor: anchors[previousIndex],
                toAnchor: anchors[indexInPoints]
            )
            matchLegs.append(matchLeg(
                leg,
                at: previousIndex,
                points: points,
                segment: segment,
                alternatives: alternatives,
                trailNames: trailNames
            ))
            if !alternatives.isEmpty {
                ambiguities.append(TrailMatchAmbiguity(
                    id: previousIndex,
                    gpsPoints: segment,
                    alternatives: alternatives
                ))
            }
            if output.isEmpty {
                output.append(contentsOf: segment)
            } else {
                output.append(contentsOf: segment.dropFirst())
            }
        }
        return (output, matchLegs, ambiguities)
    }

    /// The reviewable record of one leg: what it drew, what else it could have
    /// drawn, and — when nothing was observed across it — how long the
    /// recording was silent and whether a trail was found to bridge it.
    static func matchLeg(
        _ leg: MatchLeg,
        at legIndex: Int,
        points: [RecordingPoint],
        segment: [RecordingPoint],
        alternatives: [TrailMatchAlternative],
        trailNames: [String]
    ) -> TrailMatchLeg {
        TrailMatchLeg(
            index: legIndex,
            defaultPoints: segment,
            rawPoints: rawLegPoints(
                from: points[legIndex],
                to: points[legIndex + 1],
                inferred: leg.isGap
            ),
            alternatives: alternatives,
            trailNames: trailNames,
            isInferred: leg.isGap,
            unobservedDuration: leg.isGap
                ? points[legIndex + 1].timestamp
                    .timeIntervalSince(points[legIndex].timestamp)
                : nil,
            isBridged: leg.isConfident && leg.transition != nil
        )
    }

    /// The pair of recorded fixes a leg spans, as the review's "use GPS only"
    /// choice would draw them.
    ///
    /// Choosing GPS across a gap does not make the straight line between two
    /// distant fixes a measurement — nobody observed that ground either way —
    /// so the marking follows the leg rather than the choice made about it.
    static func rawLegPoints(
        from start: RecordingPoint,
        to end: RecordingPoint,
        inferred: Bool
    ) -> [RecordingPoint] {
        guard inferred else { return [start, end] }
        var terminal = end
        terminal.flags.formUnion(.inferred)
        return [start, terminal]
    }

    static func buildAlternatives(
        legIndex: Int,
        legs: [MatchLeg],
        fromAnchor: RecordingPoint,
        toAnchor: RecordingPoint
    ) -> [TrailMatchAlternative] {
        guard !legs[legIndex].isConfident,
              legs[legIndex].isSparse,
              let transition = legs[legIndex].transition
        else { return [] }
        return transition.alternatives.enumerated().map { alternativeIndex, alternative in
            TrailMatchAlternative(
                id: alternativeIndex,
                points: recordingPoints(
                    along: alternative.coordinates,
                    from: fromAnchor,
                    to: toAnchor,
                    inferred: legs[legIndex].isGap
                ),
                distanceMeters: alternative.distanceMeters,
                trailNames: alternative.trailNames
            )
        }
    }
}
