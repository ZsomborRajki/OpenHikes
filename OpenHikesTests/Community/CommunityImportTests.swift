//
//  CommunityImportTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing
#if canImport(UIKit)
import UIKit
#endif

/// The failure a `ModelContext` cannot be made to produce on demand — a fetch
/// against a schema it does not know returns an empty result rather than an
/// error — which is why the has-it-already read is a closure.
private struct LibraryReadFailure: Error {}

/// Turning somebody else's published hike into one of this hiker's own.
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
            photoFileURLs: photoURLs,
            photosOnRecord: photoURLs.count
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

    /// The hike that appears in the library is the one the hiker was just
    /// looking at, colour included.
    ///
    /// A file import picks at random, because nothing has been on screen to
    /// disagree with. This one has: the listing was a coloured row, a pin, a
    /// line across the map and the graph on the screen the hiker pressed the
    /// button on. Landing it as the green ``Hike`` defaults to is the version
    /// of this that shipped, and it made every saved trail identical in the
    /// list they were saved into.
    @Test("an imported hike keeps the colour its listing was drawn in")
    func importKeepsTheListingColour() async throws {
        let context = try Fixture.modelContext()
        let listing = CommunityListing.stub()
        let outcome = await CommunityImport.importHike(Self.detail(listing: listing), into: context)

        let hike = try #require(outcome.hike)
        #expect(hike.tintHex == listing.tintHex)
        #expect(hike.tintHex != Hike.defaultTintHex, "the default green is what this test exists to rule out")
    }

    /// The listing's figures are typed by a reviewer in the CloudKit Console;
    /// the route is what was actually uploaded and is what draws the line on
    /// the map. A hike whose stated length disagreed with its own polyline
    /// would be wrong in the one place the hiker can see it.
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

    /// Two hikers can publish the same ridge under the same name, so identity
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

    /// The photographs arrive as files and become the hiker's own copies,
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

    /// And they are stamped with whose they are, which is the one thing that
    /// keeps them out of a contribution back to the same trail: this saved
    /// hike is exactly the one the *Add Photos* form opens on. See
    /// `CommunityImportedPhotoGuardTests`.
    @Test("downloaded photos are marked as the listing author's, not the hiker's")
    func photosCarryTheListingTheyCameFrom() async throws {
        let context = try Fixture.modelContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("photo-0.jpeg", isDirectory: false)
        try Self.sampleJPEG().write(to: url)

        let outcome = await CommunityImport.importHike(
            Self.detail(
                pins: [CommunityPhotoPin(capturedAt: .now, coordinate: nil)],
                photoURLs: [url]
            ),
            into: context,
            libraryWriter: StubPhotoLibraryWriter()
        )

        let hike = try #require(outcome.hike)
        let photo = try #require(hike.photos.first)
        #expect(photo.importedFromListingID == hike.importedFromListingID)
        #expect(!photo.isOwn)
        #expect(CommunityPublisher.ownPhotos(of: hike).isEmpty)
    }

    /// Somebody else's photographs must never be filed into the hiker's own
    /// photo library — the opt-in is for pictures they took.
    @Test("imported photos never reach the hiker's photo library")
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

    /// The pins and the files describe each other by index, and `zip` pairs
    /// them by index whether or not they still agree about how many there are.
    ///
    /// A detail whose two arrays disagree is one a reviewer edited by hand, or
    /// a transport this app did not write. Attaching it anyway would put a
    /// photograph at another photograph's coordinate — saved, ordinary-looking
    /// and wrong for good, since nothing downstream can tell.
    @Test("photos whose pins no longer match them are not attached")
    func mismatchedPinsCostThePhotos() async throws {
        let context = try Fixture.modelContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("photo-0.jpeg", isDirectory: false)
        let second = directory.appendingPathComponent("photo-1.jpeg", isDirectory: false)
        try Self.sampleJPEG().write(to: first)
        try Self.sampleJPEG().write(to: second)

        // One pin for two files: `zip` would silently hand the first file the
        // first pin and drop the second file altogether.
        let outcome = await CommunityImport.importHike(
            Self.detail(
                pins: [CommunityPhotoPin(capturedAt: .now, coordinate: nil)],
                photoURLs: [first, second]
            ),
            into: context,
            libraryWriter: StubPhotoLibraryWriter()
        )

        let hike = try #require(outcome.hike)
        #expect(hike.photos.isEmpty, "a pairing that cannot be trusted must cost the photographs")
    }

    /// A library that cannot be asked whether it already has this listing is
    /// not a library saying no. Read as *not imported* — which is what a
    /// `try?` did — the insert goes ahead and one listing ends up with two
    /// rows claiming it: duplicate entries, and a Saved badge and an
    /// open-destination that disagree from then on. A store under stress is
    /// exactly when that costs most.
    @Test("a fetch that fails refuses the import rather than inserting a second copy")
    func unreadableLibraryRefusesTheImport() async throws {
        let context = try Fixture.modelContext()

        let outcome = await CommunityImport.importHike(
            Self.detail(),
            into: context,
            alreadyImported: { _, _ in throw LibraryReadFailure() }
        )

        guard case .refused(.unavailable) = outcome else {
            Issue.record("an unreadable library must refuse rather than import")
            return
        }
        let hikes = try context.fetch(FetchDescriptor<Hike>())
        #expect(hikes.isEmpty, "nothing may be inserted on the strength of a question nobody answered")
    }

    /// And it costs the photographs rather than the walk. The route committed
    /// before the pictures began copying and is the thing the hiker asked for,
    /// so a refusal here would be the wrong size of answer.
    @Test("a mismatched pairing still keeps the hike")
    func mismatchedPinsKeepTheWalk() async throws {
        let context = try Fixture.modelContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("photo-0.jpeg", isDirectory: false)
        try Self.sampleJPEG().write(to: url)

        let outcome = await CommunityImport.importHike(
            Self.detail(pins: [], photoURLs: [url]),
            into: context,
            libraryWriter: StubPhotoLibraryWriter()
        )

        // `hike` is `nil` only for a refusal, so requiring it is the assertion
        // that the walk survived.
        let hike = try #require(outcome.hike, "a mismatched pairing must not refuse the walk")
        #expect(hike.route.count == Fixture.ridgeRoute.count)
        #expect(hike.photos.isEmpty)
    }
}
