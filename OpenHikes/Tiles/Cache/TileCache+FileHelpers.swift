//
//  TileCache+FileHelpers.swift
//  OpenHikes
//

import Foundation
import os

nonisolated extension TileCache {

    /// Which of the two disk tiers a file belongs to.
    ///
    /// Carried explicitly rather than inferred from the file's parent
    /// directory, because ``freshModificationDate(for:in:referenceDate:)``
    /// deletes what it finds expired and the two tiers are accounted for
    /// differently — a durable byte is spent against a provider's licensed
    /// ceiling and a browsing byte is not. Comparing URLs would make that
    /// distinction depend on path normalisation; a parameter makes the
    /// compiler check it at every call site.
    enum StorageTier: Sendable {
        /// `Caches` — a tile fetched to draw the map, which the OS may reclaim.
        case browsing
        /// `Application Support` — offline coverage a hike claims.
        case durable
    }

    func directory(for tier: StorageTier) -> URL {
        switch tier {
        case .browsing: directory
        case .durable: durableDirectory
        }
    }

    func allTileFiles(in directory: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                ]
            )
        } catch {
            logFileError(
                error,
                operation: "enumerate tile directory",
                url: directory
            )
            return []
        }
    }

    func fileSize(_ url: URL) -> Int64 {
        do {
            return Int64(
                try url.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize ?? 0
            )
        } catch {
            logFileError(
                error,
                operation: "read tile size",
                url: url
            )
            return 0
        }
    }

    /// Returns a usable fetch date, deleting the file when its fixed TTL has
    /// elapsed. Modification time is the fetch time because tile files are
    /// written atomically and never rewritten except by a fresh response.
    ///
    /// `tier` is what the deletion is accounted for against. A durable tile
    /// removed here is bytes a capped provider gets back — without that, the
    /// total kept counting a file that no longer exists, and since the only
    /// thing that reset it was a launch-time sweep, a browsing session over
    /// week-old Stadia coverage could refuse legitimate saves for the rest of
    /// the session. A browsing-tier deletion is accounted for by nobody,
    /// which is why the tier has to be known rather than assumed.
    func freshModificationDate(
        for file: URL,
        in tier: StorageTier,
        referenceDate: Date = Date()
    ) -> Date? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let modified: Date?
        do {
            modified = try file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        } catch {
            logFileError(
                error,
                operation: "read tile modification date",
                url: file
            )
            modified = nil
        }
        guard let modified, !isExpired(modified, referenceDate: referenceDate) else {
            // Sized before the unlink, and given back only if the unlink was
            // this caller's: `removeItemIgnoringNotFound` reports `false` for a
            // file another thread already took, so two threads finding the
            // same tile expired cannot subtract it twice.
            let byteCount = tier == .durable ? fileSize(file) : 0
            let removed = removeItemIgnoringNotFound(
                at: file,
                operation: "remove unusable tile"
            )
            if removed, tier == .durable {
                // A decrement rather than ``invalidateDurableMeasurements()``,
                // which is what the batch deletion paths use. Those delete
                // many files and invalidate once; this deletes exactly one
                // file whose size it just read, and runs per tile on the
                // browse path. Invalidating here would make the next capped
                // provider reservation re-walk the durable directory — and
                // interleaved with a bulk download over expired coverage,
                // that is one full directory walk per tile saved.
                // ``reclaimDurableBytes(forProviderID:protecting:byteCount:)``
                // already subtracts what it deletes for the same reason.
                adjustDurableBytes(
                    forProviderID: Self.providerID(forDiskName: file.lastPathComponent),
                    by: -byteCount
                )
            }
            return nil
        }
        return modified
    }

    static func createDirectoryIfNeeded(at url: URL, excludeFromBackup: Bool = false) {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            if excludeFromBackup {
                var mutable = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try mutable.setResourceValues(values)
            }
        } catch {
            logger.error(
                // swiftlint:disable:next line_length
                "Could not create tile directory \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @discardableResult func removeItemIgnoringNotFound(
        at url: URL,
        operation: String
    ) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            guard !Self.isMissingFileError(error) else { return false }
            logFileError(error, operation: operation, url: url)
            return false
        }
    }

    func logFileError(
        _ error: Error,
        operation: String,
        url: URL
    ) {
        guard !Self.isMissingFileError(error) else { return }
        Self.logger.error(
            // swiftlint:disable:next line_length
            "Could not \(operation, privacy: .public) at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == NSFileNoSuchFileError
            || nsError.code == NSFileReadNoSuchFileError
    }

    func isExpired(_ storedAt: Date, referenceDate: Date = Date()) -> Bool {
        referenceDate.timeIntervalSince(storedAt) >= Self.tileExpirationInterval
    }
}
