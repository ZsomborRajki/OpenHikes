//
//  OfflineCountriesSupersededTransferTests.swift
//  OpenHikesTests
//
//  A transfer a cancel ended, reporting after the same file was asked for
//  again. Cancelling an area and downloading it once more asks for the same
//  files of the same build under the same key, and the cancelled task can
//  still finish, fail or report progress after its replacement has begun:
//  matched by the key alone, its events landed on the new download. They are
//  matched by the task that sent them now, while a transfer picked up from
//  an earlier launch, which this launch never started, is still taken, and
//  a launch picking up what was coming down leaves alone a download asked
//  for again meanwhile. What the session's own callbacks take is
//  `OfflineCountryTransfersTests`'.
//
//  Driven through the stub session, which hands each request a task
//  identifier of its own and delivers any request's events on demand.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: superseded transfers")
struct OfflineCountriesSupersededTransferTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let extras = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("extras".utf8)],
        maximumZoom: 0
    )

    @Test("a cancelled transfer's late events do not land on the download that replaced it")
    func lateEventsFromACancelledTransferAreIgnored() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])
            harness.countries.download(country)
            let first = harness.downloader.requests
            #expect(harness.countries.cancel("SI"))
            harness.countries.download(country)
            let replacement = try #require(harness.countries.downloads["SI"])
            #expect(harness.downloader.requests.count == first.count * 2, "precondition: the files asked for again")

            // The first tries, reporting after the second ones began.
            let firstBasemap = try #require(first.first { $0.key.role == .basemap })
            let firstExtras = try #require(first.first { $0.key.role == .extras })
            harness.downloader.onEvent?(.wrote(firstBasemap.transfer, 999))
            try harness.downloader.land(firstBasemap, as: basemap)
            harness.downloader.fail(firstExtras, resumeData: nil)

            #expect(replacement.staged[.basemap] == nil, "the old file is not the new download's")
            #expect(replacement.writtenBytes == 0)
            #expect(!replacement.hasFailed, "the old failure is not the new download's")
            #expect(harness.countries.downloads["SI"] === replacement)

            // The replacement's own come through.
            try harness.downloader.land(.basemap, as: basemap)
            #expect(replacement.staged[.basemap] != nil)
        }
    }

    @Test("a cancelled transfer's late cancellation leaves the replacement running")
    func aLateCancellationIsIgnored() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])
            harness.countries.download(country)
            let cancelled = try #require(harness.downloader.requests.first)
            #expect(harness.countries.cancel("SI"))
            harness.countries.download(country)

            harness.downloader.fail(cancelled, resumeData: Data("partial".utf8), cancelled: true)
            harness.downloader.fail(cancelled, resumeData: Data("partial".utf8))

            let replacement = try #require(harness.countries.downloads["SI"])
            #expect(!replacement.hasFailed)
            #expect(replacement.resumeData[.basemap] == nil, "nothing of the old transfer is resumed from")
            #expect(replacement.inFlight.contains(.basemap))
        }
    }

    /// A launch picks up the transfers an earlier one started without
    /// having started them itself, so it cannot know their tasks.
    @Test("a transfer picked up from an earlier launch is still taken")
    func aRecoveredTransferIsTaken() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            try store.write(pending: [OfflineCountryStore.Pending(country: country, roles: [.basemap])])
            let downloader = StubCountryDownloader()
            let key = OfflineCountryDownloadKey(country: "SI", build: country.build, role: .basemap)
            downloader.stillRunning = [key: 40]
            let countries = OfflineCountries(
                store: store,
                server: StubCountryServer(nil),
                downloader: downloader,
                archives: OfflineCountryArchives(),
                freeSpace: { 1 << 40 }
            )
            await countries.start()

            downloader.onEvent?(.wrote(OfflineCountryTransfer(key: key, task: 77), 60))

            #expect(countries.downloads["SI"]?.writtenBytes == 60)
        }
    }

    /// The areas are listed before the session has said what it still has,
    /// so the hiker can cancel one coming down and ask for it again
    /// meanwhile, which lists the same entry anew. Taken over by the launch,
    /// the new download lost the tasks it started, and with them what told
    /// the cancelled transfers' events from its own.
    @Test("a download cancelled and asked for again while the launch lists the session's tasks keeps its transfers")
    func askedForAgainDuringRecovery() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            try store.write(pending: [OfflineCountryStore.Pending(country: country, roles: [.basemap])])
            let downloader = StubCountryDownloader()
            downloader.holdsListing = true
            let countries = OfflineCountries(
                store: store,
                server: StubCountryServer(nil),
                downloader: downloader,
                archives: OfflineCountryArchives(),
                freeSpace: { 1 << 40 }
            )

            let launch = Task { await countries.start() }
            await settleDelegateHop(until: "the launch waits on the session's tasks") {
                !downloader.waitingForListing.isEmpty
            }
            #expect(countries.cancel("SI"))
            countries.download(country)
            let replacement = try #require(countries.downloads["SI"])
            downloader.releaseListing()
            await launch.value

            #expect(countries.downloads["SI"] === replacement, "the launch took none of it over")
            #expect(replacement.phase == .downloading)
            let key = OfflineCountryDownloadKey(country: "SI", build: country.build, role: .basemap)
            downloader.onEvent?(.wrote(OfflineCountryTransfer(key: key, task: 77), 60))
            #expect(replacement.writtenBytes == 0, "another task's progress is not the new download's")
            downloader.progress(.basemap, 30)
            #expect(replacement.writtenBytes == 30)
        }
    }
}
