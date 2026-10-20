//
//  TrailDraftSaveTargetTests.swift
//  OpenHikesTests
//
//  Where the maker's Save goes: a new trail, the hike being edited, or
//  nowhere because the store could not be read (#872).
//
//  The case defended is the last one. An edit whose hike is gone is saved as a
//  new trail, and that is an insert — so a fetch that threw has to be told
//  apart from one that found nothing, or a passing read failure turns an edit
//  into a duplicate beside the original.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Trail draft save target")
struct TrailDraftSaveTargetTests {
    private struct ReadFailure: Error {}

    private static func draft() -> TrailDraft {
        let draft = TrailDraft()
        draft.append(CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.86))
        draft.append(CLLocationCoordinate2D(latitude: 47.6340, longitude: 12.86))
        return draft
    }

    @Test("a new drawing asks for a name")
    func aNewDrawingIsANewTrail() throws {
        let context = try Fixture.modelContext()
        guard case .newTrail = TrailDraftSaveTarget.resolve(editing: nil, in: context) else {
            Issue.record("expected a new trail")
            return
        }
    }

    @Test("an edit whose hike is still there writes back into it")
    func anEditFindsItsHike() throws {
        let context = try Fixture.modelContext()
        let hike = try #require(TrailDraftSave.hike(from: Self.draft(), named: "Ridge", into: context).hike)

        guard case .edit(let found) = TrailDraftSaveTarget.resolve(editing: hike.id, in: context) else {
            Issue.record("expected the edit's own hike")
            return
        }
        #expect(found.id == hike.id)
    }

    @Test("an edit whose hike was deleted is saved as a new trail")
    func aDeletedHikeIsANewTrail() throws {
        let context = try Fixture.modelContext()
        let hike = try #require(TrailDraftSave.hike(from: Self.draft(), named: "Ridge", into: context).hike)
        let id = hike.id
        context.delete(hike)
        try context.save()

        guard case .newTrail = TrailDraftSaveTarget.resolve(editing: id, in: context) else {
            Issue.record("expected a new trail for a hike that is gone")
            return
        }
    }

    @Test("a read that failed refuses the save and writes nothing")
    func aFailedReadIsRefused() throws {
        let context = try Fixture.modelContext()
        let hike = try #require(TrailDraftSave.hike(from: Self.draft(), named: "Ridge", into: context).hike)
        let before = try context.fetchCount(FetchDescriptor<Hike>())

        let target = TrailDraftSaveTarget.resolve(
            editing: hike.id,
            in: context,
            fetch: { _, _ in throw ReadFailure() }
        )

        guard case .refused(.notSaved) = target else {
            Issue.record("expected the store's refusal, got \(target)")
            return
        }
        #expect(try context.fetchCount(FetchDescriptor<Hike>()) == before)
        #expect(!context.hasChanges)
    }

    @Test("a read that failed is refused even with nothing in the store")
    func aFailedReadIsNotAnEmptyStore() throws {
        let context = try Fixture.modelContext()
        let target = TrailDraftSaveTarget.resolve(
            editing: UUID(),
            in: context,
            fetch: { _, _ in throw ReadFailure() }
        )
        guard case .refused(.notSaved) = target else {
            Issue.record("expected the store's refusal, got \(target)")
            return
        }
    }
}
