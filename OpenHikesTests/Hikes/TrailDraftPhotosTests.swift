//
//  TrailDraftPhotosTests.swift
//  OpenHikesTests
//
//  The Wikimedia Commons photographs the trail maker finds: what a search
//  adds, what a second one leaves out, what turning them off deletes, and
//  what a save keeps — credited, and never the hiker's own to publish.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@MainActor
@Suite("Trail draft photos")
struct TrailDraftPhotosTests {
    /// Commons, writing a real image into the directory for each spot it
    /// was built with and writing down what it was told was already shown.
    nonisolated private final class StubSource: CommonsPhotoSourcing, Sendable {
        let spots: [CLLocationCoordinate2D]
        private let told = Mutex<[Set<URL>]>([])

        init(_ spots: [CLLocationCoordinate2D]) { self.spots = spots }

        var avoided: [Set<URL>] { told.withLock { $0 } }

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
            told.withLock { $0.append(shown) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try spots.enumerated().compactMap { index, spot in
                let photo = TrailDraftPhotosTests.photo(index, at: spot, in: directory)
                guard !shown.contains(photo.credit.license.sourceURL) else { return nil }
                try PhotoDiscoveryFixture.sampleImageData().write(to: photo.fileURL)
                return photo
            }
        }
    }

    nonisolated private static func photo(
        _ index: Int,
        at spot: CLLocationCoordinate2D,
        in directory: URL
    ) -> CommonsPhoto {
        CommonsPhoto(
            pin: CommunityPhotoPin(capturedAt: Date(timeIntervalSince1970: 1_600_000_000), coordinate: spot),
            fileURL: directory.appendingPathComponent("commons-\(index).jpeg"),
            credit: CommonsPhotoCredit(
                author: "Hiker \(index)",
                license: HikePhotoLicense(
                    name: "CC BY-SA 4.0",
                    url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"),
                    sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(index).jpg")
                        ?? URL(filePath: "/")
                )
            )
        )
    }

    /// A root of the suite's own, so its sweep never reaches another's.
    private final class Root {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrailDraftPhotosTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static let area = CommunitySearchArea(
        coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: 13.0),
        radiusMeters: 1000
    )

    /// The ridge fixture's own points, so a photograph is on the line, and
    /// one a kilometre east of it, which is not.
    private static let onTheLine = Fixture.ridgeRoute[2].clCoordinate
    private static let offTheLine = CLLocationCoordinate2D(
        latitude: Fixture.ridgeRoute[2].latitude,
        longitude: Fixture.ridgeRoute[2].longitude + 0.013
    )

    private static func searched(_ photos: TrailDraftPhotos) async {
        photos.search(in: area)
        while photos.isSearching {
            await Task.yield()
        }
    }

    // MARK: - Searching

    @Test("a launch with no source cannot ask")
    func noSourceNoSearch() {
        let photos = TrailDraftPhotos(source: nil, root: Root().url)

        #expect(!photos.isAvailable)
        #expect(!photos.search(in: Self.area))
    }

    @Test("a search adds what it found, and a second leaves out what is already shown")
    func searchesAccumulate() async {
        let root = Root()
        let source = StubSource([Self.onTheLine, Self.offTheLine])
        let photos = TrailDraftPhotos(source: source, root: root.url)

        await Self.searched(photos)
        #expect(photos.photos.count == 2)

        await Self.searched(photos)
        #expect(photos.photos.count == 2, "the same two again add nothing")
        #expect(source.avoided.last == Set(photos.photos.map(\.credit.license.sourceURL)))
    }

    @Test("a second search while one is out is refused")
    func oneSearchAtATime() {
        let photos = TrailDraftPhotos(source: StubSource([Self.onTheLine]), root: Root().url)

        #expect(photos.search(in: Self.area))
        #expect(!photos.search(in: Self.area))
        photos.cancelSearch()
        #expect(!photos.isSearching)
    }

