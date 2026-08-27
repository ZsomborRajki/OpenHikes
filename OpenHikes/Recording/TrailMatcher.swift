//
//  TrailMatcher.swift
//  OpenHikes
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

    static let minimumSigmaMeters = 4.0
    static let confidenceRatio = 1.15
    static let confidenceLogMargin = log(confidenceRatio)
    static let sparseInterval: TimeInterval = 90
    static let sparseDisplacement: CLLocationDistance = 200
    static let sparseMaximumSpeedMPS = 2.5
    static let denseMaximumSpeedMPS = 3.5
    static let minimumTransitionDistanceMeters = 75.0
    static let evidenceDistanceMarginFactor = 1.2
    /// How much longer the trail a dense leg *declined* has to be than the
    /// line it drew instead before the walker is asked about it.
    ///
    /// A dense leg is routed exactly one way — `optionLimit` is 1 off the
    /// sparse path — so when the matcher is unsure about one it has no second
    /// route to offer, only the trail it found against the raw GPS it fell
    /// back to drawing. Offering that pair unconditionally is far too noisy to
    /// ship: measured over the bundled 330-point walk, ordinary consumer noise
    /// leaves 51–94 of 329 legs non-confident, which is a review screen of
    /// 74–130 sections after every walk against 4–8 today.
    ///
    /// What separates the ones worth asking about is whether abstaining
    /// actually cost the walker any distance. For an ordinary noisy leg it
    /// costs nothing — the declined trail is a median 0.4–1.5 m *shorter* than
    /// the zig-zag the noise drew, and the 90th percentile is under 5 m at
    /// 8 m accuracy. A cut switchback corner is a different quantity
    /// altogether: the trail rounds the apex for 46 m where the fixes stepped
    /// 17.5 m straight across it, so the recording silently loses 29 m.
    ///
    /// This sits above the whole observed noise distribution and well below
    /// that, so the corner is surfaced and the noise is not. Raising it hides
    /// real lost distance; lowering it towards 10 m starts admitting ordinary
    /// legs again — 11 of them at a pessimistic 12 m accuracy.
    static let minimumDeclinedDetourMeters = 20.0
    static let widgetSourcedAccuracyWeight = 1.5

    /// When a leg stops being a stretch the matcher has to think harder about
    /// and becomes one it has no evidence across at all.
    ///
    /// Deliberately well above ``sparseInterval``. A sparse leg still has
    /// fixes close enough on either side that the ground between them is
    /// bounded; past these thresholds the recording simply stopped observing —
    /// a phone in a pack, a suspended app, a wooded valley — and whatever gets
    /// drawn there is an inference rather than a measurement.
    static let gapInterval: TimeInterval = 240
    static let gapDisplacement: CLLocationDistance = 400

    /// Hard ceiling on how far the matcher will route between two consecutive
    /// fixes, however long the silence between them.
    ///
    /// Without it the bound is `interval * sparseMaximumSpeedMPS`, which is
    /// reasonable for a minute and absurd for an afternoon: a phone that spent
    /// two hours in a pack asks for an 18 km Dijkstra radius with Yen's
    /// k-shortest paths layered on top, inside a save the walker is waiting
    /// on. Past this distance a shortest path is not weak evidence, it is
    /// none — there are far too many ways to walk that far — so the matcher
    /// abstains and the leg is reported as the gap it is.
    static let maximumBridgeDistanceMeters: CLLocationDistance = 3000

    /// The same ceiling when the pedometer can say how far the walk across the
    /// gap actually was.
    ///
    /// Step-derived distance narrows the question from "anywhere you could
    /// have reached" to "a path about this long", so the evidence itself is
    /// what bounds the search and this only has to stop a broken reading. A
    /// pedometer in a pack under-reports rather than over-reports, so the
    /// number it has to survive is an implausible large one.
    static let absoluteBridgeDistanceMeters: CLLocationDistance = 20_000

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

    /// Whether the ground between two consecutive fixes went unobserved.
    ///
    /// A deliberate pause is not a gap: the walker chose to stop recording, so
    /// nothing is missing and nothing should be inferred across it. That is
    /// the same `.resumed` guard ``needsDistanceEvidence(from:to:)`` uses, and
    /// for the same reason.
    static func isGap(
        from previous: RecordingPoint,
        to current: RecordingPoint
    ) -> Bool {
        guard !current.flags.contains(.resumed) else { return false }
        return current.timestamp.timeIntervalSince(previous.timestamp)
            > gapInterval
            || RouteGeometry.distanceMeters(
                from: previous.coordinate,
                to: current.coordinate
            ) > gapDisplacement
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
        let selection = ViterbiSelection(
            selected: selected,
            scoreMargins: scoreMargins,
            blockIDs: blockIDs
        )
        let legsResult = buildMatchingLegs(
            points: points,
            selection: selection,
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
            ambiguousLegCount: ambiguities.count,
            matchedTrailName: matchedTrailName,
            currentTrailName: currentTrailName,
            didMoveRoute: legsResult.didMoveRoute,
            ambiguities: ambiguities,
            legs: matchLegs
        )
    }
}

// MARK: - Leg types
//
// Internal rather than file-private: the leg and output building that consumes
// them lives in `TrailMatcherLegs.swift`, and they are the vocabulary the two
// files share. Nothing outside the matcher constructs them.

nonisolated extension TrailMatcher {
    struct MatchLeg {
        let transition: Transition?
        let isConfident: Bool
        let isSparse: Bool
        /// Whether the ground this leg spans went unobserved — see
        /// ``TrailMatcher/isGap(from:to:)``. Independent of confidence: a gap
        /// the matcher bridged along a mapped trail is still a gap, and what
        /// it drew across it is still an inference.
        let isGap: Bool
    }

    struct MatchingLegsResult {
        let legs: [MatchLeg]
        let matchedCount: Int
        let trailNameCounts: [String: Int]
        let didMoveRoute: Bool
    }

    /// The run-wide totals ``buildMatchingLegs`` accumulates while it walks,
    /// grouped so the per-leg work can take one `inout` rather than four.
    struct LegStats {
        var matchedCount = 0
        var trailNameCounts: [String: Int] = [:]
        var didMoveRoute = false
    }

    struct ViterbiUpdate {
        let pointIndex: Int
        let candidate: Candidate
        let scoreMargin: Double
        let blockID: Int
    }

    /// Everything the Viterbi pass decided, per fix: the state it settled on,
    /// how much better that state was than its runner-up, and which contiguous
    /// run of fixes it belongs to. Carried together because the leg building
    /// reads all three at the same two indices and would otherwise take three
    /// parallel arrays everywhere.
    struct ViterbiSelection {
        let selected: [Candidate?]
        let scoreMargins: [Double]
        let blockIDs: [Int?]
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
                  !candidates[next].isEmpty else { break }
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
                    else { continue }
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
