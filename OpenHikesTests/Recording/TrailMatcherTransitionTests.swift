//
//  TrailMatcherTransitionTests.swift
//  OpenHikesTests
//
//  Direct tests of ``TrailMatcherGraphIndex/transition(from:to:parameters:)`` —
//  the function that decides, given where a walker was and where they now are,
//  which stretch of trail they covered in between.
//
//  Everything else in the matcher is reached through it, and until now it was
//  only ever exercised end to end, where an emission term dominated by how near
//  a fix falls to an edge can hide a transition term that is scoring the wrong
//  way round. These call it with candidates and parameters built by hand, so
//  the only thing under test is the ranking.
//
//  The geometry is a "lens": one stem, two arms between the same pair of
//  junctions, one tail. Every expected distance below is computed from the
//  haversine radius ``RouteGeometry`` uses (6 371 008.8 m) rather than from the
//  matcher, and the rows are spaced far from the crossover so a metre of
//  arithmetic slack cannot flip an answer.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail matcher transition scoring")
struct TrailMatcherTransitionTests {
    /// Direct arm: 0.0020° of longitude at latitude 47.63 ≈ 149.88 m.
    private static let directMeters = 149.88
    /// Detour arm: two legs of √(100.08² + 74.93²) ≈ 125.02 m ≈ 250.04 m.
    private static let detourMeters = 250.04
    /// Shallow arm: two legs of √(27.80² + 74.94²) ≈ 79.93 m ≈ 159.85 m —
    /// within 15 % of the direct arm, which is what makes it
    /// indistinguishable from it without a distance measurement.
    private static let shallowMeters = 159.85

