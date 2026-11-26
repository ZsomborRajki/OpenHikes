//
//  HikeAttachmentTests.swift
//  OpenHikesTests
//
//  What SwiftData actually reports about a hike that has been deleted, pinned
//  because ``Hike/isAttached`` reads it and because the obvious version of
//  that check is wrong.
//
//  `isDeleted` is true only between `delete(_:)` and the save that commits it.
//  Once the save detaches the object, `isDeleted` goes back to *false* and
//  `modelContext` becomes nil instead. So a guard that asked only `isDeleted`
//  would wave through every write to a hike the user had already deleted and
//  saved — which is the whole window ``HikePhotoImport/add`` exists to close,
//  since an import runs for seconds while the hikes list is one swipe away.
//
//  These are properties of the framework rather than of this app, which is
//  exactly why they are worth a test: nothing else here would notice them
//  changing, and the failure they cause is silent.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Hike attachment")
struct HikeAttachmentTests {
    @Test("a hike in a store is attached")
    func insertedHikeIsAttached() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(hike.isAttached)
        #expect(hike.isDeleted == false)
        #expect(hike.modelContext != nil)
    }

    @Test("a hike deleted but not yet saved is already not attached")
    func deletedBeforeSaveIsNotAttached() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        context.delete(hike)

        #expect(hike.isDeleted, "this is the stage `isDeleted` covers")
        #expect(hike.isAttached == false)
    }

    /// The stage that makes the second half of the check necessary.
    @Test("a hike deleted and saved reports isDeleted false, and is detached")
    func deletedAfterSaveIsNotAttached() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        context.delete(hike)
        try context.save()

        #expect(
            hike.isDeleted == false,
            "if this ever becomes true, `isAttached` may be simplified"
        )
        #expect(hike.modelContext == nil)
        #expect(hike.isAttached == false)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    @Test("a hike that was never inserted is not attached either")
    func uninsertedHikeIsNotAttached() {
        let hike = Hike(title: "Nowhere", distanceMeters: 0, route: [])

        #expect(hike.isAttached == false)
    }

    /// What ``Hike/hasLeftItsStore`` reads to tell a deleted hike from one
    /// never saved, which `isAttached` answers alike: the store its
    /// identifier names, kept through the save that detaches it.
    @Test("a hike deleted here has left its store, before the save and after it")
    func deletedHikeHasLeftItsStore() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        try context.save()
        #expect(hike.hasLeftItsStore == false)

        context.delete(hike)
        #expect(hike.hasLeftItsStore)
        try context.save()

        #expect(hike.modelContext == nil)
        #expect(hike.hasLeftItsStore)
    }

    /// A hike never saved holds its values in memory, so a reader still
    /// reads it where it is, with no context or a context and no save.
    @Test("a hike never saved has not left a store, with or without a context")
    func neverSavedHikeHasNotLeftAStore() throws {
        let context = try Fixture.modelContext()
        let loose = Hike(title: "Nowhere", distanceMeters: 0, route: Fixture.ridgeRoute)
        let inserted = Fixture.hike(in: context)
        #expect(loose.hasLeftItsStore == false)
        #expect(inserted.hasLeftItsStore == false)

        let dropped = Fixture.hike(in: context, title: "Dropped")
        context.delete(dropped)
        try context.save()

        #expect(dropped.modelContext == nil)
        #expect(dropped.hasLeftItsStore == false, "it never reached the store")
        #expect(dropped.route.count == Fixture.ridgeRoute.count, "and still holds its line in memory")
    }
}
