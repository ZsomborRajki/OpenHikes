//
//  TileCache+FileHelpers.swift
//  OpenTrails
//

import Foundation
import os

nonisolated extension TileCache {

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
    func freshModificationDate(for file: URL, referenceDate: Date = Date()) -> Date? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
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
            _ = removeItemIgnoringNotFound(
                at: file,
                operation: "remove unusable tile"
            )
            return nil
        }
        return modified
    }

    static func createDirectoryIfNeeded(at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
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
            guard !Self.isMissingFileError(error) else {
                return false
            }
            logFileError(error, operation: operation, url: url)
            return false
        }
    }

    func logFileError(
        _ error: Error,
        operation: String,
        url: URL
    ) {
        guard !Self.isMissingFileError(error) else {
            return
        }
        Self.logger.error(
            // swiftlint:disable:next line_length
            "Could not \(operation, privacy: .public) at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return false
        }
        return nsError.code == NSFileNoSuchFileError
            || nsError.code == NSFileReadNoSuchFileError
    }

    func isExpired(_ storedAt: Date, referenceDate: Date = Date()) -> Bool {
        referenceDate.timeIntervalSince(storedAt) >= Self.tileExpirationInterval
    }
}
