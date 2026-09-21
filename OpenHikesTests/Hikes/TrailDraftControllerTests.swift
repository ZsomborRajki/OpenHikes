//
//  TrailDraftControllerTests.swift
//  OpenHikesTests
//
//  Whether the map is offering to make a trail, and what a tap on it means.
//
//  The claim worth holding still is the one nothing in the app enforces
//  directly: **the two pills in that slot can never both draw.** The camera is
//  offered while a screen is pushed *and* has attached a hike to photograph;
//  the maker is offered while nothing is pushed. That exclusion falls out of
//  two definitions in two files that do not know about each other, which makes
//  it exactly the kind of thing that breaks quietly — a later change to either
//  rule would put two controls in one place with no compiler and no reviewer
//  able to see it from one file.
//
//  The other half is the guards. A recognizer on the map sees every tap,
//  including the ones arriving as a screen leaves, so "a waypoint is only ever
//  added while the maker is up" has to be true of the controller rather than
//  of the caller.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Trail draft controller")
struct TrailDraftControllerTests {
    private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let north: Double = 47.6340
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    /// A maker that writes its draft down, and the store it writes into.
    private func makerWithStore() throws -> (TrailDraftController, TrailDraftStore) {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        return (TrailDraftController(store: store), store)
    }

    // MARK: One slot, two pills

    @Test("the maker is offered exactly when nothing is pushed")
    func offeredOnTheSearchScreen() {
        let maker = TrailDraftController()

        // Withheld until the sheet has said otherwise, so a launch that
        // restored a pushed screen never flashes it in.
        #expect(!maker.isAvailable)

        maker.setHostScreenPresent(false)
        #expect(maker.isAvailable)

        maker.setHostScreenPresent(true)
        #expect(!maker.isAvailable)
    }

    /// Driven from both sides of the same signal, which is the whole of the
    /// arrangement: `MapSheet` writes `hasPushedScreen` into both.
    @Test("the maker's pill and the camera's are never both offered")
    func thePillsAreMutuallyExclusive() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let maker = TrailDraftController()
        let camera = PhotoCaptureController()

        for isPushed in [false, true, false, true] {
            maker.setHostScreenPresent(isPushed)
            camera.setHostScreenPresent(isPushed)
            // The strongest case for the camera: a screen is pushed *and* it
            // has attached something to photograph.
            if isPushed { camera.attach(to: hike) { nil } }

            #expect(
                !(maker.isAvailable && camera.isAvailable),
                "both pills were offered the one slot with a pushed screen of \(isPushed)"
            )
        }
    }

    /// The maker itself is a pushed screen that attaches no photo subject, so
    /// opening it withdraws its own pill without offering the other one. That
    /// is what makes the slot safe to share.
    @Test("opening the maker leaves the slot empty rather than handing it over")
    func openingTheMakerOffersNeither() {
        let maker = TrailDraftController()
        let camera = PhotoCaptureController()
        maker.setHostScreenPresent(false)
        camera.setHostScreenPresent(false)

        // The maker's screen is now on top.
        maker.setHostScreenPresent(true)
        camera.setHostScreenPresent(true)
        maker.setEditing(true)

        #expect(!maker.isAvailable)
        #expect(!camera.isAvailable)
    }

    // MARK: Opening

    @Test("a request to open is refused while the pill isn't offered")
    func openIsRefusedWhileWithdrawn() {
        let maker = TrailDraftController()
        maker.setHostScreenPresent(true)

        maker.requestOpen()

        #expect(maker.openRequest == 0)
    }

    @Test("a request to open posts a token the map screen can act on")
    func openPostsAToken() {
        let maker = TrailDraftController()
        maker.setHostScreenPresent(false)

        maker.requestOpen()
        maker.requestOpen()

        #expect(maker.openRequest == 2, "each tap is its own message")
    }

    // MARK: The canvas

    @Test("a tap adds nothing while the maker is closed")
    func tapsAreIgnoredWhenNotEditing() {
        let maker = TrailDraftController()

        maker.appendWaypoint(at: Self.coordinate(Line.south))

        #expect(maker.draft.isEmpty)
    }

    @Test("a tap puts a point down while the maker is open")
    func tapsAddPointsWhileEditing() {
        let maker = TrailDraftController()
        maker.setEditing(true)

        maker.appendWaypoint(at: Self.coordinate(Line.south))
        maker.appendWaypoint(at: Self.coordinate(Line.north))

        #expect(maker.draft.waypoints.count == 2)
        #expect(maker.draft.canBeSaved)
    }

    /// The tap arriving during the pop animation is the one this refuses, and
    /// it is the reason the flag is derived from the sheet's path rather than
    /// from the screen's own `onDisappear`.
    @Test("a tap arriving as the maker closes adds nothing")
    func tapsAfterClosingAreIgnored() {
        let maker = TrailDraftController()
        maker.setEditing(true)
        maker.appendWaypoint(at: Self.coordinate(Line.south))

        maker.setEditing(false)
        maker.appendWaypoint(at: Self.coordinate(Line.north))

        #expect(maker.draft.waypoints.count == 1)
    }

    // MARK: Keeping it

    /// Written as it lands, with the maker still open — which is what makes
    /// closing it a no-op rather than the moment the drawing is saved. See
    /// ``TrailDraftController/setEditing(_:)``.
    @Test("a point put down is written down with it")
    func pointsArePersisted() throws {
        let (maker, store) = try makerWithStore()
        maker.setEditing(true)

        maker.appendWaypoint(at: Self.coordinate(Line.south))

        #expect(store.load().waypoints.count == 1)
    }

    @Test("a draft left behind comes back when the maker is opened again")
    func draftIsRestored() throws {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        store.save(
            waypoints: [
                TrailWaypoint(coordinate: Self.coordinate(Line.south)),
                TrailWaypoint(coordinate: Self.coordinate(Line.north)),
            ],
            places: [],
            snapsToPaths: true
        )
        // A fresh launch: a controller with nothing in memory.
        let maker = TrailDraftController(store: store)

        maker.setEditing(true)

        #expect(maker.draft.waypoints.count == 2)
        #expect(maker.draft.distanceMeters > 0)
    }

    /// Leaving the maker and coming back within a launch finds the line still
    /// in memory, and a restore over it would undo whatever the last write did
    /// not carry.
    @Test("reopening the maker does not overwrite what is already drawn")
    func restoreOnlyFillsAnEmptyDraft() throws {
        let (maker, _) = try makerWithStore()
        maker.setEditing(true)
        maker.appendWaypoint(at: Self.coordinate(Line.south))
        maker.appendWaypoint(at: Self.coordinate(Line.north))
        maker.setEditing(false)

        maker.setEditing(true)

        #expect(maker.draft.waypoints.count == 2)
    }

    @Test("discarding empties the drawing and what was kept of it")
    func discardingClearsBoth() throws {
        let (maker, store) = try makerWithStore()
        maker.setEditing(true)
        maker.appendWaypoint(at: Self.coordinate(Line.south))

        maker.discard()

        #expect(maker.draft.isEmpty)
        #expect(store.load().isEmpty)
    }

    /// A discard followed by a reopen finds nothing, which is the other half
    /// of Cancel meaning what it says.
    @Test("a discarded draft does not come back")
    func discardedDraftStaysGone() throws {
        let (maker, _) = try makerWithStore()
        maker.setEditing(true)
        maker.appendWaypoint(at: Self.coordinate(Line.south))
        maker.discard()

        maker.setEditing(false)
        maker.setEditing(true)

        #expect(maker.draft.isEmpty)
    }
}
