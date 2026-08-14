//
//  TrailMatcher.swift
//  OpenTrails
//
//  On-device HMM map matching over a cached OSM walking graph. Low-confidence
//  legs remain GPS geometry; matching is allowed to abstain.
//

import CoreLocation
import Foundation

nonisolated enum TrailMatcher {
    static let maximumCandidatesPerFix = 8
    static let minimumCoordinateDistanceMeters = 0.05

    typealias Candidate = TrailMatcherCandidate
    typealias GraphIndex = TrailMatcherGraphIndex
    typealias Transition = TrailMatcherTransition
    typealias TransitionAlternative = TrailMatcherTransitionAlternative
    typealias TransitionParameters = TrailMatcherTransitionParameters

    static let minimumSigmaMeters = 4.0
    private static let confidenceRatio = 1.15
    private static let confidenceLogMargin = log(confidenceRatio)
    static let sparseInterval: TimeInterval = 90
    static let sparseDisplacement: CLLocationDistance = 200
    static let sparseMaximumSpeedMPS = 2.5
    static let denseMaximumSpeedMPS = 3.5
    static let minimumTransitionDistanceMeters = 75.0
    static let evidenceDistanceMarginFactor = 1.2
    static let widgetSourcedAccuracyWeight = 1.5

    static func needsDistanceEvidence(
        from previous: RecordingPoint,
        to current: RecordingPoint
    ) -> Bool {
        guard !current.flags.contains(.resumed) else { return false }
        return current.timestamp.timeIntervalSince(previous.timestamp)
            > sparseInterval
            || RouteGeometry.distanceMeters(
                from: previous.coordinate,
                to: current.coordinate
            ) > sparseDisplacement
    }

    /// Matches without occupying the main actor.
    ///
    /// `@concurrent` rather than a detached task: the match stays in the
    /// caller's task, so cancelling it — which live matching does on every
    /// reschedule — actually stops the work. A detached match ran to
    /// completion regardless, burning Viterbi passes on a window whose result
    /// the caller had already decided to discard.
    @concurrent
    static func matchOffMain(
        points: [RecordingPoint],
        graph: TrailGraph,
        gapDistances: [Int: Double] = [:]
    ) async -> TrailMatchResult {
        assertOffMainThread("Trail matching must stay off the main thread")
        // Timed, not just counted: this is the largest single piece of work a
        // recording schedules, and the question it has to answer is whether a
        // pass still finishes inside the interval before the next fix
        // reschedules it.
        return RenderSignpost.interval("TrailMatcherWork") {
            match(points: points, graph: graph, gapDistances: gapDistances)
        }
    }

    static func match(
        points: [RecordingPoint],
        graph: TrailGraph,
        gapDistances: [Int: Double] = [:]
    ) -> TrailMatchResult {
        guard points.count > 1, !graph.isEmpty else { return emptyMatchResult(points: points) }
        var index = GraphIndex(graph: graph)
        let candidates = points.map { pt in index.candidates(for: pt) }
        let (selected, scoreMargins, blockIDs) = viterbiAndBacktrack(
            points: points,
            candidates: candidates,
            gapDistances: gapDistances,
            index: &index
        )
        let legsResult = buildMatchingLegs(
            points: points,
            selected: selected,
            scoreMargins: scoreMargins,
            blockIDs: blockIDs,
            gapDistances: gapDistances,
            index: &index
        )
        let anchors = buildAnchoredPoints(
            points: points,
            legs: legsResult.legs,
            selected: selected
        )
        let (output, matchLegs, ambiguities) = buildOutputSegments(
            points: points,
            legs: legsResult.legs,
            anchors: anchors
        )
        let matchedTrailName = legsResult.trailNameCounts.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }?.key
        let currentTrailName: String?
        if let last = legsResult.legs.last,
           last.isConfident,
           let transition = last.transition {
            currentTrailName = transition.trailNames.min()
        } else {
            currentTrailName = nil
        }
        return TrailMatchResult(
            points: output,
            matchedLegCount: legsResult.matchedCount,
            ambiguousLegCount: legsResult.ambiguousCount,
            matchedTrailName: matchedTrailName,
            currentTrailName: currentTrailName,
            didMoveRoute: legsResult.didMoveRoute,
            ambiguities: ambiguities,
            legs: matchLegs
        )
    }
}

