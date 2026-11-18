//
//  OfflineCountryStore.swift
//  OpenHikes
//
//  Where the downloaded countries are kept: their archives in one directory
//  under Application Support, kept out of the backup, beside an index that
//  owns them. *Files outside SwiftData need an owner and a sweep* (AGENTS.md):
//  the index is the owner, and ``sweep(keeping:pending:)`` deletes every
//  archive it does not name and every half-download nothing is waiting for.
//
//  An index of its own rather than a SwiftData row. A country belongs to the
//  device, not to a hike, and the tile cache reads the list from MapKit's
//  drawing threads, where a main-actor model cannot be read; what lands here
//  is opened once into ``OfflineCountryArchives`` instead.
//
//  A download is staged first and moved into place only once its SHA-256
//  matches the manifest's, so an archive under the directory's own names is
//  always a whole one.
//

import CryptoKit
import Foundation

nonisolated struct OfflineCountryStore: Sendable {
    static let directoryName = "OfflineCountries"

    /// A downloaded area: the manifest's entry it was downloaded from,
    /// outline and all, so it is listed and drawn with no network, and
    /// whether its zoom 15 came down with it.
    struct Record: Codable, Equatable, Sendable {
        var country: OfflineCountryManifest.Country
        var installedAt: Date
        var hasDetail = false

        /// The files on the device.
        var files: [OfflineCountryManifest.File] { country.files(withDetail: hasDetail) }
        var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    }

    /// A download started and not finished: the area, and which of its
    /// files it asked for.
    struct Pending: Codable, Equatable, Sendable {
        var country: OfflineCountryManifest.Country
        var roles: [OfflineCountryManifest.Role]

        var files: [OfflineCountryManifest.File] { country.files.filter { roles.contains($0.role) } }
    }

    let directory: URL

    var stagingDirectory: URL { directory.appending(path: "Staging", directoryHint: .isDirectory) }
    private var indexURL: URL { directory.appending(path: "index.json") }
    private var pendingURL: URL { directory.appending(path: "pending.json") }
    private var manifestURL: URL { directory.appending(path: "manifest.json") }

    /// The app's own, under Application Support.
    static func applicationSupport() -> Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: root.appending(path: directoryName, directoryHint: .isDirectory))
    }

    /// Makes the directories, kept out of the backup: a country is a
    /// gigabyte the server will give again.
    func prepare() throws {
        for url in [directory, stagingDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = url
            try excluded.setResourceValues(values)
        }
    }

    // MARK: - What is kept

    /// The areas downloaded, leaving out any whose files have gone.
    func installed() -> [Record] {
        let records = read([Record].self, from: indexURL) ?? []
        return records.filter { record in
            record.files.allSatisfy { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        }
    }

    func write(installed records: [Record]) throws {
        try write(records, to: indexURL)
    }

    /// The downloads started and not finished.
    func pending() -> [Pending] {
        read([Pending].self, from: pendingURL) ?? []
    }

    func write(pending downloads: [Pending]) throws {
        try write(downloads, to: pendingURL)
    }

    /// The manifest last fetched, so the list is there with no signal.
    func cachedManifest() -> OfflineCountryManifest? {
        read(OfflineCountryManifest.self, from: manifestURL)
    }

    func cache(_ manifest: OfflineCountryManifest) throws {
        try write(manifest, to: manifestURL)
    }

    func fileURL(for file: OfflineCountryManifest.File) -> URL {
        directory.appending(path: file.fileName)
    }

    func stagedURL(for file: OfflineCountryManifest.File) -> URL {
        stagingDirectory.appending(path: file.fileName)
    }

    // MARK: - Changes

    /// Moves staged files into place. Call only once every one has been
    /// checked with ``isWhole(_:at:)``.
    func install(_ files: [OfflineCountryManifest.File]) throws {
        for file in files {
            let destination = fileURL(for: file)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagedURL(for: file), to: destination)
        }
    }

    /// Deletes `files`, except any that a record in `keeping` still holds.
    func remove(_ files: [OfflineCountryManifest.File], keeping: [Record] = []) {
        let kept = Set(keeping.flatMap(\.files).map(\.fileName))
        for file in files where !kept.contains(file.fileName) {
            try? FileManager.default.removeItem(at: fileURL(for: file))
        }
    }

    /// Deletes every archive the index does not hold, and every staged file
    /// no pending download is for.
    func sweep(keeping records: [Record], pending: [Pending]) {
        let kept = Set(records.flatMap(\.files).map(\.fileName))
        let staged = Set(pending.flatMap(\.files).map(\.fileName))
        for (folder, keep) in [(directory, kept), (stagingDirectory, staged)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(OfflineCountryManifest.File.fileExtension) && !keep.contains(name) {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
        }
    }

    /// Bytes free on the volume for a download the hiker asked for.
    func availableBytes() -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Whether the file at `url` is `file`, to the byte: its size, then its
    /// SHA-256. A gigabyte takes a few seconds, so never on the main actor.
    @concurrent
    static func isWhole(_ file: OfflineCountryManifest.File, at url: URL) async -> Bool {
        assertOffMainThread("Hashing a downloaded country must stay off the main thread")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == file.byteCount
        else { return false }
        return (try? OfflineCountryDigest.sha256(of: url)) == file.sha256
    }

    // MARK: - Files

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// The SHA-256 a manifest gives each file, worked out a few megabytes at a
/// time.
nonisolated enum OfflineCountryDigest {
    static let chunkBytes = 8 * 1024 * 1024

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
