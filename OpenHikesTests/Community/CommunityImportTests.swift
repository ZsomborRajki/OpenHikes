//
//  CommunityImportTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing
#if canImport(UIKit)
import UIKit
#endif

/// Turning somebody else's published hike into one of this walker's own.
@MainActor
@Suite("Community import")
struct CommunityImportTests {
    nonisolated private static let sampleSide = 32
    nonisolated private static let sampleQuality = 0.8

    /// A real JPEG, because the import path detects the format from the bytes
    /// themselves — see ``ImageDataFormat/detect(in:)``, which refuses
    /// anything that is not a decodable image.
    nonisolated private static func sampleJPEG() -> Data {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: sampleSide, height: sampleSide)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: sampleQuality) ?? Data()
        #else
        return Data()
        #endif
    }

    private static func detail(
        listing: CommunityListing = .stub(),
        route: [RouteCoordinate] = Fixture.ridgeRoute,
        pins: [CommunityPhotoPin] = [],
        photoURLs: [URL] = []
    ) -> CommunityHikeDetail {
        CommunityHikeDetail(
            listing: listing,
            route: route,
            trackDescription: "A ridge walk",
            photoPins: pins,
            photoFileURLs: photoURLs
        )
    }

    @Test("an imported hike keeps the route and credits whoever walked it")
    func importCreatesHike() async throws {
        let context = try Fixture.modelContext()
        let outcome = await CommunityImport.importHike(Self.detail(), into: context)

        let hike = try #require(outcome.hike)
        #expect(hike.title == "Pilis Ridge")
        #expect(hike.route.count == Fixture.ridgeRoute.count)
        #expect(hike.importedFromListingID == "listing-1")
        #expect(hike.importedAuthorName == "Anna")
        #expect(hike.trackDescription == "A ridge walk")
    }

    /// The listing's figures are typed by a reviewer in the CloudKit Console;
    /// the route is what was actually uploaded and is what draws the line on
    /// the map. A hike whose stated length disagreed with its own polyline
    /// would be wrong in the one place the walker can see it.
    @Test("the distance is recomputed from the route, not copied")
    func distanceComesFromTheRoute() async throws {
        let context = try Fixture.modelContext()
        // A listing claiming a wildly different length from its own route.
        let listing = CommunityListing.stub(distanceMeters: 999_999)
        let outcome = await CommunityImport.importHike(
            Self.detail(listing: listing),
            into: context
        )

        let hike = try #require(outcome.hike)
        #expect(hike.distanceMeters != listing.distanceMeters)
        #expect(
            abs(hike.distanceMeters - CommunityImport.routeLength(of: Fixture.ridgeRoute)) < 0.001
        )
    }

    /// Two walkers can publish the same ridge under the same name, so identity
    /// is the listing rather than the title.
    @Test("importing the same listing twice returns the first hike")
    func importIsIdempotent() async throws {
        let context = try Fixture.modelContext()
        let first = await CommunityImport.importHike(Self.detail(), into: context)
        let second = await CommunityImport.importHike(Self.detail(), into: context)

        guard case .imported(let original) = first,
              case .alreadyImported(let existing) = second else {
            Issue.record("the second import should report the hike already in the library")
            return
        }
        #expect(original.id == existing.id)
        let all = try context.fetch(FetchDescriptor<Hike>())
        #expect(all.count == 1)
    }

    @Test("a hike with no usable route is refused")
    func routelessImportIsRefused() async throws {
        let context = try Fixture.modelContext()
        let outcome = await CommunityImport.importHike(
            Self.detail(route: []),
            into: context
        )

        #expect(outcome.hike == nil)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// An insert the store refuses must leave nothing behind, the same promise
    /// ``HikeImport`` makes.
    @Test("a refused commit leaves no hike in the store")
    func refusedCommitLeavesNothing() async throws {
        let context = try Fixture.modelContext()
        let outcome = await CommunityImport.importHike(
            Self.detail(),
            into: context,
            save: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        #expect(outcome.hike == nil)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// The photographs arrive as files and become the walker's own copies,
    /// pinned where the publisher pinned them.
    @Test("downloaded photos are attached at the coordinates they were pinned to")
    func photosAreAttachedWithTheirPins() async throws {
        let context = try Fixture.modelContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("photo-0.jpeg", isDirectory: false)
        try Self.sampleJPEG().write(to: url)

        let pinned = CLLocationCoordinate2D(latitude: 47.6305, longitude: 12.8605)
        let outcome = await CommunityImport.importHike(
            Self.detail(
                pins: [CommunityPhotoPin(capturedAt: .now, coordinate: pinned)],
                photoURLs: [url]
            ),
            into: context,
            libraryWriter: StubPhotoLibraryWriter()
        )

        let hike = try #require(outcome.hike)
        let photo = try #require(hike.photos.first)
        #expect(hike.photos.count == 1)
        #expect(photo.coordinate?.latitude == pinned.latitude)
        #expect(photo.coordinate?.longitude == pinned.longitude)
    }

    /// Somebody else's photographs must never be filed into the walker's own
    /// photo library — the opt-in is for pictures they took.
    @Test("imported photos never reach the walker's photo library")
    func importedPhotosSkipTheLibrary() async throws {
        let context = try Fixture.modelContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("photo-0.jpeg", isDirectory: false)
        try Self.sampleJPEG().write(to: url)

        let writer = StubPhotoLibraryWriter()
        _ = await CommunityImport.importHike(
            Self.detail(
                pins: [CommunityPhotoPin(capturedAt: .now, coordinate: nil)],
                photoURLs: [url]
            ),
            into: context,
            libraryWriter: writer
        )

        #expect(writer.saves.isEmpty)
    }
}