// MARK: - Private types

nonisolated private extension TrailMatcher {
    struct MatchLeg {
        let transition: Transition?
        let isConfident: Bool
        let isSparse: Bool
    }

    struct MatchingLegsResult {
        let legs: [MatchLeg]
        let matchedCount: Int
        let ambiguousCount: Int
        let trailNameCounts: [String: Int]
        let didMoveRoute: Bool
    }

    struct ViterbiUpdate {
        let pointIndex: Int
        let candidate: Candidate
        let scoreMargin: Double
        let blockID: Int
    }
}

// MARK: - Viterbi

nonisolated private extension TrailMatcher {
    static func viterbiAndBacktrack(
        points: [RecordingPoint],
        candidates: [[Candidate]],
        gapDistances: [Int: Double],
        index: inout GraphIndex
    ) -> (selected: [Candidate?], scoreMargins: [Double], blockIDs: [Int?]) {
        var selected = [Candidate?](repeating: nil, count: points.count)
        var scoreMargins = [Double](repeating: -.infinity, count: points.count)
        var blockIDs = [Int?](repeating: nil, count: points.count)
        var blockID = 0
        var start = 0
        while start < points.count {
            while start < points.count, candidates[start].isEmpty {
                start += 1
            }
            guard start < points.count else { break }
            let (scoreHistory, backHistory, end) = forwardViterbiPass(
                start: start,
                points: points,
                candidates: candidates,
                gapDistances: gapDistances,
                index: &index
            )
            guard let bestFinal = bestIndex(in: scoreHistory[scoreHistory.count - 1]) else {
                start += 1
                continue
            }
            let updates = backtrackViterbi(
                start: start,
                bestFinal: bestFinal,
                blockID: blockID,
                scoreHistory: scoreHistory,
                backHistory: backHistory,
                candidates: candidates
            )
            for update in updates {
                selected[update.pointIndex] = update.candidate
                scoreMargins[update.pointIndex] = update.scoreMargin
                blockIDs[update.pointIndex] = update.blockID
            }
            blockID += 1
            start = end + 1
        }
        return (selected, scoreMargins, blockIDs)
    }

    static func forwardViterbiPass(
        start: Int,
        points: [RecordingPoint],
        candidates: [[Candidate]],
        gapDistances: [Int: Double],
        index: inout GraphIndex
    ) -> (scoreHistory: [[Double]], backHistory: [[Int]], end: Int) {
        var scoreHistory = [
            candidates[start].map { candidate in
                emissionLogProbability(candidate, for: points[start])
            },
        ]
        var backHistory: [[Int]] = []
        var end = start
        while end + 1 < points.count {
            let next = end + 1
            guard !points[next].flags.contains(.resumed),
                  !candidates[next].isEmpty
            else {
                break
            }
            let previousScores = scoreHistory[scoreHistory.count - 1]
            var nextScores = [Double](repeating: -.infinity, count: candidates[next].count)
            var nextBack = [Int](repeating: -1, count: candidates[next].count)
            let parameters = transitionParameters(
                from: points[end],
                to: points[next],
                evidenceDistance: gapDistances[next]
            )
            for currentIndex in candidates[next].indices {
                for previousIndex in candidates[end].indices {
                    guard previousScores[previousIndex].isFinite,
                          let transition = index.transition(
                              from: candidates[end][previousIndex],
                              to: candidates[next][currentIndex],
                              parameters: parameters
                          )
                    else {
                        continue
                    }
                    let score = previousScores[previousIndex]
                        + transitionLogProbability(
                            transition.distanceMeters,
                            parameters: parameters
                        )
                        + emissionLogProbability(
                            candidates[next][currentIndex],
                            for: points[next]
                        )
                    if score > nextScores[currentIndex] {
                        nextScores[currentIndex] = score
                        nextBack[currentIndex] = previousIndex
                    }
                }
            }
            guard nextScores.contains(where: \.isFinite) else { break }
            scoreHistory.append(nextScores)
            backHistory.append(nextBack)
            end = next
        }
        return (scoreHistory, backHistory, end)
    }

    static func backtrackViterbi(
        start: Int,
        bestFinal: Int,
        blockID: Int,
        scoreHistory: [[Double]],
        backHistory: [[Int]],
        candidates: [[Candidate]]
    ) -> [ViterbiUpdate] {
        var updates: [ViterbiUpdate] = []
        var chosen = bestFinal
        for localIndex in stride(from: scoreHistory.count - 1, through: 0, by: -1) {
            let pointIndex = start + localIndex
            let candidate = candidates[pointIndex][chosen]
            let scoreMargin = margin(
                for: chosen,
                in: scoreHistory[localIndex],
                candidates: candidates[pointIndex]
            )
            updates.append(
                ViterbiUpdate(
                    pointIndex: pointIndex,
                    candidate: candidate,
                    scoreMargin: scoreMargin,
                    blockID: blockID
                )
            )
            if localIndex > 0 {
                chosen = backHistory[localIndex - 1][chosen]
            }
        }
        return updates
    }
}

