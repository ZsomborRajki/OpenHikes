//
//  CommunityImportCommonsTests.swift
//  OpenHikesTests
//
//  What a saved curated route holds of the Wikimedia Commons photographs its
//  preview showed — and what it will never offer to send anywhere.
//
//  ## The rule these were written for
//
//  A hiker opens an OpenStreetMap trail, sees Commons photographs pinned along
//  it, saves it, walks it, adds pictures of their own, and offers those to the
//  trail. The form must offer *their* pictures and none of the Commons ones:
//  those are somebody else's work, which the licence lets this hiker keep and
//  look at — credited — and not publish under their name. The listing stamp
//  keeps them out the way it keeps a stranger's community photographs out, and
//  ``HikePhoto/licence`` keeps them out on its own.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community import of Commons photos")
struct CommunityImportCommonsTests {
    private static let takenOn = Date(timeIntervalSince1970: 1_600_000_000)

    /// The import refused a trail every case here expects it to keep.
    private struct NotImported: Error {}

    /// A directory of real image files, removed when the test leaves — the
    /// import detects the format from the bytes, so filler would not get in.
    private final class Staging {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityImportCommonsTests-\(UUID().uuidString)", isDirectory: true)

        init() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func file(_ name: String, written: Bool = true) -> URL {
            let url = directory.appendingPathComponent("\(name).jpeg", isDirectory: false)
            if written { try? PhotoDiscoveryFixture.sampleImageData().write(to: url) }
            return url
        }
    }

    private static func licence(_ name: String) -> HikePhotoLicence? {
        URL(string: "https://commons.wikimedia.org/wiki/File:\(name).jpg").map { source in
            HikePhotoLicence(
                name: "CC BY-SA 4.0",
                url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"),
                sourceURL: source
            )
        }
    }

    private static func photo(_ url: URL, author: String?, step: Int) throws -> CommonsPhoto {
        let point = Fixture.ridgeRoute[step]
        return CommonsPhoto(
            pin: CommunityPhotoPin(capturedAt: takenOn, coordinate: point.clCoordinate),
            fileURL: url,
            credit: CommonsPhotoCredit(
                author: author,
                licence: try #require(licence(url.deletingPathExtension().lastPathComponent))
            )
        )
    }

    private static func curatedListing() -> CommunityListing {
        CommunityListing(
            id: CommunityIdentity.curated(relationID: 4242),
            origin: .openStreetMap(
                relationID: 4242,
                facts: CuratedTrailFacts(tags: ["name": "Soleleitensteig"], route: [])
            ),
            title: "Soleleitensteig",
            authorName: "",
            hikeDate: nil,
            distanceMeters: 1100,
            photoCount: 0,
            latitude: 37.33,
            longitude: -122.03,
            publishedAt: takenOn
        )
    }

    private static func detail(_ commons: [CommonsPhoto]) -> CommunityHikeDetail {
        var detail = CommunityHikeDetail(
            listing: curatedListing(),
            route: Fixture.ridgeRoute,
            trackDescription: nil,
            photoPins: [],
            photoFileURLs: [],
            photosOnRecord: 0
        )
        detail.commonsPhotos = commons
        return detail
    }

    private func imported(
        _ detail: CommunityHikeDetail,
        in sandbox: PhotoStoreSandbox
    ) async throws -> (Hike, CommunityPhotoCopy) {
        let outcome = await CommunityImport.importHike(
            detail,
            into: try Fixture.modelContext(),
            store: sandbox.store,
            libraryWriter: StubPhotoLibraryWriter()
        )
        guard case let .imported(hike, photos) = outcome else { throw NotImported() }
        return (hike, photos)
    }

    // MARK: - What the saved hike holds

    @Test("a saved curated route holds the Commons photographs its preview showed, credited")
    func commonsPhotographsAreSavedWithTheirCredit() async throws {
        let staging = Staging()
        let (hike, copy) = try await imported(
            Self.detail([
                try Self.photo(staging.file("summit"), author: "Anna", step: 2),
                try Self.photo(staging.file("lake"), author: nil, step: 4),
            ]),
            in: PhotoStoreSandbox()
        )

        #expect(copy.isComplete)
        #expect(hike.photos.count == 2)
        let sources = Set(hike.photos.compactMap(\.licence?.sourceURL.lastPathComponent))
        #expect(sources == ["File:summit.jpg", "File:lake.jpg"])
        #expect(hike.photos.compactMap(\.importedAuthorName) == ["Anna"], "a file page naming nobody names nobody")
        #expect(hike.photos.allSatisfy { $0.matchEvidence == .place }, "pinned by the camera's own position")
    }

    @Test("each copy stands where its pin stood, on the route")
    func copiesKeepTheirPins() async throws {
        let staging = Staging()
        let (hike, _) = try await imported(
            Self.detail([try Self.photo(staging.file("summit"), author: "Anna", step: 3)]),
            in: PhotoStoreSandbox()
        )

        let coordinate = try #require(hike.photos.first?.coordinate)
        #expect(coordinate.latitude == Fixture.ridgeRoute[3].latitude)
        #expect(coordinate.longitude == Fixture.ridgeRoute[3].longitude)
    }

    // MARK: - What it will never send

    /// The user's rule, end to end: Commons copies in, the hiker's own picture
    /// added afterwards, and the publishing gate offering exactly the second.
    @Test("only the photographs the hiker adds afterwards are offered for publishing")
    func onlyOwnPhotographsArePublishable() async throws {
        let staging = Staging()
        let (hike, _) = try await imported(
            Self.detail([try Self.photo(staging.file("summit"), author: "Anna", step: 2)]),
            in: PhotoStoreSandbox()
        )
        let own = HikePhoto(capturedAt: Self.takenOn, coordinate: Fixture.ridgeRoute[5].clCoordinate)
        hike.addPhoto(own)

        #expect(hike.photos.count == 2)
        #expect(CommunityPublisher.ownPhotos(of: hike).map(\.id) == [own.id])
        #expect(CommunityPublisher.shareablePhotos(of: hike).map(\.id) == [own.id])
    }

    /// The licence keeps a copy out on its own, whatever the listing stamp
    /// says — so a Commons photograph that ever reaches a hike some other way
    /// is still not the hiker's to send.
    @Test("a photograph under somebody else's licence is never the hiker's own")
    func licenceAloneKeepsItOut() throws {
        let licence = try #require(Self.licence("anywhere"))
        #expect(!HikePhoto(licence: licence).isOwn)
    }

    // MARK: - What a failed copy offers

    @Test("a Commons photograph that did not copy is offered again, and lands on the retry")
    func failedCopyIsRetried() async throws {
        let staging = Staging()
        let missing = staging.file("lake", written: false)
        let detail = Self.detail([
            try Self.photo(staging.file("summit"), author: "Anna", step: 2),
            try Self.photo(missing, author: "Bence", step: 4),
        ])
        let sandbox = PhotoStoreSandbox()
        let (hike, first) = try await imported(detail, in: sandbox)
        #expect(first.failed.count == 1)

        try PhotoDiscoveryFixture.sampleImageData().write(to: missing)
        let retried = await CommunityImport.copyPhotos(
            of: detail,
            onto: hike,
            after: first,
            store: sandbox.store,
            libraryWriter: StubPhotoLibraryWriter()
        )

        #expect(retried.isComplete)
        #expect(hike.photos.count == 2, "the one that landed the first time is not copied twice")
    }
}
