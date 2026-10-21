//
//  OfflineDownloadBackgroundTimeTests.swift
//  OpenHikesTests
//
//  Whether a download asks not to be suspended, and whether it gives the
//  grant back.
//
//  Its own file so that a file declares one `@Suite`; the context it shares
//  with the rest of the downloader's suites is in
//  `OfflineTileDownloaderTests.swift`'s header.
//
//  What makes this testable at all is that the reservation is a seam. The
//  branch that matters most — the system reclaiming the time — cannot be
//  induced on a device, let alone in a suite, so a stand-in that can fire the
//  expiration handler on demand is the only way it is ever exercised. The
//  same argument `BackgroundTimeReservation`'s own header makes, and the same
//  one the downloader's transport and gate were built on.
//

import Foundation
@testable import OpenHikes
import Testing

/// Records what was asked for, and can expire the grant on demand.
@MainActor
private final class RecordingBackgroundTime {
    private(set) var begun = 0
    private(set) var ended: [BackgroundTimeToken] = []
    /// `false` makes every reservation a refusal, which is what a device out
    /// of background time answers.
    var isAvailable = true
    /// Reuses an ended handle to exercise reservation identity.
    var reusesToken = false
    private(set) var expirationHandler: (@MainActor () -> Void)?
    private var nextToken = 1

    var reservation: BackgroundTimeReservation {
        BackgroundTimeReservation(
            begin: { [self] handler in
                begun += 1
                guard isAvailable else { return nil }
                expirationHandler = handler
                defer { nextToken += 1 }
                return BackgroundTimeToken(rawValue: reusesToken ? 1 : nextToken)
            },
            end: { [self] token in ended.append(token) }
        )
    }

    /// What the system does when it wants its time back.
    func expire() {
        let handler = expirationHandler
        expirationHandler = nil
        handler?()
    }

    var isOutstanding: Bool { begun > ended.count }
}

/// Holds every save open until the test lets it go, and says when the first
/// one arrived — so a run can be pinned mid-download, in flight, while the
/// test looks at what time it holds. The shape `SaveProbe` takes in
/// `OfflineTileDownloaderTests+Window.swift`, for the reason it gives.
private actor ParkedSaves {
    private(set) var arrived = false
    private var isReleased = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func save() async -> Bool {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !isReleased {
            await withCheckedContinuation { parked.append($0) }
        }
        return true
    }

    func waitForFirstSave() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let resumed = parked
        parked.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}

