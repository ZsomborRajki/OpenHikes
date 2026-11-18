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

    /// A downloaded country: the manifest's entry it was downloaded from,
    /// outline and all, so it is listed and drawn with no network.
    struct Record: Codable, Equatable, Sendable {
        var country: OfflineCountryManifest.Country
        var installedAt: Date
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

    /// The countries downloaded, leaving out any whose file has gone.
    func installed() -> [Record] {
        let records = read([Record].self, from: indexURL) ?? []
        return records.filter { record in
            record.country.files.allSatisfy { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        }
    }

    func write(installed records: [Record]) throws {
        try write(records, to: indexURL)
    }

    /// The countries a download was started for and has not finished.
    func pending() -> [OfflineCountryManifest.Country] {
        read([OfflineCountryManifest.Country].self, from: pendingURL) ?? []
    }

    func write(pending countries: [OfflineCountryManifest.Country]) throws {
        try write(countries, to: pendingURL)
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

    /// Moves a country's staged files into place. Call only once every one
    /// has been checked with ``isWhole(_:at:)``.
    func install(_ country: OfflineCountryManifest.Country, at date: Date) throws -> Record {
        for file in country.files {
            let destination = fileURL(for: file)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagedURL(for: file), to: destination)
        }
        return Record(country: country, installedAt: date)
    }

    /// Deletes `record`'s files, except any that `keeping` also names.
    func remove(_ record: Record, keeping: [Record] = []) {
        let kept = Set(keeping.flatMap(\.country.files).map(\.fileName))
        for file in record.country.files where !kept.contains(file.fileName) {
            try? FileManager.default.removeItem(at: fileURL(for: file))
        }
    }

    /// Deletes every archive the index does not name, and every staged file
    /// no pending download is for.
    func sweep(keeping records: [Record], pending: [OfflineCountryManifest.Country]) {
        let kept = Set(records.flatMap(\.country.files).map(\.fileName))
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
