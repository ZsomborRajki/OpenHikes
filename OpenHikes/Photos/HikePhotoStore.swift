//
//  HikePhotoStore.swift
//  OpenHikes
//
//  Where a hike's pictures actually live, and the only place that reads or
//  writes them.
//
//  Application Support, alongside ``TileCache``'s durable tier and the
//  recording journal — but *not* excluded from backup, which is the one way
//  this differs from every other file the app keeps. A tile can be downloaded
//  again and a journal describes a walk that is already over; a photograph of
//  the walk cannot be re-derived from anything, so it is exactly the kind of
//  file a device backup exists for.
//
//  Every method here decodes, encodes, enumerates or deletes, so every method
//  here is off-main by contract — the same rule the tile pipeline follows, and
//  asserted the same way. Decoding a 12-megapixel capture on the main thread
//  is a dropped frame per photo, and the gallery draws several at once.
//

import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
typealias PhotoImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PhotoImage = NSImage
#endif

/// The stored form of an image's bytes: the extension they should be written
/// under, resolved from the bytes themselves rather than from whatever handed
/// them over.
///
/// A picker reports the *asset's* content types, which is not always what the
/// transferred representation turns out to be, and a file named `.jpg`
/// containing HEIC bytes is a bug that only shows up in someone else's photo
/// library. ImageIO is the authority because it is also what reads the file
/// back.
nonisolated struct ImageDataFormat: Equatable, Sendable {
    /// What the camera path always produces — see
    /// ``HikePhotoStore/encode(_:)``.
    ///
    /// `jpeg` rather than `jpg` because that is what ``detect(in:)`` returns
    /// for JPEG bytes: the extension comes from
    /// `UTType.jpeg.preferredFilenameExtension`, and a constant that disagreed
    /// with the one path that writes files would describe nothing that is
    /// actually on disk.
    static let jpeg = Self(pathExtension: "jpeg")

    let pathExtension: String

    /// `nil` when the data is not a decodable image at all, which is the one
    /// answer an import has to be able to give.
    static func detect(in data: Data) -> Self? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              type.conforms(to: .image),
              let detected = type.preferredFilenameExtension
        else { return nil }
        return Self(pathExtension: detected)
    }
}

