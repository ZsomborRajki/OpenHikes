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
//  always a whole one. Until the index names it, a file that came down is
//  one the download can install again: an install that fails part of the
//  way, or that the index then cannot be written for, puts its files back
//  in staging (#1528), where the next try, or the next launch, finds them
//  still whole rather than asking for gigabytes again.
//
//  A list that is there and cannot be read is not an empty one. The device
//  may not have been unlocked since it restarted, when a launch the system
//  makes for a location or a finished download can list and delete files and
//  read none; or the list may be a later build's, with a file of a role this
//  one does not know, which is read strictly here because it is on the
//  device. So reading says which (``List``), and a launch that cannot read
//  sweeps nothing and writes over neither.
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

    /// One of the store's two lists, as it could be read.
    enum List<Element: Sendable>: Sendable {
        /// What it names: nothing, where none was kept.
        case holding([Element])
        /// One is kept, and it cannot be read.
        case unreadable
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

    /// The index: the areas downloaded, leaving out any whose files have
    /// gone, or ``List/unreadable`` where one is kept that cannot be read,
    /// which names files nobody can list.
    func index() -> List<Record> {
        guard case let .holding(records) = list(Record.self, at: indexURL) else { return .unreadable }
        return .holding(records.filter { record in
            record.files.allSatisfy { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        })
    }

    /// The areas downloaded, as far as can be read.
    func installed() -> [Record] {
        guard case let .holding(records) = index() else { return [] }
        return records
    }

    func write(installed records: [Record]) throws {
        try write(records, to: indexURL)
    }

    /// The downloads started and not finished, or ``List/unreadable``
    /// where their list is kept and cannot be read.
    func downloadsUnderWay() -> List<Pending> {
        list(Pending.self, at: pendingURL)
    }

    /// The downloads started and not finished, as far as can be read.
    func pending() -> [Pending] {
        guard case let .holding(downloads) = downloadsUnderWay() else { return [] }
        return downloads
    }

    func write(pending downloads: [Pending]) throws {
        try write(downloads, to: pendingURL)
    }

    /// The manifest last fetched, so the list is there with no signal.
    func cachedManifest() -> OfflineCountryManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? OfflineCountryManifest.catalog(from: data)
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

    /// Moves staged files into place, all or none: where one cannot be
    /// moved, those moved before it go back to staging, and the error is
    /// thrown. Call only once every one has been checked with
    /// ``isWhole(_:at:)``.
    func install(_ files: [OfflineCountryManifest.File]) throws {
        var moved: [OfflineCountryManifest.File] = []
        do {
            for file in files {
                let destination = fileURL(for: file)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: stagedURL(for: file), to: destination)
                moved.append(file)
            }
        } catch {
            unstage(moved)
            throw error
        }
    }

    /// Moves installed files back to staging, except any a record in
    /// `keeping` still holds: files the index could not be written to name,
    /// which the next try installs from there rather than bringing down
    /// again. One that cannot be moved back is deleted, because nothing
    /// names it, and the download it was for asks for it again.
    func unstage(_ files: [OfflineCountryManifest.File], keeping: [Record] = []) {
        let kept = Set(keeping.flatMap(\.files).map(\.fileName))
        for file in files where !kept.contains(file.fileName) {
            let installed = fileURL(for: file)
            let staged = stagedURL(for: file)
            do {
                if FileManager.default.fileExists(atPath: staged.path) {
                    try FileManager.default.removeItem(at: staged)
                }
                try FileManager.default.moveItem(at: installed, to: staged)
            } catch {
                try? FileManager.default.removeItem(at: installed)
            }
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

    /// The list kept at `url`: empty where no file is there, and unreadable
    /// where one is and it cannot be read or is not such a list.
    private func list<Element: Decodable>(_ type: Element.Type, at url: URL) -> List<Element> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .holding([]) }
        return read([Element].self, from: url).map { .holding($0) } ?? .unreadable
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// The SHA-256 a manifest gives each file, worked out a few megabytes at a
/// time.
nonisolated enum OfflineCountryDigest {
    static let chunkBytes = 8 * 1024 * 1024

    /// A pool for each chunk, because `FileHandle` hands one back
    /// autoreleased and nothing on a task's thread drains until the task
    /// lets go of it: without one, every chunk read was still in memory when
    /// the last was hashed, which for a country is gigabytes.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var isAtEnd = false
        while !isAtEnd {
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else {
                    isAtEnd = true
                    return
                }
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
