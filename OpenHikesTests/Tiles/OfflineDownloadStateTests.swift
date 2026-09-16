//
//  OfflineDownloadStateTests.swift
//  OpenHikesTests
//
//  "Offline download state", split out of OfflineTileDownloaderTests.swift so
//  that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftData
import Testing

/// Holds every stubbed save open until the test lets it go.
///
/// What a cancellation test needs is fetches that are genuinely still in
/// flight when `cancel()` lands, and then a way to know their tail has
/// finished unwinding. Sleeping supplies neither: it only makes both *likely*,
/// at the cost of the sleep on every run.
private actor HeldSaves {
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func save() async -> Bool {
        if !isReleased {
            await withCheckedContinuation { waiting.append($0) }
        }
        return true
    }

    func release() {
        isReleased = true
        let resumed = waiting
        waiting.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}

private actor AttemptCounter {
    private var attempts = 0

    func succeedAlternating() -> Bool {
        attempts += 1
        return !attempts.isMultiple(of: 2)
    }
}

@Suite("Offline download state")
struct OfflineDownloadStateTests {
    /// A source that can't reach anything: enough to drive the state machine
    /// without depending on a tile server (or on being online at all).
    ///
    /// Its `providerID` is a real, download-permitting one because `start`
    /// now refuses a source whose provider forbids bulk downloads and an
    /// unrecognised id fails closed. Only the id's *policy* is borrowed —
    /// the template points nowhere and every save is injected, so nothing is
    /// fetched from or written under the real provider.
    private let unreachable = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "http://127.0.0.1:9/{z}/{x}/{y}.png",
        maximumZ: 10
    )

    private let controlled = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 12
    )

    /// `supportsBulkDownload` is a promise to the tile host rather than a
    /// feature toggle, and it used to be kept by exactly one `if` in a
    /// SwiftUI body — `ActiveTileSource` dropped the flag, so the downloader
    /// could not have enforced it. This pins the domain's own refusal: the
    /// thing that would do the fetching declines before a single tile is
    /// planned, let alone requested.
    @Test("a provider that forbids bulk downloads is refused by the downloader")
    func refusesAForbiddenProvider() {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in
                Issue.record("a forbidden provider must not fetch a tile")
                return false
            }
        )

        downloader.start(
            route: Fixture.ridgeRoute,
            source: ActiveTileSource(.openStreetMap),
            claim: Fixture.unrecordedClaim,
        )

        #expect(downloader.isFailed)
        #expect(downloader.total == 0, "it must refuse before planning any tiles")
        #expect(downloader.completed == 0)
    }

    /// An id no catalog entry matches resolves to the default provider, which
    /// is OpenStreetMap — so a source the app cannot identify fails closed
    /// rather than inheriting permission nobody granted it.
    @Test("an unrecognised source fails closed")
    func refusesAnUnknownProvider() {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in true }
        )

        downloader.start(
            route: Fixture.ridgeRoute,
            source: ActiveTileSource(
                providerID: "not_a_provider",
                urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
                maximumZ: 12
            ),
            claim: Fixture.unrecordedClaim,
        )

        #expect(downloader.isFailed)
        #expect(downloader.total == 0)
    }

    @Test("a route with nothing to draw is refused with a reason")
    func refusesEmptyRoute() {
        let downloader = OfflineTileDownloader()
        downloader.start(route: [], source: unreachable, claim: Fixture.unrecordedClaim)
        #expect(downloader.isFailed)
        #expect(downloader.phase == .failed("No route to save."))

        downloader.start(
            route: [RouteCoordinate(latitude: 47.63, longitude: 12.86)],
            source: unreachable,
            claim: Fixture.unrecordedClaim,
        )
        #expect(downloader.isFailed)
    }

    @Test("progress is zero until there's something to count")
    func progressStartsEmpty() {
        let downloader = OfflineTileDownloader()
        #expect(downloader.phase == .idle)
        #expect(downloader.progress == 0)
        #expect(downloader.total == 0)
        #expect(!downloader.isFailed)
    }

    /// The button goes back to "Offline" once the hiker has dealt with a
    /// failure — by deleting the hike's tiles, which is the one path that
    /// clears a finished or failed run. It used to have a `reset()` of its
    /// own, which declined while a download was running and so could not be
    /// used by the deletion that needed it; `cancel()` is the one spelling
    /// now, and it works from every phase.
    @Test("a failed download can be cleared back to idle")
    func cancelAfterFailure() {
        let downloader = OfflineTileDownloader()
        downloader.start(route: [], source: unreachable, claim: Fixture.unrecordedClaim)
        #expect(downloader.isFailed)
        downloader.cancel()
        #expect(downloader.phase == .idle)
        #expect(downloader.total == 0)
    }

    /// Starting counts the work up front, which is what the "Saving N tiles…"
    /// note reports.
    ///
    /// Connectivity and the fetch itself are both injected, so this says the
    /// same thing on a machine with no network as on one with — it used to be
    /// gated on `TileCache.shared.isOnline`, i.e. it silently didn't run.
    @Test("starting a download counts the tiles it's going to fetch")
    func startCountsTiles() async {
        let downloader = OfflineTileDownloader(isOnline: { true }, saveTile: { _, _ in false })
        downloader.start(route: Fixture.ridgeRoute, source: unreachable, claim: Fixture.unrecordedClaim)
        #expect(downloader.phase == .downloading)
        await downloader.waitForPlanning()
        #expect(downloader.total > 0)
        downloader.cancel()
    }

    /// `waitForPlanning()` parks a continuation, so every path out of planning
    /// has to release it. Cancelling mid-plan is the one that used to be
    /// missed — and the previous implementation, a `Task.yield()` spin on the
    /// main actor, could not have been fixed by adding a case: it competed for
    /// the actor with the work it was waiting for.
    @Test("a waiter is released when planning is cancelled rather than finished")
    func cancellingPlanningReleasesWaiters() async {
        let route = (0..<100_000).map { index in
            RouteCoordinate(
                latitude: 47.63 + Double(index) * 0.000001,
                longitude: 12.86
            )
        }
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in true }
        )

        downloader.start(route: route, source: controlled, claim: Fixture.unrecordedClaim)
        let waiter = Task { await downloader.waitForPlanning() }
        downloader.cancel()

        await waiter.value
        #expect(downloader.phase == .idle)
        #expect(downloader.total == 0)
    }

    /// Nothing is planning, so there is nothing to wait for. Parking here
    /// would hang every caller that asks after a finished or idle run.
    @Test("waiting on planning that isn't happening returns immediately")
    func waitingWithoutPlanningReturns() async {
        let downloader = OfflineTileDownloader(isOnline: { true }, saveTile: { _, _ in false })
        await downloader.waitForPlanning()
        #expect(downloader.phase == .idle)
    }

    @Test("cancelling while a long route is being planned is final")
    func cancelDuringPlanning() async {
        let route = (0..<100_000).map { index in
            RouteCoordinate(
                latitude: 47.63 + Double(index) * 0.000001,
                longitude: 12.86
            )
        }
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in true }
        )

        downloader.start(route: route, source: controlled, claim: Fixture.unrecordedClaim)
        downloader.cancel()
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .idle)
        #expect(downloader.total == 0)
        #expect(downloader.completed == 0)
    }

    /// Cancelling has to leave the downloader genuinely idle — including
    /// after the abandoned run's in-flight fetches finish, which is the race
    /// the generation counter exists to close. A stale run reporting
    /// "finished" over a fresh one is the visible symptom.
    ///
    /// The tail is waited for rather than slept past: the saves are held open
    /// until the test lets them go, and `waitForCurrentRun()` then returns
    /// once the abandoned run has actually finished unwinding.
    @Test("a cancelled download stays cancelled while its tail unwinds")
    func cancelIsFinal() async {
        let held = HeldSaves()
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in await held.save() }
        )
        downloader.start(route: Fixture.ridgeRoute, source: unreachable, claim: Fixture.unrecordedClaim)
        #expect(downloader.phase == .downloading)

        downloader.cancel()
        #expect(downloader.phase == .idle)
        #expect(downloader.completed == 0)
        #expect(downloader.total == 0)

        await held.release()
        await downloader.waitForCurrentRun()
        #expect(downloader.phase == .idle, "the abandoned run must not report over a cancellation")
        #expect(downloader.total == 0)
    }

    /// Cancel-then-restart is one tap away in the UI (the same button), so the
    /// second download's state must survive the first one's tail.
    @Test("restarting after a cancel isn't clobbered by the abandoned run")
    func restartAfterCancel() async {
        let held = HeldSaves()
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in await held.save() }
        )
        let route = Fixture.ridgeRoute
        downloader.start(route: route, source: unreachable, claim: Fixture.unrecordedClaim)
        downloader.cancel()
        downloader.start(route: route, source: unreachable, claim: Fixture.unrecordedClaim)
        #expect(downloader.phase == .downloading)

        // Both runs' saves complete now, so the abandoned one's tail unwinds
        // alongside the live one rather than after it.
        await held.release()
        await downloader.waitForCurrentRun()

        // Finished on its own terms — but never knocked back to idle by the
        // run that was cancelled.
        #expect(downloader.phase != .idle)
        downloader.cancel()
    }

    @Test("a partial download fails and records only successful tiles")
    func partialDownloadIsNotReportedComplete() async {
        let attempts = AttemptCounter()
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in await attempts.succeedAlternating() }
        )

        downloader.start(route: Fixture.ridgeRoute, source: controlled, claim: Fixture.unrecordedClaim)
        await downloader.waitForCurrentRun()

        #expect(downloader.isFailed)
        let record = downloader.completedRecord
        #expect(record?.savedTileKeys.isEmpty == false)
        #expect((record?.savedTileKeys.count ?? 0) < downloader.total)
        // The bar and the "Saved N of M" message read the same number.
        #expect(downloader.completed == record?.savedTileKeys.count)
        #expect(downloader.completed < downloader.total, "half the tiles saved is not a full bar")
    }

    /// Progress counts tiles that really landed, not attempts: a download
    /// where every tile fails must not fill its bar on the way to reporting
    /// "Couldn't save any tiles."
    @Test("a download that saves nothing doesn't fill its progress bar")
    func failedDownloadReportsNoProgress() async {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in false }
        )

        downloader.start(route: Fixture.ridgeRoute, source: controlled, claim: Fixture.unrecordedClaim)
        await downloader.waitForCurrentRun()

        #expect(downloader.isFailed)
        #expect(downloader.total > 0, "precondition: it had tiles to try")
        #expect(downloader.completed == 0)
        #expect(downloader.progress == 0, "nothing saved is nothing to show")
    }

    /// And the other end: a download that really did save everything still
    /// reads as finished, so reporting successes hasn't made success
    /// unreachable.
    @Test("a complete download does fill its progress bar")
    func completeDownloadReportsFullProgress() async {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in true }
        )

        downloader.start(route: Fixture.ridgeRoute, source: controlled, claim: Fixture.unrecordedClaim)
        await downloader.waitForCurrentRun()

        #expect(downloader.completed == downloader.total)
        #expect(downloader.progress == 1)
    }

    @Test("a complete download keeps the compact deterministic record")
    func completeDownloadFinishes() async {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in true }
        )

        downloader.start(route: Fixture.ridgeRoute, source: controlled, claim: Fixture.unrecordedClaim)
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(downloader.completedRecord?.savedTileKeys.isEmpty == true)
    }
}
