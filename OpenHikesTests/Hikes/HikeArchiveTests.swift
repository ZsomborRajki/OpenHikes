//
//  HikeArchiveTests.swift
//  OpenHikesTests
//
//  What an archive actually contains, which is the only claim this feature
//  makes: a hiker's photographs leaving the app in a file they can keep.
//
//  Asserted against a staged folder rather than by expanding a zip, and that
//  is a constraint rather than a preference — these are hosted tests on a
//  simulator, where there is no `unzip` to reach for and `Foundation.Process`
//  does not exist. ``HikeArchive/stage(_:in:store:)`` is the seam that makes
//  the substance testable; one test below checks the archive really is a zip
//  by its header, which is the part staging cannot answer.
//
//  The store is rooted in a temporary directory throughout, never
//  `HikePhotoStore.shared`, for the reason `HikePhotoStoreTests` gives: the
//  singleton writes into the host app's Application Support.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

#if canImport(UIKit)
import UIKit
#endif

/// A store and an output directory, both removed when the test that made them
/// ends. A class so `deinit` can do the cleanup, as `PhotoSandbox` is.
nonisolated private final class ArchiveSandbox: Sendable {
    let root: URL
    let output: URL
    let store: HikePhotoStore

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-sandbox-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("store", isDirectory: true)
        output = base.appendingPathComponent("out", isDirectory: true)
        store = HikePhotoStore(storageRoot: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

@Suite("Hike archive")
struct HikeArchiveTests {
    nonisolated private static let side = 8
    private static let date = Date(timeIntervalSince1970: 1_750_000_000)
    private static let latitude = 47.6301234
    private static let longitude = 12.9901234

    /// A genuinely decodable PNG, because the store asks ImageIO what the
    /// bytes are rather than trusting the caller — see ``ImageDataFormat``.
    nonisolated private static func imageData() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
        #else
        return Data()
        #endif
    }

    /// A photo whose pixels are really on disk in `sandbox`.
    private static func storedPhoto(
        in sandbox: ArchiveSandbox,
        anchored: Bool,
        capturedAt: Date
    ) async throws -> HikePhoto {
        let data = imageData()
        try #require(!data.isEmpty)
        let coordinate = anchored
            ? CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            : nil
        let store = sandbox.store
        // The store asserts it is not on main, and Swift Testing runs these
        // suites main-actor-isolated.
        return try #require(
            await offMain { store.store(data, capturedAt: capturedAt, coordinate: coordinate) }
        )
    }

    /// A photo row with no file behind it — the state a second device is
    /// permanently in, since the metadata mirrors and the pixels do not.
    private static func absentPhoto(capturedAt: Date) -> HikePhoto {
        HikePhoto(
            capturedAt: capturedAt,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    private static func archive(_ photos: [HikePhoto]) -> HikeArchive {
        HikeArchive(
            track: GPXExport.Track(
                name: "Thumsee Loop",
                trackDescription: nil,
                author: nil,
                keywords: nil,
                date: date,
                route: [
                    RouteCoordinate(latitude: latitude, longitude: longitude),
                    RouteCoordinate(latitude: latitude + 0.01, longitude: longitude + 0.01),
                ]
            ),
            photographs: photos.enumerated().map { index, photo in
                HikeArchive.Photograph(
                    files: HikePhotoStore.PhotoFiles(photo),
                    fileName: "photo-\(index + 1).\(photo.pathExtension)",
                    coordinate: photo.coordinate.map { coordinate in
                        RouteCoordinate(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                    },
                    capturedAt: photo.capturedAt
                )
            }
        )
    }

    @Test("the archive carries every photograph's original bytes")
    func carriesOriginals() async throws {
        let sandbox = ArchiveSandbox()
        let first = try await Self.storedPhoto(in: sandbox, anchored: true, capturedAt: Self.date)
        let second = try await Self.storedPhoto(
            in: sandbox,
            anchored: true,
            capturedAt: Self.date.addingTimeInterval(600)
        )
        let archive = Self.archive([first, second])

        let root = try await offMain {
            try HikeArchive.stage(archive, in: sandbox.output, store: sandbox.store)
        }

        let photos = root.appendingPathComponent(HikeArchive.photoDirectoryName, isDirectory: true)
        let names = try FileManager.default
            .contentsOfDirectory(atPath: photos.path)
            .sorted()
        #expect(names == ["photo-1.png", "photo-2.png"])

        // Byte-for-byte, which is the whole difference between this and the
        // community export: a rescue that re-encodes hands back something
        // lossier than the file it rescued.
        let original = try Data(contentsOf: sandbox.store.url(for: first))
        let archived = try Data(contentsOf: photos.appendingPathComponent("photo-1.png"))
        #expect(archived == original)
    }

    @Test("the document inside is named after the archive and links its photographs")
    func documentLinksPhotographs() async throws {
        let sandbox = ArchiveSandbox()
        let photo = try await Self.storedPhoto(in: sandbox, anchored: true, capturedAt: Self.date)
        let archive = Self.archive([photo])

        let root = try await offMain {
            try HikeArchive.stage(archive, in: sandbox.output, store: sandbox.store)
        }

        #expect(root.lastPathComponent == archive.stem)
        let document = root.appendingPathComponent("\(archive.stem).gpx")
        let xml = try String(contentsOf: document, encoding: .utf8)
        #expect(xml.contains("<link href=\"Photos/photo-1.png\"/>"))
        // The link belongs between `<name>` and `<sym>`; GPX 1.1 fixes the
        // order of `<wpt>`'s children and a validating reader refuses the file
        // over the wrong one.
        let name = try #require(xml.range(of: "<name>Photo</name>"))
        let link = try #require(xml.range(of: "<link href="))
        let symbol = try #require(xml.range(of: "<sym>"))
        #expect(name.upperBound < link.lowerBound)
        #expect(link.upperBound < symbol.lowerBound)
    }

    @Test("a photograph this device does not have gets a waypoint but no link")
    func absentPhotographIsNotLinked() async throws {
        let sandbox = ArchiveSandbox()
        let here = try await Self.storedPhoto(in: sandbox, anchored: true, capturedAt: Self.date)
        let elsewhere = Self.absentPhoto(capturedAt: Self.date.addingTimeInterval(600))
        let archive = Self.archive([here, elsewhere])

        let root = try await offMain {
            try HikeArchive.stage(archive, in: sandbox.output, store: sandbox.store)
        }

        let photos = root.appendingPathComponent(HikeArchive.photoDirectoryName, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: photos.path)
        #expect(names == ["photo-1.png"])

        let xml = try String(
            contentsOf: root.appendingPathComponent("\(archive.stem).gpx"),
            encoding: .utf8
        )
        // Both were photographed somewhere, so both are waypoints. Only the
        // one that is really beside the file may be linked — an `href` at the
        // other is the broken promise the plain `.gpx` export refuses to make.
        #expect(xml.components(separatedBy: "<wpt ").count - 1 == 2)
        #expect(xml.components(separatedBy: "<link href=").count - 1 == 1)
        #expect(!xml.contains("photo-2.jpeg"))
    }

    @Test("an unanchored photograph is in the archive and not in the document")
    func unanchoredPhotographIsCarriedNotWritten() async throws {
        let sandbox = ArchiveSandbox()
        let unanchored = try await Self.storedPhoto(in: sandbox, anchored: false, capturedAt: Self.date)
        let archive = Self.archive([unanchored])

        let root = try await offMain {
            try HikeArchive.stage(archive, in: sandbox.output, store: sandbox.store)
        }

        // The pixels are exactly as irreplaceable as an anchored photo's, and
        // `<wpt>` requires `lat` and `lon`, so it travels and is not written.
        let photos = root.appendingPathComponent(HikeArchive.photoDirectoryName, isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: photos.path) == ["photo-1.png"])
        let xml = try String(
            contentsOf: root.appendingPathComponent("\(archive.stem).gpx"),
            encoding: .utf8
        )
        #expect(!xml.contains("<wpt "))
    }

    @Test("the plain GPX export still writes no link")
    func plainExportIsUnchanged() {
        // The archive is a second export, not a replacement: a bare `.gpx` is
        // what a GPX reader can match, and it travels beside nothing.
        let track = GPXExport.Track(
            name: "Thumsee Loop",
            trackDescription: nil,
            author: nil,
            keywords: nil,
            date: Self.date,
            route: [RouteCoordinate(latitude: Self.latitude, longitude: Self.longitude)],
            photographs: [
                GPXExport.Photograph(
                    coordinate: RouteCoordinate(
                        latitude: Self.latitude,
                        longitude: Self.longitude
                    ),
                    capturedAt: Self.date
                ),
            ]
        )
        let xml = GPXExport.xml(for: track)
        #expect(xml.contains("<wpt "))
        #expect(!xml.contains("<link"))
    }

    @Test("what the share sheet is handed is a real zip")
    func writeProducesAZip() async throws {
        let sandbox = ArchiveSandbox()
        let photo = try await Self.storedPhoto(in: sandbox, anchored: true, capturedAt: Self.date)
        let archive = Self.archive([photo])

        let url = try await HikeArchive.write(archive, store: sandbox.store)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(url.lastPathComponent == "\(archive.stem).zip")
        let header = try Data(contentsOf: url).prefix(4)
        // "PK\u{03}\u{04}" — the local file header every zip starts with. The
        // system's own archiver produced it, so this asserts the coordination
        // really ran rather than that the bytes are well-formed.
        #expect(Array(header) == [0x50, 0x4B, 0x03, 0x04])
    }
}
