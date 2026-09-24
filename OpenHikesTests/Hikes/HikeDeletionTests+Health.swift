//
//  HikeDeletionTests+Health.swift
//  OpenHikesTests
//
//  The fourth store a hike can be in, and the one this app cannot read back.
//
//  ``HikeWorkoutWriting/write(_:)``'s header states the invariant these pin:
//  Health is a second store and it must never hold a walk this app does not.
//  Deleting a hike used to invert it — the row, the sidecar, the photographs
//  and the walk history all went, the `HKWorkout` stayed, and the app threw
//  away the only handle it had in the same breath.
//
//  An extension rather than a suite of its own, for the reason
//  `HikeDeletionTests+Photos.swift` is one: the ordering against the commit is
//  the same argument in a different store, and the two belong beside each
//  other. `HikeWorkoutWriting` is unavailable in a hosted test the way
//  ActivityKit and `StoreKitTest` are, so everything worth asserting sits
//  above the seam — which is exactly what that protocol exists for.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
extension HikeDeletionTests {
    /// A saved hike whose recording reached Health, with the identifier filed
    /// against its sidecar the way `HikeRecorder` files one.
    private func recordedHike(
        in context: ModelContext,
        workoutID: UUID
    ) -> Hike {
        let hike = Fixture.hike(in: context)
        let state = HikeLocalState.forHike(hike.id, in: context)
        state.healthWorkoutID = workoutID
        try? context.save()
        return hike
    }

    @Test("deleting a hike takes its workout out of Health")
    func deletingAHikeRemovesItsWorkout() async throws {
        let context = try Fixture.modelContext()
        let workoutID = UUID()
        let hike = recordedHike(in: context, workoutID: workoutID)
        let writer = StubWorkoutWriter()

        try HikeDeletion.delete([hike], workouts: writer)
        // The removal is fire-and-forget, the shape the write already takes.
        await Task.yield()

        #expect(writer.deleted == [workoutID])
    }

    /// The whole reason the identifier is read before `deleteLocalState()`
    /// rather than after: a deleted row has no sidecar left to ask, so a
    /// deletion that looked it up afterwards would find nothing and silently
    /// leave the workout behind — which is the bug, wearing a fix.
    @Test("the identifier survives the sidecar it was stored in")
    func readsTheIdentifierBeforeTheSidecarGoes() async throws {
        let context = try Fixture.modelContext()
        let workoutID = UUID()
        let hike = recordedHike(in: context, workoutID: workoutID)
        let writer = StubWorkoutWriter()

        try HikeDeletion.delete([hike], workouts: writer)
        await Task.yield()

        #expect(HikeLocalState.existing(for: hike.id, in: context) == nil)
        #expect(writer.deleted == [workoutID], "and the workout still went")
    }

    /// A refused save puts everything back — the hike, its sidecar and its
    /// files — so the workout has to stay too. Deleting it here would take a
    /// walk out of Health that is still in the list, which is the invariant
    /// inverted in the other direction.
    @Test("a refused deletion leaves the workout where it was")
    func aRefusedDeletionKeepsTheWorkout() async throws {
        let context = try Fixture.modelContext()
        let hike = recordedHike(in: context, workoutID: UUID())
        let writer = StubWorkoutWriter()

        #expect(throws: (any Error).self) {
            try HikeDeletion.delete([hike], workouts: writer) { _ in
                throw HikeWorkoutFailure.notWritten
            }
        }
        await Task.yield()

        #expect(writer.deleted.isEmpty)
    }

    /// An imported hike never reached Health, so there is nothing to ask for.
    /// `exportToHealth` is called from the recording save path alone.
    @Test("a hike that never reached Health asks Health for nothing")
    func anUnexportedHikeAsksNothing() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let writer = StubWorkoutWriter()

        try HikeDeletion.delete([hike], workouts: writer)
        await Task.yield()

        #expect(writer.deleted.isEmpty)
    }

    /// A launch with no Health writer — a hosted suite, or a device with no
    /// Health store. `nil` is not a stub: the workout is not deleted, exactly
    /// as it was never written.
    @Test("a launch with no Health writer still deletes the hike")
    func deletesWithoutAWriter() throws {
        let context = try Fixture.modelContext()
        let hike = recordedHike(in: context, workoutID: UUID())

        try HikeDeletion.delete([hike])

        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// Health declining is not the hiker's problem and must not become one:
    /// they asked for the hike to go, and it has. The alternative is refusing
    /// to delete a hike because a second store would not co-operate.
    @Test("a hike is still deleted when Health refuses to remove its workout")
    func survivesARefusalFromHealth() async throws {
        let context = try Fixture.modelContext()
        let hike = recordedHike(in: context, workoutID: UUID())
        let writer = StubWorkoutWriter()
        writer.deleteFailure = .unavailable

        try HikeDeletion.delete([hike], workouts: writer)
        await Task.yield()

        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// The orphan sweep deletes a dozen drafts at once and none of them
    /// carries a workout, so the batch must cost Health nothing at all.
    @Test("a batch asks only about the hikes that have a workout")
    func asksOnlyAboutExportedHikes() async throws {
        let context = try Fixture.modelContext()
        let workoutID = UUID()
        let exported = recordedHike(in: context, workoutID: workoutID)
        let plain = Fixture.hike(in: context, title: "Imported Track")
        let writer = StubWorkoutWriter()

        try HikeDeletion.delete([exported, plain], workouts: writer)
        await Task.yield()

        #expect(writer.deleted == [workoutID])
    }
}
