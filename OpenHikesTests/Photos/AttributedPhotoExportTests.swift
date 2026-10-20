//
//  AttributedPhotoExportTests.swift
//  OpenHikesTests
//
//  A Wikimedia Commons copy leaving the app with the credit its licence asks
//  for — on its own through the share sheet, and inside a hike's archive.
//
//  Every picture here is made in the test and carries no metadata of its own,
//  and the first assertion of each test says so. That is the point of the
//  suite: the credit was stored beside the photograph on its row, never in its
//  bytes, so an export that only copied the bytes would hand back a picture
//  with nothing in it. A real Commons JPEG often does embed an author, and a
//  test against one could pass by accident through it.
//
//  Read back through ImageIO, for the reason `PhotoMetadataStampTests` gives:
//  the question is what a file on somebody else's disk says.
//

import CoreLocation
import Foundation
import ImageIO
@testable import OpenHikes
import OpenHikesData
import Testing

#if canImport(UIKit)
import UIKit
#endif

/// A store and an output directory, both removed when the test that made them
/// ends, as `ArchiveSandbox` in `HikeArchiveTests` is.
nonisolated private final class CreditSandbox: Sendable {
    let root: URL
    let output: URL
    let store: HikePhotoStore

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("credit-sandbox-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("store", isDirectory: true)
        output = base.appendingPathComponent("out", isDirectory: true)
        store = HikePhotoStore(storageRoot: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

@Suite("Attributed photo exports")
struct AttributedPhotoExportTests {
    nonisolated private static let side = 8
    nonisolated private static let date = Date(timeIntervalSince1970: 1_750_000_000)
    nonisolated private static let latitude = 47.6301234
    nonisolated private static let longitude = 12.9901234
    nonisolated private static let page = URL(
        string: "https://commons.wikimedia.org/wiki/File:Thumsee_Ufer.jpg"
    )!
    nonisolated private static let licenceText = URL(
        string: "https://creativecommons.org/licenses/by-sa/4.0/"
    )!
    nonisolated private static let credit = CommonsPhotoCredit(
        author: "Anna Berger",
        licence: HikePhotoLicence(name: "CC BY-SA 4.0", url: licenceText, sourceURL: page)
    )

    // MARK: - The bytes

    @Test("the credit is written into a JPEG that carried none")
    func creditsAJPEG() async throws {
        let original = Self.image(jpeg: true)
        try #require(Self.copyright(of: original) == nil)

        let credited = try #require(
            await offMain { PhotoMetadataStamp.credited(original, with: Self.credit) }
        )

        #expect(Self.copyright(of: credited) == Self.credit.notice)
        let iptc = Self.properties(of: credited)[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCSource] as? String == Self.page.absoluteString)
        let metadata = try #require(Self.metadata(of: credited))
        #expect(CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:creator[0]" as CFString)
            as String? == "Anna Berger")
        #expect(CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmpRights:WebStatement" as CFString)
            as String? == Self.licenceText.absoluteString)
    }

    @Test("the copyright notice alone names the author, the licence and both links")
    func noticeCarriesAllThree() async throws {
        // A PNG keeps no IPTC and no `dc:creator`, so the notice is the whole
        // of its credit and has to say everything the licence asks for.
        let original = Self.image(jpeg: false)
        try #require(Self.copyright(of: original) == nil)

        let credited = try #require(
            await offMain { PhotoMetadataStamp.credited(original, with: Self.credit) }
        )

        let notice = try #require(Self.copyright(of: credited))
        #expect(notice.contains("Anna Berger"))
        #expect(notice.contains("CC BY-SA 4.0"))
        #expect(notice.contains(Self.page.absoluteString))
        #expect(notice.contains(Self.licenceText.absoluteString))
    }

    // MARK: - Sharing one photograph

    @Test("sharing a Commons copy sends a credited copy and leaves the stored file alone")
    func shareSendsACreditedCopy() async throws {
        let sandbox = CreditSandbox()
        let photo = try await Self.storedPhoto(in: sandbox)
        let stored = sandbox.store.url(for: photo)
        let before = try Data(contentsOf: stored)
        let output = sandbox.output

        let sent = try await offMain {
            try HikePhotoFile.stageCredited(stored, with: Self.credit, named: "Thumsee-1.png", in: output)
        }

        #expect(sent.lastPathComponent == "Thumsee-1.png")
        #expect(Self.copyright(of: try Data(contentsOf: sent)) == Self.credit.notice)
        #expect(try Data(contentsOf: stored) == before)
    }

    @Test("a Commons copy that cannot carry its credit is not sent")
    func uncreditableCopyIsWithheld() async throws {
        let sandbox = CreditSandbox()
        let output = sandbox.output
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let unreadable = output.appendingPathComponent("broken.jpeg")
        try Data("not an image".utf8).write(to: unreadable)

        await #expect(throws: HikePhotoFile.CreditNotWritten.self) {
            try await offMain {
                try HikePhotoFile.stageCredited(
                    unreadable,
                    with: Self.credit,
                    named: "Thumsee-1.jpeg",
                    in: output.appendingPathComponent("sent", isDirectory: true)
                )
            }
        }
    }

    // MARK: - The archive

    @Test("an archive credits a Commons copy in its file, its credits list and its waypoint")
    func archiveCreditsACopy() async throws {
        let sandbox = CreditSandbox()
        let own = try await Self.storedPhoto(in: sandbox)
        let commons = try await Self.storedPhoto(in: sandbox)
        let archive = Self.archive([(own, nil), (commons, Self.credit)])

        let root = try await offMain {
            try HikeArchive.stage(archive, in: sandbox.output, store: sandbox.store)
        }

        let photos = root.appendingPathComponent(HikeArchive.photoDirectoryName, isDirectory: true)
        // The hiker's own photograph is still the stored file, byte for byte.
        #expect(
            try Data(contentsOf: photos.appendingPathComponent("photo-1.png"))
                == Data(contentsOf: sandbox.store.url(for: own))
        )
        let copy = try Data(contentsOf: photos.appendingPathComponent("photo-2.png"))
        #expect(Self.copyright(of: copy) == Self.credit.notice)

        let credits = try String(
            contentsOf: root.appendingPathComponent(HikeArchive.creditsFileName),
            encoding: .utf8
        )
        #expect(credits == "Photos/photo-2.png\n\(Self.credit.notice)\n")

        let xml = try String(contentsOf: root.appendingPathComponent("\(archive.stem).gpx"), encoding: .utf8)
        // One `<desc>`, on the Commons copy's waypoint, and its page linked
        // after the file — in the order GPX 1.1 fixes for `<wpt>`'s children.
        #expect(xml.components(separatedBy: "<desc>").count - 1 == 1)
        let description = try #require(xml.range(of: "<desc>Photo by Anna Berger · CC BY-SA 4.0</desc>"))
        let file = try #require(xml.range(of: "<link href=\"Photos/photo-2.png\"/>"))
        let pageLink = try #require(xml.range(of: "<link href=\"\(Self.page.absoluteString)\"/>"))
        let symbol = try #require(xml.range(of: "<sym>", range: pageLink.upperBound..<xml.endIndex))
        #expect(description.upperBound < file.lowerBound)
        #expect(file.upperBound < pageLink.lowerBound)
        #expect(pageLink.upperBound < symbol.lowerBound)
    }

    @Test("an archive of the hiker's own photographs has no credits list")
    func ownArchiveHasNoCredits() async throws {
        let sandbox = CreditSandbox()
        let own = try await Self.storedPhoto(in: sandbox)
        let archive = Self.archive([(own, nil)])

        let root = try await offMain {
            try HikeArchive.stage(archive, in: sandbox.output, store: sandbox.store)
        }

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(HikeArchive.creditsFileName).path
        ))
    }

    @Test("a saved Commons copy reads its credit from its row, and the hiker's own reads none")
    func creditComesFromTheRow() {
        let copy = HikePhoto(importedAuthorName: "Anna Berger", licence: Self.credit.licence)
        #expect(CommonsPhotoCredit(copy) == Self.credit)
        // A contributed photograph names its author and has no licence: it is
        // credited in the app, and nothing here is owed for it.
        #expect(CommonsPhotoCredit(HikePhoto(importedAuthorName: "Anna Berger")) == nil)
        #expect(CommonsPhotoCredit(HikePhoto()) == nil)
    }

    // MARK: - Fixtures

    /// A decodable image with no metadata at all.
    nonisolated private static func image(jpeg: Bool) -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return (jpeg ? image.jpegData(compressionQuality: 0.9) : image.pngData()) ?? Data()
        #else
        return Data()
        #endif
    }

    /// A photo whose pixels are really on disk in `sandbox`.
    private static func storedPhoto(in sandbox: CreditSandbox) async throws -> HikePhoto {
        let data = image(jpeg: false)
        try #require(!data.isEmpty)
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let store = sandbox.store
        return try #require(
            await offMain { store.store(data, capturedAt: date, coordinate: coordinate) }
        )
    }

    private static func archive(_ photos: [(HikePhoto, CommonsPhotoCredit?)]) -> HikeArchive {
        HikeArchive(
            track: GPXExport.Track(
                name: "Thumsee Loop",
                trackDescription: nil,
                author: nil,
                keywords: nil,
                date: date,
                route: [RouteCoordinate(latitude: latitude, longitude: longitude)]
            ),
            photographs: photos.enumerated().map { index, entry in
                HikeArchive.Photograph(
                    files: HikePhotoStore.PhotoFiles(entry.0),
                    fileName: "photo-\(index + 1).\(entry.0.pathExtension)",
                    coordinate: RouteCoordinate(latitude: latitude, longitude: longitude),
                    capturedAt: entry.0.capturedAt,
                    credit: entry.1
                )
            }
        )
    }

    nonisolated private static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let copied = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        return copied
    }

    nonisolated private static func metadata(of data: Data) -> CGImageMetadata? {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
    }

    /// TIFF `Copyright` — the field every container keeps.
    nonisolated private static func copyright(of data: Data) -> String? {
        let tiff = properties(of: data)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return tiff?[kCGImagePropertyTIFFCopyright] as? String
    }
}
