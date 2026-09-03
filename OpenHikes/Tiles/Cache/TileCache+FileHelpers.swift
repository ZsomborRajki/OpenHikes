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
    /// directory, because ``storedModificationDate(for:in:referenceDate:)``
    /// deletes an expired *browsing* file and never an expired durable one —
    /// the tier is what decides whether age is allowed to unlink anything at
    /// all. Comparing URLs would make that distinction depend on path
    /// normalisation; a parameter makes the compiler check it at every call
    /// site.
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

    /// The file's modification date, read flat — no tier rules, no deletion,
    /// and no substitute for a date that cannot be read.
    ///
    /// ``storedModificationDate(for:in:referenceDate:)`` is the answer to "how
    /// old is this tile, and is that allowed"; this is the answer to "which of
    /// these two files is the newer one", where a missing date has to mean
    /// *unknown* rather than `.distantPast` — the comparison would otherwise
    /// invent an ordering out of a failed stat.
    ///
    /// The cached resource value is cleared first: a directory enumerated with
    /// `includingPropertiesForKeys:` hands back the date read during the walk,
    /// which may predate a write this call is meant to see.
    func modificationDate(of file: URL) -> Date? {
        var file = file
        file.removeAllCachedResourceValues()
        do {
            return try file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        } catch {
            logFileError(
                error,
                operation: "read tile modification date",
                url: file
            )
            return nil
        }
    }

    /// Returns the file's fetch date, or `nil` when there is no usable file.
    /// Modification time is the fetch time because tile files are written
    /// atomically and never rewritten except by a fresh response.
    ///
    /// **The tier decides what age is allowed to do.** A browsing tile past
    /// ``TileCache/tileExpirationInterval`` is deleted here and reported
    /// absent: it is cache, nobody asked for it, and the only cost of losing
    /// it is refetching it. A **durable** tile is offline coverage a walker
    /// explicitly saved, so age never unlinks it — the date comes back as it
    /// stands and the caller decides whether to refresh. Deleting it here is
    /// what made a map saved a week before a trip blank on the trail: the
    /// bytes went before anything had asked whether the phone had signal to
    /// replace them. See ``TileCache/loadTileResult(forKey:url:purpose:)``.
    ///
    /// Callers that need *freshness* rather than presence pass the returned
    /// date through ``isExpired(_:referenceDate:)``; callers asking whether a
    /// key is stored at all — ``TileCache/promoteCachedTile(forKey:racingWriter:)``
    /// — want exactly this answer, because stale coverage is still coverage
    /// and a hike's claim on it is still true.
    ///
    /// A durable file whose date cannot be read is reported as `.distantPast`:
    /// it is present, so its bytes stay, but nothing can vouch for its age and
    /// treating it as maximally stale is what sends it to be refreshed.
    func storedModificationDate(
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
        guard tier == .browsing else { return modified ?? .distantPast }
        guard let modified, !isExpired(modified, referenceDate: referenceDate) else {
            _ = removeItemIgnoringNotFound(
                at: file,
                operation: "remove unusable tile"
            )
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
