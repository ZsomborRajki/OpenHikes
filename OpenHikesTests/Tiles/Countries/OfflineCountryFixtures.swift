//
//  OfflineCountryFixtures.swift
//  OpenHikesTests
//
//  What the downloaded-country suites build on: a country as the manifest
//  lists it, a real PMTiles archive written the way the cutting tool writes
//  one, a directory of the suite's own for the store, and stand-ins for the
//  tile server and the background session, so no suite reaches either.
//

import CryptoKit
import Foundation
@testable import OpenHikes
import Synchronization

// swiftlint:disable no_magic_numbers

nonisolated enum OfflineCountryFixture {
    /// A square of Slovenia's size around Ljubljana, as its outline too.
    static let bounds = OfflineCountryManifest.Bounds(west: 13.3, south: 45.4, east: 16.6, north: 46.9)
    /// A square north of it, sharing its northern edge, standing for Austria.
    static let northernBounds = OfflineCountryManifest.Bounds(west: 9.5, south: 46.9, east: 17.2, north: 49.0)

    /// `bounds` as an outline: one ring, closed.
    static func outline(of bounds: OfflineCountryManifest.Bounds) -> [[[Double]]] {
        [
            [
                [bounds.west, bounds.south], [bounds.east, bounds.south],
                [bounds.east, bounds.north], [bounds.west, bounds.north],
                [bounds.west, bounds.south],
            ],
        ]
    }

    /// An area whose basemap is `bytes`, and its other files the others
    /// given, named and summed as the manifest would name and sum them. A
    /// region when `group` names its country.
    static func country(
        bytes: Data,
        id: String = "SI",
        build: String = "20261117",
        extras: Data? = nil,
        detail: Data? = nil,
        detailExtras: Data? = nil,
        group: String? = nil,
        names: [String: String] = [:],
        schema: Int = OfflineCountryManifest.readableSchema
    ) -> OfflineCountryManifest.Country {
        var files = [file(.basemap, name: "\(id)-\(build).pmtiles", bytes: bytes)]
        for (role, infix, data) in [
            (OfflineCountryManifest.Role.extras, "extras-", extras),
            (.detail, "detail-", detail),
            (.detailExtras, "detail-extras-", detailExtras),
        ] {
            if let data { files.append(file(role, name: "\(id)-\(infix)\(build).pmtiles", bytes: data)) }
        }
        return OfflineCountryManifest.Country(
            id: id,
            group: group,
            names: names,
            build: build,
            schema: schema,
            bounds: bounds,
            outline: outline(of: bounds),
            files: files
        )
    }

    /// A second country, Austria, filling ``northernBounds``.
    static func northernCountry(bytes: Data) -> OfflineCountryManifest.Country {
        var country = country(bytes: bytes, id: "AT")
        country.bounds = northernBounds
        country.outline = outline(of: northernBounds)
        return country
    }

    static func file(_ role: OfflineCountryManifest.Role, name: String, bytes: Data) -> OfflineCountryManifest.File {
        OfflineCountryManifest.File(
            role: role,
            path: "countries/\(name)",
            byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            minimumZoom: role.isDetail ? 15 : 0,
            maximumZoom: role.isDetail ? 15 : 14
        )
    }

    static func manifest(_ countries: [OfflineCountryManifest.Country]) -> OfflineCountryManifest {
        OfflineCountryManifest(version: OfflineCountryManifest.currentVersion, countries: countries)
    }

    /// An archive holding `tiles`, each its own bytes, laid out as the tool
    /// lays one out: leaf directories once the root would pass its 16 KiB.
    static func archive(_ tiles: [VectorTileAddress: Data], maximumZoom: Int, minimumZoom: Int = 0) -> Data {
        let sorted = tiles.map { (id: PMTilesTileID.id(z: $0.key.z, x: $0.key.x, y: $0.key.y), bytes: $0.value) }
            .sorted { $0.id < $1.id }
        var data = Data()
        var entries: [PMTilesEntry] = []
        for tile in sorted {
            let length = UInt64(tile.bytes.count)
            entries.append(PMTilesEntry(tileID: tile.id, offset: UInt64(data.count), length: length, runLength: 1))
            data.append(tile.bytes)
        }
        var header = PMTilesHeader()
        header.minimumZoom = UInt8(minimumZoom)
        header.maximumZoom = UInt8(maximumZoom)
        header.tileType = 1
        let prefix = PMTilesLayout.prefix(
            header: header,
            entries: entries,
            metadata: Array("{}".utf8),
            tileDataLength: UInt64(data.count)
        )
        return Data(prefix) + data
    }

    /// A directory of the calling suite's own, gone when `body` returns.
    static func withDirectory<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "offline-countries-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }
}

// swiftlint:enable no_magic_numbers

