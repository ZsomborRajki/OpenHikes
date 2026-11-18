//
//  OfflineCountries.swift
//  OpenHikes
//
//  The countries a hiker can download for the OpenHikes map, and the ones
//  they have (#1482): what *Offline Maps* lists, what the hike screen's
//  *Offline* button offers, and what fills ``OfflineCountryArchives`` for the
//  tile cache to draw from.
//
//  One owner, on the main actor. The list comes from the tile server's
//  manifest, kept on the device so it is there with no signal. A download
//  is two files in the background session (``OfflineCountryDownloading``),
//  each checked against the manifest's SHA-256 before it is moved into place
//  (``OfflineCountryStore``); an update downloads the new build beside the
//  old one and deletes the old one only once the new one is in. Each
//  country's download in progress is an object of its own, so a progress
//  tick re-runs its row and nothing above it.
//
//  A country download is `.speculative`, as a bulk tile download is: it
//  waits for Wi-Fi, and it is refused outright in Low Power Mode or while
//  the device is hot (``TileNetworkPolicy``).
//

import CoreLocation
import Foundation
import Observation
import OpenHikesData
import os

@MainActor
@Observable
final class OfflineCountries {
    enum Failure: Equatable, Sendable {
        /// The connection failed or the server did.
        case connection
        /// The device has no room for it.
        case space
        /// It came down, and is not the file the manifest describes.
        case damaged
        /// Low Power Mode is on, or the device is hot.
        case conserving
    }

    enum ListPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var listPhase = ListPhase.idle
    /// What the server offers that this app can draw.
    private(set) var offered: [OfflineCountryManifest.Country] = []
    /// What is downloaded, by country code.
    private(set) var installed: [String: OfflineCountryStore.Record] = [:]
    /// What is coming down, by country code.
    private(set) var downloads: [String: OfflineCountryDownload] = [:]
    /// The outlines *Offline Maps* draws on the map behind it.
    @ObservationIgnored let outlines = OfflineCountryOutlines()

    @ObservationIgnored private let store: OfflineCountryStore
    @ObservationIgnored private let server: (any OfflineCountryServing)?
    @ObservationIgnored private let downloader: (any OfflineCountryDownloading)?
    @ObservationIgnored private let archives: OfflineCountryArchives?
    @ObservationIgnored private let networkDecision: () -> TileNetworkDecision
    @ObservationIgnored private let archivesDidChange: () -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let freeSpace: () -> Int64?
    @ObservationIgnored private var hasStarted = false

    private static let logger = Logger(subsystem: "OpenHikes", category: "OfflineCountries")
    /// Room left over on the volume after a download, so a country never
    /// takes the last of the hiker's storage.
    static let spareBytes: Int64 = 500 * 1024 * 1024

    init(
        store: OfflineCountryStore,
        server: (any OfflineCountryServing)?,
        downloader: (any OfflineCountryDownloading)?,
        archives: OfflineCountryArchives?,
        networkDecision: @escaping () -> TileNetworkDecision = { .allowed },
        archivesDidChange: @escaping () -> Void = { /* nothing draws from them */ },
        now: @escaping () -> Date = Date.init,
        freeSpace: (() -> Int64?)? = nil
    ) {
        self.store = store
        self.server = server
        self.downloader = downloader
        self.archives = archives
        self.networkDecision = networkDecision
        self.archivesDidChange = archivesDidChange
        self.now = now
        // The volume the store is on, unless a suite says how full it is.
        self.freeSpace = freeSpace ?? { store.availableBytes() }
        downloader?.onEvent = { [weak self] event in self?.handle(event) }
    }

    nonisolated deinit { /* intentionally empty */ }