    private func graph(
        nodes: [(Int64, Double, Double)],
        ways: [(Int64, [Int64], String)]
    ) -> TrailGraph {
        let graphNodes = nodes.map { node in
            TrailGraphNode(
                id: node.0,
                coordinate: CLLocationCoordinate2D(latitude: node.1, longitude: node.2)
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: graphNodes.map { ($0.id, $0) })
        var edges: [TrailGraphEdge] = []
        for way in ways {
            for index in 0..<(way.1.count - 1) {
                guard let from = byID[way.1[index]], let to = byID[way.1[index + 1]] else {
                    continue
                }
                edges.append(TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: way.0, segmentIndex: index),
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    lengthMeters: RouteGeometry.distanceMeters(
                        from: from.coordinate,
                        to: to.coordinate
                    ),
                    name: way.2,
                    hikingRouteName: nil,
                    sacScale: nil,
                    trailVisibility: nil,
                    access: nil,
                    surface: nil
                ))
            }
        }
        return TrailGraph(nodes: graphNodes, edges: edges)
    }

    /// Stem 1→2, two arms 2→4, tail 4→5. The walker is at junction 2 and then
    /// at junction 4; only the arm between them is in question.
    private func lensGraph() -> TrailGraph {
        graph(
            nodes: [
                (1, 47.6300, 12.8580),
                (2, 47.6300, 12.8600),
                (3, 47.6309, 12.8610),
                (4, 47.6300, 12.8620),
                (5, 47.6300, 12.8640),
            ],
            ways: [
                (10, [1, 2], "Stem"),
                (11, [2, 4], "Direct"),
                (12, [2, 3, 4], "Detour"),
                (13, [4, 5], "Tail"),
            ]
        )
    }

    /// The same lens with the second arm bowed only slightly, so the two arms
    /// are within the 15 % the matcher treats as indistinguishable.
    private func shallowLensGraph() -> TrailGraph {
        graph(
            nodes: [
                (1, 47.6300, 12.8580),
                (2, 47.6300, 12.8600),
                (3, 47.63025, 12.8610),
                (4, 47.6300, 12.8620),
                (5, 47.6300, 12.8640),
            ],
            ways: [
                (10, [1, 2], "Stem"),
                (11, [2, 4], "Direct"),
                (12, [2, 3, 4], "Shallow"),
                (13, [4, 5], "Tail"),
            ]
        )
    }

    // MARK: - Which arm wins

    /// The scoring table.
    ///
    /// The two arms are 149.88 m and 250.04 m, so their errors are equal at an
    /// expected distance of 199.96 m. Each row sits at least 10 m clear of that
    /// crossover in one direction or the other, and names the arm the walker
    /// must have taken to have covered the distance the clock and the GPS
    /// displacement imply. Nothing sits beyond 250 m, because past that the
    /// best answer stops being an arm at all — walking back down the stem and
    /// out along the tail is a longer real path through the same graph.
    @Test(
        "distance evidence selects the arm nearest the expected length",
        arguments: [
            (expected: 150.0, arm: "Direct", other: "Detour"),
            (expected: 190.0, arm: "Direct", other: "Detour"),
            (expected: 215.0, arm: "Detour", other: "Direct"),
            (expected: 250.0, arm: "Detour", other: "Direct"),
        ]
    )
    func expectedDistanceSelectsArm(row: (expected: Double, arm: String, other: String)) throws {
        var index = TrailMatcherGraphIndex(graph: lensGraph())
        let from = try candidate(atEndOf: 10, in: index)
        let to = try candidate(atStartOf: 13, in: index)

        let scored = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: row.expected)
        )
        let transition = try #require(scored)

        let expectedLength = row.arm == "Direct" ? Self.directMeters : Self.detourMeters
        #expect(transition.trailNames.contains(row.arm))
        #expect(!transition.trailNames.contains(row.other))
        #expect(abs(transition.distanceMeters - expectedLength) < 1.5)
        // The walk starts on the stem and ends on the tail whichever arm it
        // took, so naming those does not distinguish the answer — the arm does.
        #expect(transition.trailNames.contains("Stem"))
        #expect(transition.trailNames.contains("Tail"))
    }

    /// The arm the walker did not take is offered as the alternative, so the
    /// review screen has something to offer when the margin is thin.
    @Test("a sparse transition keeps the runner-up as an alternative")
    func sparseTransitionOffersRunnerUp() throws {
        var index = TrailMatcherGraphIndex(graph: lensGraph())
        let from = try candidate(atEndOf: 10, in: index)
        let to = try candidate(atStartOf: 13, in: index)

        let scored = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 150)
        )
        let transition = try #require(scored)

        #expect(transition.alternatives.count == 2)
        #expect(transition.alternatives.contains { $0.trailNames.contains("Detour") })
        let runnerUp = try #require(
            transition.alternatives.first { $0.trailNames.contains("Detour") }
        )
        #expect(abs(runnerUp.distanceMeters - Self.detourMeters) < 1.5)
    }

    /// A dense transition asks for one path per endpoint pair, so the long arm
    /// is never built and cannot win no matter what distance is expected.
    ///
    /// This is deliberate rather than incidental: fixes a minute apart carry no
    /// usable distance evidence, and letting them pick a 250 m detour over a
    /// 150 m direct line would draw loops nobody walked.
    @Test("a dense transition never considers the longer arm")
    func denseTransitionIgnoresLongArm() throws {
        var index = TrailMatcherGraphIndex(graph: lensGraph())
        let from = try candidate(atEndOf: 10, in: index)
        let to = try candidate(atStartOf: 13, in: index)

        let scored = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 250, isSparse: false)
        )
        let transition = try #require(scored)

        #expect(transition.trailNames.contains("Direct"))
        #expect(!transition.trailNames.contains("Detour"))
        #expect(abs(transition.distanceMeters - Self.directMeters) < 1.5)
        #expect(transition.alternatives.isEmpty)
        #expect(transition.likelihoodMargin == .infinity)
    }

    // MARK: - Reachability

    /// A budget between the two arms removes the long one from consideration,
    /// so the short arm wins despite being 100 m from the expected distance —
    /// and is then the only thing left to offer the review screen.
    @Test("an arm beyond the reachable budget is not offered")
    func unreachableArmIsFiltered() throws {
        var index = TrailMatcherGraphIndex(graph: lensGraph())
        let from = try candidate(atEndOf: 10, in: index)
        let to = try candidate(atStartOf: 13, in: index)

        let scored = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 250, maximum: 200)
        )
        let transition = try #require(scored)

        #expect(transition.trailNames.contains("Direct"))
        #expect(!transition.trailNames.contains("Detour"))
        // The alternatives are the top of the ranking rather than the losers,
        // so with one survivor the sole entry is the chosen path itself.
        #expect(transition.alternatives.count == 1)
        #expect(transition.alternatives.first?.trailNames.contains("Detour") == false)
        #expect(transition.likelihoodMargin == .infinity)
    }

    /// With a budget under the shorter arm nothing connects the two fixes, and
    /// the matcher says so rather than inventing a path — the caller reads the
    /// nil as "abstain" and leaves the raw GPS line alone.
    @Test("no reachable path yields no transition")
    func unreachablePairYieldsNil() throws {
        var index = TrailMatcherGraphIndex(graph: lensGraph())
        let from = try candidate(atEndOf: 10, in: index)
        let to = try candidate(atStartOf: 13, in: index)

        let transition = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 150, maximum: 100)
        )

        #expect(transition == nil)
    }

    /// The budget also governs a walk that never left one edge — and that is
    /// the only thing it governs on its own.
    ///
    /// A path through nodes is bounded before it is built: the collector
    /// subtracts both endpoint costs and hands the remainder to the router as
    /// its own ceiling, so an over-budget one is never returned. The
    /// along-edge option is the one built without asking, so removing the
    /// filter would let a 120 m stretch answer a 100 m budget.
    @Test("the budget also rejects an over-long walk along one edge")
    func sameEdgeWalkRespectsBudget() throws {
        var index = TrailMatcherGraphIndex(graph: lensGraph())
        let edge = try edgeIndex(wayID: 11, in: index)
        let length = index.edges[edge].lengthMeters
        let from = TrailMatcherCandidate(
            edgeIndex: edge,
            projectedCoordinate: index.edgeEndpoints[edge].start,
            offsetMeters: length * 0.1,
            offRouteMeters: 0
        )
        let to = TrailMatcherCandidate(
            edgeIndex: edge,
            projectedCoordinate: index.edgeEndpoints[edge].end,
            offsetMeters: length * 0.9,
            offRouteMeters: 0
        )

        // 0.8 of a 149.88 m edge is 119.9 m, and getting from one end of that
        // stretch to the other through the junctions is longer still.
        let denied = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 120, maximum: 100, isSparse: false)
        )
        #expect(denied == nil)

        let allowed = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 120, maximum: 130, isSparse: false)
        )
        let transition = try #require(allowed)
        #expect(abs(transition.distanceMeters - length * 0.8) < 0.001)
        #expect(transition.trailNames == ["Direct"])
    }

    // MARK: - Confidence

    /// Two arms of 149.88 m and 159.85 m differ by 6.2 % of the longer, inside
    /// the 15 % the matcher treats as the same length. Without distance
    /// evidence the choice between them is a coin toss, and the margin says so
    /// exactly — zero, not merely small.
    @Test("indistinguishable arms score no margin without distance evidence")
    func similarArmsAbstainWithoutEvidence() throws {
        var index = TrailMatcherGraphIndex(graph: shallowLensGraph())
        let from = try candidate(atEndOf: 10, in: index)
        let to = try candidate(atStartOf: 13, in: index)

        let scored = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 150, hasDistanceEvidence: false)
        )
        let transition = try #require(scored)

        #expect(transition.likelihoodMargin == 0)
        #expect(transition.trailNames.contains("Direct"))
    }

    /// The same two arms with distance evidence available: the 10 m difference
    /// is now a measurement rather than noise, and the margin becomes the
    /// error gap over beta — (9.85 − 0.12) / 30 ≈ 0.32, comfortably past the
    /// ``TrailMatcher`` confidence threshold of ln(1.15) ≈ 0.14.
    @Test("distance evidence turns the same gap into a usable margin")
    func similarArmsScoreMarginWithEvidence() throws {
        var index = TrailMatcherGraphIndex(graph: shallowLensGraph())
        let from = try candidate(atEndOf: 10, in: index)
        let to = try candidate(atStartOf: 13, in: index)

        let scored = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 150, hasDistanceEvidence: true)
        )
        let transition = try #require(scored)

        #expect(transition.likelihoodMargin > 0.25)
        #expect(transition.likelihoodMargin < 0.40)
        #expect(transition.trailNames.contains("Direct"))
    }

    /// Expecting 156 m puts the shallow arm 3.85 m out and the direct arm
    /// 6.12 m out, so the longer arm wins by 2.27 m — a margin of 0.076, which
    /// is real but under the ln(1.15) confidence threshold. That is the shape
    /// of a leg the matcher draws its best guess for and still reports as
    /// ambiguous rather than as fact.
    @Test("a length between two similar arms leaves a sub-threshold margin")
    func betweenSimilarArmsMarginStaysBelowThreshold() throws {
        var index = TrailMatcherGraphIndex(graph: shallowLensGraph())
        let from = try candidate(atEndOf: 10, in: index)
        let to = try candidate(atStartOf: 13, in: index)

        let scored = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: 156, hasDistanceEvidence: true)
        )
        let transition = try #require(scored)

        #expect(transition.likelihoodMargin > 0.03)
        #expect(transition.likelihoodMargin < 0.14)
        #expect(abs(transition.distanceMeters - Self.shallowMeters) < 1.5)
        #expect(transition.trailNames.contains("Shallow"))
    }

    // MARK: - Same edge

    /// A walker who stayed on one edge gets the along-edge distance, not a trip
    /// round the graph, and no alternative is offered because there is nothing
    /// to be uncertain about.
    @Test("staying on one edge scores the offset difference")
    func sameEdgeTransitionUsesOffsetDifference() throws {
        var index = TrailMatcherGraphIndex(graph: lensGraph())
        let edge = try edgeIndex(wayID: 11, in: index)
        let length = index.edges[edge].lengthMeters
        let from = TrailMatcherCandidate(
            edgeIndex: edge,
            projectedCoordinate: index.edgeEndpoints[edge].start,
            offsetMeters: length * 0.25,
            offRouteMeters: 0
        )
        let to = TrailMatcherCandidate(
            edgeIndex: edge,
            projectedCoordinate: index.edgeEndpoints[edge].end,
            offsetMeters: length * 0.75,
            offRouteMeters: 0
        )

        let scored = index.transition(
            from: from,
            to: to,
            parameters: parameters(expected: length * 0.5, isSparse: false)
        )
        let transition = try #require(scored)

        #expect(abs(transition.distanceMeters - length * 0.5) < 0.001)
        #expect(transition.trailNames == ["Direct"])
    }
}

