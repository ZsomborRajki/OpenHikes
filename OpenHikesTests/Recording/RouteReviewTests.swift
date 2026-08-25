//
//  RouteReviewTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Route review sections")
struct RouteReviewTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: Fixtures

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
        ways: [(Int64, [Int64], String?)]
    ) -> TrailGraph {
        let graphNodes = nodes.map { node in
            TrailGraphNode(
                id: node.0,
                coordinate: CLLocationCoordinate2D(
                    latitude: node.1,
                    longitude: node.2
                )
            )
        }
        let byID = Dictionary(
            uniqueKeysWithValues: graphNodes.map { ($0.id, $0) }
        )
        var edges: [TrailGraphEdge] = []
        for way in ways {
            for index in 0..<(way.1.count - 1) {
                guard let from = byID[way.1[index]],
                      let to = byID[way.1[index + 1]] else { continue }
                edges.append(
                    TrailGraphEdge(
                        id: TrailGraphEdgeID(
                            wayID: way.0,
                            segmentIndex: index
                        ),
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
                    )
                )
            }
        }
        return TrailGraph(nodes: graphNodes, edges: edges)
    }

    /// A straight named trail with fixes recorded ~7.5 m to its east, so every
    /// leg is confidently snapped and therefore reviewable.
    private func snappedFixture() -> (
        result: TrailMatchResult,
        points: [RecordingPoint]
    ) {
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6306, 12.8600),
            ],
            ways: [(10, [1, 2], "Ridge Path")]
        )
        let points = [
            point(47.6300, 12.86010, at: 0),
            point(47.6302, 12.86010, at: 10),
            point(47.6304, 12.86010, at: 20),
        ]
        return (
            TrailMatcher.match(points: points, graph: graph),
            points
        )
    }

    /// Two plausible ways through one sparse gap, which is what the matcher
    /// refuses to decide on its own.
    private func ambiguousFixture() -> (
        result: TrailMatchResult,
        points: [RecordingPoint]
    ) {
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6302, 12.8600),
                (3, 47.6340, 12.8600),
                (4, 47.6340, 12.8640),
                (5, 47.6302, 12.8640),
                (6, 47.6300, 12.8640),
                (7, 47.6260, 12.8600),
                (8, 47.6260, 12.8640),
            ],
            ways: [
                (10, [1, 2], "Fork Trail"),
                (11, [2, 3, 4, 5], "North Fork"),
                (12, [2, 7, 8, 5], "South Fork"),
                (13, [5, 6], "Fork Trail"),
            ]
        )
        let points = [
            point(47.6300, 12.8600, at: 0, accuracy: 5),
            point(47.6300, 12.8640, at: 720, accuracy: 5),
        ]
        return (
            TrailMatcher.match(points: points, graph: graph),
            points
        )
    }
}

// MARK: - Section building

extension RouteReviewTests {
    @Test("a snapped run becomes one reviewable section")
    func snappedLegsCollapseIntoOneSection() throws {
        let fixture = snappedFixture()

        let sections = RouteReviewSection.sections(in: fixture.result)

        #expect(sections.count == 1)
        let section = try #require(sections.first)
        #expect(section.kind == .snapped)
        #expect(section.legIndices == [0, 1])
        #expect(section.trailName == "Ridge Path")
        #expect(section.defaultChoice == .matched)
        #expect(section.availableChoices == [.matched, .gps])
        #expect(section.rawPoints.map(\.coordinate.latitude)
            == fixture.points.map(\.latitude))
    }

    @Test("an ambiguous leg stays its own section with its alternatives")
    func ambiguousLegBecomesItsOwnSection() throws {
        let fixture = ambiguousFixture()

        let sections = RouteReviewSection.sections(in: fixture.result)

        #expect(sections.count == 1)
        let section = try #require(sections.first)
        #expect(section.kind == .ambiguous)
        #expect(section.alternatives.count >= 2)
        #expect(section.defaultChoice == .gps)
        #expect(section.availableChoices.first == .gps)
        #expect(section.availableChoices.count == section.alternatives.count + 1)
    }

    @Test("legs the matcher left alone are not offered as a choice")
    func unmatchedLegsProduceNoSection() {
        let points = [
            point(47.6300, 12.8600, at: 0),
            point(47.6302, 12.8600, at: 10),
        ]

        let result = TrailMatcher.match(points: points, graph: .empty)

        #expect(result.legs.isEmpty)
        #expect(RouteReviewSection.sections(in: result).isEmpty)
    }

    @Test("a section reports the distance of each option")
    func sectionMeasuresBothOptions() throws {
        let fixture = snappedFixture()

        let section = try #require(
            RouteReviewSection.sections(in: fixture.result).first
        )

        #expect(section.matchedDistanceMeters > 0)
        #expect(section.rawDistanceMeters > 0)
        // The recorded line is east of the trail but runs parallel to it, so
        // both options cover the same ground to within a metre.
        #expect(
            abs(section.matchedDistanceMeters - section.rawDistanceMeters) < 1
        )
    }
}

