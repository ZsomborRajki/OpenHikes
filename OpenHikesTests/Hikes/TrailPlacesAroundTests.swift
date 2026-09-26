//
//  TrailPlacesAroundTests.swift
//  OpenHikesTests
//
//  *Places Around Trail*'s claim on the map: the pale pins, the pill and the
//  press belong to the screen holding the claim, and to nothing once it goes.
//
//  The map's half — the pins MapKit draws and the tap that reaches them — is
//  in `MapCoordinatorTests+TrailPlaces.swift`.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Places around a trail on the map")
struct TrailPlacesAroundTests {
    private static let spot = CLLocationCoordinate2D(latitude: 47.61, longitude: 12.98)
    private static let row = TrailPlaceRow(place: TrailPlace(coordinate: spot, symbol: .summit), offRouteMeters: 600)

    private final class Calls {
        var selected: [UUID] = []
        var searches = 0
        var drops: [CLLocationCoordinate2D] = []
    }

    private static func handlers(_ calls: Calls) -> TrailPlacesAround.Handlers {
        TrailPlacesAround.Handlers(
            select: { calls.selected.append($0) },
            searchArea: { calls.searches += 1 },
            dropPin: { calls.drops.append($0) }
        )
    }

    @Test("a claimed screen's pins open its cards, and a press drops its pin")
    func claimedScreenAnswers() {
        let around = TrailPlacesAround()
        let calls = Calls()
        let token = around.attach(Self.handlers(calls))
        around.show([Self.row], token: token)

        #expect(around.isActive)
        #expect(around.candidates == [Self.row])
        #expect(around.select(Self.row.id))
        #expect(!around.select(UUID()), "a pin that is not one of the screen's opens nothing")
        #expect(around.dropPin(at: Self.spot))
        #expect(calls.selected == [Self.row.id])
        #expect(calls.drops.count == 1)
    }

    @Test("once the screen goes, nothing is drawn and nothing answers")
    func detachedScreenIsSilent() {
        let around = TrailPlacesAround()
        let calls = Calls()
        let token = around.attach(Self.handlers(calls))
        around.show([Self.row], token: token)

        around.detach(token: token)

        #expect(!around.isActive)
        #expect(around.candidates.isEmpty)
        #expect(!around.select(Self.row.id))
        #expect(!around.dropPin(at: Self.spot))
        #expect(calls.selected.isEmpty && calls.drops.isEmpty)
    }

    /// The screen that replaces this one appears before this one disappears,
    /// so the release has to be checked against the claim it was given.
    @Test("a stale screen's release leaves the newer claim standing")
    func staleReleaseIsIgnored() {
        let around = TrailPlacesAround()
        let first = around.attach(Self.handlers(Calls()))
        let second = around.attach(Self.handlers(Calls()))
        around.show([Self.row], token: second)

        around.detach(token: first)
        around.show([], token: first)

        #expect(around.isActive)
        #expect(around.candidates == [Self.row])
    }

    @Test("a launch that cannot ask offers no search")
    func noSourceNoSearch() {
        let around = TrailPlacesAround()
        let calls = Calls()
        around.attach(Self.handlers(calls))

        around.searchVisibleArea()

        #expect(!around.canSearch)
        #expect(calls.searches == 0)
    }
}