// The remaining fixtures sit in an extension only to keep the suite body
// inside the length SwiftLint enforces on a type.
private extension TrailMatcherTransitionTests {
    func edgeIndex(
        wayID: Int64,
        in index: TrailMatcherGraphIndex,
        segment: Int = 0
    ) throws -> Int {
        try #require(index.edges.firstIndex { edge in
            edge.id.wayID == wayID && edge.id.segmentIndex == segment
        })
    }

    /// A fix sitting exactly on the far end of a way — junction 2 for the stem,
    /// junction 4 for the tail. Both endpoint costs are then zero, so the only
    /// distance in the transition is the arm itself.
    func candidate(
        atEndOf wayID: Int64,
        in index: TrailMatcherGraphIndex
    ) throws -> TrailMatcherCandidate {
        let edge = try edgeIndex(wayID: wayID, in: index)
        return TrailMatcherCandidate(
            edgeIndex: edge,
            projectedCoordinate: index.edgeEndpoints[edge].end,
            offsetMeters: index.edges[edge].lengthMeters,
            offRouteMeters: 0
        )
    }

    func candidate(
        atStartOf wayID: Int64,
        in index: TrailMatcherGraphIndex
    ) throws -> TrailMatcherCandidate {
        let edge = try edgeIndex(wayID: wayID, in: index)
        return TrailMatcherCandidate(
            edgeIndex: edge,
            projectedCoordinate: index.edgeEndpoints[edge].start,
            offsetMeters: 0,
            offRouteMeters: 0
        )
    }

    func parameters(
        expected: Double,
        maximum: Double = 3000,
        beta: Double = 30,
        isSparse: Bool = true,
        hasDistanceEvidence: Bool = true
    ) -> TrailMatcherTransitionParameters {
        TrailMatcherTransitionParameters(
            expectedDistance: expected,
            maximumDistance: maximum,
            beta: beta,
            isSparse: isSparse,
            hasDistanceEvidence: hasDistanceEvidence,
            startEndpointTolerance: 4,
            endEndpointTolerance: 4
        )
    }
}
