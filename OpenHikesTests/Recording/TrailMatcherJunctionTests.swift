//
//  TrailMatcherJunctionTests.swift
//  OpenHikesTests
//
//  End-to-end matching over three hand-drawn shapes where the transition term
//  is what decides the answer: a Y fork, a pair of trails 10 m apart, and a
//  switchback.
//
//  Ten metres is the case worth the most. It is inside a good GPS fix's own
//  error, so the emission term alone will put some fixes on the wrong path, and
//  the only thing standing between a walker on the upper trail and a saved hike
//  drawn along the lower one is the cost of the detour needed to get there.
//  The matcher gets that one right, in both directions.
//
//  The switchback it does not, and the two tests at the end of this file say so
//  in detail: the turn is routed correctly when the transition is asked
//  directly, and lost end to end because the confidence rule reads a forward
//  score in which the right answer is briefly behind. That is asserted as it
//  behaves today rather than endorsed.
//
//  Every expected answer below is written from the geometry rather than taken
//  from a run.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail matcher junctions")
struct TrailMatcherJunctionTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func point(
        _ latitude: Double,
        _ longitude: Double,
        at offset: TimeInterval,
        accuracy: Double = 8
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: longitude,
            timestamp: start.addingTimeInterval(offset),
            horizontalAccuracy: accuracy,
            elevation: 600 + offset / 60
        )
    }

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

    // MARK: - Parallel trails 10 m apart

    /// Two trails leaving one junction and running east 10 m apart: the upper
    /// at 47.63009, the lower at 47.63000.
    private func parallelPairGraph() -> TrailGraph {
        graph(
            nodes: [
                (1, 47.630045, 12.8598),
                (2, 47.63009, 12.8600),
                (3, 47.63009, 12.8620),
                (4, 47.63000, 12.8600),
                (5, 47.63000, 12.8620),
            ],
            ways: [
                (10, [1, 2, 3], "Upper Trail"),
                (20, [1, 4, 5], "Lower Trail"),
            ]
        )
    }

    /// A walk along the upper trail whose third fix strays 5.6 m south — past
    /// the midline, so on that fix alone the lower trail is the better
    /// explanation by 0.09 nats.
    ///
    /// Nothing but the transition term rejects it: switching arms and back
    /// means returning to the junction 90 m west and coming out again, against
    /// an expected 30 m of walking. That is the failure this shape exists to
    /// catch — one noisy fix dragging a leg onto the wrong path.
    @Test("a walker on the upper of two trails 10 m apart stays on it")
    func upperOfParallelPairWins() {
        let points = [
            point(47.630092, 12.8602, at: 0),
            point(47.630084, 12.8606, at: 60),
            point(47.630040, 12.8610, at: 120),
            point(47.630095, 12.8614, at: 180),
            point(47.630090, 12.8618, at: 240),
        ]

        let result = TrailMatcher.match(points: points, graph: parallelPairGraph())

        #expect(result.matchedTrailName == "Upper Trail")
        #expect(result.currentTrail?.name == "Upper Trail")
        #expect(result.matchedLegCount == 4)
        #expect(result.ambiguousLegCount == 0)
        // Every drawn coordinate is on the upper trail. A metre of tolerance
        // still excludes the lower trail 10 m away and the junction 5 m south.
        #expect(result.points.allSatisfy { abs($0.latitude - 47.63009) < 0.00001 })
        #expect(result.didMoveRoute)
    }

    /// The same shape walked along the lower trail, so the assertion above
    /// cannot be passing because the matcher prefers whichever way was listed
    /// first or happens to sort earlier by name.
    @Test("a walker on the lower of two trails 10 m apart stays on it")
    func lowerOfParallelPairWins() {
        let points = [
            point(47.630002, 12.8602, at: 0),
            point(47.629994, 12.8606, at: 60),
            point(47.630050, 12.8610, at: 120),
            point(47.630005, 12.8614, at: 180),
            point(47.630000, 12.8618, at: 240),
        ]

        let result = TrailMatcher.match(points: points, graph: parallelPairGraph())

        #expect(result.matchedTrailName == "Lower Trail")
        #expect(result.currentTrail?.name == "Lower Trail")
        #expect(result.matchedLegCount == 4)
        #expect(result.points.allSatisfy { abs($0.latitude - 47.63000) < 0.00001 })
    }

    // MARK: - Y fork

    /// A stem running north into a junction that splits north-east and
    /// north-west.
    private func forkGraph() -> TrailGraph {
        graph(
            nodes: [
                (1, 47.6290, 12.8600),
                (2, 47.6300, 12.8600),
                (3, 47.6310, 12.8620),
                (4, 47.6310, 12.8580),
            ],
            ways: [
                (10, [1, 2], "Stem"),
                (11, [2, 3], "East Branch"),
                (12, [2, 4], "West Branch"),
            ]
        )
    }

    /// Two fixes up the stem and three out along the east branch, each sitting
    /// exactly on its edge.
    ///
    /// Three legs of the five name the east branch and two name the stem, so
    /// the run is an east-branch walk, and nothing drawn may sit west of the
    /// junction's longitude.
    @Test("a fork walked east is drawn east")
    func eastBranchOfForkWins() {
        let points = [
            point(47.6292, 12.8600, at: 0),
            point(47.6298, 12.8600, at: 60),
            point(47.6302, 12.8604, at: 120),
            point(47.6306, 12.8612, at: 180),
            point(47.6309, 12.8618, at: 240),
        ]

        let result = TrailMatcher.match(points: points, graph: forkGraph())

        #expect(result.matchedTrailName == "East Branch")
        #expect(result.currentTrail?.name == "East Branch")
        #expect(result.matchedLegCount == 4)
        #expect(result.ambiguousLegCount == 0)
        #expect(result.points.allSatisfy { $0.longitude >= 12.8600 - 0.000001 })
        // The walk only ever went north; a leg drawn round the wrong branch
        // would have to come back down.
        #expect(zip(result.points, result.points.dropFirst()).allSatisfy { earlier, later in
            later.latitude >= earlier.latitude - 0.000001
        })
    }

    /// The mirror image, for the same reason as the lower-trail case: the fork
    /// must be decided by the fixes rather than by the order the ways were
    /// added or the alphabetical order of their names.
    @Test("a fork walked west is drawn west")
    func westBranchOfForkWins() {
        let points = [
            point(47.6292, 12.8600, at: 0),
            point(47.6298, 12.8600, at: 60),
            point(47.6302, 12.8596, at: 120),
            point(47.6306, 12.8588, at: 180),
            point(47.6309, 12.8582, at: 240),
        ]

        let result = TrailMatcher.match(points: points, graph: forkGraph())

        #expect(result.matchedTrailName == "West Branch")
        #expect(result.currentTrail?.name == "West Branch")
        #expect(result.matchedLegCount == 4)
        #expect(result.points.allSatisfy { $0.longitude <= 12.8600 + 0.000001 })
    }

    // MARK: - Switchback

    /// A hairpin: north up one arm to an apex at 47.6309, then back south down
    /// a second arm 30 m to the east at its foot.
    private func switchbackGraph() -> TrailGraph {
        graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6309, 12.8600),
                (3, 47.6300, 12.8604),
            ],
            ways: [
                (10, [1, 2], "West Zag"),
                (11, [2, 3], "East Zag"),
            ]
        )
    }

    /// The six fixes: three up the west arm at 10 %, 50 % and 85 % of its
    /// length, three down the east arm at 30 %, 60 % and 90 % of its.
    private func switchbackWalk() -> [RecordingPoint] {
        [
            point(47.630090, 12.860000, at: 0),
            point(47.630450, 12.860000, at: 60),
            point(47.630765, 12.860000, at: 120),
            point(47.630630, 12.860120, at: 180),
            point(47.630360, 12.860240, at: 240),
            point(47.630090, 12.860360, at: 300),
        ]
    }

    /// Asked directly, the matcher does route the turn round the apex.
    ///
    /// The two fixes either side of the hairpin are 17.5 m apart in a straight
    /// line and 46.3 m apart along the trail — 15.0 m up to the apex node and
    /// 31.3 m back down — and there is no other way between them, so the apex
    /// coordinate is in the path it returns. This is asserted separately from
    /// the walk below so the two cannot be confused: the routing is correct,
    /// and what the walk loses is lost somewhere else.
    @Test("the leg across a switchback apex routes over the apex node")
    func switchbackTransitionCrossesApex() throws {
        var index = TrailMatcherGraphIndex(graph: switchbackGraph())
        let westEdge = try #require(index.edges.firstIndex { edge in
            edge.id.wayID == 10
        })
        let eastEdge = try #require(index.edges.firstIndex { edge in
            edge.id.wayID == 11
        })
        let from = TrailMatcherCandidate(
            edgeIndex: westEdge,
            projectedCoordinate: CLLocationCoordinate2D(
                latitude: 47.630765,
                longitude: 12.8600
            ),
            offsetMeters: index.edges[westEdge].lengthMeters * 0.85,
            offRouteMeters: 0
        )
        let to = TrailMatcherCandidate(
            edgeIndex: eastEdge,
            projectedCoordinate: CLLocationCoordinate2D(
                latitude: 47.630630,
                longitude: 12.860120
            ),
            offsetMeters: index.edges[eastEdge].lengthMeters * 0.3,
            offRouteMeters: 0
        )

        let scored = index.transition(
            from: from,
            to: to,
            parameters: TrailMatcherTransitionParameters(
                expectedDistance: 17.5,
                maximumDistance: 226,
                beta: 30,
                isSparse: false,
                hasDistanceEvidence: false,
                startEndpointTolerance: 8,
                endEndpointTolerance: 8
            )
        )
        let transition = try #require(scored)

        #expect(transition.coordinates.contains { coordinate in
            abs(coordinate.latitude - 47.6309) < 0.000001
                && abs(coordinate.longitude - 12.8600) < 0.000001
        })
        #expect(abs(transition.distanceMeters - 46.35) < 1.5)
        #expect(transition.trailNames.sorted() == ["East Zag", "West Zag"])
    }

    /// The same walk end to end still loses the apex — and now says so.
    ///
    /// The confidence rule reads how far ahead the chosen state was in the
    /// forward Viterbi score at each fix, and at a hairpin the globally correct
    /// state is *behind* locally: staying on the arm you are already on
    /// explains a 17.5 m step far better than a 46.3 m trip round the apex, and
    /// only the fixes further down the far arm settle it. Both legs at the turn
    /// therefore fall below the confidence margin and are drawn as raw GPS, so
    /// the drawn route stops at the highest recorded fix — 47.630765 — and
    /// never reaches the apex at 47.6309.
    ///
    /// All of that is unchanged, and is still the conservative answer: the raw
    /// fixes are handed back untouched rather than moved onto a trail the
    /// matcher could not vouch for. What changed is that the walker is now
    /// told. The leg that declined the apex is surfaced as ambiguous, with the
    /// trail it turned down offered beside the GPS line it drew, so the cut
    /// corner can be put back from the review screen. It used to be counted
    /// neither as matched nor as ambiguous, which read as a clean walk.
    ///
    /// Only one of the two legs at the turn qualifies, and that is the rule
    /// rather than an accident. A non-confident *dense* leg is surfaced when
    /// the trail it declined is at least ``TrailMatcher/minimumDeclinedDetourMeters``
    /// longer than the line it drew instead — here 46.3 m of trail against a
    /// 17.5 m step straight across the corner. The `isSparse` qualifier that
    /// used to gate this was dropped because it excluded exactly this case,
    /// and the detour test replaces it rather than nothing: surfacing every
    /// non-confident dense leg put 74–130 sections on the review screen after
    /// an ordinary walk, against 4–8 before. Do not reintroduce the sparse
    /// qualifier, and do not drop the detour test in its place.
    @Test("a switchback loses its apex but is offered for review")
    func switchbackApexIsOfferedForReview() throws {
        let points = switchbackWalk()

        let result = TrailMatcher.match(points: points, graph: switchbackGraph())

        // Geometry is untouched by the disclosure: the default drawing still
        // stops short of the apex, and nothing has been moved onto a trail.
        let highest = try #require(result.points.map(\.latitude).max())
        #expect(abs(highest - 47.630765) < 0.000001)
        #expect(result.matchedLegCount == 3)
        #expect(!result.didMoveRoute)
        // Legs 2 and 3 span the turn and name no trail at all.
        #expect(result.legs[2].trailNames.isEmpty)
        #expect(result.legs[3].trailNames.isEmpty)
        #expect(!result.legs[2].isBridged)
        #expect(!result.legs[3].isBridged)
        // What is matched is still matched: both arms are recognised either
        // side of the turn.
        #expect(result.legs[0].trailNames == ["West Zag"])
        #expect(result.legs[4].trailNames == ["East Zag"])
        #expect(result.currentTrail?.name == "East Zag")
        #expect(result.matchedTrailName == "West Zag")

        // The corner is now disclosed, and the count matches what is offered.
        #expect(result.ambiguousLegCount == 1)
        #expect(result.ambiguities.count == 1)
        let ambiguity = try #require(result.ambiguities.first)
        let alternative = try #require(ambiguity.alternatives.first)
        // What is offered is the apex itself, over both arms of the hairpin.
        #expect(alternative.points.contains { drawn in
            abs(drawn.latitude - 47.6309) < 0.000001
                && abs(drawn.longitude - 12.8600) < 0.000001
        })
        #expect(alternative.trailNames == ["East Zag", "West Zag"])
        #expect(abs(alternative.distanceMeters - 46.35) < 1.5)

        // And the review screen presents it as a real choice: keep the GPS
        // line that is drawn today, or take the trail round the corner.
        let sections = RouteReviewSection.sections(in: result)
        let ambiguous = sections.filter { section in section.kind == .ambiguous }
        #expect(ambiguous.count == 1)
        let section = try #require(ambiguous.first)
        #expect(section.defaultChoice == .gps)
        #expect(section.availableChoices == [.gps, .alternative(0)])
    }

    /// The abstention is confined to the turn: nothing is drawn outside the
    /// hairpin, and the walk still goes up one arm and down the other.
    @Test("a switchback stays inside its own two arms")
    func switchbackStaysWithinItsArms() {
        let result = TrailMatcher.match(
            points: switchbackWalk(),
            graph: switchbackGraph()
        )

        #expect(result.points.allSatisfy { drawn in
            drawn.longitude >= 12.8600 - 0.000001
                && drawn.longitude <= 12.8604 + 0.000001
        })
        #expect(result.points.allSatisfy { drawn in
            drawn.latitude <= 47.6309 + 0.000001
        })
        #expect(result.points.count == 6)
    }
}