/// Reads and writes the photo files behind ``HikePhoto``, and keeps the
/// gallery's thumbnails so a strip of ten pictures doesn't decode ten
/// full-size images to draw ten 64pt squares.
///
/// `@unchecked Sendable` for the same reason ``TileCache`` is: `NSCache` is
/// thread-safe but not declared `Sendable` by the SDK. Every other stored
/// property is immutable.
nonisolated final class HikePhotoStore: @unchecked Sendable {
    /// The two files one photo occupies, named rather than modelled, so a
    /// measurement can be taken off the main actor. See
    /// `byteCount(of: [PhotoFiles])`.
    struct PhotoFiles: Equatable, Sendable {
        let fileName: String
        let thumbnailFileName: String

        init(_ photo: HikePhoto) {
            fileName = photo.fileName
            thumbnailFileName = photo.thumbnailFileName
        }
    }

    static let shared = HikePhotoStore()

    static let logger = Logger(subsystem: "OpenHikes", category: "HikePhotos")

    /// Longest edge of a stored gallery thumbnail, in pixels. Comfortably over
    /// the strip's tile at 3× so it stays sharp, far under a capture so it
    /// stays cheap.
    static let thumbnailMaxPixelSize = 512
    /// Longest edge the full-screen viewer decodes to. A capture is bigger
    /// than any iPhone screen, and the difference is only memory.
    static let displayMaxPixelSize = 2688

    private static let directoryName = "HikePhotos"
    private static let thumbnailDirectoryName = "Thumbnails"
    private static let thumbnailQuality = 0.8
    /// Quality for a captured frame. Visually indistinguishable from the
    /// original at roughly a third of the bytes, which on a long walk is the
    /// difference between a hike costing megabytes and costing tens of them.
    private static let captureQuality = 0.9
    /// Ceiling on the decoded bytes the thumbnail tier holds.
    ///
    /// The number that binds. A thumbnail is decoded at
    /// ``thumbnailMaxPixelSize`` with `kCGImageSourceShouldCacheImmediately`,
    /// so it is held as an uncompressed bitmap of roughly 0.75 MB, not as the
    /// JPEG it came from — and this tier used to be bounded only by a count of
    /// 200, an effective ceiling near 150 MB sitting alongside `TileCache`'s
    /// own memory tier. That is the same argument ``TileCache/memoryByteLimit``
    /// makes: a limit expressed in images says nothing about the resource being
    /// spent, and leaves the app relying on the system noticing.
    ///
    /// Sized for a long strip — about 42 thumbnails — rather than for a whole
    /// gallery, because the strip is what scrolls and a re-decode off screen
    /// costs 20 ms on a background executor rather than a dropped frame.
    private static let thumbnailByteLimit = 32 * 1024 * 1024
    /// A secondary backstop for the pathological case of very small images.
    /// The byte limit is what binds at any real thumbnail size.
    private static let thumbnailCountLimit = 200

    /// Where the full-size files live. Internal so a test can point a store at
    /// its own directory and inspect what landed there.
    let directory: URL
    private let thumbnailDirectory: URL
    // swiftlint:disable:next legacy_objc_type
    private let thumbnails = NSCache<NSString, PhotoImage>()

    /// - Parameter storageRoot: Overrides Application Support, so a suite gets
    ///   its own photo directory rather than the host app's — the same
    ///   arrangement ``TileCache`` offers.
    init(storageRoot: URL? = nil) {
        let root = storageRoot
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
        directory = root.appendingPathComponent(
            Self.directoryName,
            isDirectory: true
        )
        thumbnailDirectory = directory.appendingPathComponent(
            Self.thumbnailDirectoryName,
            isDirectory: true
        )
        thumbnails.totalCostLimit = Self.thumbnailByteLimit
        thumbnails.countLimit = Self.thumbnailCountLimit
    }

    // MARK: - Writing

    /// Writes `data` as the photo's file and returns the metadata to attach to
    /// the hike, or `nil` if the bytes are not an image or could not be
    /// stored.
    ///
    /// Metadata is returned rather than attached: the caller owns the `Hike`,
    /// and a `@Model` must not be written from the thread this runs on.
    func store(
        _ data: Data,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) -> HikePhoto? {
        assertOffMainThread("Photo storage must stay off the main thread")
        guard let format = ImageDataFormat.detect(in: data) else {
            Self.logger.error("Refused a photo whose bytes are not an image.")
            return nil
        }
        let photo = HikePhoto(
            capturedAt: capturedAt,
            pathExtension: format.pathExtension,
            coordinate: coordinate
        )
        do {
            try createDirectories()
            try data.write(to: url(for: photo), options: .atomic)
        } catch {
            Self.logger.error(
                "Could not store a photo: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        return photo
    }

    /// JPEG bytes for a captured frame, with the camera's orientation baked
    /// into the pixels.
    ///
    /// Normalised rather than left as an orientation tag: the tag is honoured
    /// by everything that reads through ImageIO and by nothing that reads the
    /// raw buffer, and a photo that is upright in the gallery and on its side
    /// in someone's photo library is the kind of bug that is only ever found
    /// by a user.
    func encode(_ image: PhotoImage) -> Data? {
        assertOffMainThread("Photo encoding must stay off the main thread")
        #if canImport(UIKit)
        let upright: UIImage
        if image.imageOrientation == .up {
            upright = image
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.opaque = true
            upright = UIGraphicsImageRenderer(size: image.size, format: format)
                .image { _ in
                    image.draw(in: CGRect(origin: .zero, size: image.size))
                }
        }
        return upright.jpegData(compressionQuality: Self.captureQuality)
        #else
        return nil
        #endif
    }

    // MARK: - Reading

    func url(for photo: HikePhoto) -> URL {
        directory.appendingPathComponent(photo.fileName, isDirectory: false)
    }

    private func thumbnailURL(for photo: HikePhoto) -> URL {
        thumbnailDirectory.appendingPathComponent(
            photo.thumbnailFileName,
            isDirectory: false
        )
    }

    /// The gallery strip's image.
    ///
    /// Rendered once and kept: the strip is rebuilt every time the hike screen
    /// appears, and re-downsampling a capture per appearance is the most
    /// expensive thing this file could do. The memory tier on top of that is
    /// what makes a scroll free rather than merely cheap.
    func thumbnail(for photo: HikePhoto) -> PhotoImage? {
        assertOffMainThread("Thumbnail decoding must stay off the main thread")
        // swiftlint:disable:next legacy_objc_type
        let key = photo.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }

        let stored = thumbnailURL(for: photo)
        if let image = Self.decode(stored, maxPixelSize: Self.thumbnailMaxPixelSize) {
            cacheThumbnail(image, forKey: key)
            return image
        }

        guard let image = Self.decode(
            url(for: photo),
            maxPixelSize: Self.thumbnailMaxPixelSize
        ) else { return nil }
        writeThumbnail(image, to: stored)
        cacheThumbnail(image, forKey: key)
        return image
    }

    // swiftlint:disable legacy_objc_type
    /// The single insertion point on purpose: `setObject(_:forKey:)` without a
    /// cost is free as far as `NSCache` is concerned, so one call site that
    /// forgot it would exempt its entries from ``thumbnailByteLimit`` entirely.
    /// The measurement is ``TileCache/decodedByteCost(of:)`` rather than a
    /// second copy of it — `PhotoImage` and `TileImage` are the same type, and
    /// two hand-written versions of "how big is this bitmap" would agree until
    /// one of them was tuned.
    private func cacheThumbnail(_ image: PhotoImage, forKey key: NSString) {
        thumbnails.setObject(image, forKey: key, cost: TileCache.decodedByteCost(of: image))
    }
    // swiftlint:enable legacy_objc_type

    /// The viewer's image: the full picture, decoded no larger than a screen
    /// can show.
    func displayImage(for photo: HikePhoto) -> PhotoImage? {
        assertOffMainThread("Photo decoding must stay off the main thread")
        return Self.decode(url(for: photo), maxPixelSize: Self.displayMaxPixelSize)
    }

    /// The original bytes, for the photo library and for sharing — neither of
    /// which should be handed a re-encoded copy of a picture we already have.
    func imageData(for photo: HikePhoto) -> Data? {
        assertOffMainThread("Photo reads must stay off the main thread")
        return try? Data(contentsOf: url(for: photo), options: .mappedIfSafe)
    }

    /// What these photos cost on disk, thumbnails included.
    func byteCount(of photos: [HikePhoto]) -> Int64 {
        assertOffMainThread("Photo measurement must stay off the main thread")
        return photos.reduce(into: Int64(0)) { total, photo in
            total += Self.fileSize(url(for: photo))
            total += Self.fileSize(thumbnailURL(for: photo))
        }
    }

    /// The same measurement from a snapshot of the names rather than from the
    /// models.
    ///
    /// ``HikePhoto`` is a SwiftData model and so cannot cross an isolation
    /// boundary. The one screen that shows this number reads the photos on the
    /// main actor and measures them off it, which needs something that can —
    /// exactly what ``TileOwnership`` does for a hike's tiles.
    func byteCount(of files: [PhotoFiles]) -> Int64 {
        assertOffMainThread("Photo measurement must stay off the main thread")
        return files.reduce(into: Int64(0)) { total, file in
            total += Self.fileSize(
                directory.appendingPathComponent(file.fileName, isDirectory: false)
            )
            total += Self.fileSize(
                thumbnailDirectory.appendingPathComponent(
                    file.thumbnailFileName,
                    isDirectory: false
                )
            )
        }
    }

    // MARK: - Deleting

    /// Removes these photos' files. Safe to call for a photo whose file is
    /// already gone, which is what a partly-failed import leaves behind.
    func remove(_ photos: [HikePhoto]) {
        assertOffMainThread("Photo deletion must stay off the main thread")
        for photo in photos {
            try? FileManager.default.removeItem(at: url(for: photo))
            try? FileManager.default.removeItem(at: thumbnailURL(for: photo))
            // swiftlint:disable:next legacy_objc_type
            thumbnails.removeObject(forKey: photo.id.uuidString as NSString)
        }
    }

    /// Deletes files no ``HikePhoto`` claims any more, and returns how many
    /// went.
    ///
    /// The deletes this backstops are fire-and-forget by design — there is no
    /// screen where waiting on one would tell the user anything — so a hike
    /// deleted moments before the app was killed leaves its pictures behind
    /// with nothing left in the store pointing at them. That is exactly the
    /// job ``TileOwnership`` does for tiles, and it is done the same way: the
    /// caller assembles the complete claim set, and anything unclaimed goes.
    ///
    /// - Parameters:
    ///   - claimed: Every file name still spoken for, full-size and thumbnail
    ///     alike. Must be complete — an under-reported claim set is
    ///     indistinguishable from an orphan and would delete a real photo.
    ///   - youngerThan: Files newer than this are left alone regardless. A
    ///     photo is written before it is attached, so a file with no claim is
    ///     also what an import in flight looks like; the grace period is what
    ///     keeps a sweep from deleting a picture that is a fraction of a
    ///     second away from being claimed.
    @discardableResult func reclaimOrphans(
        claimedBy claimed: Set<String>,
        youngerThan grace: TimeInterval = 300,
        now: Date = .now
    ) -> Int {
        assertOffMainThread("Photo reclamation must stay off the main thread")
        let cutoff = now.addingTimeInterval(-grace)
        return reclaim(in: directory, claimedBy: claimed, before: cutoff)
            + reclaim(in: thumbnailDirectory, claimedBy: claimed, before: cutoff)
    }

    private func reclaim(
        in directory: URL,
        claimedBy claimed: Set<String>,
        before cutoff: Date
    ) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else { return 0 }
        var removed = 0
        for entry in entries {
            let values = try? entry.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else { continue }
            guard !claimed.contains(entry.lastPathComponent) else { continue }
            guard let modified = values?.contentModificationDate,
                  modified < cutoff
            else { continue }
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        if removed > 0 {
            Self.logger.info("Reclaimed \(removed, privacy: .public) orphaned photo files.")
        }
        return removed
    }

    // MARK: - Files

    private func createDirectories() throws {
        try FileManager.default.createDirectory(
            at: thumbnailDirectory,
            withIntermediateDirectories: true
        )
    }

    private func writeThumbnail(_ image: PhotoImage, to url: URL) {
        #if canImport(UIKit)
        guard let data = image.jpegData(compressionQuality: Self.thumbnailQuality) else { return }
        try? createDirectories()
        try? data.write(to: url, options: .atomic)
        #endif
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }

    /// Decodes at most `maxPixelSize` on the longest edge, with the file's
    /// orientation applied.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` rather than decoding and scaling:
    /// it never materialises the full-size bitmap, which for a capture is the
    /// difference between tens of megabytes and one. `WithTransform` is what
    /// makes a portrait photo come back portrait, so nothing above this has to
    /// carry an orientation.
    private static func decode(_ url: URL, maxPixelSize: Int) -> PhotoImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: image)
        #elseif canImport(AppKit)
        return NSImage(
            cgImage: image,
            size: CGSize(width: image.width, height: image.height)
        )
        #endif
    }
}
