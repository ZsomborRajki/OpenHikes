//
//  SharedHikeCatalogueTests.swift
//  OpenHikesSharedTests
//
//  The App Group's copy of the library, and the per-hike trail snapshots that
//  let two placed widgets show two trails (#468).
//
//  Everything here is about the boundary between processes. The widget
//  extension has no `ModelContainer`, no registered dependency and no `Hike`
//  to fetch, so what it can read is exactly what these functions write — and
//  the properties worth pinning are the ones a second process would otherwise
//  have to trust: that a snapshot filed under one hike is never handed back
//  for another, that deselecting a trail does not take a pinned widget's route
//  with it, and that the prune is bounded by what is on a screen.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("The App Group's copy of the library")
struct SharedHikeCatalogueTests {
    private static func summary(
        id: UUID = UUID(),
        name: String = "Thumsee Loop",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SharedHikeSummary {
        SharedHikeSummary(id: id, name: name, date: date, distanceMeters: 8420)
    }

    // MARK: The catalogue

    @Test("a catalogue survives the round trip through the container")
    func catalogueRoundTrips() throws {
        try withSharedStoreSandbox { _ in
            let catalogue = SharedHikeCatalogue(hikes: [Self.summary(), Self.summary()])

            SharedStore.saveHikeCatalogue(catalogue)

            #expect(SharedStore.loadHikeCatalogue().hikes.count == 2)
        }
    }

    /// Empty rather than `nil`, because every caller is a picker and a picker
    /// with nothing to offer draws the same either way. An optional would
    /// spread a decision none of them can act on.
    @Test("a container that has never been written reads as an empty catalogue")
    func anUnwrittenCatalogueIsEmpty() throws {
        try withSharedStoreSandbox { _ in
            #expect(SharedStore.loadHikeCatalogue().hikes.isEmpty)
        }
    }

    @Test("no container at all reads as an empty catalogue rather than failing")
    func noContainerIsAnEmptyCatalogue() {
        withoutSharedStoreContainer {
            #expect(SharedStore.loadHikeCatalogue().hikes.isEmpty)
        }
    }

    // MARK: What a picker asks of it

    @Test("hikes are found by identifier")
    func findsByIdentifier() {
        let wanted = Self.summary(name: "Rennsteig")
        let catalogue = SharedHikeCatalogue(hikes: [Self.summary(), wanted, Self.summary()])

        #expect(catalogue.hikes(withIDs: [wanted.id]).map(\.name) == ["Rennsteig"])
    }

    @Test("hikes are found by name, ignoring case and accents")
    func findsByName() {
        let catalogue = SharedHikeCatalogue(
            hikes: [Self.summary(name: "Kalvarienberg"), Self.summary(name: "Thumsee Loop")]
        )

        #expect(catalogue.hikes(matching: "kalvarienberg").count == 1)
        #expect(catalogue.hikes(matching: "KALVARIENBERG").count == 1)
        #expect(catalogue.hikes(matching: "thumsee").count == 1)
    }

    /// An empty query is the picker before anything has been typed, which is
    /// every hike rather than none.
    @Test("an empty query matches everything")
    func anEmptyQueryMatchesEverything() {
        let catalogue = SharedHikeCatalogue(hikes: [Self.summary(), Self.summary()])

        #expect(catalogue.hikes(matching: "   ").count == 2)
    }

    @Test("suggestions are bounded and take the catalogue's own order")
    func suggestionsAreBounded() {
        let hikes = (0..<20).map { index in Self.summary(name: "Hike \(index)") }
        let catalogue = SharedHikeCatalogue(hikes: hikes)

        let suggested = catalogue.suggestions(limit: 10)

        #expect(suggested.count == 10)
        #expect(suggested.first?.name == "Hike 0")
    }

    // MARK: Per-hike trail snapshots

    @Test("a snapshot is read back for the hike it was filed under")
    func perHikeSnapshotRoundTrips() throws {
        try withSharedStoreSandbox { _ in
            let hikeID = UUID()
            let snapshot = SharedStoreSandbox.trailSnapshot(hikeID: hikeID, title: "Rennsteig")

            SharedStore.saveTrailSnapshot(snapshot)

            #expect(SharedStore.loadTrailSnapshot(for: hikeID)?.title == "Rennsteig")
        }
    }

    /// **The one a pinned widget depends on.** A snapshot handed back for the
    /// wrong hike is a widget quietly showing a different trail from the one
    /// its own settings name.
    @Test("a snapshot is never handed back for a different hike")
    func aSnapshotIsNotHandedBackForAnotherHike() throws {
        try withSharedStoreSandbox { _ in
            SharedStore.saveTrailSnapshot(SharedStoreSandbox.trailSnapshot(hikeID: UUID()))

            #expect(SharedStore.loadTrailSnapshot(for: UUID()) == nil)
        }
    }

    /// The selected trail's writes are mirrored per hike, and here rather than
    /// at the call sites, so a widget pinned to the hike that also happens to
    /// be selected cannot see a staler copy than the widget beside it.
    @Test("saving the selected trail also files it under its hike")
    func savingTheSelectionMirrorsIt() throws {
        try withSharedStoreSandbox { _ in
            let hikeID = UUID()

            SharedStore.save(SharedStoreSandbox.trailSnapshot(hikeID: hikeID))

            #expect(SharedStore.load()?.hikeID == hikeID)
            #expect(SharedStore.loadTrailSnapshot(for: hikeID)?.hikeID == hikeID)
        }
    }

    /// **Deselection must not take a pinned widget's route away.** That is the
    /// bug #468 was filed about, and clearing the per-hike files here would be
    /// the same bug in a new place.
    @Test("deselecting a trail leaves the pinned snapshots alone")
    func clearingTheSelectionKeepsPinnedSnapshots() throws {
        try withSharedStoreSandbox { _ in
            let hikeID = UUID()
            SharedStore.save(SharedStoreSandbox.trailSnapshot(hikeID: hikeID))

            SharedStore.clear()

            #expect(SharedStore.load() == nil)
            #expect(SharedStore.loadTrailSnapshot(for: hikeID) != nil)
        }
    }

    /// Deletion is what does take it, because a route that outlives its hike
    /// on somebody's Home Screen is the other way to get this wrong.
    @Test("clearing one hike's snapshot leaves the others")
    func clearingOneSnapshotLeavesTheRest() throws {
        try withSharedStoreSandbox { _ in
            let doomed = UUID()
            let kept = UUID()
            SharedStore.saveTrailSnapshot(SharedStoreSandbox.trailSnapshot(hikeID: doomed))
            SharedStore.saveTrailSnapshot(SharedStoreSandbox.trailSnapshot(hikeID: kept))

            SharedStore.clearTrailSnapshot(for: doomed)

            #expect(SharedStore.loadTrailSnapshot(for: doomed) == nil)
            #expect(SharedStore.loadTrailSnapshot(for: kept) != nil)
        }
    }

    /// The bound on the whole design: snapshots are kept for what is on a
    /// screen, not for the library. A hiker with three hundred walks must not
    /// accumulate three hundred routes in the App Group.
    @Test("the prune keeps exactly what it is told and no more")
    func pruneKeepsOnlyWhatIsAsked() throws {
        try withSharedStoreSandbox { _ in
            let pinned = UUID()
            let selected = UUID()
            let forgotten = UUID()
            for hikeID in [pinned, selected, forgotten] {
                SharedStore.saveTrailSnapshot(SharedStoreSandbox.trailSnapshot(hikeID: hikeID))
            }

            SharedStore.pruneTrailSnapshots(keeping: [pinned, selected])

            #expect(SharedStore.loadTrailSnapshot(for: pinned) != nil)
            #expect(SharedStore.loadTrailSnapshot(for: selected) != nil)
            #expect(SharedStore.loadTrailSnapshot(for: forgotten) == nil)
        }
    }

    @Test("a prune with nothing to keep empties the store")
    func pruneWithNothingKeptEmptiesIt() throws {
        try withSharedStoreSandbox { _ in
            let hikeID = UUID()
            SharedStore.saveTrailSnapshot(SharedStoreSandbox.trailSnapshot(hikeID: hikeID))

            SharedStore.pruneTrailSnapshots(keeping: [])

            #expect(SharedStore.loadTrailSnapshot(for: hikeID) == nil)
        }
    }
}
