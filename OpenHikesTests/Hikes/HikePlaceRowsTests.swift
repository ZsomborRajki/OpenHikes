//
//  HikePlaceRowsTests.swift
//  OpenHikesTests
//
//  A saved hike's places, measured along its line once and reused: what a
//  body pass measures again, what it does not, and where the measuring runs.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Synchronization
import Testing

@MainActor
@Suite("Hike place rows")
struct HikePlaceRowsTests {
    /// The real projection, counted: how often it ran, how many places it was
    /// asked about, and how often that was on the main thread.
    nonisolated private final class Tally: Sendable {
        private struct Counts {
            var calls = 0
            var places = 0
            var onMainThread = 0
        }

        private let counts = Mutex(Counts())

        var calls: Int { counts.withLock { $0.calls } }
        var places: Int { counts.withLock { $0.places } }
        var onMainThread: Int { counts.withLock { $0.onMainThread } }

        func measure(_ places: [TrailPlace], _ route: [RouteCoordinate]) -> [UUID: TrailPlaceAnchor] {
            let onMain = pthread_main_np() != 0
            counts.withLock { counts in
                counts.calls += 1
                counts.places += places.count
                if onMain { counts.onMainThread += 1 }
            }
            return TrailPlaceOrder.anchors(of: places, along: route)
        }
    }

    private enum Line {
        static let south = 47.60
        static let north = 47.70
        static let longitude = 12.98
        static let points = 400
    }

    /// A straight line north, `Line.points` long — enough segments that the
    /// projection is worth keeping, and few enough to be quick.
    private static func route(northward: Bool = true) -> [RouteCoordinate] {
        let step = (Line.north - Line.south) / Double(Line.points - 1)
        let route = (0..<Line.points).map { index in
            RouteCoordinate(latitude: Line.south + Double(index) * step, longitude: Line.longitude)
        }
        return northward ? route : route.reversed()
    }

    /// Places along the line, marked from the north end down, so the order
    /// they are met walking north is not the order they were marked in.
    private static func places(_ count: Int) -> [TrailPlace] {
        (0..<count).map { index in
            TrailPlace(
                latitude: Line.north - 0.005 - Double(index) * 0.008,
                longitude: Line.longitude + 0.0002,
                name: "Place \(index)"
            )
        }
    }