// MARK: - Match leg and output building

nonisolated private extension TrailMatcher {
    static func buildMatchingLegs(
        points: [RecordingPoint],
        selected: [Candidate?],
        scoreMargins: [Double],
        blockIDs: [Int?],
        gapDistances: [Int: Double],
        index: inout GraphIndex
    ) -> MatchingLegsResult {
        var legs: [MatchLeg] = []
        var matchedLegCount = 0
        var ambiguousLegCount = 0
        var trailNameCounts: [String: Int] = [:]
        var didMoveRoute = false
        for indexInPoints in 1..<points.count {
            let previousIndex = indexInPoints - 1
            guard let previous = selected[previousIndex],
                  let current = selected[indexInPoints],
                  blockIDs[previousIndex] == blockIDs[indexInPoints],
                  !points[indexInPoints].flags.contains(.resumed)
            else {
                legs.append(MatchLeg(transition: nil, isConfident: false, isSparse: false))
                continue
            }
            let parameters = transitionParameters(
                from: points[previousIndex],
                to: points[indexInPoints],
                evidenceDistance: gapDistances[indexInPoints]
            )
            guard let transition = index.transition(
                from: previous,
                to: current,
                parameters: parameters
            ) else {
                legs.append(MatchLeg(transition: nil, isConfident: false, isSparse: parameters.isSparse))
                continue
            }
            let confident =
                scoreMargins[previousIndex] >= confidenceLogMargin
                && scoreMargins[indexInPoints] >= confidenceLogMargin
                && (!parameters.isSparse || transition.likelihoodMargin >= confidenceLogMargin)
            legs.append(MatchLeg(
                transition: transition,
                isConfident: confident,
                isSparse: parameters.isSparse
            ))
            if confident {
                matchedLegCount += 1
                updateConfidentLegStats(
                    from: previous,
                    to: current,
                    transition: transition,
                    trailNameCounts: &trailNameCounts,
                    didMoveRoute: &didMoveRoute
                )
            } else if parameters.isSparse {
                ambiguousLegCount += 1
            }
        }
        return MatchingLegsResult(
            legs: legs,
            matchedCount: matchedLegCount,
            ambiguousCount: ambiguousLegCount,
            trailNameCounts: trailNameCounts,
            didMoveRoute: didMoveRoute
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
            let coordinates: [CLLocationCoordinate2D]
            let trailNames: [String]
            if legs[previousIndex].isConfident,
               let transition = legs[previousIndex].transition {
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
                to: anchors[indexInPoints]
            )
            let alternatives = buildAlternatives(
                legIndex: previousIndex,
                legs: legs,
                fromAnchor: anchors[previousIndex],
                toAnchor: anchors[indexInPoints]
            )
            matchLegs.append(TrailMatchLeg(
                index: previousIndex,
                defaultPoints: segment,
                rawPoints: [points[previousIndex], points[indexInPoints]],
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
                    to: toAnchor
                ),
                distanceMeters: alternative.distanceMeters,
                trailNames: alternative.trailNames
            )
        }
    }
}
