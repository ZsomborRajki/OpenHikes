//
//  CommunityAssetDecodingTests.swift
//  OpenHikesTests
//
//  Reading the two attachments a published hike carries back off a record.
//
//  A submission arrives as a `CKRecord` with an asset of photographs and an
//  asset of pins describing them, and both are read by code that cannot ask
//  the sender what it meant. ``CommunityPhotoPairingTests`` pins what happens
//  once the two lists are in hand; these are the step before it, where a
//  record written by an older build, a reviewer editing by hand, or a cache
//  CloudKit has already swept turns into those lists in the first place.
//
//  The index is the thread running through all of it. `copyPhotos` returns
//  each surviving file beside the position of the asset it came from, because
//  that position is the only thing pairing a photograph with its pin — and a
//  list silently renumbered by a file that would not copy is the one failure
//  nothing downstream could ever notice.
//
//  No container and no public database: `CKRecord` and `CKAsset` are both
//  constructible against the local filesystem, which is the whole reason these
//  two helpers are reachable at all.
//

import CloudKit
import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community asset decoding")
struct CommunityAssetDecodingTests {
    private static let hikeDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// A scratch directory per test, removed when the test leaves.
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("community-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func pins(_ count: Int) -> [CommunityPhotoPin] {
        (0..<count).map { index in
            CommunityPhotoPin(
                capturedAt: Self.hikeDate.addingTimeInterval(Double(index) * 60),
                coordinate: CLLocationCoordinate2D(
                    latitude: 47.6 + Double(index) / 100,
                    longitude: 12.8 + Double(index) / 100
                )
            )
        }
    }

    /// A file of `contents` in the scratch directory, as an asset on a record.
    private func asset(named name: String, containing contents: Data) throws -> CKAsset {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, options: .atomic)
        return CKAsset(fileURL: url)
    }

    private func submission() -> CKRecord {
        CKRecord(recordType: CommunitySchema.submissionType)
    }

    private func record(carrying pins: [CommunityPhotoPin]) throws -> CKRecord {
        let record = submission()
        record[CommunitySchema.Submission.photoPins] = try asset(
            named: "pins.json",
            containing: JSONEncoder().encode(pins)
        )
        return record
    }

    // MARK: - Pins

    /// The ordinary case, which is also the one that proves the encoding the
    /// upload uses and the decoding the download uses are the same one.
    @Test("a record's pins come back in the order they were written")
    func pinsRoundTripInOrder() throws {
        let written = pins(3)

        let read = CloudKitCommunityTransport.decodePins(in: try record(carrying: written))

        #expect(read == written)
    }

    /// A submission published before photographs carried pins.
    ///
    /// The older shape of the same hike, not a broken one — its photographs
    /// belong in the list rather than on the map.
    @Test("a record with no pin asset has no pins")
    func recordWithoutPinAssetHasNoPins() {
        #expect(CloudKitCommunityTransport.decodePins(in: submission()).isEmpty)
    }

    /// An asset CloudKit has not cached, which is a file that is simply not
    /// there when the decode reaches for it.
    @Test("a pin asset whose file has gone has no pins")
    func missingPinFileHasNoPins() {
        let record = submission()
        record[CommunitySchema.Submission.photoPins] = CKAsset(
            fileURL: directory.appendingPathComponent("never-written.json", isDirectory: false)
        )

        #expect(CloudKitCommunityTransport.decodePins(in: record).isEmpty)
    }

    /// A file that exists and is not what it claims to be.
    ///
    /// Worth its own case rather than folding into the one above: a decode
    /// that threw here would take down a gallery that had every photograph it
    /// needed, over a coordinate none of them required.
    @Test("a pin asset that is not pins has no pins")
    func undecodablePinFileHasNoPins() throws {
        let record = submission()
        record[CommunitySchema.Submission.photoPins] = try asset(
            named: "junk.json",
            containing: Data("not a pin list".utf8)
        )

        #expect(CloudKitCommunityTransport.decodePins(in: record).isEmpty)
    }

    /// A field holding something that is not an asset at all.
    @Test("a pin field that is not an asset has no pins")
    func nonAssetPinFieldHasNoPins() {
        let record = submission()
        record[CommunitySchema.Submission.photoPins] = "a string, somehow"

        #expect(CloudKitCommunityTransport.decodePins(in: record).isEmpty)
    }

    // MARK: - Photographs

    private func photoAssets(_ names: [String]) throws -> [CKAsset] {
        try names.map { try asset(named: $0, containing: Data($0.utf8)) }
    }

    /// Every file arriving keeps its position, and lands where the app can
    /// still read it a minute later.
    @Test("every asset that copies keeps the index it came from")
    func copiedPhotosKeepTheirIndex() throws {
        let destination = directory.appendingPathComponent("kept", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let copied = CloudKitCommunityTransport.copyPhotos(
            try photoAssets(["a.jpeg", "b.jpeg", "c.jpeg"]),
            into: destination
        )

        #expect(copied.map(\.index) == [0, 1, 2])
        for (index, url) in copied {
            #expect(url.lastPathComponent == "photo-\(index).jpeg")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// The contract the pairing downstream depends on.
    ///
    /// One file in the middle that will not copy has to cost that photograph
    /// and no other — the two after it keep the positions their pins were
    /// written against, rather than sliding down one.
    @Test("a file that will not copy does not renumber the ones after it")
    func aLostFileDoesNotRenumberTheRest() throws {
        let destination = directory.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var assets = try photoAssets(["a.jpeg", "b.jpeg", "c.jpeg"])
        assets[1] = CKAsset(
            fileURL: directory.appendingPathComponent("swept-away.jpeg", isDirectory: false)
        )

        let copied = CloudKitCommunityTransport.copyPhotos(assets, into: destination)

        #expect(copied.map(\.index) == [0, 2])
        #expect(copied.last?.url.lastPathComponent == "photo-2.jpeg")
    }

    /// A gallery opened twice.
    ///
    /// The destination is named after the index, so a second download writes
    /// the same paths the first one did. Copying onto an existing file throws,
    /// which is what the removal before it exists to prevent — without it the
    /// second open of a hike would come back empty.
    @Test("a second download replaces the files the first one left")
    func copyingOverAnEarlierDownloadSucceeds() throws {
        let destination = directory.appendingPathComponent("twice", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let assets = try photoAssets(["first.jpeg", "second.jpeg"])
        _ = CloudKitCommunityTransport.copyPhotos(assets, into: destination)
        let second = CloudKitCommunityTransport.copyPhotos(assets, into: destination)

        #expect(second.map(\.index) == [0, 1])
        for (_, url) in second {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Nothing to copy is not a failure.
    @Test("no assets copy to no files")
    func noAssetsCopyToNothing() throws {
        let destination = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        #expect(CloudKitCommunityTransport.copyPhotos([], into: destination).isEmpty)
    }

    /// A destination that is not there at all.
    ///
    /// `copyPhotos` does not create its directory — the caller stages one — so
    /// this is the shape of a caller that forgot. Every copy fails, and the
    /// answer is empty rather than a crash or a half-written gallery.
    @Test("a destination that does not exist costs every photograph")
    func missingDestinationKeepsNothing() throws {
        let destination = directory.appendingPathComponent("never-made", isDirectory: true)

        #expect(
            CloudKitCommunityTransport.copyPhotos(
                try photoAssets(["a.jpeg"]),
                into: destination
            ).isEmpty
        )
    }
}
