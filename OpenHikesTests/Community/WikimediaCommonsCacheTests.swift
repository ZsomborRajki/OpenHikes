//
//  WikimediaCommonsCacheTests.swift
//  OpenHikesTests
//
//  What ``WikimediaCommonsSource`` does with a ``CommonsPhotoStore``: the file
//  details it already holds are not asked for again, and a geosearch that
//  cannot be asked falls back to the files this device found there before.
//  The thumbnails are downloaded every time either way, and once more for a
//  screen whose copy was deleted under it. Driven through
//  ``WikimediaCommonsSource/Transport``, as the other Commons suites are.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@Suite("Wikimedia Commons file cache")
struct WikimediaCommonsCacheTests {
    nonisolated private enum Answers {
        static let middle = (latitude: 47.6, longitude: 13.0)
        static let cameras = [
            (id: 1, latitude: 47.602, longitude: 13.001),
            (id: 2, latitude: 47.598, longitude: 13.003),
            (id: 3, latitude: 47.601, longitude: 12.996),
        ]

        static let geosearch: Data = {
            let hits = cameras.map { camera in
                """
                {"pageid":\(camera.id),"ns":6,"title":"File:\(camera.id).jpg",\
                "lat":\(camera.latitude),"lon":\(camera.longitude),"dist":1,"primary":true}
                """
            }
            return Data(#"{"batchcomplete":true,"query":{"geosearch":[\#(hits.joined(separator: ","))]}}"#.utf8)
        }()

        /// Details for the first two only: the third is a file this app may
        /// not show, which Commons answers by leaving it out.
        static let imageInfo: Data = {
            let pages = cameras.prefix(2).map { camera in
                """
                {"pageid":\(camera.id),"ns":6,"title":"File:\(camera.id).jpg","imageinfo":[{\
                "timestamp":"2020-06-0\(camera.id)T10:00:00Z","width":3000,"mime":"image/jpeg",\
                "thumburl":"https://upload.wikimedia.org/thumb/\(camera.id)/960px-\(camera.id).jpg",\
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:\(camera.id).jpg",\
                "extmetadata":{"Artist":{"value":"Hiker \(camera.id)"},"LicenseShortName":{"value":"CC BY 4.0"}}}]}
                """
            }
            return Data(#"{"batchcomplete":true,"query":{"pages":[\#(pages.joined(separator: ","))]}}"#.utf8)
        }()
    }

    /// Commons, answering from memory, writing down what it was asked, and
    /// refusing whichever question it is told to.
    nonisolated private final class StubCommons: Sendable {
        private let asked = Mutex<[URL]>([])
        private let refusing = Mutex<Set<String>>([])

        var requests: [URL] { asked.withLock { $0 } }

        func count(_ marker: String) -> Int {
            requests.filter { $0.absoluteString.contains(marker) }.count
        }

        func refuse(_ marker: String) {
            refusing.withLock { _ = $0.insert(marker) }
        }

        var transport: WikimediaCommonsSource.Transport {
            { [self] request in
                let url = request.url ?? URL(filePath: "/")
                asked.withLock { $0.append(url) }
                let text = url.absoluteString
                if refusing.withLock({ $0.contains { text.contains($0) } }) { return (Data(), 503) }
                if text.contains("list=geosearch") { return (Answers.geosearch, 200) }
                if text.contains("prop=imageinfo") { return (Answers.imageInfo, 200) }
                return (PhotoDiscoveryFixture.sampleImageData(), 200)
            }
        }
    }

    private final class Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikimediaCommonsCacheTests-\(UUID().uuidString)", isDirectory: true)

        var store: CommonsPhotoStore { CommonsPhotoStore(directory: root.appending(path: "store")) }

        func downloads() -> URL { root.appending(path: UUID().uuidString) }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let geosearch = "list=geosearch"
    private static let imageInfo = "prop=imageinfo"
    private static let thumbnails = "/thumb/"

    private static let area = CommunitySearchArea(
        coordinate: CLLocationCoordinate2D(latitude: Answers.middle.latitude, longitude: Answers.middle.longitude),
        radiusMeters: 1500
    )

    private static func source(_ commons: StubCommons, _ scratch: Scratch) -> WikimediaCommonsSource {
        WikimediaCommonsSource(transport: commons.transport, pause: { _ in /* never busy */ }, store: scratch.store)
    }

    @Test("a second search over the same area asks for no file details")
    func knownFilesAreNotAskedAbout() async throws {
        let commons = StubCommons()
        let scratch = Scratch()
        let source = Self.source(commons, scratch)

        let first = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())
        let second = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())

        #expect(first.count == 2)
        #expect(Set(second.map(\.credit)) == Set(first.map(\.credit)), "the same two, from what was kept")
        #expect(commons.count(Self.imageInfo) == 1, "the details were asked for once")
        #expect(commons.count(Self.geosearch) == 2, "where the cameras stood is asked every time")
        #expect(commons.count(Self.thumbnails) == 4, "and the pictures are never kept")
    }

