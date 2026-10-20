//
//  CommonsPhotoStoreTests.swift
//  OpenHikesTests
//
//  What ``CommonsPhotoStore`` keeps of a Commons answer, and for how long.
//  The directory's behaviour — the trim, the re-stamp on use — is
//  ``OverpassFileStore``'s and is covered by the curated and place stores'
//  suites. What is this store's own is the file format: a page with its
//  details, a page with none, and the camera's position the fallback finds it
//  by. A directory and a clock per case, as every cache suite here has.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@Suite("Commons photo store")
struct CommonsPhotoStoreTests {
    private static let center = CLLocationCoordinate2D(latitude: 47.6, longitude: 13.0)
    private static let metersPerDegreeLatitude: Double = 111_320
    private static let day: TimeInterval = 24 * 60 * 60

    /// A clock the case moves by hand.
    nonisolated private final class Clock: Sendable {
        private let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

        var read: @Sendable () -> Date { { [self] in now.withLock { $0 } } }

        func advance(by seconds: TimeInterval) {
            now.withLock { $0 += seconds }
        }
    }

    private final class Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommonsPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private static func page(_ id: Int, metersNorth: Double, shown: Bool = true) throws -> CommonsPage {
        let candidate = CommonsPhotoCandidate(
            pageID: id,
            latitude: center.latitude + metersNorth / metersPerDegreeLatitude,
            longitude: center.longitude
        )
        let source = try #require(URL(string: "https://commons.wikimedia.org/wiki/File:\(id).jpg"))
        let thumbnail = try #require(URL(string: "https://upload.wikimedia.org/thumb/\(id).jpg"))
        let file = CommonsFile(
            pageID: id,
            thumbnailURL: thumbnail,
            credit: CommonsPhotoCredit(
                author: "Hiker \(id)",
                license: HikePhotoLicense(name: "CC BY 4.0", url: nil, sourceURL: source)
            ),
            capturedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        return CommonsPage(candidate, file: shown ? file : nil)
    }

    @Test("a page comes back with its details, and one this app may not show without")
    func pagesRoundTrip() throws {
        let scratch = Scratch()
        let store = CommonsPhotoStore(directory: scratch.directory)
        let shown = try Self.page(1, metersNorth: 0)
        let refused = try Self.page(2, metersNorth: 0, shown: false)

        store.save([shown, refused])

        #expect(store.page(1) == shown)
        #expect(store.page(2) == refused)
        #expect(store.page(3) == nil, "a page never asked about is not answered")
    }

    @Test("a page is trusted for thirty days")
    func pagesExpire() throws {
        let scratch = Scratch()
        let clock = Clock()
        let store = CommonsPhotoStore(directory: scratch.directory, clock: clock.read)
        store.save([try Self.page(1, metersNorth: 0)])

        clock.advance(by: 29 * Self.day)
        #expect(store.page(1) != nil)
        // The read above re-stamped the file for the trim, not its age: the
        // thirty days are counted from when Commons was asked.
        clock.advance(by: 2 * Self.day)
        #expect(store.page(1) == nil)
    }

    @Test("the fallback finds pages by where the camera stood, nearest first")
    func pagesNearAnArea() throws {
        let scratch = Scratch()
        let store = CommonsPhotoStore(directory: scratch.directory)
        store.save([
            try Self.page(1, metersNorth: 800),
            try Self.page(2, metersNorth: 100),
            try Self.page(3, metersNorth: 5000),
        ])

        let near = store.pages(near: CommunitySearchArea(coordinate: Self.center, radiusMeters: 1000), limit: 10)

        #expect(near.map(\.pageID) == [2, 1])
    }

    /// The credit is written down here and inside published community
    /// payloads that older builds read, both under `licence` — the key it
    /// had before the property was spelled `license` (#847).
    @Test("a credit keeps the key its licence was first written under")
    func creditKeyIsUnchanged() throws {
        let written = try #require(try Self.page(1, metersNorth: 0).file?.credit)
        let keys = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(written)) as? [String: Any]
        ).keys

        let saved = Data(#"{"author":"Anna","licence":{"name":"CC0","sourceURL":"https://commons.wikimedia.org/"}}"#.utf8)
        let decoded = try JSONDecoder().decode(CommonsPhotoCredit.self, from: saved)

        #expect(Set(keys) == ["author", "licence"])
        #expect(decoded.license.name == "CC0")
    }
}
