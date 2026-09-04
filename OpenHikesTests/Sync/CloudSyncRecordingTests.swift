//
//  CloudSyncRecordingTests.swift
//  OpenHikesTests
//
//  The case that settled the relaunch: the iCloud switch moved while a walk is
//  being recorded.
//
//  Rebuilding the container in place is the alternative, and this is where it
//  costs more than it buys. ``HikeRecorder`` holds the container it started
//  with, its live trace and its journal are half a walk that only that store
//  can finish, and a swap underneath them trades an honest prompt for a
//  recording that ends in a store which no longer exists. So the switch is
//  deliberately inert until the next launch — and inertness is a claim a suite
//  can hold to: the walk crosses the flip untouched and lands whole, and the
//  settings row is the only thing that changed.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Cloud sync switch during a recording")
final class CloudSyncRecordingTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let source = StubRecordingLocationSource()
    private let clock = TestClock()
    private let journalDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "cloud-sync-recording-\(UUID().uuidString)",
            isDirectory: true
        )
    // periphery:ignore - the strong reference that keeps the recorder alive
    // for the length of the test; never read back.
    private var recorder: HikeRecorder?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: journalDirectory)
    }

    /// A walk that spans the flip is finished by the store it started in, and
    /// the switch says out loud that it has not taken effect yet.
    ///
    /// Both halves matter. Without the first, a live swap could be introduced
    /// and nothing here would notice a recording losing the store underneath
    /// it. Without the second, the switch would be inert *and* silent, which
    /// is the state a person reads as a broken toggle.
    @Test("the switch moved mid-walk changes the row and nothing else")
    func flippingDuringARecordingLeavesTheWalkAlone() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "CloudSyncRecordingTests-\(UUID().uuidString)")
        )
        let sync = CloudSyncCoordinator(
            defaults: defaults,
            isSyncingThisLaunch: true,
            storageIsDurable: true
        )
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        let draft = try #require(hikeRecorder.currentHike)
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        #expect(hikeRecorder.stats.pointCount == 2)

        sync.isEnabled = false

        // The recorder was told nothing, because there is nothing to tell it:
        // the same draft in the same store goes on collecting fixes.
        #expect(hikeRecorder.currentHike?.id == draft.id)
        #expect(hikeRecorder.phase == .recording)
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6304))
        #expect(hikeRecorder.stats.pointCount == 3)

        let hike = try savedHike(from: await hikeRecorder.stop())
        #expect(hike.id == draft.id)
        #expect(hike.route.count == 3)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)

        // And the row carries the whole of the change until the next launch.
        #expect(sync.pendingRelaunch)
        #expect(sync.status.title == "Restart to Apply")
        #expect(sync.status.detail.contains("reopen"))
    }

    private func makeRecorder() -> HikeRecorder {
        let defaults = UserDefaults(
            suiteName: "cloud-sync-recording-settings-\(UUID().uuidString)"
        ) ?? UserDefaults.standard
        let instance = HikeRecorder(
            container: container,
            source: source,
            defaults: defaults,
            // Never the process-wide monitor in a test: it would assert
            // against the machine's battery rather than against the policy.
            powerMonitor: PowerStateMonitor(
                read: { PowerState() },
                observesNotifications: false
            ),
            journalDirectory: journalDirectory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        recorder = instance
        return instance
    }

    private func savedHike(from outcome: RecordingStopOutcome) throws -> Hike {
        guard case .saved(let hike) = outcome else {
            Issue.record("the recording unexpectedly required review")
            throw RecordingFailure.save(
                "The recording unexpectedly required review."
            )
        }
        return hike
    }

    private func fix(latitude: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: 12.86
            ),
            altitude: 600,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            course: 0,
            speed: 1,
            timestamp: clock.now
        )
    }
}
