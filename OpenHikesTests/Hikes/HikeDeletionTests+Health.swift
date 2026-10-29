//
//  HikeDeletionTests+Health.swift
//  OpenHikesTests
//
//  The fourth store a hike can be in, and the one this app cannot read back.
//
//  The invariant these pin is the one `HikeRecorder.exportToHealth` states:
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
    /// A saved hike whose recording reached Health, marked on its sidecar the
    /// way `HikeWorkoutExport` marks one.
    private func recordedHike(in context: ModelContext) -> Hike {
        let hike = Fixture.hike(in: context)
        let state = HikeLocalState.forHike(hike.id, in: context)
        state.wroteToHealth = true
        try? context.save()
        return hike
    }

    @Test("deleting a hike takes its workout out of Health")
    func deletingAHikeRemovesItsWorkout() async throws {
        let context = try Fixture.modelContext()
        let hike = recordedHike(in: context)
        let hikeID = hike.id
        let writer = StubWorkoutWriter()

        try HikeDeletion.delete([hike], workouts: writer)
        // The removal is fire-and-forget, the shape the write already takes.
        await Task.yield()

        #expect(writer.deleted == [hikeID])
    }

    /// The whole reason the mark is read before `deleteLocalState()` rather
    /// than after: a deleted row has no sidecar left to ask, so a deletion
    /// that looked it up afterwards would find nothing and silently leave the
    /// workout behind — which is the bug, wearing a fix.
    @Test("the mark survives the sidecar it was stored in")
    func readsTheMarkBeforeTheSidecarGoes() async throws {
        let context = try Fixture.modelContext()
        let hike = recordedHike(in: context)
        let hikeID = hike.id
        let writer = StubWorkoutWriter()

        try HikeDeletion.delete([hike], workouts: writer)
        await Task.yield()

        #expect(HikeLocalState.existing(for: hikeID, in: context) == nil)
        #expect(writer.deleted == [hikeID], "and the workout still went")
    }

    /// A refused save puts everything back — the hike, its sidecar and its
    /// files — so the workout has to stay too. Deleting it here would take a
    /// walk out of Health that is still in the list, which is the invariant
    /// inverted in the other direction.
    @Test("a refused deletion leaves the workout where it was")
    func aRefusedDeletionKeepsTheWorkout() async throws {
        let context = try Fixture.modelContext()
        let hike = recordedHike(in: context)
        let writer = StubWorkoutWriter()

        #expect(throws: (any Error).self) {
            try HikeDeletion.delete([hike], workouts: writer) { _ in
                throw HikeWorkoutFailure.unavailable
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
        let hike = recordedHike(in: context)

        try HikeDeletion.delete([hike])

        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// Health declining is not the hiker's problem and must not become one:
    /// they asked for the hike to go, and it has. The alternative is refusing
    /// to delete a hike because a second store would not co-operate.
    @Test("a hike is still deleted when Health refuses to remove its workout")
    func survivesARefusalFromHealth() async throws {
        let context = try Fixture.modelContext()
        let hike = recordedHike(in: context)
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
        let exported = recordedHike(in: context)
        let exportedID = exported.id
        let plain = Fixture.hike(in: context, title: "Imported Track")
        let writer = StubWorkoutWriter()

        try HikeDeletion.delete([exported, plain], workouts: writer)
        await Task.yield()

        #expect(writer.deleted == [exportedID])
    }

    // MARK: - A deletion while the export is still being written

    /// The race the deletion above cannot settle alone: ``HikeDeletion`` asks
    /// Health as it commits, and a write Health has not answered for yet may
    /// not have saved everything by then. The export has to notice the hike
    /// went while it was suspended, and ask again.
    @Test("a workout Health finishes after its hike was deleted is taken back out")
    func aWorkoutFinishedAfterDeletionIsRemoved() async throws {
        let container = try Fixture.modelContainer()
        let context = container.mainContext
        let hike = Fixture.hike(in: context)
        try context.save()
        let hikeID = hike.id
        let writer = HeldWorkoutWriter()

        let export = Task {
            await HikeWorkoutExport.write(
                Self.request(for: hikeID),
                with: writer,
                filingInto: container
            )
        }
        await writer.untilWriting()
        try HikeDeletion.delete([hike], workouts: writer)
        await settleDelegateHop(until: "the deletion to ask while the write is held") {
            writer.deleted == [hikeID]
        }
        writer.finish()
        await export.value

        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
        #expect(
            HikeLocalState.existing(for: hikeID, in: context) == nil,
            "no sidecar comes back for a hike that is gone"
        )
        #expect(writer.deleted == [hikeID, hikeID], "asked as it committed, and again once Health answered")
    }

    /// The same suspension with nothing deleted under it, so the check above
    /// is not simply taking back anything written slowly. The mark is on disk
    /// before Health hears anything, which is what a deletion during the
    /// write asks by, and one after a write this process never finished.
    @Test("a slow write for a hike that is still here is marked before Health answers")
    func aSlowWriteForALiveHikeIsMarkedFirst() async throws {
        let container = try Fixture.modelContainer()
        let context = container.mainContext
        let hike = Fixture.hike(in: context)
        try context.save()
        let hikeID = hike.id
        let writer = HeldWorkoutWriter()

        let export = Task {
            await HikeWorkoutExport.write(
                Self.request(for: hikeID),
                with: writer,
                filingInto: container
            )
        }
        await writer.untilWriting()
        let markedOnDisk = HikeLocalState.existing(for: hikeID, in: ModelContext(container))?.wroteToHealth
        writer.finish()
        await export.value

        #expect(markedOnDisk == true)
        #expect(HikeLocalState.existing(for: hikeID, in: context)?.wroteToHealth == true)
        #expect(writer.deleted.isEmpty)
    }

    /// Marking a hike that is already gone would put a sidecar back for it,
    /// and writing it would put a walk in Health this app does not hold.
    @Test("a hike gone before its export starts is neither written nor marked")
    func aHikeGoneBeforeItsExportIsLeftAlone() async throws {
        let container = try Fixture.modelContainer()
        let context = container.mainContext
        let hike = Fixture.hike(in: context)
        try context.save()
        let hikeID = hike.id
        try HikeDeletion.delete([hike])
        let writer = StubWorkoutWriter()

        await HikeWorkoutExport.write(Self.request(for: hikeID), with: writer, filingInto: container)

        #expect(writer.written.isEmpty)
        #expect(HikeLocalState.existing(for: hikeID, in: context) == nil)
    }

    /// A store that could not say is not a store that said "gone": taking the
    /// workout out on a failed fetch would delete a walk from Health that is
    /// still in the list.
    @Test("a failed owner lookup is not read as a deleted hike")
    func aFailedLookupIsNotADeletion() {
        #expect(!HikeWorkoutExport.hikeIsGone { throw HikeWorkoutFailure.unavailable })
        #expect(!HikeWorkoutExport.hikeIsGone { 1 })
        #expect(HikeWorkoutExport.hikeIsGone { 0 })
    }

    /// Any walk will do: nothing here reads the figures back.
    private static let startedAt = Date.distantPast
    private static let hourSeconds: TimeInterval = 3600
    private static let walkMeters = 5000.0

    private static func request(for hikeID: UUID) -> HikeWorkoutRequest {
        HikeWorkoutRequest(
            hikeID: hikeID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(hourSeconds),
            pauses: [],
            distanceMeters: walkMeters,
            elevationGainMeters: nil,
            elevationLossMeters: nil,
            weather: nil,
            route: []
        )
    }
}

/// A writer whose `write` stays suspended until the test lets it answer, so a
/// deletion can land at a known point inside it — a handshake, not a race.
@MainActor
private final class HeldWorkoutWriter: HikeWorkoutWriting {
    /// The hikes a deletion asked Health to take back, in the order it asked.
    private(set) var deleted: [UUID] = []
    private var hasEntered = false
    private var entered: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?

    func write(_ request: HikeWorkoutRequest) async {
        hasEntered = true
        entered?.resume()
        entered = nil
        // Parked in the same main-actor turn as the resume above, so `held`
        // is set before the test can reach `finish()`.
        await withCheckedContinuation { held = $0 }
    }

    func deleteWorkout(of hikeID: UUID) {
        deleted.append(hikeID)
    }

    /// Returns once `write` has been entered and is waiting.
    func untilWriting() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entered = $0 }
    }

    /// Lets the held `write` answer.
    func finish() {
        held?.resume()
        held = nil
    }
}
