//
//  TrailStopRecentsTests.swift
//  OpenHikesTests
//
//  The stop search's *Recents*: what is kept, in what order, and what is not.
//
//  Three rules are worth pinning because a picture of the list could not tell
//  them apart from their opposites. A place picked twice is one row, at the
//  top. The list stops at ``TrailStopRecents/limit``. And a *My Location* pick
//  — which names nothing, and is somewhere else tomorrow — is never kept.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail stop recents")
struct TrailStopRecentsTests {
    private static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TrailStopRecentsTests-\(UUID().uuidString)"))
    }

    private static func pick(_ name: String, _ latitude: Double, subtitle: String = "") -> TrailStopSearchPick {
        TrailStopSearchPick(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 12.98),
            subtitle: subtitle
        )
    }

    @Test("a picked place goes to the top, with the address it was offered with")
    func aPickGoesToTheTop() {
        let recents = TrailStopRecents(defaults: nil)
        recents.record(Self.pick("Wimbachbrücke", 47.60, subtitle: "Ramsau"))
        recents.record(Self.pick("Kärlingerhaus", 47.51))

        #expect(recents.entries.map(\.name) == ["Kärlingerhaus", "Wimbachbrücke"])
        #expect(recents.entries.last?.subtitle == "Ramsau")
    }

    /// Picking the same car park again moves it up rather than listing it
    /// twice — and a pick a few metres from the first, which is what a second
    /// resolve of the same suggestion lands on, is still the same place.
    @Test("a place picked again is one row, moved to the top")
    func aPlacePickedAgainIsOneRow() {
        let recents = TrailStopRecents(defaults: nil)
        recents.record(Self.pick("Wimbachbrücke", 47.60))
        recents.record(Self.pick("Kärlingerhaus", 47.51))
        recents.record(Self.pick("Wimbachbrücke", 47.60005))

        #expect(recents.entries.map(\.name) == ["Wimbachbrücke", "Kärlingerhaus"])
    }

    /// Two huts sharing a name across a range are two places.
    @Test("the same name far apart is two places")
    func theSameNameFarApartIsTwoPlaces() {
        let recents = TrailStopRecents(defaults: nil)
        recents.record(Self.pick("Watzmannhaus", 47.57))
        recents.record(Self.pick("Watzmannhaus", 47.61))

        #expect(recents.entries.count == 2)
    }

    @Test("the list keeps the newest few and drops the oldest")
    func theListIsBounded() {
        let recents = TrailStopRecents(defaults: nil)
        for index in 0...TrailStopRecents.limit {
            recents.record(Self.pick("Place \(index)", 47.0 + Double(index) / 10))
        }

        #expect(recents.entries.count == TrailStopRecents.limit)
        #expect(recents.entries.first?.name == "Place \(TrailStopRecents.limit)")
        #expect(!recents.entries.contains { $0.name == "Place 0" })
    }

    /// *My Location* hands back a pick with no name — see
    /// ``TrailStopSearchSheet`` — and where the hiker stood is not a place
    /// they will want to pick again.
    @Test("a pick with no name is not kept")
    func aMyLocationPickIsNotKept() {
        let recents = TrailStopRecents(defaults: nil)
        recents.record(Self.pick("", 47.60))

        #expect(recents.entries.isEmpty)
    }

    @Test("a swipe forgets one entry")
    func aSwipeForgetsOne() {
        let recents = TrailStopRecents(defaults: nil)
        recents.record(Self.pick("Wimbachbrücke", 47.60))
        recents.record(Self.pick("Kärlingerhaus", 47.51))

        recents.remove(atOffsets: IndexSet(integer: 0))

        #expect(recents.entries.map(\.name) == ["Wimbachbrücke"])
    }

    @Test("the list survives a relaunch")
    func theListSurvivesARelaunch() throws {
        let defaults = try Self.defaults()
        let recents = TrailStopRecents(defaults: defaults)
        recents.record(Self.pick("Wimbachbrücke", 47.60, subtitle: "Ramsau"))
        recents.record(Self.pick("Kärlingerhaus", 47.51))

        let relaunched = TrailStopRecents(defaults: defaults)

        #expect(relaunched.entries.map(\.name) == ["Kärlingerhaus", "Wimbachbrücke"])
        #expect(relaunched.entries.last?.pick == Self.pick("Wimbachbrücke", 47.60, subtitle: "Ramsau"))
    }

    /// The row a recent is tapped from puts it down exactly as it was picked
    /// the first time, and moves it back to the top.
    @Test("choosing a recent again keeps it one row, at the top")
    func choosingARecentAgain() throws {
        let recents = TrailStopRecents(defaults: nil)
        recents.record(Self.pick("Wimbachbrücke", 47.60))
        recents.record(Self.pick("Kärlingerhaus", 47.51))
        let older = try #require(recents.entries.last)

        recents.record(older.pick)

        #expect(recents.entries.map(\.name) == ["Wimbachbrücke", "Kärlingerhaus"])
    }
}
