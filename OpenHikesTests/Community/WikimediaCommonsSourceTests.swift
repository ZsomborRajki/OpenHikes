//
//  WikimediaCommonsSourceTests.swift
//  OpenHikesTests
//
//  The three steps of asking Commons about a route — where, what, and the
//  pictures themselves — driven through ``WikimediaCommonsSource/Transport``
//  rather than the network.
//
//  The stub answers the way the live service does: a geosearch with three
//  files standing on the route wherever the circle is, an imageinfo answer
//  describing them, and image bytes for each thumbnail. What is asserted is
//  what the preview depends on and cannot see from the photographs alone:
//  that a busy answer is waited out once rather than hammered, that one lost
//  thumbnail costs only itself, and that a screen that has gone has nothing
//  written into the directory it is deleting.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@Suite("Wikimedia Commons source")
struct WikimediaCommonsSourceTests {
    /// What the stand-in service answers with, readable off the main actor
    /// where its calls arrive.
    nonisolated private enum Answers {
        static let startLatitude = 47.6
        static let longitude = 13.0
        static let kilometre = 0.009
        /// Where along the ten-kilometre route the three files stand.
        static let photographed = [(id: 1, kilometres: 1.0), (id: 2, kilometres: 5.0), (id: 3, kilometres: 9.0)]

        static let route: [RouteCoordinate] = (0...10).map { step in
            RouteCoordinate(latitude: startLatitude + Double(step) * kilometre, longitude: longitude)
        }

        static let geosearch: Data = {
            let hits = photographed.map { photo in
                """
                {"pageid":\(photo.id),"ns":6,"title":"File:\(photo.id).jpg",\
                "lat":\(startLatitude + photo.kilometres * kilometre),"lon":\(longitude),"dist":1,"primary":true}
                """
            }
            return Data(#"{"batchcomplete":true,"query":{"geosearch":[\#(hits.joined(separator: ","))]}}"#.utf8)
        }()

        static let imageInfo: Data = {
            let pages = photographed.map { photo in
                """
                {"pageid":\(photo.id),"ns":6,"title":"File:\(photo.id).jpg","imageinfo":[{\
                "timestamp":"2020-06-0\(photo.id)T10:00:00Z","width":3000,"mime":"image/jpeg",\
                "thumburl":"https://upload.wikimedia.org/thumb/\(photo.id)/960px-\(photo.id).jpg",\
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:\(photo.id).jpg",\
                "extmetadata":{"Artist":{"value":"Hiker \(photo.id)"},"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]}
                """
            }
            return Data(#"{"batchcomplete":true,"query":{"pages":[\#(pages.joined(separator: ","))]}}"#.utf8)
        }()
    }

    private static var route: [RouteCoordinate] { Answers.route }
    private static var longitude: Double { Answers.longitude }
    private static var photographed: [(id: Int, kilometres: Double)] { Answers.photographed }

    // MARK: - The stand-in service

    /// Commons, answering from memory and writing down what it was asked.
    ///
    /// `final class` behind a `Mutex` for the reason the elevation suite's
    /// stub is one: the calls arrive off the main actor.
    nonisolated private final class StubCommons: @unchecked Sendable {
        private struct State {
            var requests: [URLRequest] = []
            var busyGeosearches = 0
            var missingThumbnails: Set<Int> = []
            var holdsDownloads = false
            /// Kept so each held download's stream stays open until its task
            /// is cancelled, rather than finishing when nothing references it.
            var holds: [AsyncStream<Void>.Continuation] = []
        }

        private let state = Mutex(State())
        private let started = AsyncStream<Void>.makeStream()

        var requests: [URLRequest] { state.withLock(\.requests) }

        /// The next `count` geosearches answer *too busy*.
        func beBusy(times count: Int) { state.withLock { $0.busyGeosearches = count } }

        /// These files' thumbnails answer 404.
        func lose(_ pageID: Int) { state.withLock { _ = $0.missingThumbnails.insert(pageID) } }

        /// Every thumbnail asked for is held until its task is cancelled —
        /// the pictures still on their way when the hiker backs out.
        func holdDownloads() { state.withLock { $0.holdsDownloads = true } }

        /// Returns once the first held thumbnail has been asked for.
        func firstDownloadStarted() async {
            for await _ in started.stream { return }
        }

        var transport: WikimediaCommonsSource.Transport {
            { [self] request in await answer(request) }
        }

        private func answer(_ request: URLRequest) async -> (Data, Int) {
            let url = request.url?.absoluteString ?? ""
            let (busy, missing, holds) = state.withLock { current in
                current.requests.append(request)
                let busy = url.contains("list=geosearch") && current.busyGeosearches > 0
                if busy { current.busyGeosearches -= 1 }
                return (busy, current.missingThumbnails, current.holdsDownloads)
            }
            if busy {
                return (Data(#"{"error":{"code":"cirrussearch-too-busy-error","info":"busy"}}"#.utf8), 200)
            }
            if url.contains("list=geosearch") { return (Answers.geosearch, 200) }
            if url.contains("prop=imageinfo") { return (Answers.imageInfo, 200) }
            if holds { await held() }
            let isMissing = missing.contains { url.contains("/thumb/\($0)/") }
            return isMissing ? (Data(), 404) : (PhotoDiscoveryFixture.sampleImageData(), 200)
        }

        /// Waits on a stream nothing yields to, which ends when the waiting
        /// task is cancelled — and then answers, as a download that finished
        /// just as the hiker left would.
        private func held() async {
            let (hold, continuation) = AsyncStream<Void>.makeStream()
            state.withLock { $0.holds.append(continuation) }
            started.continuation.yield()
            for await _ in hold { /* nothing is ever yielded: the loop ends on cancellation */ }
        }
    }

    /// A directory the source writes into, removed when the test leaves.
    private final class Downloads {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikimediaCommonsSourceTests-\(UUID().uuidString)", isDirectory: true)

        var files: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// The pauses a busy answer asked for, recorded rather than slept.
    nonisolated private final class Pauses: @unchecked Sendable {
        private let taken = Mutex<[Duration]>([])
        var durations: [Duration] { taken.withLock { $0 } }
        var pause: WikimediaCommonsSource.Pause {
            { [self] duration in taken.withLock { $0.append(duration) } }
        }
    }

    private static func source(_ commons: StubCommons, pauses: Pauses = Pauses()) -> WikimediaCommonsSource {
        WikimediaCommonsSource(transport: commons.transport, pause: pauses.pause)
    }

    // MARK: - The whole question

    @Test("the photographs standing on a route come back in walking order, credited and downloaded")
    func photographsAlongARoute() async throws {
        let commons = StubCommons()
        let downloads = Downloads()

        let photos = try await Self.source(commons).photos(along: Self.route, downloadingInto: downloads.directory)

        #expect(photos.map(\.credit.author) == ["Hiker 1", "Hiker 2", "Hiker 3"])
        #expect(photos.allSatisfy { $0.credit.licence.name == "CC BY-SA 4.0" })
        #expect(photos.allSatisfy { abs(($0.pin.coordinate?.longitude ?? 0) - Self.longitude) < 0.00001 })
        #expect(Set(downloads.files) == ["commons-1.jpeg", "commons-2.jpeg", "commons-3.jpeg"])
        #expect(
            commons.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent },
            "every request, thumbnails included, says who is asking"
        )
    }

    /// One imageinfo request for the lot, however many circles found them.
    @Test("the files are described in one request, after every stretch has been searched")
    func oneMetadataRequest() async throws {
        let commons = StubCommons()
        let downloads = Downloads()

        _ = try await Self.source(commons).photos(along: Self.route, downloadingInto: downloads.directory)

        let urls = commons.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.filter { $0.contains("prop=imageinfo") }.count == 1)
        let lastSearch = try #require(urls.lastIndex { $0.contains("list=geosearch") })
        let description = try #require(urls.firstIndex { $0.contains("prop=imageinfo") })
        #expect(lastSearch < description)
    }

    // MARK: - Busy, lost, gone

    @Test("a busy search is asked once more after a pause, not hammered")
    func busySearchIsRetriedOnce() async throws {
        let commons = StubCommons()
        commons.beBusy(times: 1)
        let pauses = Pauses()
        let downloads = Downloads()

        let photos = try await Self.source(commons, pauses: pauses)
            .photos(along: Self.route, downloadingInto: downloads.directory)

        #expect(pauses.durations == [WikimediaCommonsSource.busyRetryDelay])
        #expect(photos.count == Self.photographed.count, "the retry found what the busy answer did not")
    }

    @Test("a stretch still busy after its retry costs that stretch and nothing else")
    func stillBusyCostsOneStretch() async throws {
        let commons = StubCommons()
        // Both tries of the first stretch; every later stretch answers, and
        // each of them finds all three files.
        commons.beBusy(times: 2)
        let downloads = Downloads()

        let photos = try await Self.source(commons).photos(along: Self.route, downloadingInto: downloads.directory)

        #expect(photos.count == Self.photographed.count)
    }

    @Test("a thumbnail that does not arrive costs only itself")
    func lostThumbnailCostsItself() async throws {
        let commons = StubCommons()
        commons.lose(2)
        let downloads = Downloads()

        let photos = try await Self.source(commons).photos(along: Self.route, downloadingInto: downloads.directory)

        #expect(photos.map(\.credit.author) == ["Hiker 1", "Hiker 3"])
        #expect(!downloads.files.contains("commons-2.jpeg"))
    }

    /// The guard the preview's discard depends on: it waits for this task and
    /// then removes the directory, so a write after the cancellation would
    /// leave a stranger's photograph behind with nothing to collect it.
    @Test("a hiker backing out mid-download has nothing written after they left")
    func cancellationStopsTheWrites() async {
        let commons = StubCommons()
        commons.holdDownloads()
        let downloads = Downloads()
        let source = Self.source(commons)
        let directory = downloads.directory
        let path = Self.route

        let fetch = Task {
            try await source.photos(along: path, downloadingInto: directory)
        }
        await commons.firstDownloadStarted()
        fetch.cancel()
        let result = await fetch.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(downloads.files.isEmpty)
    }

    @Test("a route with nowhere to go asks nothing")
    func pointAsksNothing() async throws {
        let commons = StubCommons()
        let downloads = Downloads()

        let photos = try await Self.source(commons).photos(along: [Self.route[0]], downloadingInto: downloads.directory)

        #expect(photos.isEmpty)
        #expect(commons.requests.isEmpty)
    }
}
