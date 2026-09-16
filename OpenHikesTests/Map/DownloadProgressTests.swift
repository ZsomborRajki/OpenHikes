//
//  DownloadProgressTests.swift
//  OpenHikesTests
//
//  "Download progress", split out of RenderIsolationTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

@Suite("Download progress")
struct DownloadProgressTests {
    /// Progress still publishes once per saved tile, but only the focused
    /// download child views observe it; `HikeDetailView.body` observes
    /// low-frequency phase transitions instead.
    ///
    /// Saves are stubbed rather than pointed at a dead port: `completed` counts
    /// tiles *saved*, so a download where every tile fails now correctly
    /// publishes no progress at all, and there'd be nothing here to observe.
    @Test("progress notifies once per tile")
    func progressNotifiesPerTile() async {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            // Suspends before answering, so completions land in separate
            // runloop turns the way real fetches do — by yielding rather than
            // by sleeping, which would spend the same wall-clock time on every
            // run to buy the same ordering.
            saveTile: { _, _ in
                for _ in 0..<4 { await Task.yield() }
                return true
            }
        )
        let counter = ObservationCounter { _ = downloader.progress }
        await counter.settle()

        downloader.start(
            route: Fixture.ridgeRoute,
            source: ActiveTileSource(providerID: TileProvider.stadiaOutdoors.id, urlTemplate: "https://tiles.invalid/{z}/{x}/{y}.png", maximumZ: 14),
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForPlanning()
        let total = downloader.total
        #expect(total > 1, "precondition: there is more than one tile to fetch")

        await downloader.waitForCurrentRun()
        await counter.settle()

        #expect(downloader.completed == total)
        // Deliberately not `>= total`: this counter re-registers through a
        // `Task`, exactly like the map coordinator does, so completions that
        // land in the same runloop turn are coalesced — which is also what
        // SwiftUI does with the resulting invalidations. The point stands
        // either way: progress publishes repeatedly during a download, and
        // every view reading it is rebuilt each time.
        #expect(counter.count >= 2)
    }
}
