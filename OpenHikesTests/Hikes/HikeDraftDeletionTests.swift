//
//  HikeDraftDeletionTests.swift
//  OpenHikesTests
//
//  Which rows the hikes list is allowed to offer a Delete swipe for.
//
//  The rule used to be "anything `belongsToActiveRecording(currentHikeID:)`
//  says no to", and that read one mirrored flag as proof a walk was under way.
//  `isRecording` travels through CloudKit; the journal claim behind it —
//  ``HikeLocalState/ownsRecordingDraft`` — deliberately does not. So a draft
//  could arrive on a reinstalled app with the flag set and nothing local
//  standing behind it, at which point all three exits were shut: the launch
//  sweep skips unowned drafts on purpose, recovery needs a journal that is
//  gone, and the list built no Delete button for it. The row could not be
//  removed by any sequence of taps.
//
//  These pin the two halves that have to stay true together: the live
//  recording is still protected, and the abandoned draft is not.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Hike draft deletion")
struct HikeDraftDeletionTests {
    /// The ordinary case, and the one that must not regress: a saved hike has
    /// nothing to do with recording and is deletable whatever the recorder is
    /// doing elsewhere.
    @Test("a finished hike is deletable")
    func finishedHikeIsDeletable() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(hike.canBeDeletedFromLibrary(currentHikeID: nil))
        #expect(hike.canBeDeletedFromLibrary(currentHikeID: UUID()))
        #expect(!hike.isAbandonedRecordingDraft(currentHikeID: nil))
    }

    /// The walk in progress on this phone. Protected by identity rather than
    /// by the flag, which is what keeps it protected through the save — see
    /// ``Hike/belongsToActiveRecording(currentHikeID:)``, where the recorder's
    /// current ID covers the window after `isRecording` goes false.
    @Test("the recording this device is running cannot be deleted")
    func liveRecordingIsProtected() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.isRecording = true }

        #expect(!hike.canBeDeletedFromLibrary(currentHikeID: hike.id))
        #expect(!hike.isAbandonedRecordingDraft(currentHikeID: hike.id))
    }

    /// Still protected once the finished route is saved and the flag is off,
    /// because the recorder has not let go of it yet.
    @Test("the hike being saved cannot be deleted while the recorder holds it")
    func savingHikeIsProtected() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.isRecording = false }

        #expect(!hike.canBeDeletedFromLibrary(currentHikeID: hike.id))
    }

    /// A draft this device claimed but is not currently recording into: the
    /// launch sweep owns this one, so the list stays out of its way rather
    /// than racing it.
    @Test("a draft this device has claimed is left to the sweep")
    func ownedDraftIsLeftToTheSweep() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { hike in
            hike.isRecording = true
            hike.ownsRecordingDraft = true
        }
        try context.save()

        #expect(!hike.canBeDeletedFromLibrary(currentHikeID: nil))
        #expect(!hike.isAbandonedRecordingDraft(currentHikeID: nil))
    }

    /// The regression. A mirrored draft with no local claim is exactly what a
    /// reinstall leaves behind, and it has to be removable by hand: nothing
    /// else in the app will ever touch it.
    @Test("an abandoned draft with no local claim is deletable")
    func abandonedDraftIsDeletable() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.isRecording = true }
        try context.save()

        #expect(
            !hike.ownsRecordingDraft,
            "no journal was ever recovered for this draft on this device"
        )
        #expect(hike.isAbandonedRecordingDraft(currentHikeID: nil))
        #expect(hike.canBeDeletedFromLibrary(currentHikeID: nil))
    }

    /// The old gate, kept as a statement of what changed: the draft above is
    /// still "active" by the predicate that routes taps to the recording
    /// screen. Deletion had to stop asking that question; navigation has not,
    /// and this pins that they now disagree on purpose.
    @Test("deletion and navigation disagree about an abandoned draft")
    func deletionNoLongerFollowsNavigation() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.isRecording = true }
        try context.save()

        #expect(hike.belongsToActiveRecording(currentHikeID: nil))
        #expect(hike.canBeDeletedFromLibrary(currentHikeID: nil))
    }

    /// Another phone's live draft is indistinguishable from an abandoned one —
    /// the claim that would tell them apart is device-local by design. The
    /// deletion is a deliberate, confirmed act on this hiker's own library, so
    /// it is allowed; this records that the ambiguity was priced in rather
    /// than missed.
    @Test("a draft claimed only after the fact stops being deletable")
    func claimingADraftProtectsIt() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.isRecording = true }
        try context.save()

        #expect(hike.canBeDeletedFromLibrary(currentHikeID: nil))

        hike.ownsRecordingDraft = true
        try context.save()

        #expect(!hike.canBeDeletedFromLibrary(currentHikeID: nil))
    }
}