/// The tile server, answering with a manifest the suite gives it.
nonisolated final class StubCountryServer: OfflineCountryServing {
    struct Unreachable: Error {}

    /// Whether it keeps requests waiting, and those it keeps.
    private struct Hold {
        var isOn = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let answer: Mutex<OfflineCountryManifest?>
    private let held = Mutex(Hold())

    init(_ manifest: OfflineCountryManifest?) {
        answer = Mutex(manifest)
    }

    func serve(_ manifest: OfflineCountryManifest?) {
        answer.withLock { $0 = manifest }
    }

    /// Keeps every request waiting until ``release()``: a read still out.
    func hold() {
        held.withLock { $0.isOn = true }
    }

    /// Answers every request waiting, with what it serves now.
    func release() {
        let waiting = held.withLock { hold in
            defer { hold = Hold() }
            return hold.waiting
        }
        for request in waiting { request.resume() }
    }

    @concurrent
    func manifest() async throws -> OfflineCountryManifest {
        await withCheckedContinuation { request in
            let isHeld = held.withLock { hold in
                if hold.isOn { hold.waiting.append(request) }
                return hold.isOn
            }
            if !isHeld { request.resume() }
        }
        guard let manifest = answer.withLock({ $0 }) else { throw Unreachable() }
        return manifest
    }

    func url(of file: OfflineCountryManifest.File) -> URL {
        URL(filePath: "/countries").appending(path: file.fileName)
    }
}

/// The background session: records what was asked of it, and delivers what
/// the suite says came down.
@MainActor
final class StubCountryDownloader: OfflineCountryDownloading {
    struct Request {
        let key: OfflineCountryDownloadKey
        let staged: URL
        let resumeData: Data?
    }

    var onEvent: ((OfflineCountryDownloadEvent) -> Void)?
    private(set) var requests: [Request] = []
    private(set) var cancelled: [String] = []
    /// What a relaunch finds still coming down.
    var stillRunning: [OfflineCountryDownloadKey: Int64] = [:]

    nonisolated deinit { /* intentionally empty */ }

    func start(_ key: OfflineCountryDownloadKey, from url: URL, stagingAt staged: URL, resumeData: Data?) {
        requests.append(Request(key: key, staged: staged, resumeData: resumeData))
    }

    func cancel(country: String) {
        cancelled.append(country)
    }

    func running() -> [OfflineCountryDownloadKey: Int64] {
        stillRunning
    }

    /// The last request for `role`'s file came down as `bytes`.
    func land(_ role: OfflineCountryManifest.Role, as bytes: Data) throws {
        guard let request = requests.last(where: { $0.key.role == role }) else { return }
        try FileManager.default.createDirectory(
            at: request.staged.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: request.staged)
        onEvent?(.finished(request.key, request.staged))
    }

    func progress(_ role: OfflineCountryManifest.Role, _ bytes: Int64) {
        guard let request = requests.last(where: { $0.key.role == role }) else { return }
        onEvent?(.wrote(request.key, bytes))
    }

    func fail(_ role: OfflineCountryManifest.Role, resumeData: Data?) {
        guard let request = requests.last(where: { $0.key.role == role }) else { return }
        onEvent?(.failed(request.key, resumeData: resumeData, cancelled: false))
    }
}

/// A model over a store of the suite's own, a stand-in server offering
/// `offered`, and a stand-in session, started and with its list loaded.
@MainActor
struct OfflineCountryHarness {
    let countries: OfflineCountries
    let downloader: StubCountryDownloader
    let archives: OfflineCountryArchives
    let server: StubCountryServer
    let store: OfflineCountryStore

    static func make(
        in directory: URL,
        offering offered: [OfflineCountryManifest.Country],
        defaults: UserDefaults? = nil
    ) async -> Self {
        let madeStore = OfflineCountryStore(directory: directory)
        let madeServer = StubCountryServer(OfflineCountryFixture.manifest(offered))
        let madeDownloader = StubCountryDownloader()
        let madeArchives = OfflineCountryArchives()
        let model = OfflineCountries(
            store: madeStore,
            server: madeServer,
            downloader: madeDownloader,
            archives: madeArchives,
            defaults: defaults,
            freeSpace: { 1 << 40 }
        )
        await model.start()
        await model.refreshList()
        return Self(
            countries: model,
            downloader: madeDownloader,
            archives: madeArchives,
            server: madeServer,
            store: madeStore
        )
    }

    /// Lands every file the last requests asked for, with the bytes given.
    func land(_ bytes: [OfflineCountryManifest.Role: Data]) throws {
        for (role, data) in bytes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try downloader.land(role, as: data)
        }
    }

    func fileExists(_ file: OfflineCountryManifest.File) -> Bool {
        FileManager.default.fileExists(atPath: store.fileURL(for: file).path)
    }
}