// MARK: - Resolving a choice

extension RouteReviewTests {
    @Test("keeping the trail leaves the matched geometry in place")
    func matchedChoiceKeepsSnappedGeometry() {
        let fixture = snappedFixture()
        let review = RecordingRouteReview(
            sections: RouteReviewSection.sections(in: fixture.result)
        )

        let resolved = fixture.result.points(resolving: review.legChoices)

        #expect(resolved == fixture.result.points)
        #expect(resolved.allSatisfy { point in
            abs(point.longitude - 12.8600) < 0.00001
        })
    }

    @Test("handing a section back to GPS restores the recorded fixes")
    func gpsChoiceRestoresRawGeometry() {
        let fixture = snappedFixture()
        let review = RecordingRouteReview(
            sections: RouteReviewSection.sections(in: fixture.result)
        )

        review.select(.gps)
        let resolved = fixture.result.points(resolving: review.legChoices)

        #expect(resolved.count == fixture.points.count)
        #expect(resolved.map(\.coordinate.latitude)
            == fixture.points.map(\.latitude))
        #expect(resolved.allSatisfy { point in
            abs(point.longitude - 12.86010) < 0.000001
        })
    }

    @Test("a section choice reaches every leg the section covers")
    func choiceExpandsAcrossTheSectionsLegs() throws {
        let fixture = snappedFixture()
        let review = RecordingRouteReview(
            sections: RouteReviewSection.sections(in: fixture.result)
        )
        let section = try #require(review.current)

        review.select(.gps)

        #expect(review.legChoices.count == section.legIndices.count)
        #expect(section.legIndices.allSatisfy { legIndex in
            review.legChoices[legIndex] == .gps
        })
    }

    @Test("a leg nobody reviewed keeps the matcher's own geometry")
    func unreviewedLegsKeepMatchedGeometry() {
        let fixture = snappedFixture()

        let resolved = fixture.result.points(resolving: [:])

        #expect(resolved == fixture.result.points)
    }

    @Test("choosing an alternative rewrites only the ambiguous leg")
    func alternativeChoiceReplacesTheAmbiguousLeg() throws {
        let fixture = ambiguousFixture()
        let review = RecordingRouteReview(
            sections: RouteReviewSection.sections(in: fixture.result)
        )
        let section = try #require(review.current)
        let alternative = try #require(section.alternatives.first)

        review.select(.alternative(alternative.id))
        let resolved = fixture.result.points(resolving: review.legChoices)

        #expect(resolved.count > fixture.points.count)
        #expect(resolved.first?.coordinate.latitude == fixture.points.first?.latitude)
        #expect(resolved.last?.coordinate.latitude == fixture.points.last?.latitude)
    }
}

// MARK: - Review navigation

extension RouteReviewTests {
    @Test("the review starts on the first section and walks forward once")
    func navigationStaysInsideTheSectionList() {
        let fixture = snappedFixture()
        let review = RecordingRouteReview(
            sections: RouteReviewSection.sections(in: fixture.result)
        )

        #expect(review.currentIndex == 0)
        #expect(!review.canMoveBackward)
        #expect(!review.canMoveForward)

        review.moveForward()
        #expect(review.currentIndex == 0, "a single section cannot advance")

        review.moveBackward()
        #expect(review.currentIndex == 0)
    }

    @Test("selecting only changes the section being shown")
    func selectionAppliesToTheCurrentSection() throws {
        let fixture = snappedFixture()
        let sections = RouteReviewSection.sections(in: fixture.result)
        let review = RecordingRouteReview(sections: sections)
        let section = try #require(review.current)

        #expect(review.choice(for: section) == .matched)
        review.select(.gps)
        #expect(review.choice(for: section) == .gps)
        #expect(review.choices.count == sections.count)
    }

    @Test("the highlighted geometry follows the chosen option")
    func highlightFollowsTheChoice() throws {
        let fixture = snappedFixture()
        let review = RecordingRouteReview(
            sections: RouteReviewSection.sections(in: fixture.result)
        )
        let section = try #require(review.current)

        let matched = section.points(for: review.choice(for: section))
        review.select(.gps)
        let raw = section.points(for: review.choice(for: section))

        #expect(matched == section.matchedPoints)
        #expect(raw == section.rawPoints)
        #expect(matched != raw)
    }
}