    @Test("clearing forgets the photographs and deletes their files")
    func clearDeletesTheFiles() async throws {
        let root = Root()
        let photos = TrailDraftPhotos(source: StubSource([Self.onTheLine]), root: root.url)
        await Self.searched(photos)
        let file = try #require(photos.photos.first?.fileURL)
        let before = photos.directory

        photos.clear()

        #expect(photos.photos.isEmpty)
        #expect(photos.directory != before, "the next search writes somewhere new")
        while FileManager.default.fileExists(atPath: file.path) {
            await Task.yield()
        }
    }

    /// The sweep runs off the main actor, so a search may already be writing
    /// into this drawing's directory by the time it lists the root.
    @Test("a launch sweeps what an earlier one left, and keeps this drawing's", .timeLimit(.minutes(1)))
    func launchSweepsEarlierLaunches() async throws {
        let root = Root()
        let earlier = root.url.appendingPathComponent("earlier", isDirectory: true)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        try PhotoDiscoveryFixture.sampleImageData().write(to: earlier.appendingPathComponent("left.jpeg"))

        let photos = TrailDraftPhotos(source: StubSource([Self.onTheLine]), root: root.url)
        await Self.searched(photos)
        let file = try #require(photos.photos.first?.fileURL)

        while FileManager.default.fileExists(atPath: earlier.path) {
            await Task.yield()
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - What a save keeps

    @Test("only the photographs the line passes are kept, pinned onto it")
    func onlyThoseOnTheLine() throws {
        let directory = FileManager.default.temporaryDirectory
        let near = Self.photo(0, at: Self.onTheLine, in: directory)
        let far = Self.photo(1, at: Self.offTheLine, in: directory)

        let kept = TrailDraftPhotos.onTrail([far, near], along: Fixture.ridgeRoute)

        #expect(kept.map(\.credit.author) == ["Hiker 0"])
        let pin = try #require(kept.first?.pin.coordinate)
        #expect(abs(pin.latitude - Self.onTheLine.latitude) < 0.0001)
    }

    @Test("a hand-off takes the files with it, so a discard after it deletes nothing it needs")
    func handOffKeepsTheFiles() async throws {
        let root = Root()
        let photos = TrailDraftPhotos(source: StubSource([Self.onTheLine, Self.offTheLine]), root: root.url)
        await Self.searched(photos)

        let handOff = try #require(photos.handOff(along: Fixture.ridgeRoute))
        photos.clear()

        #expect(handOff.photos.count == 1)
        #expect(photos.photos.isEmpty)
        #expect(handOff.directory != photos.directory)
        let kept = try #require(handOff.photos.first)
        #expect(FileManager.default.fileExists(atPath: kept.fileURL.path))
    }

    @Test("a line that passes none hands nothing over")
    func nothingToHandOff() async {
        let photos = TrailDraftPhotos(source: StubSource([Self.offTheLine]), root: Root().url)
        await Self.searched(photos)

        #expect(photos.handOff(along: Fixture.ridgeRoute) == nil)
        #expect(photos.photos.count == 1, "nothing handed over, nothing forgotten")
    }

    @Test("the copies are credited, licensed, never the hiker's own, and not copied twice")
    func theCopiesAreCredited() async throws {
        let root = Root()
        let sandbox = PhotoStoreSandbox()
        let photos = TrailDraftPhotos(source: StubSource([Self.onTheLine]), root: root.url)
        await Self.searched(photos)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let handOff = try #require(photos.handOff(along: hike.route))

        let missed = await handOff.attach(to: hike, store: sandbox.store, libraryWriter: StubPhotoLibraryWriter())
        let again = await handOff.attach(to: hike, store: sandbox.store, libraryWriter: StubPhotoLibraryWriter())

        #expect(missed == nil)
        #expect(again == nil)
        let copy = try #require(hike.photos.first)
        #expect(hike.photos.count == 1)
        #expect(copy.importedAuthorName == "Hiker 0")
        #expect(copy.license?.name == "CC BY-SA 4.0")
        #expect(copy.matchEvidence == .place)
        #expect(!copy.isOwn, "somebody else's photograph is never offered for publishing")
    }
}
