//
//  FieldMetricsStoreTests.swift
//  OpenHikesTests
//
//  The store keeps files on disk that nothing else owns, which is exactly the
//  shape of thing this repository has been bitten by before — see the orphan
//  sweeps behind `TileCache.trimCache(claimedBy:)` and
//  `HikePhotoStore.reclaimOrphans(claimedBy:)`. The defence here is different
//  and simpler: the directory is bounded on every write, by count and by
//  bytes, so it cannot grow without limit even if nothing ever prunes it.
//
//  These tests are what says the bound actually holds. Every one of them
//  injects its own temporary directory rather than touching
//  `FieldMetricsStore.shared`, for the same reason a tile suite builds a
//  `TileSandbox`: the singleton belongs to the app, and suites run in parallel.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Field metrics store")
nonisolated struct FieldMetricsStoreTests {
    /// A directory of this suite's own, removed when the test ends.
    private struct Sandbox: ~Copyable {
        let directory: URL

        init() {
            directory = URL.temporaryDirectory.appending(
                path: "FieldMetricsTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func report(
        receivedAt: Date,
        version: String = "1.0",
        signposts: [SignpostDigest] = []
    ) -> FieldMetricsReport {
        FieldMetricsReport(
            receivedAt: receivedAt,
            periodStart: receivedAt.addingTimeInterval(-86_400),
            periodEnd: receivedAt,
            appVersion: version,
            content: .metrics(FieldMetricsDigest(cpuSeconds: 42, signposts: signposts))
        )
    }

    private static func bulkyDiagnosticReport(receivedAt: Date, bytes: Int) -> FieldMetricsReport {
        // Stands in for a real call-stack tree, which is where the byte budget
        // actually goes: a crash payload dwarfs a metrics digest.
        let filler = Data(repeating: 0x41, count: bytes)
        return FieldMetricsReport(
            receivedAt: receivedAt,
            periodStart: receivedAt.addingTimeInterval(-86_400),
            periodEnd: receivedAt,
            appVersion: "1.0",
            content: .diagnostics([FieldDiagnosticDigest(kind: .crash, reason: "test")]),
            rawJSON: filler
        )
    }

    /// Every file the store owns, decodable or not. `reports()` cannot answer
    /// this: it hides exactly the files these tests are about.
    private static func storedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        .filter { $0.pathExtension == "json" }
    }

    /// Writes a file the current ``FieldMetricsReport`` cannot decode, as an
    /// older shape of the type would leave behind.
    @discardableResult private static func writeUndecodableFile(
        in directory: URL,
        bytes: Int = 8
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(
            path: "\(UUID().uuidString).json",
            directoryHint: .notDirectory
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test("an empty store reports nothing and exports nothing")
    func emptyStore() async {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory)

        #expect(await store.reports().isEmpty)
        // A share sheet offering an empty file is a bug report waiting to
        // happen, so this returns nil rather than an empty archive.
        #expect(await store.exportArchive(into: sandbox.directory, named: "export") == nil)
    }

    @Test("a saved report survives a round trip through disk")
    func roundTrip() async {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory)
        let original = Self.report(
            receivedAt: Date(),
            version: "2.4",
            signposts: [SignpostDigest(name: "RecordingSession", category: "Hiking", count: 3)]
        )

        #expect(await store.save(original))

        let loaded = await store.reports()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == original.id)
        #expect(loaded.first?.appVersion == "2.4")
        #expect(loaded.first?.digest?.cpuSeconds == 42)
        #expect(loaded.first?.digest?.signposts.first?.count == 3)
    }

    @Test("reports come back newest first")
    func newestFirst() async {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for day in 0..<3 {
            await store.save(
                Self.report(
                    receivedAt: base.addingTimeInterval(Double(day) * 86_400),
                    version: "1.\(day)"
                )
            )
        }

        let loaded = await store.reports()
        #expect(loaded.map(\.appVersion) == ["1.2", "1.1", "1.0"])
    }

    @Test("the retention limit drops the oldest report, not the newest")
    func retentionLimit() async {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory, retentionLimit: 3)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for day in 0..<6 {
            await store.save(
                Self.report(
                    receivedAt: base.addingTimeInterval(Double(day) * 86_400),
                    version: "1.\(day)"
                )
            )
        }

        let loaded = await store.reports()
        #expect(loaded.count == 3)
        // The three most recent, in the order the screen shows them.
        #expect(loaded.map(\.appVersion) == ["1.5", "1.4", "1.3"])
    }

    @Test("the byte limit prunes independently of the count")
    func byteLimit() async {
        let sandbox = Sandbox()
        // Generous count, tight bytes: only the byte budget can be doing the
        // pruning here, which is the point of it existing separately.
        let store = FieldMetricsStore(
            directory: sandbox.directory,
            retentionLimit: 100,
            byteLimit: 40_000
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<6 {
            await store.save(
                Self.bulkyDiagnosticReport(
                    receivedAt: base.addingTimeInterval(Double(index) * 86_400),
                    bytes: 12_000
                )
            )
        }

        let loaded = await store.reports()
        #expect(loaded.count < 6)
        #expect(!loaded.isEmpty)
    }

    @Test("the newest report is kept even when it alone exceeds the byte limit")
    func newestSurvivesAnOversizedPayload() async {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(
            directory: sandbox.directory,
            retentionLimit: 100,
            byteLimit: 1000
        )

        // A single diagnostic payload larger than the whole budget. Trimming
        // to zero would mean a crash report is silently discarded at the exact
        // moment it is most worth having, so the newest is never pruned.
        await store.save(Self.bulkyDiagnosticReport(receivedAt: Date(), bytes: 50_000))

        let loaded = await store.reports()
        #expect(loaded.count == 1)
        #expect(loaded.first?.diagnostics.first?.kind == .crash)
    }

    @Test("deleting one report leaves the others alone")
    func deleteOne() async {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let keep = Self.report(receivedAt: base, version: "keep")
        let drop = Self.report(receivedAt: base.addingTimeInterval(86_400), version: "drop")

        await store.save(keep)
        await store.save(drop)
        await store.delete(drop.id)

        let loaded = await store.reports()
        #expect(loaded.map(\.appVersion) == ["keep"])
    }

    @Test("deleting everything empties the directory")
    func deleteAll() async throws {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory)

        await store.save(Self.report(receivedAt: Date()))
        await store.save(Self.report(receivedAt: Date().addingTimeInterval(60)))
        // A file from an older shape of the type. Deleting by what decodes
        // would leave this one on disk for good, and `reports()` would keep
        // saying the store is empty while it sat there.
        try Self.writeUndecodableFile(in: sandbox.directory)
        await store.deleteAll()

        #expect(await store.reports().isEmpty)
        #expect(try Self.storedFiles(in: sandbox.directory).isEmpty)
    }

    @Test("a file that no longer decodes still occupies a retention slot")
    func undecodableFilesCountTowardRetention() async throws {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory, retentionLimit: 2)

        for _ in 0..<4 {
            try Self.writeUndecodableFile(in: sandbox.directory)
        }
        // Newest by a clear margin, so the sweep has to reach past it into the
        // undecodable files rather than the other way round.
        await store.save(Self.report(receivedAt: Date().addingTimeInterval(3600), version: "good"))

        #expect(try Self.storedFiles(in: sandbox.directory).count == 2)
        #expect(await store.reports().map(\.appVersion) == ["good"])
    }

    @Test("a file that no longer decodes still costs its bytes")
    func undecodableFilesCountTowardByteLimit() async throws {
        let sandbox = Sandbox()
        // Generous count, tight bytes: only the byte budget can prune here.
        let byteLimit = 40_000
        let store = FieldMetricsStore(
            directory: sandbox.directory,
            retentionLimit: 100,
            byteLimit: byteLimit
        )

        // Three old-schema files that between them already blow the budget.
        for _ in 0..<3 {
            try Self.writeUndecodableFile(in: sandbox.directory, bytes: 20_000)
        }
        await store.save(
            Self.bulkyDiagnosticReport(
                receivedAt: Date().addingTimeInterval(3600),
                bytes: 12_000
            )
        )

        let total = try Self.storedFiles(in: sandbox.directory)
            .reduce(0) { sum, url in
                sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        #expect(total <= byteLimit)
        #expect(await store.reports().count == 1)
    }

    @Test("an export contains every stored report")
    func export() async throws {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory)
        let destination = sandbox.directory.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await store.save(Self.report(receivedAt: Date(), version: "1.0"))
        await store.save(Self.report(receivedAt: Date().addingTimeInterval(60), version: "1.1"))

        let url = await store.exportArchive(into: destination, named: "OpenHikes-metrics")
        let archive = try #require(url)
        #expect(archive.pathExtension == "json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([FieldMetricsReport].self, from: Data(contentsOf: archive))
        #expect(decoded.count == 2)
        #expect(Set(decoded.map(\.appVersion)) == ["1.0", "1.1"])
    }

    @Test("a file that no longer decodes is skipped rather than fatal")
    func corruptFileIsSkipped() async throws {
        let sandbox = Sandbox()
        let store = FieldMetricsStore(directory: sandbox.directory)

        await store.save(Self.report(receivedAt: Date(), version: "good"))
        try Self.writeUndecodableFile(in: sandbox.directory)

        // A diagnostics screen that refuses to open is strictly worse than one
        // missing a stale entry, and there is nothing here worth migrating.
        let loaded = await store.reports()
        #expect(loaded.map(\.appVersion) == ["good"])
    }
}
