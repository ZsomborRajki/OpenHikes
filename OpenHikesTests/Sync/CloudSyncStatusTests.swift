//
//  CloudSyncStatusTests.swift
//  OpenHikesTests
//
//  Whether the settings screen can still be told sync went wrong.
//
//  `didSendChanges` always follows `sentRecordZoneChanges`, so a failure
//  raised while sending was immediately overwritten by the event after it:
//  "Sync Problem" and its warning icon were unreachable outside one throw
//  path, and a failed pass still stamped a fresh "last synced" time. These
//  cases pin the bracket rather than the strings.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Cloud sync status")
struct CloudSyncStatusTests {
    @Test("A pass that raised nothing finishes clean and stamps its time")
    func cleanPassGoesIdle() {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        #expect(status.activity == .working)

        status.finished()

        #expect(status.activity == .idle)
        #expect(status.lastSyncedAt != nil)
    }

    /// The headline regression: the event that ends the pass must not erase
    /// the failure the pass raised a moment earlier.
    @Test("A failure survives the event that ends the pass")
    func failureSurvivesFinish() {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        status.failed("Out of iCloud storage")
        status.finished()

        #expect(status.activity == .failed("Out of iCloud storage"))
        #expect(status.title == "Sync Problem")
        #expect(status.detail == "Out of iCloud storage")
    }

    /// Claiming a sync time for a pass that failed is what made the row read
    /// "Synced with iCloud" over data that never left the device.
    @Test("A failed pass does not claim a sync time it did not earn")
    func failedPassStampsNoTime() {
        let status = CloudSyncStatus()
        status.began()
        status.failed("Zone missing")
        status.finished()

        #expect(status.lastSyncedAt == nil)
    }

    /// A pass the network cut short transferred nothing, so it has no more
    /// claim on "last synced" than a permanent failure does.
    @Test("A transient failure does not claim a sync time it did not earn")
    func transientPassStampsNoTime() {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        status.retrying()
        status.finished()

        #expect(status.activity == .retrying)
        #expect(status.lastSyncedAt == nil)
        #expect(status.title == "Waiting for iCloud")
    }

    /// And it does not roll back the time an earlier pass did earn.
    @Test("A transient failure leaves an earned sync time alone")
    func transientPassKeepsThePreviousTime() throws {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        status.finished()
        let earned = try #require(status.lastSyncedAt)

        status.began()
        status.retrying()
        status.finished()

        #expect(status.lastSyncedAt == earned)
        #expect(status.activity == .retrying)
        #expect(status.detail.contains("Last synced"))
    }

    /// "Waiting for iCloud" is not "Sync Problem": there is nothing for the
    /// user to do, and the retry that succeeds is silent.
    @Test("A transient failure is not reported as a problem")
    func transientPassIsNotAFailure() {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        status.retrying()

        #expect(status.title != "Sync Problem")
        #expect(status.title != "Synced with iCloud")
    }

    /// Within one pass the actionable problem wins, in either order: a full
    /// iCloud account is not made better by a dropped connection after it.
    @Test("A permanent failure outranks a transient one in the same pass")
    func permanentFailureOutranksTransient() {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        status.failed("Out of iCloud storage")
        status.retrying()
        status.finished()

        #expect(status.activity == .failed("Out of iCloud storage"))
        #expect(status.lastSyncedAt == nil)
    }

    /// One dropped connection must not leave the row waiting forever.
    @Test("The next pass clears the last one's transient failure")
    func nextPassClearsTheTransientFailure() {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        status.retrying()

        status.began()
        status.finished()

        #expect(status.activity == .idle)
        #expect(status.lastSyncedAt != nil)
    }

    /// A failure outlives its own pass, but not the next attempt — otherwise
    /// one bad pass would leave the row saying "Sync Problem" forever.
    @Test("The next pass clears the last one's failure")
    func nextPassClearsTheFailure() {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        status.failed("Zone missing")

        status.began()
        status.finished()

        #expect(status.activity == .idle)
        #expect(status.lastSyncedAt != nil)
    }

    /// Turning sync off is an answer in itself, not a failure left standing.
    @Test("Pausing clears a failure raised before it")
    func pausingClearsTheFailure() {
        let status = CloudSyncStatus()
        status.account = .available
        status.began()
        status.failed("Zone missing")

        status.paused()
        #expect(status.activity == .paused)

        status.began()
        status.finished()
        #expect(status.activity == .idle)
    }

    /// No account outranks whatever the engine last managed to do: there is
    /// nothing actionable in "Sync Problem" when the real answer is "sign in".
    @Test("A missing account outranks the activity")
    func accountOutranksActivity() {
        let status = CloudSyncStatus()
        status.account = .noAccount
        status.began()
        status.failed("Zone missing")

        #expect(status.title == "No Apple Account")
    }
}
