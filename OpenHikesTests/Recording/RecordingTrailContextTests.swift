//
//  RecordingTrailContextTests.swift
//  OpenHikesTests
//
//  What the live matcher now says about the ground underfoot, beyond the
//  trail's name.
//
//  The graph these run against was already being downloaded and matched
//  during a recording — every fix resolves a way in order to snap the line —
//  so what is pinned here is that the tags on that way reach the screen, and
//  that they stop reaching it at exactly the moment the matcher stops being
//  sure where the walker is.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Recording trail context")
struct RecordingTrailContextTests {
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
            horizontalAccuracy: accuracy
        )
    }

    /// One straight named way carrying whichever tags a test is about.
    private func graph(
        name: String?,
        sacScale: String? = nil,
        surface: String? = nil,
        tracktype: String? = nil
    ) -> TrailGraph {
        let from = TrailGraphNode(
            id: 1,
            coordinate: CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        )
        let to = TrailGraphNode(
            id: 2,
            coordinate: CLLocationCoordinate2D(latitude: 47.6306, longitude: 12.8600)
        )
        return TrailGraph(
            nodes: [from, to],
            edges: [
                TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: 10, segmentIndex: 0),
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    lengthMeters: RouteGeometry.distanceMeters(
                        from: from.coordinate,
                        to: to.coordinate
                    ),
                    name: name,
                    sacScale: sacScale,
                    surface: surface,
                    tracktype: tracktype
                ),
            ]
        )
    }

    private var walkedTrace: [RecordingPoint] {
        [
            point(47.6300, 12.86010, at: 0),
            point(47.6302, 12.86010, at: 10),
            point(47.6304, 12.86010, at: 20),
        ]
    }

    // MARK: What reaches the screen

    @Test("a matched way carries its grade and surface, not only its name")
    func matchedWayCarriesItsTags() throws {
        let result = TrailMatcher.match(
            points: walkedTrace,
            graph: graph(
                name: "Ridge Path",
                sacScale: "mountain_hiking",
                surface: "gravel"
            )
        )

        let trail = try #require(result.currentTrail)
        #expect(trail.name == "Ridge Path")
        #expect(trail.difficulty == .mountainHiking)
        #expect(trail.surface == .gravel)
        #expect(trail.descriptors == ["Mountain Hiking", "Gravel"])
    }

    /// The two halves are independent. A forestry track is tagged and
    /// nameless, and reporting nothing for it would throw away the only thing
    /// OSM actually knows about the ground.
    @Test("an unnamed way still reports what it is made of")
    func unnamedWayStillReportsItsTags() throws {
        let result = TrailMatcher.match(
            points: walkedTrace,
            graph: graph(name: nil, surface: "ground")
        )

        let trail = try #require(result.currentTrail)
        #expect(trail.name == nil)
        #expect(trail.surface == .ground)
        #expect(!trail.isEmpty)
    }

    /// `tracktype` is a firmness grade rather than a material, and roughly a
    /// fifth of untagged tracks carry one. It is consulted through the same
    /// initializer the saved-hike breakdown uses, so a live reading and a
    /// saved one cannot classify the same way differently.
    @Test("a track with no surface tag falls back to its tracktype")
    func tracktypeFillsInForAMissingSurface() throws {
        let result = TrailMatcher.match(
            points: walkedTrace,
            graph: graph(name: "Forest Track", surface: nil, tracktype: "grade1")
        )

        let trail = try #require(result.currentTrail)
        #expect(trail.surface == .paved)
    }

    // MARK: What must not reach it

    /// A walker who has stepped off the path is told nothing, rather than
    /// told about the path they left — which for the surface and the grade
    /// matters more than it did for the name: "T2, rock" describes ground the
    /// walker is provably not standing on.
    @Test("a trace that leaves the graph reports no trail at all")
    func unmatchableTraceReportsNothing() {
        let far = [
            point(47.7000, 12.9000, at: 0),
            point(47.7010, 12.9000, at: 60),
        ]

        let result = TrailMatcher.match(
            points: far,
            graph: graph(name: "Ridge Path", surface: "gravel")
        )

        #expect(result.currentTrail == nil)
    }

    @Test("an empty graph reports no trail at all")
    func emptyGraphReportsNothing() {
        let result = TrailMatcher.match(points: walkedTrace, graph: .empty)

        #expect(result.currentTrail == nil)
    }

    // MARK: Presentation rules

    /// "Unknown" beside a trail name is worse than no chip: it takes the space
    /// a real grade would and reads, at a glance, like one. Both untagged
    /// cases are OSM being silent, and silence is not a descriptor.
    @Test("an untagged way offers no descriptors to draw")
    func untaggedWayOffersNoDescriptors() throws {
        let result = TrailMatcher.match(
            points: walkedTrace,
            graph: graph(name: "Ridge Path")
        )

        let trail = try #require(result.currentTrail)
        #expect(trail.surface == .unknown)
        #expect(trail.difficulty == .unknown)
        #expect(trail.descriptors.isEmpty)
        // Not empty: there is still a name to draw.
        #expect(!trail.isEmpty)
    }

    /// The card draws nothing for this. "You are on *a* mapped path" is
    /// already what the line on the map says.
    @Test("a nameless untagged way is nothing worth drawing")
    func namelessUntaggedWayIsEmpty() throws {
        let result = TrailMatcher.match(
            points: walkedTrace,
            graph: graph(name: nil)
        )

        let trail = try #require(result.currentTrail)
        #expect(trail.isEmpty)
    }

    @Test("the grade is stated before the surface")
    func descriptorsLeadWithTheGrade() {
        let trail = RecordingTrailContext(
            name: "Ridge Path",
            surface: .rock,
            difficulty: .alpineHiking
        )

        #expect(trail.descriptors == ["Alpine Hiking", "Rock"])
    }
}
