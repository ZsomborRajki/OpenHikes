//
//  OfflineCountryStoreTests.swift
//  OpenHikesTests
//
//  Where the downloaded countries are kept, and the sweep that owns them
//  (*Files outside SwiftData need an owner and a sweep* in AGENTS.md): an
//  archive the index does not name goes, a half-download nothing is waiting
//  for goes, and a record whose file has gone reads as not downloaded.
//

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