    /// The third file is not one this app may show, and that answer is kept
    /// too — otherwise every search would ask about it again.
    @Test("a file this app may not show is not asked about again either")
    func refusedFilesAreRemembered() async throws {
        let commons = StubCommons()
        let scratch = Scratch()
        let source = Self.source(commons, scratch)

        _ = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())

        let kept = try #require(scratch.store.page(3))
        #expect(kept.file == nil)
        #expect(kept.latitude == Answers.cameras[2].latitude)
    }

    @Test("a geosearch that fails falls back to the files found there before")
    func failedGeosearchUsesWhatWasFound() async throws {
        let commons = StubCommons()
        let scratch = Scratch()
        let source = Self.source(commons, scratch)
        let first = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())

        commons.refuse(Self.geosearch)
        let second = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())

        #expect(Set(second.map(\.credit)) == Set(first.map(\.credit)))
        #expect(commons.count(Self.imageInfo) == 1)
    }

    @Test("with nothing kept, a geosearch that fails finds nothing")
    func failedGeosearchWithNothingKept() async throws {
        let commons = StubCommons()
        let scratch = Scratch()
        commons.refuse(Self.geosearch)

        let photos = try await Self.source(commons, scratch)
            .photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())

        #expect(photos.isEmpty)
        #expect(commons.count(Self.imageInfo) == 0)
    }

    @Test("a photograph's thumbnail is fetched again from where it came, and nothing else is asked")
    func downloadAgain() async throws {
        let commons = StubCommons()
        let scratch = Scratch()
        let source = Self.source(commons, scratch)
        let found = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())
        let first = try #require(found.first)
        #expect(first.thumbnailURL?.absoluteString.contains(Self.thumbnails) == true)

        let again = try #require(try await source.download(first, into: scratch.downloads()))

        #expect(again.fileURL != first.fileURL)
        #expect(again.credit == first.credit)
        #expect(again.pin == first.pin)
        #expect(FileManager.default.fileExists(atPath: again.fileURL.path))
        #expect(commons.count(Self.thumbnails) == found.count + 1)
        #expect(commons.count(Self.geosearch) == 1)
        #expect(commons.count(Self.imageInfo) == 1)
    }

    @Test("a photograph with nowhere to fetch from is not fetched again")
    func noThumbnailNoDownload() async throws {
        let commons = StubCommons()
        let scratch = Scratch()
        let source = Self.source(commons, scratch)
        let found = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())
        var first = try #require(found.first)
        first.thumbnailURL = nil

        #expect(try await source.download(first, into: scratch.downloads()) == nil)
        #expect(commons.count(Self.thumbnails) == found.count)
    }

    @Test("without a store, every search asks for the details again")
    func noStoreKeepsNothing() async throws {
        let commons = StubCommons()
        let scratch = Scratch()
        let source = WikimediaCommonsSource(transport: commons.transport, pause: { _ in /* never busy */ })

        _ = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())
        _ = try await source.photos(in: Self.area, avoiding: [], downloadingInto: scratch.downloads())

        #expect(commons.count(Self.imageInfo) == 2)
    }
}
