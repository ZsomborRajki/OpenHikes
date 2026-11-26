//
//  OfflineCountryTransfersTests.swift
//  OpenHikesTests
//
//  Which session task a country file's callbacks are taken from, as the
//  background session's callbacks ask it: the task this launch last started
//  for the file, kept once it has ended; an earlier launch's task where this
//  launch started none; and nothing of an area a cancel ended, until a task
//  is started for it again. Held without a session.
//

import Foundation
@testable import OpenHikes
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Offline countries: which transfer a callback is taken from")
struct OfflineCountryTransfersTests {
    private let basemap = OfflineCountryDownloadKey(country: "SI", build: "20261117", role: .basemap)
    private let extras = OfflineCountryDownloadKey(country: "SI", build: "20261117", role: .extras)
    private let staging = URL(filePath: "/staging/SI-20261117.pmtiles")
    private let fallback = URL(filePath: "/fallback/SI-20261117.pmtiles")

    private func transfer(_ key: OfflineCountryDownloadKey, _ task: Int) -> OfflineCountryTransfer {
        OfflineCountryTransfer(key: key, task: task)
    }

    /// How `transfer`'s end is taken.
    private func end(_ transfer: OfflineCountryTransfer, in transfers: inout OfflineCountryTransfers)
        -> OfflineCountryTransfers.Ending {
        transfers.end(transfer)
    }

    /// Whether progress `transfer` reports at `instant` is passed on, every
    /// half a second at the most.
    private func reports(
        _ transfer: OfflineCountryTransfer,
        at instant: ContinuousClock.Instant,
        in transfers: inout OfflineCountryTransfers
    ) -> Bool {
        transfers.reports(transfer, at: instant, every: .milliseconds(500))
    }

    /// Lands `transfer`, answering where it was staged, or `nil` with nothing
    /// moved.
    private func land(_ transfer: OfflineCountryTransfer, in transfers: inout OfflineCountryTransfers) -> URL? {
        var moved: [URL] = []
        let staged = transfers.land(transfer, fallback: fallback) { moved.append($0) }
        #expect(moved == staged.map { [$0] } ?? [], "moved only where it answers it was staged")
        return staged
    }

    @Test("a task its file's next start replaced is refused, and the replacement is not touched")
    func replacedTaskIsRefused() {
        var transfers = OfflineCountryTransfers()
        let now = ContinuousClock.now
        transfers.start(transfer(basemap, 1), stagingAt: staging)
        transfers.start(transfer(basemap, 2), stagingAt: staging)

        #expect(!transfers.takes(transfer(basemap, 1)))
        #expect(!reports(transfer(basemap, 1), at: now, in: &transfers))
        #expect(land(transfer(basemap, 1), in: &transfers) == nil)
        #expect(end(transfer(basemap, 1), in: &transfers) == .refused)

        #expect(reports(transfer(basemap, 2), at: now, in: &transfers))
        #expect(land(transfer(basemap, 2), in: &transfers) == staging)
        #expect(end(transfer(basemap, 2), in: &transfers) == .landed, "the old end cleared nothing of the new")
    }

    @Test("a task stays refused once the task that replaced it has ended")
    func replacedTaskStaysRefusedAfterTheReplacementEnds() {
        var transfers = OfflineCountryTransfers()
        transfers.start(transfer(basemap, 1), stagingAt: staging)
        transfers.start(transfer(basemap, 2), stagingAt: staging)
        #expect(land(transfer(basemap, 2), in: &transfers) == staging)
        #expect(end(transfer(basemap, 2), in: &transfers) == .landed)

        #expect(land(transfer(basemap, 1), in: &transfers) == nil, "nothing moved over the landed file")
        #expect(end(transfer(basemap, 1), in: &transfers) == .refused)
        #expect(!reports(transfer(basemap, 1), at: .now, in: &transfers))
    }

    @Test("a cancel refuses its area's tasks, an earlier launch's too, until one is started again")
    func cancelRefusesTheArea() {
        var transfers = OfflineCountryTransfers()
        let austria = OfflineCountryDownloadKey(country: "AT", build: "20261117", role: .basemap)
        transfers.start(transfer(basemap, 1), stagingAt: staging)
        transfers.cancel(country: "SI")

        #expect(!transfers.takes(transfer(basemap, 1)))
        #expect(land(transfer(basemap, 1), in: &transfers) == nil)
        #expect(end(transfer(basemap, 1), in: &transfers) == .refused)
        #expect(!transfers.takes(transfer(extras, 9)), "an earlier launch's task of the area")
        #expect(transfers.takes(transfer(austria, 9)), "an earlier launch's task of another area")

        transfers.start(transfer(basemap, 3), stagingAt: staging)
        #expect(transfers.takes(transfer(basemap, 3)))
        #expect(!transfers.takes(transfer(basemap, 1)))
        #expect(!transfers.takes(transfer(extras, 9)), "only the file started again is taken")
    }

    @Test("an earlier launch's task is taken, and staged where the model looks for it")
    func earlierLaunchsTaskIsTaken() {
        var transfers = OfflineCountryTransfers()
        #expect(transfers.takes(transfer(basemap, 7)))
        #expect(land(transfer(basemap, 7), in: &transfers) == fallback)
        #expect(end(transfer(basemap, 7), in: &transfers) == .landed)
        #expect(end(transfer(extras, 8), in: &transfers) == .stopped)
    }

    @Test("a task that ends without landing has stopped short")
    func endWithoutLandingIsAStop() {
        var transfers = OfflineCountryTransfers()
        transfers.start(transfer(basemap, 1), stagingAt: staging)
        #expect(end(transfer(basemap, 1), in: &transfers) == .stopped)
    }

    @Test("progress is passed on at most once an interval, and afresh for a new start")
    func progressIsPaced() {
        var transfers = OfflineCountryTransfers()
        let start = ContinuousClock.now
        transfers.start(transfer(basemap, 1), stagingAt: staging)

        #expect(reports(transfer(basemap, 1), at: start, in: &transfers))
        #expect(!reports(transfer(basemap, 1), at: start.advanced(by: .milliseconds(100)), in: &transfers))
        #expect(reports(transfer(basemap, 1), at: start.advanced(by: .milliseconds(600)), in: &transfers))

        transfers.start(transfer(basemap, 2), stagingAt: staging)
        #expect(reports(transfer(basemap, 2), at: start.advanced(by: .milliseconds(700)), in: &transfers))
    }
}

// swiftlint:enable no_magic_numbers
