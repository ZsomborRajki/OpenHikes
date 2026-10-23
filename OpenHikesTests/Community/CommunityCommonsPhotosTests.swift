//
//  CommunityCommonsPhotosTests.swift
//  OpenHikesTests
//
//  The Wikimedia Commons photographs the *Community* tab finds: which
//  questions ask for them, that each answer replaces the last, that the
//  maker's *Photos* chip is their switch too, and when the map draws them.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@MainActor
@Suite("Community Commons photos")
struct CommunityCommonsPhotosTests {
    /// Commons, answering one photograph per area at the area's middle and
    /// writing down every area it was asked about. An area north of
    /// ``held`` waits for ``release()`` — or for its task to be cancelled —
    /// before it answers, which is how a search is kept out.
    nonisolated private final class StubSource: CommonsPhotoSourcing, Sendable {
        static let held = 50.0

        private let areas = Mutex<[CommunitySearchArea]>([])
        private let fetchedAgain = Mutex(0)
        private let gate: AsyncStream<Void>
        private let opener: AsyncStream<Void>.Continuation

        init() {
            (gate, opener) = AsyncStream.makeStream(of: Void.self)
        }

        var asked: [CommunitySearchArea] { areas.withLock { $0 } }
        /// How many thumbnails ``download(_:into:)`` fetched a second time.
        var downloads: Int { fetchedAgain.withLock { $0 } }

        func release() { opener.yield() }

        @concurrent
        func photos(along route: [RouteCoordinate], downloadingInto directory: URL) async -> [CommonsPhoto] {
            []
        }

        @concurrent
        func photos(
            in area: CommunitySearchArea,
            avoiding shown: Set<URL>,
            downloadingInto directory: URL
        ) async throws -> [CommonsPhoto] {
            areas.withLock { $0.append(area) }
            if area.latitude > Self.held {
                for await _ in gate { break }
                try Task.checkCancellation()
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let photo = CommunityCommonsPhotosTests.photo(at: area.coordinate, in: directory)
            try PhotoDiscoveryFixture.sampleImageData().write(to: photo.fileURL)
            return [photo]
        }

        @concurrent
        func download(_ photo: CommonsPhoto, into directory: URL) async throws -> CommonsPhoto? {
            fetchedAgain.withLock { $0 += 1 }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var again = photo
            again.fileURL = directory.appendingPathComponent("again-\(UUID().uuidString).jpeg")
            try PhotoDiscoveryFixture.sampleImageData().write(to: again.fileURL)
            return again
        }
    }

    /// A photograph named after where it was taken, so two areas' answers
    /// are two different Commons pages.
    nonisolated private static func photo(at spot: CLLocationCoordinate2D, in directory: URL) -> CommonsPhoto {
        let name = "\(spot.latitude),\(spot.longitude)"
        return CommonsPhoto(
            pin: CommunityPhotoPin(capturedAt: Date(timeIntervalSince1970: 1_600_000_000), coordinate: spot),
            fileURL: directory.appendingPathComponent("commons-\(name).jpeg"),
            credit: CommonsPhotoCredit(
                author: nil,
                license: HikePhotoLicense(
                    name: "CC0",
                    url: nil,
                    sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(name).jpg")
                        ?? URL(filePath: "/")
                )
            )
        )
    }

    /// A root of the suite's own, so its sweep never reaches another's.
    private final class Root {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityCommonsPhotosTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func area(latitude: Double) -> CommunitySearchArea {
        CommunitySearchArea(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 13.0), radiusMeters: 3000)
    }

    private static func region(latitude: Double = 47.63, spanMeters: Double = 20_000) -> MKCoordinateRegion {
        let degrees = spanMeters / 111_320
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: 12.86),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    // MARK: - The holder

    @Test("a search shows what it found, and the next area's answer replaces it")
    func answersReplace() async throws {
        let root = Root()
        let photos = CommunityCommonsPhotos(source: StubSource(), root: root.url)

        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()
        let first = try #require(photos.photos.first)

        photos.search(in: Self.area(latitude: 47.7))
        await photos.settle()

        #expect(photos.photos.count == 1)
        #expect(photos.photos.first?.pin.coordinate?.latitude == 47.7)
        #expect(photos.photo(at: first.fileURL) == nil, "the last area's photograph is gone")
        #expect(!photos.isSearching)
    }

    /// A photograph's screen can be open over the map while the pill is
    /// tapped again, and its viewer and *Plan a Trail Here* read the file.
    @Test("the answer before stays on disk until the next one lands", .timeLimit(.minutes(1)))
    func previousFilesOutliveOneAnswer() async throws {
        let root = Root()
        let photos = CommunityCommonsPhotos(source: StubSource(), root: root.url)
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()
        let first = try #require(photos.photos.first).fileURL

        photos.search(in: Self.area(latitude: 47.7))
        await photos.settle()
        #expect(FileManager.default.fileExists(atPath: first.path))

        photos.search(in: Self.area(latitude: 47.8))
        await photos.settle()
        // Deleted off the main actor, so waited on rather than assumed.
        while FileManager.default.fileExists(atPath: first.path) {
            await Task.yield()
        }
    }

    /// The sweep runs off the main actor while the first search may already
    /// be writing, so what it spares is the launch's directory, not the
    /// answer's — which it has no name for yet.
    @Test("a launch sweeps what an earlier one left, and keeps its own answers", .timeLimit(.minutes(1)))
    func launchSweepsEarlierLaunches() async throws {
        let root = Root()
        let earlier = root.url.appendingPathComponent("earlier", isDirectory: true)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        try PhotoDiscoveryFixture.sampleImageData().write(to: earlier.appendingPathComponent("left.jpeg"))

        let photos = CommunityCommonsPhotos(source: StubSource(), root: root.url)
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()
        let answer = try #require(photos.photos.first).fileURL

        await settleDelegateHop(until: "the earlier launch's directory to be swept") {
            !FileManager.default.fileExists(atPath: earlier.path)
        }
        #expect(FileManager.default.fileExists(atPath: answer.path))
    }

    @Test("a newer search supersedes one still out")
    func newerSearchWins() async {
        let root = Root()
        let source = StubSource()
        let photos = CommunityCommonsPhotos(source: source, root: root.url)

        photos.search(in: Self.area(latitude: StubSource.held + 1))
        while source.asked.isEmpty {
            await Task.yield()
        }
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()
        source.release()

        #expect(photos.photos.map(\.pin.coordinate?.latitude) == [47.6])
    }

    @Test("with the Photos chip off, nothing is asked and what was shown goes")
    func chipOffAsksNothing() async {
        let root = Root()
        let source = StubSource()
        let filter = TrailPlaceFilter(defaults: nil)
        let photos = CommunityCommonsPhotos(source: source, filter: filter, root: root.url)
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()

        filter.setPhotosShown(false)
        #expect(photos.shown.isEmpty, "the map lets go of them at once")

        photos.search(in: Self.area(latitude: 47.7))
        await photos.settle()

        #expect(source.asked.count == 1)
        #expect(photos.photos.isEmpty)
    }

    @Test("the map draws none while the maker is up")
    func hiddenWhileDrawing() async {
        let root = Root()
        let drawing = Mutex(false)
        let photos = CommunityCommonsPhotos(
            source: StubSource(),
            isHidden: { drawing.withLock { $0 } },
            root: root.url
        )
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()
        #expect(photos.shown.count == 1)

        drawing.withLock { $0 = true }

        #expect(photos.shown.isEmpty)
        #expect(photos.photos.count == 1, "only hidden, not forgotten")
    }

    // MARK: - A screen that outlives its answer

    @Test("a photograph whose answer is still kept is used as it is")
    func keptFileIsUsedAsItIs() async throws {
        let root = Root()
        let source = StubSource()
        let photos = CommunityCommonsPhotos(source: source, root: root.url)
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()
        let first = try #require(photos.photos.first)
        photos.search(in: Self.area(latitude: 47.7))
        await photos.settle()

        #expect(await photos.usable(first) == first, "one answer back is still on disk")
        #expect(source.downloads == 0)
    }

    /// Two answers later the file is deleted — off the main actor, so
    /// possibly not yet — and a screen still showing it needs another.
    @Test("a photograph two answers old is downloaded again, once")
    func deletedFileIsDownloadedAgain() async throws {
        let root = Root()
        let source = StubSource()
        let photos = CommunityCommonsPhotos(source: source, root: root.url)
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()
        let first = try #require(photos.photos.first)
        photos.search(in: Self.area(latitude: 47.7))
        await photos.settle()
        photos.search(in: Self.area(latitude: 47.8))
        await photos.settle()

        let again = try #require(await photos.usable(first))

        #expect(again.fileURL != first.fileURL)
        #expect(again.credit == first.credit)
        #expect(FileManager.default.fileExists(atPath: again.fileURL.path))
        #expect(await photos.usable(again) == again, "and kept past the next answer's tidying")
        #expect(source.downloads == 1)
    }

    /// A group's grid asks for every tile at once, and the screen a tile
    /// opens asks again with the photograph the grid holds — the one whose
    /// file is gone.
    @Test("each photograph is downloaded again once, however many ask and in whatever order")
    func eachPageIsDownloadedAgainOnce() async throws {
        let root = Root()
        let source = StubSource()
        let photos = CommunityCommonsPhotos(source: source, root: root.url)
        var old: [CommonsPhoto] = []
        for latitude in [47.6, 47.65] {
            photos.search(in: Self.area(latitude: latitude))
            await photos.settle()
            old += photos.photos
        }
        for latitude in [47.7, 47.8] {
            photos.search(in: Self.area(latitude: latitude))
            await photos.settle()
        }
        let first = try #require(old.first)
        let second = try #require(old.last)

        async let tileOne = photos.usable(first)
        async let tileTwo = photos.usable(second)
        async let screen = photos.usable(first)
        let (one, two, opened) = await (tileOne, tileTwo, screen)

        #expect(one != nil && two != nil)
        #expect(opened == one, "the screen shares the tile's copy")
        #expect(await photos.usable(second) == two, "and asking again later downloads nothing")
        #expect(source.downloads == 2)
    }

    @Test("a photograph the newest answer found again is taken from it")
    func samePageFromTheNewestAnswer() async throws {
        let root = Root()
        let source = StubSource()
        let photos = CommunityCommonsPhotos(source: source, root: root.url)
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()
        let first = try #require(photos.photos.first)
        photos.search(in: Self.area(latitude: 47.7))
        await photos.settle()
        photos.search(in: Self.area(latitude: 47.6))
        await photos.settle()

        let again = try #require(await photos.usable(first))

        #expect(again == photos.photos.first)
        #expect(source.downloads == 0)
    }

    // MARK: - The browser

    @Test("opening the tab asks Commons about the same area, and the pins go with the tab")
    func theTabAsks() async {
        let root = Root()
        let source = StubSource()
        let browser = CommunityBrowser(
            transport: StubCommunityTransport(),
            blockList: .scratch(),
            areaPhotos: CommunityCommonsPhotos(source: source, root: root.url)
        )
        browser.regionDidSettle(Self.region())

        browser.startBrowsing()
        await browser.areaPhotos.settle()

        #expect(source.asked.count == 1)
        #expect(source.asked.first?.latitude == 47.63)
        #expect(browser.commonsPins.count == 1)

        browser.stopBrowsing()
        #expect(browser.commonsPins.isEmpty)
        #expect(browser.areaPhotos.photos.count == 1, "kept with the rows for the way back")
    }

    /// The list's area is never under ten kilometres; a map zoomed to three
    /// shows a sliver of that, and a photograph off screen is worth nothing.
    @Test("Commons is asked about the part of the area the map shows")
    func theVisiblePartIsAsked() async throws {
        let root = Root()
        let source = StubSource()
        let browser = CommunityBrowser(
            transport: StubCommunityTransport(),
            blockList: .scratch(),
            areaPhotos: CommunityCommonsPhotos(source: source, root: root.url)
        )
        let zoomedIn = Self.region(spanMeters: 3000)
        browser.regionDidSettle(zoomedIn)

        browser.startBrowsing()
        await browser.areaPhotos.settle()

        let asked = try #require(source.asked.first)
        #expect(asked.radiusMeters == CommunityQueryPolicy.visibleRadiusMeters(for: zoomedIn))
        #expect(asked.radiusMeters < CommunityQueryPolicy.minimumRadiusMeters)
    }

    @Test("a refill after a block asks Commons nothing")
    func blockRefillAsksNothing() async {
        let root = Root()
        let source = StubSource()
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(
            transport: transport,
            blockList: .scratch(),
            areaPhotos: CommunityCommonsPhotos(source: source, root: root.url)
        )
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await browser.areaPhotos.settle()

        browser.refreshAfterBlock()
        await browser.areaPhotos.settle()

        #expect(source.asked.count == 1)
    }

    @Test("a tapped photo pin goes where the sheet said")
    func pinTapOpens() {
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        let photo = Self.photo(at: Self.area(latitude: 47.6).coordinate, in: Root().url)
        var opened: [CommonsPhoto] = []
        browser.onOpenCommonsPhoto { opened.append($0) }

        browser.open(photo)

        #expect(opened == [photo])
    }
}
