//
//  HikePhotoSearchSourceReadTests.swift
//  OpenHikesTests
//
//  Which hikes a photo search reads from the store, in a context of its own,
//  and which it still reads where they are (#1215).
//
//  A context of its own sees only what the store holds, so the rule worth
//  pinning is the one that keeps that from changing an answer: a hike with
//  edits the store has not had yet is read on the spot, edits and all. Where
//  a saved hike's read runs, and that it finds what the main actor's read
//  found, is asserted beside each search's other steps, in
//  ``PhotoDiscoveryControllerTests`` and ``PickedPhotoPlacementTests``.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Photo search source read")
struct HikePhotoSearchSourceReadTests {
    /// A walk inserted under a hike its context has saved is an edit the
    /// store has not had yet. Read from the store, the hike would come back
    /// without it, and an imported trail walked once would read as one with
    /// nothing to search.
    @Test("a walk not yet written is searched where it is")
    func unsavedWalkIsReadWhereItIs() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        try context.save()
        let length = RouteProfile(route: PhotoDiscoveryFixture.unstampedRoute).totalDistanceMeters
        let walk = PhotoDiscoveryFixture.walk(
            hikeID: hike.id,
            fromStep: 0,
            toStep: 9,
            covering: 0...length,
            routeDistanceMeters: length
        )
        context.insert(walk)
        walk.hike = hike

        let read = HikePhotoSearchPlan.SourceRead(hike)
        let source = try #require(read.source(fetch: HikePhotoSearchPlan.SourceRead.fetchHike))

        #expect(source.walks.count == 1)
        #expect(!HikePhotoSearchPlan(source: source).isEmpty)
    }

    /// The read is named on the main actor and made off it, so the row can
    /// go in between: a hike deleted on another device and merged here after
    /// the search began. Neither search has anything left to read then.
    @Test("a hike the store no longer holds reads as nothing")
    func deletedRowReadsAsNothing() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        try context.save()
        let read = HikePhotoSearchPlan.SourceRead(hike)
        context.delete(hike)
        try context.save()

        #expect(read.source(fetch: HikePhotoSearchPlan.SourceRead.fetchHike) == nil)
        #expect(await PhotoDiscoveryWork.standard.plan(for: read) == nil)
        #expect(await PickedPhotoWork.standard.plan(from: read) == nil)
    }
}
