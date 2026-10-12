//
//  MergedCommunityCommonsTests.swift
//  OpenHikesTests
//
//  Who Wikimedia Commons is asked about: a curated route, along the route the
//  preview downloaded, and nothing else.
//
//  Routed on the listing's origin, like every per-listing method on the
//  merged transport — a published hike carries the photographs its author
//  took, and Commons is not asked about a stranger's walk on the strength of
//  where it went. And dormant unless the composition root says otherwise, so
//  no suite reaches Wikimedia by building a transport and forgetting a
//  parameter.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@Suite("Merged transport's Commons photos")
struct MergedCommunityCommonsTests {
    /// Commons, writing down which routes it was asked about and answering
    /// with one photograph each time.
    nonisolated private final class RecordingCommons: CommonsPhotoSourcing, @unchecked Sendable {
        private let asked = Mutex<[[RouteCoordinate]]>([])

        var routes: [[RouteCoordinate]] { asked.withLock { $0 } }

        @concurrent
        func photos(along route: [RouteCoordinate], downloadingInto directory: URL) async -> [CommonsPhoto] {
            asked.withLock { $0.append(route) }
            guard let source = URL(string: "https://commons.wikimedia.org/wiki/File:Recorded.jpg") else { return [] }
            return [
                CommonsPhoto(
                    pin: CommunityPhotoPin(capturedAt: .distantPast, coordinate: route.first?.clCoordinate),
                    fileURL: directory.appendingPathComponent("recorded.jpeg"),
                    credit: CommonsPhotoCredit(
                        author: nil,
                        licence: HikePhotoLicence(name: "CC0", url: nil, sourceURL: source)
                    )
                ),
            ]
        }
    }

    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MergedCommunityCommonsTests", isDirectory: true)

    private static let curated = CommunityListing(
        id: CommunityIdentity.curated(relationID: 77),
        origin: .openStreetMap(relationID: 77, facts: CuratedTrailFacts(tags: ["name": "Steig"], route: [])),
        title: "Steig",
        authorName: "",
        hikeDate: nil,
        distanceMeters: 1100,
        photoCount: 0,
        latitude: 37.33,
        longitude: -122.03,
        publishedAt: .distantPast
    )

    private static func merged(_ commons: RecordingCommons) -> MergedCommunityTransport {
        MergedCommunityTransport(
            published: StubCommunityTransport(),
            curated: StubCuratedTrailSource(),
            commons: commons
        )
    }

    @Test("a curated route asks Commons along the route the preview downloaded")
    func curatedRouteAsks() async throws {
        let commons = RecordingCommons()

        let photos = try await Self.merged(commons).commonsPhotos(
            for: Self.curated,
            along: Fixture.ridgeRoute,
            downloadingInto: Self.directory
        )

        #expect(photos.count == 1)
        #expect(commons.routes == [Fixture.ridgeRoute])
    }

    @Test("a published hike asks Commons nothing")
    func publishedHikeAsksNothing() async throws {
        let commons = RecordingCommons()

        let photos = try await Self.merged(commons).commonsPhotos(
            for: .stub(),
            along: Fixture.ridgeRoute,
            downloadingInto: Self.directory
        )

        #expect(photos.isEmpty)
        #expect(commons.routes.isEmpty)
    }

    @Test("a transport built without a source asks nobody")
    func dormantByDefault() async throws {
        let merged = MergedCommunityTransport(published: StubCommunityTransport(), curated: StubCuratedTrailSource())

        let photos = try await merged.commonsPhotos(
            for: Self.curated,
            along: Fixture.ridgeRoute,
            downloadingInto: Self.directory
        )

        #expect(photos.isEmpty)
        #expect(merged.commons is DormantCommonsPhotoSource)
    }
}