@MainActor
@Suite("Offline download background time")
struct OfflineDownloadBackgroundTimeTests {
    /// Points nowhere, so nothing is fetched. Borrowed from
    /// `OfflineDownloadStateTests` for the reason that suite gives: only the
    /// id's *policy* matters, since every save is injected.
    private let unreachable = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "http://127.0.0.1:9/{z}/{x}/{y}.png",
        maximumZ: 10
    )

    private var reclaimingQuota: OfflineTileDownloader.QuotaBroker {
        .init(
            space: { _ in (limit: 0, used: 0) },
            reclaimable: { _, _ in .max },
            reclaim: { _, _, bytes in bytes }
        )
    }

    private func downloader(
        _ time: RecordingBackgroundTime
    ) -> OfflineTileDownloader {
        OfflineTileDownloader(
            isOnline: { true },
            backgroundTime: time.reservation,
            saveTile: { _, _ in false }
        )
    }

    /// A downloader whose saves park in `saves`, with a gate and registry of
    /// its own so a run held open here holds nothing another suite shares.
    private func downloader(
        _ time: RecordingBackgroundTime,
        parkingIn saves: ParkedSaves,
        quota: OfflineTileDownloader.QuotaBroker = .unlimited
    ) -> OfflineTileDownloader {
        OfflineTileDownloader(
            gate: TileLoadGate(),
            isOnline: { true },
            quota: quota,
            registry: OfflineDownloadRegistry(),
            backgroundTime: time.reservation,
            saveTile: { _, _ in await saves.save() }
        )
    }

    @Test("a download asks not to be suspended")
    func reservesTimeOnStart() {
        let time = RecordingBackgroundTime()
        let downloader = downloader(time)

        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )

        #expect(time.begun == 1)
        downloader.cancel()
    }

    /// The system counts these, and an app that keeps one after its work has
    /// stopped is killed on the next expiry rather than suspended.
    @Test("cancelling gives the grant back")
    func cancellingReleasesTheGrant() {
        let time = RecordingBackgroundTime()
        let downloader = downloader(time)

        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        downloader.cancel()

        #expect(!time.isOutstanding)
    }

    /// `cancel()` and the task's own tail both release, because a cancelled
    /// task's tail is not guaranteed to run promptly. Ending a grant twice is
    /// its own fault, so the second call has to do nothing.
    @Test("the grant is given back exactly once however many paths release it")
    func releaseIsIdempotent() {
        let time = RecordingBackgroundTime()
        let downloader = downloader(time)

        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        downloader.cancel()
        downloader.cancel()

        #expect(time.ended.count == 1)
    }

    /// The branch no device can be made to take on demand: the system is
    /// about to reclaim the time, and an app still running when it does is
    /// killed rather than suspended — which would cost the hiker every tile
    /// the run had fetched.
    @Test("an expiring grant stops the run rather than being ignored")
    func expiryStopsTheRun() {
        let time = RecordingBackgroundTime()
        let downloader = downloader(time)
        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        #expect(downloader.phase == .downloading)

        time.expire()

        #expect(downloader.phase == .idle, "the run has to stop before the grant does")
        #expect(!time.isOutstanding, "and the time has to go back")
    }

    /// Background execution can simply be unavailable. The download then does
    /// exactly what it did before any of this existed — stalls on lock,
    /// resumes on return — and nothing is reported, because there is nothing
    /// the hiker could do about it.
    @Test("a refused reservation does not stop the download")
    func aRefusalIsNotAFailure() {
        let time = RecordingBackgroundTime()
        time.isAvailable = false
        let downloader = downloader(time)

        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )

        #expect(downloader.phase == .downloading)
        #expect(time.begun == 1)
        #expect(time.ended.isEmpty, "nothing was granted, so there is nothing to end")
        downloader.cancel()
    }

    /// A run restarted over a run already holding a grant must not leak the
    /// first one: the system charges an app for a task it never gets back.
    @Test("restarting gives the old grant back before taking a new one")
    func restartingDoesNotLeak() {
        let time = RecordingBackgroundTime()
        let downloader = downloader(time)

        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        downloader.cancel()
        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )

        #expect(time.begun == 2)
        downloader.cancel()
        #expect(time.ended.count == 2, "each grant is ended exactly once")
    }

    /// Cancel and restart in one breath, and the cancelled run's tail lands
    /// after the restart has taken its grant. That tail used to end whatever
    /// the downloader held — the replacement's grant, with the replacement
    /// still downloading and now suspendable on lock (#876).
    @Test("a cancelled run's late tail leaves its replacement's grant alone", arguments: [false, true])
    func supersededTailKeepsTheReplacementsGrant(reusesToken: Bool) async throws {
        let time = RecordingBackgroundTime()
        time.reusesToken = reusesToken
        let saves = ParkedSaves()
        let downloader = downloader(time, parkingIn: saves)

        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        let cancelled = try #require(downloader.lastRun)
        downloader.cancel()
        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        await saves.waitForFirstSave()
        await cancelled.value

        #expect(downloader.phase == .downloading, "precondition: the replacement is mid-download")
        #expect(time.ended == [BackgroundTimeToken(rawValue: 1)], "only the cancelled run's grant went back")
        #expect(time.isOutstanding, "the replacement still holds its own")

        await saves.release()
        await downloader.waitForCurrentRun()
        #expect(time.ended == [
            BackgroundTimeToken(rawValue: 1),
            BackgroundTimeToken(rawValue: reusesToken ? 1 : 2),
        ])
    }

    /// The grant `start` took went back when planning stopped to ask about
    /// space, so the run the hiker's confirmation starts needs one of its own
    /// — it used to run with none, and lock meant suspension (#882).
    @Test("freeing space for a download reserves time for the run it starts")
    func confirmedReclaimReservesItsOwnGrant() async throws {
        let time = RecordingBackgroundTime()
        let saves = ParkedSaves()
        let downloader = downloader(
            time,
            parkingIn: saves,
            quota: reclaimingQuota
        )
        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForCurrentRun()
        _ = try #require(downloader.pendingSpaceShortfall)
        #expect(!time.isOutstanding, "waiting on the hiker holds no time")

        downloader.confirmReclaimingSpace()
        await saves.waitForFirstSave()

        #expect(downloader.phase == .downloading)
        #expect(time.begun == 2)
        #expect(time.isOutstanding, "the confirmed run is covered while it downloads")

        await saves.release()
        await downloader.waitForCurrentRun()
        #expect(downloader.phase == .finished)
        #expect(!time.isOutstanding, "and gives its grant back when it ends")
    }

    /// Planning and the run its confirmation starts share a generation, so a
    /// generation is not what tells their grants apart. The planning grant's
    /// expiry, landing after that grant went back, must stop neither the
    /// question nor the answer to it.
    @Test("an ended planning grant cannot cancel the space decision or its confirmed run", arguments: [false, true])
    func planningExpiryLeavesItsSuccessorAlone(confirmFirst: Bool) async throws {
        let time = RecordingBackgroundTime()
        let saves = ParkedSaves()
        let downloader = downloader(time, parkingIn: saves, quota: reclaimingQuota)
        downloader.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        let planningExpiry = try #require(time.expirationHandler)
        await downloader.waitForCurrentRun()
        _ = try #require(downloader.pendingSpaceShortfall)

        if confirmFirst {
            downloader.confirmReclaimingSpace()
            await saves.waitForFirstSave()
        }

        // Replay a callback already queued for the grant planning returned.
        // Confirmation shares the plan's download generation, but owns a
        // different reservation; neither it nor the prompt belongs to this
        // ended grant's expiration handler.
        planningExpiry()

        if confirmFirst {
            #expect(downloader.phase == .downloading)
        } else {
            #expect(downloader.pendingSpaceShortfall != nil)
        }
        #expect(time.isOutstanding == confirmFirst)
        #expect(time.ended == [BackgroundTimeToken(rawValue: 1)])

        if confirmFirst {
            time.expire()
            #expect(downloader.phase == .idle, "the confirmed run's own grant still expires it")
        } else {
            downloader.cancel()
        }
        await saves.release()
        await downloader.waitForCurrentRun()
        #expect(!time.isOutstanding)
    }
}