// MARK: - UI automation fixture

extension RouteReviewTests {
    /// The UI test walks a simulated route beside a bundled trail and expects
    /// a section to review. That expectation is arithmetic on the matcher, so
    /// it is checked here — a fixture that stops snapping fails in seconds
    /// instead of as a puzzling simulator failure.
    @Test("the bundled UI-test graph produces a section to review")
    func bundledGraphFixtureIsReviewable() throws {
        let provider = try #require(
            BundledTrailGraphProvider(
                fixtureName: UITestRecordingFixture.trailGraphName
            )
        )
        let points = UITestRecordingFixture.coordinates.enumerated().map { fix in
            point(
                fix.element.latitude,
                fix.element.longitude,
                at: TimeInterval(fix.offset) * 5,
                accuracy: 5
            )
        }
        let graph = try #require(
            provider.cachedGraph(covering: points.map(\.coordinate))
        )

        let result = TrailMatcher.match(points: points, graph: graph)
        let sections = RouteReviewSection.sections(in: result)

        #expect(result.didMoveRoute)
        #expect(sections.count == 1)
        #expect(sections.first?.kind == .snapped)
        #expect(sections.first?.trailName == "Thumsee Ridge Path")
    }

    /// The Previous/Next buttons are disabled with one section, so the test
    /// that drives them needs a walk that produces two. Which walk that is, is
    /// arithmetic on the matcher and the run-flushing rule — so it is settled
    /// here, in seconds, rather than by watching a simulator walk for a minute
    /// and guessing at why the buttons stayed grey.
    @Test("the twin-path fixture produces two sections to review")
    func twinPathFixtureProducesTwoSections() throws {
        let provider = try #require(
            BundledTrailGraphProvider(
                fixtureName: UITestMultiSectionFixture.trailGraphName
            )
        )
        let points = UITestMultiSectionFixture.coordinates.enumerated().map { fix in
            point(
                fix.element.latitude,
                fix.element.longitude,
                at: TimeInterval(fix.offset) * 5,
                accuracy: 5
            )
        }
        let graph = try #require(
            provider.cachedGraph(covering: points.map(\.coordinate))
        )

        let result = TrailMatcher.match(points: points, graph: graph)
        let sections = RouteReviewSection.sections(in: result)

        #expect(result.didMoveRoute)
        #expect(sections.count == 2)
        #expect(sections.allSatisfy { section in section.kind == .snapped })
        // One section per trail, in the order they were walked — which is what
        // makes "Next" a meaningful thing for the UI test to assert on.
        #expect(sections.first?.trailName == "Thumsee Ridge Path")
        #expect(sections.last?.trailName == "Seehaus Link")
    }
}

/// The route the UI test walks, kept beside the assertion that it still
/// produces a reviewable section. `OpenHikesUITests` holds the same numbers;
/// they are duplicated rather than shared because the UI bundle runs
/// out-of-process and cannot import the app.
enum UITestRecordingFixture {
    static let trailGraphName = "ThumseeRidgePath"
    /// East of the bundled trail, which runs due north along one longitude.
    static let longitude = 12.83180
    static let startLatitude = 47.71840
    static let middleLatitude = 47.71860
    static let endLatitude = 47.71880
    static var coordinates: [CLLocationCoordinate2D] {
        [startLatitude, middleLatitude, endLatitude].map { latitude in
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
}

/// The longer walk behind the review screen's Previous/Next buttons.
///
/// Those buttons only exist when there is more than one section, and one
/// section is all the fixture above can ever produce. Two need a walk that is
/// snapped, then left alone for long enough to close the run
/// (``RouteReviewSection/absorbedUnmovedDistanceMeters``), then snapped again
/// — which is why this is a second graph with two disconnected trails rather
/// than a longer trace over the first.
///
/// The gap is walked, not skipped: the fixes across it are further than the
/// matcher's 50 m candidate radius from either trail, so it has nothing to
/// snap them to and leaves them on the recorded line. That is exactly the
/// "matching agreed with me here" stretch that separates one decision from
/// the next.
enum UITestMultiSectionFixture {
    static let trailGraphName = "ThumseeTwinPaths"
    static let longitude = 12.83180
    static let startLatitude = 47.71840
    /// 22 m at the four-second pace UI automation walks — a believable stride
    /// rather than one ``RecordingFixPolicy`` turns down for implied speed.
    static let latitudeStep = 0.0002
    static let fixCount = 17

    static var coordinates: [CLLocationCoordinate2D] {
        (0..<fixCount).map { index in
            CLLocationCoordinate2D(
                latitude: startLatitude + latitudeStep * Double(index),
                longitude: longitude
            )
        }
    }
}
