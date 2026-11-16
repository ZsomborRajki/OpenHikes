//
//  SheetDestinationStateTests+PhotoDiscovery.swift
//  OpenHikesTests
//
//  *Find Photos of This Hike* on the sheet's stack: kept through a turn of
//  the phone, and closed with the hike's screens (#1462).
//
//  An extension of ``SheetDestinationStateTests`` for the reason the photo
//  discovery suite's halves are one: one test type per file, and this is one
//  more destination's state.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension SheetDestinationStateTests {
    /// A turn of the phone replaces the photo section that presents the
    /// sheet, so the sheet and its search live with the hike's interaction
    /// until the last of the hike's screens is popped — and that closes them,
    /// since nothing writes the flag back then.
    @Test("Find Photos' sheet and its choice outlive rotation, and close with the hike's screens")
    func photoDiscoveryFollowsTheNavigationLifetime() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation()
        presentation.path = [.hike(hike)]
        let discovery = presentation.hikeInteraction(for: hike).photoDiscovery
        discovery.start()
        discovery.controller.selection = ["b"]

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.hikeInteraction(for: hike).photoDiscovery === discovery)
            #expect(discovery.isPresented, "the sheet is presented again in the other host")
            #expect(discovery.controller.selection == ["b"], "on the same choice")
        }

        presentation.path.append(.photo(hike, UUID()))
        #expect(discovery.isPresented, "a screen pushed over the hike keeps it")
        presentation.path = []
        #expect(!discovery.isPresented, "the hike's screens going close it")
        #expect(presentation.hikeInteraction(for: hike).photoDiscovery === discovery, "for the screen sliding out")
        presentation.path = [.hike(hike)]
        #expect(presentation.hikeInteraction(for: hike).photoDiscovery !== discovery, "and opening it again is new")
    }
}
