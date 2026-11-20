//
//  OfflineCountryStoreTests.swift
//  OpenHikesTests
//
//  Where the downloaded countries are kept, and the sweep that owns them
//  (*Files outside SwiftData need an owner and a sweep* in AGENTS.md): an
//  archive the index does not name goes, a half-download nothing is waiting
//  for goes, and a record whose file has gone reads as not downloaded.
//

import CryptoKit
import Foundation
@testable import OpenHikes
import Testing

@Suite("Offline country store")
struct OfflineCountryStoreTests {
    @Test("a checked country is moved into place and listed")
    func installs() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let bytes = Data("basemap".utf8)
            let country = OfflineCountryFixture.country(bytes: bytes)
            let file = try #require(country.files.first)
            try bytes.write(to: store.stagedURL(for: file))

            #expect(await OfflineCountryStore.isWhole(file, at: store.stagedURL(for: file)))
            try store.install(country.files)
            let record = OfflineCountryStore.Record(country: country, installedAt: Date(timeIntervalSince1970: 0))
            try store.write(installed: [record])

            #expect(store.installed() == [record])
            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: file).path))
            #expect(!FileManager.default.fileExists(atPath: store.stagedURL(for: file).path))
        }
    }

    @Test("a file of the right size and the wrong bytes is not whole")
    func checksTheDigest() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: Data("basemap".utf8))
            let file = try #require(country.files.first)
            let staged = store.stagedURL(for: file)

            try Data("basemaq".utf8).write(to: staged)
            #expect(!(await OfflineCountryStore.isWhole(file, at: staged)))
            try Data("base".utf8).write(to: staged)
            #expect(!(await OfflineCountryStore.isWhole(file, at: staged)))
        }
    }

    @Test("a record whose file has gone reads as not downloaded")
    func missingFile() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: Data("basemap".utf8))
            try store.write(installed: [OfflineCountryStore.Record(country: country, installedAt: .now)])

            #expect(store.installed().isEmpty)
        }
    }

    @Test("the sweep keeps what the index and the pending downloads name, and nothing else")
    func sweeps() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let kept = OfflineCountryFixture.country(bytes: Data("SI".utf8), id: "SI")
            let pending = OfflineCountryFixture.country(bytes: Data("AT".utf8), id: "AT")
            let keptFile = try #require(kept.files.first)
            let pendingFile = try #require(pending.files.first)
            let orphan = directory.appending(path: "HU-20261117.pmtiles")
            let strayStage = store.stagingDirectory.appending(path: "CZ-20261117.pmtiles")
            // The store's own bookkeeping, which is no archive.
            let index = directory.appending(path: "notes.json")
            for url in [store.fileURL(for: keptFile), store.stagedURL(for: pendingFile), orphan, strayStage, index] {
                try Data("x".utf8).write(to: url)
            }

            store.sweep(
                keeping: [OfflineCountryStore.Record(country: kept, installedAt: .now)],
                pending: [OfflineCountryStore.Pending(country: pending, roles: [.basemap])]
            )

            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: keptFile).path))
            #expect(FileManager.default.fileExists(atPath: store.stagedURL(for: pendingFile).path))
            #expect(FileManager.default.fileExists(atPath: index.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(!FileManager.default.fileExists(atPath: strayStage.path))
        }
    }

    /// An update whose files keep a name — the extras, rebuilt only when the
    /// basemap is — must not delete what the new record still reads.
    @Test("removing a country keeps any file another record still names")
    func removeKeepsShared() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let old = OfflineCountryFixture.country(bytes: Data("old".utf8), build: "20261001")
            var new = OfflineCountryFixture.country(bytes: Data("new".utf8), build: "20261117")
            let shared = OfflineCountryFixture.file(.extras, name: "SI-extras-20261001.pmtiles", bytes: Data("e".utf8))
            var oldWithExtras = old
            oldWithExtras.files.append(shared)
            new.files.append(shared)
            for file in oldWithExtras.files + new.files {
                try Data("x".utf8).write(to: store.fileURL(for: file))
            }

            store.remove(oldWithExtras.files, keeping: [OfflineCountryStore.Record(country: new, installedAt: .now)])

            let oldBasemap = try #require(old.files.first)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: oldBasemap).path))
            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: shared).path))
        }
    }

    /// A country's file is gigabytes. Read into memory whole, Germany's would
    /// have the system end the app while its row said *Checking…*, and the
    /// next launch would start on the same file again.
    @Test("hashing a file holds a chunk of it in memory, not the file")
    func hashesAChunkAtATime() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let chunks = 6
            let url = directory.appending(path: "large.pmtiles")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(OfflineCountryDigest.chunkBytes * chunks))
            try handle.close()
            var expected = SHA256()
            let empty = Data(count: OfflineCountryDigest.chunkBytes)
            for _ in 0..<chunks { expected.update(data: empty) }

            let before = Self.memoryFootprint()
            let digest = try OfflineCountryDigest.sha256(of: url)
            let grown = Int64(Self.memoryFootprint()) - Int64(before)

            #expect(digest == expected.finalize().map { String(format: "%02x", $0) }.joined())
            // Half the file, which is three chunks: well clear of the one a
            // pooled read holds and of the six an unpooled one did, with room
            // for what the rest of the process allocates meanwhile.
            #expect(grown < Int64(OfflineCountryDigest.chunkBytes * chunks / 2))
        }
    }

    /// What the system charges the process with, which is what it ends an
    /// app for.
    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @Test("the directories are kept out of the backup")
    func excludedFromBackup() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory.appending(path: "Countries"))
            try store.prepare()
            for url in [store.directory, store.stagingDirectory] {
                #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            }
        }
    }
}
