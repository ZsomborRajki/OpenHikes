//
//  CuratedTrailDecodingTests+Cells.swift
//  OpenHikesTests
//
//  A square's routes are measured first and drawn only for the page.
//
//  That the page is the right routes is `TrailCellLibraryTests`' to say. What
//  is asserted here is the half no answer shows: how many routes were drawn
//  to fill it. A wide search has thousands of routes in its area and keeps
//  fifty, and a version that drew them all first would return the same fifty
//  seconds later.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

// The coordinates of the fixture's routes, which have no better names than
// their own digits.
// swiftlint:disable no_magic_numbers

extension CuratedTrailDecodingTests {
    private static let area = CuratedTrailQuery.BoundingBox(south: 47.5, west: 12.9, north: 47.7, east: 13.1)
    private static let center = CLLocationCoordinate2D(latitude: 47.6, longitude: 13)

    /// A route of one way, `index` steps north of the area's middle.
    private static func route(_ index: Int) -> TrailCellFile.Relation {
        let latitude = 47.6 + Double(index) * 0.01
        return TrailCellFixture.relation(
            Int64(index),
            name: "Route \(index)",
            from: TrailCellFixture.point(latitude, 13),
            to: TrailCellFixture.point(latitude + 0.005, 13.005)
        )
    }

    /// Two pieces of one length that do not join, nearer the middle than any
    /// of ``route(_:)``'s: a route that is measured and cannot be drawn.
    private static let inPieces = TrailCellFile.Relation(
        id: 99,
        tags: ["name": "In Pieces", "route": "hiking"],
        ways: [
            TrailCellFile.Way(
                role: "",
                points: [TrailCellFixture.point(47.599, 12.999), TrailCellFixture.point(47.5995, 12.9995)]
            ),
            TrailCellFile.Way(
                role: "",
                points: [TrailCellFixture.point(47.6005, 13.0005), TrailCellFixture.point(47.601, 13.001)]
            ),
        ]
    )

    /// `relations` as candidates nearest first, and how many of them
    /// ``CuratedTrailDecoding/drawn(_:limit:)`` asked for.
    private static func page(
        of relations: [TrailCellFile.Relation],
        limit: Int
    ) -> (trails: [CuratedTrail], asked: Int) {
        let candidates = CuratedTrailDecoding
            .candidates(in: TrailCellFile(relations: relations), touching: [area], from: center)
            .sorted { $0.distanceMeters < $1.distanceMeters }
        var remaining = candidates.makeIterator()
        var asked = 0
        let counted = AnySequence {
            AnyIterator {
                asked += 1
                return remaining.next()
            }
        }
        return (CuratedTrailDecoding.drawn(counted, limit: limit), asked)
    }

    @Test("a square's routes are measured from the point asked about, by where their pins stand")
    func candidatesAreMeasured() throws {
        let candidates = CuratedTrailDecoding.candidates(
            in: TrailCellFile(relations: [Self.route(3), Self.route(1)]),
            touching: [Self.area],
            from: Self.center
        )

        #expect(candidates.map(\.relation.id) == [3, 1])
        for candidate in candidates {
            let drawn = try #require(CuratedTrailDecoding.drawn([candidate], limit: 1).first)
            // The very measure the source orders its rows by, so the same number.
            #expect(RouteGeometry.distanceMeters(from: Self.center, to: drawn.coordinate) == candidate.distanceMeters)
        }
    }

    @Test("a page draws no more routes than it holds")
    func aPageDrawsOnlyItself() {
        let page = Self.page(of: (0..<8).map(Self.route), limit: 3)

        #expect(page.trails.map(\.relationID) == [0, 1, 2])
        #expect(page.asked == 3)
    }

    @Test("a route with nothing to draw is passed over, and costs the page one more")
    func anUndrawableRouteCostsOneMore() {
        let page = Self.page(of: [Self.inPieces] + (0..<8).map(Self.route), limit: 3)

        #expect(page.trails.map(\.relationID) == [0, 1, 2])
        #expect(page.asked == 4)
    }

    @Test("a page of nothing draws nothing")
    func anEmptyPageDrawsNothing() {
        let page = Self.page(of: (0..<8).map(Self.route), limit: 0)

        #expect(page.trails.isEmpty)
        #expect(page.asked == 0)
    }
}

// swiftlint:enable no_magic_numbers