extension OfflineDownloadBackgroundTimeTests {
    /// A run whose task held its downloader weakly could find it gone, and
    /// then neither download nor give back the grant taken for it — which is
    /// the app killed on the next expiry rather than suspended.
    @Test("a run returns its grant after its caller releases the downloader", arguments: [false, true])
    func callerCanReleaseDownloader(reclaiming: Bool) async throws {
        let time = RecordingBackgroundTime()
        let saves = ParkedSaves()
        var downloader: OfflineTileDownloader? = downloader(
            time,
            parkingIn: saves,
            quota: reclaiming ? reclaimingQuota : .unlimited
        )
        downloader?.start(
            route: Fixture.ridgeRoute,
            source: unreachable,
            claim: Fixture.unrecordedClaim
        )
        if reclaiming {
            await downloader?.waitForCurrentRun()
            _ = try #require(downloader?.pendingSpaceShortfall)
            downloader?.confirmReclaimingSpace()
        }
        let run = try #require(downloader?.lastRun)
        #expect(time.begun == (reclaiming ? 2 : 1))
        weak let releasedDownloader = downloader

        // The task has not started yet. The detail screen is allowed to
        // leave immediately after either action; the run still owes the
        // system its grant back, even without a screen keeping it alive.
        downloader = nil
        await saves.release()
        await run.value

        #expect(await saves.arrived, "the download outlives the screen that started it")
        #expect(!time.isOutstanding)
        #expect(time.ended.count == time.begun)
        #expect(releasedDownloader == nil, "the completed task must release its owner")
    }
}