    private func hike(places count: Int = 8) throws -> (Hike, ModelContext) {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route())
        hike.replacePlaces(with: Self.places(count), in: context)
        try context.save()
        return (hike, context)
    }

    private static func rows(_ tally: Tally, budget: Int = HikePlaceRows.synchronousBudget) -> HikePlaceRows {
        HikePlaceRows(budget: budget) { places, route in tally.measure(places, route) }
    }

    // MARK: Reuse

    /// The finding: the detail screen's *Places* section re-ran the whole
    /// projection on every pass, and a pass comes with every photograph added.
    @Test("the places section measures the line once across its passes")
    func sectionMeasuresOnce() async throws {
        let (hike, _) = try hike()
        let tally = Tally()
        let rows = Self.rows(tally, budget: 0)
        let pins = TrailPlacePinController(placeRows: rows)

        _ = HikePlaceSection(hike: hike, mapPins: pins).body
        await settleDelegateHop(until: "the anchors land") { rows.revision == 1 }
        for _ in 0..<3 {
            _ = HikePlaceSection(hike: hike, mapPins: pins).body
            _ = HikePlacePinClaim(hike: hike, controller: pins).body
        }

        #expect(tally.calls == 1)
        #expect(rows.rows(of: hike) == hike.orderedPlaces)
    }

    @Test("a renamed place and a new photograph reuse what was measured")
    func textAndPhotosMeasureNothing() throws {
        let (hike, _) = try hike()
        let tally = Tally()
        let rows = Self.rows(tally)
        _ = rows.rows(of: hike)
        let renamed = try #require(hike.places.first)

        #expect(hike.editPlace(id: renamed.id, name: "Spring", symbol: .water, note: "Cold"))
        var photo = HikePhoto()
        photo.placeID = renamed.id
        hike.addPhoto(photo)
        let after = rows.rows(of: hike)

        #expect(tally.calls == 1, "nothing about the line or where a place stands moved")
        #expect(after == hike.orderedPlaces)
        #expect(after.first { $0.id == renamed.id }?.place.name == "Spring", "the row says what the hike says now")
    }

    // MARK: What measures again

    @Test("an edited route measures every place again, and the order follows it")
    func editedRouteMeasuresAgain() throws {
        let (hike, _) = try hike()
        let tally = Tally()
        let rows = Self.rows(tally)
        let north = rows.rows(of: hike)

        hike.route = Self.route(northward: false)
        let south = rows.rows(of: hike)

        #expect(tally.calls == 2)
        #expect(tally.places == 16)
        #expect(south == hike.orderedPlaces)
        #expect(south.map(\.id) == north.map(\.id).reversed(), "walked the other way, met the other way round")
    }

    @Test("a place added or moved is measured alone")
    func addedOrMovedPlaceIsMeasuredAlone() throws {
        let (hike, context) = try hike()
        let tally = Tally()
        let rows = Self.rows(tally)
        _ = rows.rows(of: hike)

        let added = TrailPlace(latitude: Line.south + 0.001, longitude: Line.longitude, name: "Trailhead")
        #expect(hike.addPlace(added, in: context))
        let withAdded = rows.rows(of: hike)
        #expect(tally.places == 9)
        #expect(withAdded.first?.id == added.id, "and takes its place along the line at once")

        // As a sync moving it on another device writes it.
        let moved = try #require(hike.trailPoints?.first { $0.id == added.id })
        moved.latitude = Line.north - 0.001
        let withMoved = rows.rows(of: hike)

        #expect(tally.places == 10)
        #expect(withMoved.last?.id == added.id)
        #expect(withMoved == hike.orderedPlaces)
    }

    // MARK: Where the measuring runs

    @Test("a long trail is measured off the main thread, and draws what it has meanwhile")
    func longTrailIsMeasuredOffTheMainThread() async throws {
        let (hike, _) = try hike()
        let tally = Tally()
        let rows = Self.rows(tally, budget: 0)

        let first = rows.rows(of: hike)
        #expect(first.map(\.id) == hike.places.map(\.id), "in the order they were marked, until measured")
        #expect(first.allSatisfy { $0.anchor == nil })

        await settleDelegateHop(until: "the anchors land") { rows.revision == 1 }

        #expect(tally.calls == 1)
        #expect(tally.onMainThread == 0)
        #expect(rows.rows(of: hike) == hike.orderedPlaces)
    }

    @Test("a short trail is measured in the read that needs it")
    func shortTrailIsMeasuredAtOnce() throws {
        let (hike, _) = try hike()
        let tally = Tally()
        let rows = Self.rows(tally)
        let place = try #require(hike.places.first)

        #expect(rows.rows(of: hike) == hike.orderedPlaces)
        let card = HikePlaceCard(hike: hike, placeID: place.id, preparedBy: rows)
        #expect(card == HikePlaceCard(hike: hike, placeID: place.id))
        #expect(tally.calls == 1)
        #expect(rows.revision == 0, "nothing landed later, so nothing has to draw again")
    }

    /// Two answers out at once, the first about a line that has since been
    /// edited. Whichever lands last, the rows are the edited line's.
    @Test("an answer about a line edited since it was asked is dropped")
    func staleAnswerIsDropped() async throws {
        let (hike, _) = try hike()
        let tally = Tally()
        let rows = Self.rows(tally, budget: 0)

        _ = rows.rows(of: hike)
        hike.route = Self.route(northward: false)
        _ = rows.rows(of: hike)
        await settleDelegateHop(until: "both lines are measured") { tally.calls == 2 && rows.revision >= 1 }
        await settleDelegateHop()

        #expect(rows.revision == 1, "only the edited line's answer is drawn")
        #expect(rows.rows(of: hike) == hike.orderedPlaces)
    }

    // MARK: The detached-row guard

    @Test("a deleted hike has no places, and nothing is measured")
    func deletedHikeHasNoRows() throws {
        let (hike, context) = try hike()
        let tally = Tally()
        let rows = Self.rows(tally)
        let place = try #require(hike.places.first)

        context.delete(hike)
        try context.save()

        #expect(rows.rows(of: hike).isEmpty)
        #expect(rows.row(place.id, of: hike) == nil)
        #expect(tally.calls == 0)
    }
}
