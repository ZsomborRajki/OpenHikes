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
    private var expirationHandler: (@MainActor () -> Void)?
    private var nextToken = 1

    var reservation: BackgroundTimeReservation {
        BackgroundTimeReservation(
            begin: { [self] handler in
                begun += 1
                guard isAvailable else { return nil }
                expirationHandler = handler
                defer { nextToken += 1 }
                return BackgroundTimeToken(rawValue: nextToken)
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

    private func downloader(
        _ time: RecordingBackgroundTime
    ) -> OfflineTileDownloader {
        OfflineTileDownloader(
            isOnline: { true },
            backgroundTime: time.reservation,
            saveTile: { _, _ in false }
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
}