    /// The app's: the OpenHikes tile server, the background session and the
    /// archives `TileCache.shared` draws from. A suite's launch has none of
    /// them, and lists nothing.
    static func forThisLaunch() -> OfflineCountries {
        guard !AppLaunchEnvironment.isRunningTests else {
            return OfflineCountries(
                store: OfflineCountryStore(directory: FileManager.default.temporaryDirectory),
                server: nil,
                downloader: nil,
                archives: nil
            )
        }
        return OfflineCountries(
            store: .applicationSupport(),
            server: OfflineCountryServer.openHikes,
            downloader: BackgroundCountryDownloader.shared,
            archives: .shared,
            networkDecision: { TileCache.shared.networkDecision(for: .speculative) },
            archivesDidChange: { TileCache.shared.notifyInteractiveFetchUnblocked() }
        )
    }

    /// Whether this launch can list and download countries at all.
    var isAvailable: Bool { server != nil }

    // MARK: - Launch

    /// Opens what is downloaded, picks up what was coming down, and sweeps
    /// what nothing owns. Once a launch.
    func start() async {
        guard !hasStarted, let archives else { return }
        hasStarted = true
        do {
            try store.prepare()
        } catch {
            Self.logger.error("Countries directory: \(String(describing: error), privacy: .public)")
        }
        let records = store.installed()
        installed = Dictionary(records.map { ($0.country.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let cached = store.cachedManifest() { offered = cached.readableCountries }
        archives.replace(with: await Self.open(records, in: store))
        if !records.isEmpty { archivesDidChange() }
        await resumePending()
        await Self.sweep(store, keeping: records, pending: store.pending())
    }

    @concurrent
    private static func sweep(
        _ store: OfflineCountryStore,
        keeping records: [OfflineCountryStore.Record],
        pending: [OfflineCountryManifest.Country]
    ) async {
        store.sweep(keeping: records, pending: pending)
    }

    @concurrent
    private static func open(_ records: [OfflineCountryStore.Record], in store: OfflineCountryStore) async
        -> [OfflineCountryArchives.Country] {
        records.compactMap { record in
            guard let basemap = record.country.files.first(where: { $0.role == .basemap }),
                  let archive = try? PMTilesArchive(contentsOf: store.fileURL(for: basemap))
            else { return nil }
            let extras = record.country.files.first { $0.role == .extras }
                .flatMap { try? PMTilesArchive(contentsOf: store.fileURL(for: $0)) }
            return OfflineCountryArchives.Country(
                id: record.country.id,
                bounds: record.country.bounds,
                basemap: archive,
                extras: extras,
                record: record
            )
        }
    }

    private func resumePending() async {
        let pending = store.pending()
        guard !pending.isEmpty else { return }
        let running = await downloader?.running() ?? [:]
        for country in pending {
            let download = OfflineCountryDownload(country: country, phase: .downloading)
            downloads[country.id] = download
            for file in country.files {
                let staged = store.stagedURL(for: file)
                if FileManager.default.fileExists(atPath: staged.path) {
                    download.landed(file, at: staged)
                } else if let written = running[Self.key(country, file)] {
                    download.wrote(written, of: file.role)
                } else {
                    download.set(.failed(.connection))
                }
            }
            if download.isStaged { await finish(download) }
        }
    }

    // MARK: - The list

    func refreshList() async {
        guard let server, listPhase != .loading else { return }
        listPhase = .loading
        do {
            let manifest = try await server.manifest()
            offered = manifest.readableCountries
            listPhase = .loaded
            try? store.cache(manifest)
        } catch {
            Self.logger.error("Country list: \(String(describing: error), privacy: .public)")
            listPhase = .failed
        }
    }

    // MARK: - Downloads

    /// Starts `country`, or its update. A refusal is shown on its row.
    func download(_ country: OfflineCountryManifest.Country) {
        guard let server, let downloader, downloads[country.id].map(\.hasFailed) ?? true else { return }
        let decision = networkDecision()
        if decision.reason == "low-power-mode" || decision.reason == "thermal" {
            downloads[country.id] = OfflineCountryDownload(country: country, phase: .failed(.conserving))
            return
        }
        if let free = freeSpace(), free < country.byteCount + Self.spareBytes {
            downloads[country.id] = OfflineCountryDownload(country: country, phase: .failed(.space))
            return
        }
        let download = OfflineCountryDownload(
            country: country,
            phase: decision.isAllowed ? .downloading : .waitingForWiFi
        )
        if let previous = downloads[country.id] { download.resume(from: previous) }
        downloads[country.id] = download
        writePending { pending in
            pending.removeAll { $0.id == country.id }
            pending.append(country)
        }
        for file in country.files where download.staged[file.role] == nil {
            downloader.start(
                Self.key(country, file),
                from: server.url(of: file),
                stagingAt: store.stagedURL(for: file),
                resumeData: download.resumeData[file.role]
            )
        }
        if download.isStaged {
            Task { await finish(download) }
        }
    }

    func cancel(_ id: String) {
        guard let download = downloads.removeValue(forKey: id) else { return }
        downloader?.cancel(country: id)
        writePending { $0.removeAll { $0.id == id } }
        for file in download.country.files {
            try? FileManager.default.removeItem(at: store.stagedURL(for: file))
        }
    }

    /// Deletes a downloaded country, and the tiles drawn from it go with
    /// the cache as any tile does.
    func delete(_ id: String) {
        guard let record = installed.removeValue(forKey: id) else { return }
        saveIndex()
        reopenArchives()
        store.remove(record, keeping: Array(installed.values))
    }

    private func handle(_ event: OfflineCountryDownloadEvent) {
        switch event {
        case let .wrote(key, bytes):
            download(for: key)?.wrote(bytes, of: key.role)
        case let .finished(key, staged):
            guard let download = download(for: key),
                  let file = download.country.files.first(where: { $0.role == key.role })
            else { return }
            download.landed(file, at: staged)
            if download.isStaged {
                Task { await finish(download) }
            }
        case let .failed(key, resumeData, cancelled):
            guard !cancelled else { return }
            download(for: key)?.stopped(key.role, resumeData: resumeData)
        }
    }

    private func download(for key: OfflineCountryDownloadKey) -> OfflineCountryDownload? {
        guard let download = downloads[key.country], download.country.build == key.build else { return nil }
        return download
    }

    /// Checks every staged file, then moves the country into place.
    private func finish(_ download: OfflineCountryDownload) async {
        guard download.phase != .checking else { return }
        download.set(.checking)
        let country = download.country
        for file in country.files {
            let staged = store.stagedURL(for: file)
            guard await OfflineCountryStore.isWhole(file, at: staged) else {
                try? FileManager.default.removeItem(at: staged)
                download.discard(file.role)
                return
            }
        }
        guard downloads[country.id] === download else { return }
        do {
            let record = try store.install(country, at: now())
            let previous = installed[country.id]
            installed[country.id] = record
            saveIndex()
            reopenArchives()
            if let previous, previous.country.build != country.build {
                store.remove(previous, keeping: Array(installed.values))
            }
            downloads[country.id] = nil
            writePending { $0.removeAll { $0.id == country.id } }
        } catch {
            let reason = String(describing: error)
            Self.logger.error("Installing \(country.id, privacy: .public): \(reason, privacy: .public)")
            download.set(.failed(.space))
        }
    }

    private func reopenArchives() {
        guard let archives else { return }
        let records = Array(installed.values)
        Task {
            archives.replace(with: await Self.open(records, in: store))
            archivesDidChange()
        }
    }

    private func saveIndex() {
        do {
            try store.write(installed: installed.values.sorted { $0.country.id < $1.country.id })
        } catch {
            Self.logger.error("Countries index: \(String(describing: error), privacy: .public)")
        }
    }

    private func writePending(_ change: (inout [OfflineCountryManifest.Country]) -> Void) {
        var pending = store.pending()
        change(&pending)
        try? store.write(pending: pending)
    }

    private static func key(_ country: OfflineCountryManifest.Country, _ file: OfflineCountryManifest.File)
        -> OfflineCountryDownloadKey {
        OfflineCountryDownloadKey(country: country.id, build: country.build, role: file.role)
    }
}

// MARK: - What the screens read

extension OfflineCountries {
    /// Every country to list: those offered, and those downloaded that no
    /// longer are, by name in the hiker's language.
    var listed: [OfflineCountryManifest.Country] {
        var byID = Dictionary(offered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in installed.values where byID[record.country.id] == nil {
            byID[record.country.id] = record.country
        }
        return byID.values.sorted { left, right in
            Self.name(of: left.id).localizedStandardCompare(Self.name(of: right.id)) == .orderedAscending
        }
    }

    /// The bytes every downloaded country takes.
    var installedByteCount: Int64 {
        installed.values.reduce(0) { $0 + $1.country.byteCount }
    }

    func isInstalled(_ id: String) -> Bool { installed[id] != nil }

    /// Whether the server has a newer build of a country downloaded.
    func update(for id: String) -> OfflineCountryManifest.Country? {
        guard let record = installed[id],
              let newer = offered.first(where: { $0.id == id }),
              newer.build > record.country.build
        else { return nil }
        return newer
    }

    /// The country's name in the hiker's language.
    nonisolated static func name(of id: String) -> String {
        Locale.current.localizedString(forRegionCode: id) ?? id
    }

    /// *Offline Maps*' three sections: what is downloaded or coming down,
    /// what is near `coordinate`, then the rest. Each country once, in the
    /// first section it belongs to.
    func sections(
        of listed: [OfflineCountryManifest.Country],
        near coordinate: CLLocationCoordinate2D?
    ) -> OfflineCountrySections {
        let held = listed.filter { isInstalled($0.id) || downloads[$0.id] != nil }
        let heldIDs = Set(held.map(\.id))
        let nearby = coordinate.map { nearby($0) }?.filter { !heldIDs.contains($0.id) } ?? []
        let nearbyIDs = Set(nearby.map(\.id))
        let rest = listed.filter { !heldIDs.contains($0.id) && !nearbyIDs.contains($0.id) }
        return OfflineCountrySections(held: held, nearby: nearby, rest: rest)
    }

    /// The countries a saved line passes through, tested every so many
    /// points: a country is tens of kilometres across, so one point every
    /// few hundred metres of a long trail still finds every one it reaches.
    func countries(
        alongRoute route: [RouteCoordinate],
        testing points: Int = 400
    ) -> [OfflineCountryManifest.Country] {
        guard !route.isEmpty else { return [] }
        let step = max(route.count / points, 1)
        var sampled = stride(from: 0, to: route.count, by: step).map { route[$0].clCoordinate }
        if let last = route.last { sampled.append(last.clCoordinate) }
        return countries(along: sampled)
    }

    /// The countries a line passes through, in the order it reaches them.
    func countries(along coordinates: [CLLocationCoordinate2D]) -> [OfflineCountryManifest.Country] {
        let candidates = listed
        var found: [OfflineCountryManifest.Country] = []
        for coordinate in coordinates {
            for country in candidates where !found.contains(where: { $0.id == country.id })
                && country.contains(longitude: coordinate.longitude, latitude: coordinate.latitude) {
                found.append(country)
            }
        }
        return found
    }

    /// The countries nearest `coordinate`: the one it is in first, then
    /// those within `kilometers` of it.
    func nearby(
        _ coordinate: CLLocationCoordinate2D,
        within kilometers: Double = 250
    ) -> [OfflineCountryManifest.Country] {
        let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distances = listed.map { country -> (OfflineCountryManifest.Country, Double) in
            if country.contains(longitude: coordinate.longitude, latitude: coordinate.latitude) { return (country, 0) }
            let bounds = country.bounds
            let nearest = CLLocation(
                latitude: min(max(coordinate.latitude, bounds.south), bounds.north),
                longitude: min(max(coordinate.longitude, bounds.west), bounds.east)
            )
            return (country, point.distance(from: nearest) / 1000)
        }
        return distances.filter { $0.1 <= kilometers }.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// What *Offline Maps* lists, in the order it lists it.
struct OfflineCountrySections: Equatable {
    var held: [OfflineCountryManifest.Country]
    var nearby: [OfflineCountryManifest.Country]
    var rest: [OfflineCountryManifest.Country]
}
