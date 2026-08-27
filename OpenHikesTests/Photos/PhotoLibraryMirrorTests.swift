//
//  PhotoLibraryMirrorTests.swift
//  OpenHikesTests
//
//  The opt-in second copy: what ``HikePhotoImport`` hands the photo library
//  when a user has asked for their hike photos to land there too.
//
//  Driven through ``PhotoLibraryWriting`` rather than through PhotoKit, for
//  the same reasons the read side is stubbed: an add-only authorization prompt
//  cannot be answered from a test, and a suite has no business writing assets
//  into whatever library the machine running it happens to have.
//
//  What is being pinned is a promise rather than a mechanism. The setting says
//  "this photo, in my library"; a copy that arrives with no date and no place
//  sorts into Recents under the moment it was filed and appears nowhere in
//  Places, on a picture the app could say both of. The app knows when the
//  shutter fired and which point of the trail the walker was standing on —
//  both of those have to leave with the bytes.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Photo library mirror")
struct PhotoLibraryMirrorTests {
    private static let latitude: Double = 47.6300
    private static let longitude: Double = 12.8600
    /// Fixed and firmly in the past, so "the moment it was taken" is
    /// distinguishable from "the moment it was filed" — which is the whole
    /// difference being tested, and which a `.now` fixture would hide.
    private static let capturedAt = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("a mirrored photo carries the moment it was taken")
    func mirrorCarriesTheCaptureDate() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let data = PhotoDiscoveryFixture.sampleImageData()

        _ = await HikePhotoImport.add(
            data,
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: true,
            capturedAt: Self.capturedAt,
            store: sandbox.store,
            libraryWriter: writer
        )

        let saved = try #require(writer.saves.last)
        #expect(saved.byteCount == data.count, "the picture itself still goes over")
        #expect(saved.capturedAt == Self.capturedAt)
        #expect(
            saved.capturedAt != saved.filedAt,
            "a copy dated when it was filed is the bug this pins"
        )
    }

    @Test("a mirrored photo carries the point of the trail it was taken on")
    func mirrorCarriesTheCoordinate() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let coordinate = CLLocationCoordinate2D(
            latitude: Self.latitude,
            longitude: Self.longitude
        )

        _ = await HikePhotoImport.add(
            PhotoDiscoveryFixture.sampleImageData(),
            to: hike,
            coordinate: coordinate,
            savesToPhotoLibrary: true,
            capturedAt: Self.capturedAt,
            store: sandbox.store,
            libraryWriter: writer
        )

        let saved = try #require(writer.saves.last)
        #expect(saved.latitude == Self.latitude)
        #expect(saved.longitude == Self.longitude)
    }

    /// A photograph the app genuinely cannot place — location refused, or a
    /// hike with no route point to stand on. Writing a coordinate here would
    /// mean inventing one, and a pin on a map reads as a fact.
    @Test("a photo the app cannot place is dated but not placed")
    func mirrorOmitsAnAbsentCoordinate() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        _ = await HikePhotoImport.add(
            PhotoDiscoveryFixture.sampleImageData(),
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: true,
            capturedAt: Self.capturedAt,
            store: sandbox.store,
            libraryWriter: writer
        )

        let saved = try #require(writer.saves.last)
        #expect(saved.latitude == nil)
        #expect(saved.longitude == nil)
        #expect(saved.capturedAt == Self.capturedAt)
    }

    /// The setting is off by default and is the only thing that puts a copy in
    /// somebody's library. A mirror that happened anyway would be the app
    /// writing to the photo library uninvited.
    @Test("nothing is mirrored unless the setting asked for it")
    func mirrorIsSkippedWhenNotOptedIn() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let photo = await HikePhotoImport.add(
            PhotoDiscoveryFixture.sampleImageData(),
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: false,
            capturedAt: Self.capturedAt,
            store: sandbox.store,
            libraryWriter: writer
        )

        #expect(photo != nil, "the app's own copy is written either way")
        #expect(writer.saves.isEmpty)
    }

    /// The ordering ``HikePhotoImport`` exists to guarantee, seen from the
    /// mirror's side: bytes that are not an image never reach the library,
    /// because the app's own copy is what everything downstream hangs off.
    @Test("bytes that are not an image are never mirrored")
    func mirrorIsSkippedForNonImageBytes() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let photo = await HikePhotoImport.add(
            Data("not a picture".utf8),
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: true,
            capturedAt: Self.capturedAt,
            store: sandbox.store,
            libraryWriter: writer
        )

        #expect(photo == nil)
        #expect(writer.saves.isEmpty)
    }

    /// The library copy and the app's copy have to be the same photograph
    /// making the same claims. ``HikePhoto`` is what the gallery and the map
    /// read, so it is what the mirror agrees with — not the arguments that
    /// happened to be passed alongside it.
    @Test("the mirrored copy says what the stored photo says")
    func mirrorAgreesWithTheStoredPhoto() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let coordinate = CLLocationCoordinate2D(
            latitude: Self.latitude,
            longitude: Self.longitude
        )

        let photo = try #require(
            await HikePhotoImport.add(
                PhotoDiscoveryFixture.sampleImageData(),
                to: hike,
                coordinate: coordinate,
                savesToPhotoLibrary: true,
                capturedAt: Self.capturedAt,
                store: sandbox.store,
                libraryWriter: writer
            )
        )

        let saved = try #require(writer.saves.last)
        #expect(saved.capturedAt == photo.capturedAt)
        #expect(saved.latitude == photo.coordinate?.latitude)
        #expect(saved.longitude == photo.coordinate?.longitude)
        #expect(
            saved.fileExtension == photo.pathExtension,
            "the resource is named for the format the bytes really are"
        )
    }
}

/// A photo library that records what it was asked to file, and files nothing.
///
/// The coordinate is unpacked into two optional `Double`s rather than kept as
/// a `CLLocationCoordinate2D?`: the type is not `Equatable`, and a comparison
/// hand-written at every assertion is one that eventually gets written wrong.
nonisolated final class StubPhotoLibraryWriter: PhotoLibraryWriting {
    struct Save: Sendable {
        let fileExtension: String
        let capturedAt: Date
        let latitude: Double?
        let longitude: Double?
        let byteCount: Int
        /// When the library was actually asked — which is what a copy carrying
        /// no creation date ends up dated by.
        let filedAt: Date
    }

    /// Exposed as a plain array rather than as the `Mutex` itself: the testing
    /// macros capture each sub-expression of a condition, and a non-copyable
    /// value cannot be captured — so `#require(writer.lock.withLock(...))`
    /// does not compile at all.
    var saves: [Save] { recorded.withLock { $0 } }

    private let recorded = Mutex<[Save]>([])

    // Async because the protocol is, not because this body suspends: the real
    // writer awaits an authorization prompt and a change request, this one
    // appends to an array.
    // swiftlint:disable async_without_await
    @discardableResult func save(
        _ data: Data,
        fileExtension: String,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) async -> Bool {
        // swiftlint:enable async_without_await
        recorded.withLock { saves in
            saves.append(
                Save(
                    fileExtension: fileExtension,
                    capturedAt: capturedAt,
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude,
                    byteCount: data.count,
                    filedAt: .now
                )
            )
        }
        return true
    }
}
