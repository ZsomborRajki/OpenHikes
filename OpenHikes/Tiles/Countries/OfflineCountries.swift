//
//  OfflineCountries.swift
//  OpenHikes
//
//  The areas a hiker can download for the OpenHikes map, and the ones they
//  have (#1482): what *Offline Maps* lists, what the hike screen's *Offline*
//  button offers, and what fills ``OfflineCountryArchives`` for the tile cache
//  to draw from. An area is a country, or a state or province of one of the
//  few too big for one download.
//
//  One owner, on the main actor. The list comes from the tile server's
//  manifest, kept on the device so it is there with no signal. A download is
//  an area's files in the background session (``OfflineCountryDownloading``),
//  each checked against the manifest's SHA-256 before it is moved into place
//  (``OfflineCountryStore``); an update downloads the new build beside the old
//  one and deletes the old one only once the new one is in. Each download in
//  progress is an object of its own, so a progress tick re-runs its row and
//  nothing above it. What the screens read is `OfflineCountries+Listing.swift`.
//
//  *Extra Detail* decides which files an area takes: to zoom 14 always, and
//  zoom 15, with its buildings and most of its points, when it is on.
//  Turning it on brings zoom 15 to every area already down; turning it off
//  deletes it from them and keeps the areas (``reconcile()``). A file the
//  list names for a build already down that the area did not take is
//  brought the same way, and ahead of any zoom 15 the area lacks: the day
//  hikes' squares, which builds already listed gained after many areas were
//  down.
//
//  A download is `.speculative`, as a bulk tile download is: it waits for
//  Wi-Fi, and it is refused outright in Low Power Mode or while the device is
//  hot (``TileNetworkPolicy``).
//
//  What the index names is the area's whether or not the map can open it
//  (#1534). A file that will not open, cut short or gone or refused by the
//  device for now, is offered again on its own (``unopenable``), and opened
//  again each time the app comes to the front, so a failure that passes
//  deletes nothing that was checked. Only an area whose basemap opened is
//  drawn, and only that counts as saved.
//

import CoreLocation
import Foundation
import Observation
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

    /// What this launch has read of the device's own two lists, the index
    /// and the downloads under way.
    enum Holdings: Equatable {
        /// Not yet, or not at all on a launch that keeps no archives.
        case unread
        case read
        /// One is kept and cannot be read, so nothing downloads until
        /// ``start()`` reads both: a download writes both, and written over
        /// one this launch cannot read, it would leave what that one names
        /// to the next sweep.
        case unreadable
    }

    typealias Country = OfflineCountryManifest.Country
    typealias Record = OfflineCountryStore.Record

    private(set) var listPhase = ListPhase.idle
    /// What the server offers that this app can draw.
    private(set) var offered: [Country] = [] {
        // Every read of the list writes it, mostly with what it held.
        didSet { if offered != oldValue { catalogRevision &+= 1 } }
    }
    /// What is downloaded, by area code.
    private(set) var installed: [String: Record] = [:] {
        didSet { catalogRevision &+= 1 }
    }
    /// Counts the changes to what ``listed`` is read from. A screen that
    /// keeps something worked out from the list keys it to this rather than
    /// to the areas' codes: a new build of an area keeps its code and
    /// changes its files, its size and maybe its outline.
    private(set) var catalogRevision = 0
    /// What is coming down, by area code.
    private(set) var downloads: [String: OfflineCountryDownload] = [:]
    /// Whether an area brings its zoom 15 too: *Extra Detail*.
    private(set) var includesDetail: Bool
    private(set) var holdings = Holdings.unread
    /// The files of each downloaded area that the archives' last opening
    /// could not open, by area code: still the index's, and on no map.
    private(set) var unopenable: [String: Set<OfflineCountryManifest.Role>] = [:]
    /// The outlines *Offline Maps* draws on the map behind it.
    @ObservationIgnored let outlines = OfflineCountryOutlines()

    @ObservationIgnored private let store: OfflineCountryStore
    @ObservationIgnored private let server: (any OfflineCountryServing)?
    @ObservationIgnored private let downloader: (any OfflineCountryDownloading)?
    @ObservationIgnored private let archives: OfflineCountryArchives?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let networkDecision: () -> TileNetworkDecision
    @ObservationIgnored private let archivesDidChange: () -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let freeSpace: () -> Int64?
    /// Whether a staged file is the file the manifest names, to the byte —
    /// ``OfflineCountryStore/isWhole(_:at:)``, unless a suite holds the
    /// answer back.
    @ObservationIgnored private let checksFile: @Sendable (OfflineCountryManifest.File, URL) async -> Bool
    /// The read of the server's list under way, which a second caller waits
    /// for rather than going by the list before it.
    @ObservationIgnored private var listRead: Task<Void, Never>?
    /// Counts the openings of the archives, so an opening that finishes after
    /// a later one is dropped rather than put back over it.
    @ObservationIgnored private var archiveGeneration = 0
    /// Whether the launch is still picking up what was coming down. Until it
    /// has, an area it is bringing has no row in ``downloads``, and bringing
    /// the areas to the list would ask for that file a second time, to the
    /// same staging path, so ``reconcile()`` waits for the launch's own.
    @ObservationIgnored private var isRecovering = false

    nonisolated static let logger = Logger(subsystem: "OpenHikes", category: "OfflineCountries")
    /// Room left over on the volume after a download, so an area never takes
    /// the last of the hiker's storage.
    static let spareBytes: Int64 = 500 * 1024 * 1024

    init(
        store: OfflineCountryStore,
        server: (any OfflineCountryServing)?,
        downloader: (any OfflineCountryDownloading)?,
        archives: OfflineCountryArchives?,
        defaults: UserDefaults? = nil,
        networkDecision: @escaping () -> TileNetworkDecision = { .allowed },
        archivesDidChange: @escaping () -> Void = { /* nothing draws from them */ },
        now: @escaping () -> Date = Date.init,
        freeSpace: (() -> Int64?)? = nil,
        checksFile: @escaping @Sendable (OfflineCountryManifest.File, URL) async -> Bool = { file, url in
            await OfflineCountryStore.isWhole(file, at: url)
        }
    ) {
        self.store = store
        self.server = server
        self.downloader = downloader
        self.archives = archives
        self.defaults = defaults
        self.networkDecision = networkDecision
        self.archivesDidChange = archivesDidChange
        self.now = now
        // The volume the store is on, unless a suite says how full it is.
        self.freeSpace = freeSpace ?? { store.availableBytes() }
        self.checksFile = checksFile
        includesDetail = defaults?.object(forKey: SettingsKey.offlineCountriesDetail) as? Bool
            ?? SettingsDefault.offlineCountriesDetail
        downloader?.onEvent = { [weak self] event in self?.handle(event) }
    }

    nonisolated deinit { /* intentionally empty */ }

    /// Whether this launch can list and download areas at all: it has a
    /// server, and the device's own lists are not ones it cannot read.
    var isAvailable: Bool { server != nil && holdings != .unreadable }

    /// Brings every area down, and not coming down, to *Extra Detail*'s
    /// setting, and to the files the list now names for its build. A
    /// download under way is left to finish, and brought to it then. An area
    /// the server has a newer build of is left for its update to bring zoom
    /// 15: the server deletes a build it has moved past, and asking for that
    /// build's files failed at every launch. So is one with a file that
    /// would not open, for the hiker's *Try Again*, which brings zoom 15
    /// after it: here it would come down again unasked at every launch, even
    /// where the device only refused a read for the moment. Nothing is
    /// brought while the launch picks up what was coming down
    /// (``isRecovering``); the launch brings the areas once it has.
    private func reconcile() {
        guard !isRecovering else { return }
        for record in installed.values where downloads[record.country.id] == nil {
            let current = offeredBuild(of: record)
            if includesDetail, !record.hasDetail {
                guard update(for: record.country.id) == nil, !needsRepair(record.country.id) else { continue }
                download(current ?? record.country)
            } else if !includesDetail, record.hasDetail {
                let before = installed
                var stripped = record
                stripped.hasDetail = false
                installed[record.country.id] = stripped
                guard commitIndex(restoring: before) else { continue }
                forgetUnopenable(record.files.filter(\.role.isDetail).map(\.role), of: record.country.id)
                reopenArchives()
                store.remove(record.files.filter(\.role.isDetail), keeping: Array(installed.values))
            } else if let current, !needsRepair(record.country.id), !filesToFetch(for: current).isEmpty {
                // A file its build gained since it came down: its day hikes.
                download(current)
            }
        }
    }

    /// The area `record` is of, as the list offers it now, where the list
    /// offers the same build: what it names may have grown since the area
    /// came down. `nil` where the list offers another build, or none.
    private func offeredBuild(of record: Record) -> Country? {
        offered.first { $0.id == record.country.id && $0.build == record.country.build }
    }

    // MARK: - The list

    /// Reads the server's list. A caller that asks while a read is out waits
    /// for that one, so what it does next goes by the list as it is now.
    func refreshList() async {
        if let listRead {
            await listRead.value
            return
        }
        let read = Task { await readList() }
        listRead = read
        await read.value
        listRead = nil
    }

    private func readList() async {
        guard let server else { return }
        listPhase = .loading
        do {
            let manifest = try await server.manifest()
            offered = manifest.readableCountries
            listPhase = .loaded
            // A build already down may name a file it did not.
            reconcile()
            await Self.cache(manifest, in: store)
        } catch {
            Self.logger.error("Country list: \(String(describing: error), privacy: .public)")
            listPhase = .failed
        }
    }

    // MARK: - Downloads

    /// Starts `country`, its update, or the zoom 15 it lacks. A refusal is
    /// shown on its row. Nothing starts before the device's own lists are
    /// read (``Holdings``), and no transfer before the list of downloads
    /// under way names it: a relaunch picks up only what that list names,
    /// and sweeps the staged files of the rest.
    func download(_ country: Country) {
        guard let server, let downloader, holdings == .read,
              downloads[country.id].map(\.hasFailed) ?? true
        else { return }
        let files = filesToFetch(for: country)
        guard !files.isEmpty else { return }
        let decision = networkDecision()
        let download = OfflineCountryDownload(
            country: country,
            files: files,
            phase: decision.isAllowed ? .downloading : .waitingForWiFi
        )
        // Before any refusal, so that one keeps what an earlier try got down
        // and the next try asks only for the rest.
        if let previous = downloads[country.id] { download.resume(from: previous) }
        downloads[country.id] = download
        if decision.reason == "low-power-mode" || decision.reason == "thermal" {
            download.set(.failed(.conserving))
            return
        }
        // Room for what has not come down, of this area and of the others
        // coming down beside it: what has is on the volume already.
        let needed = download.remainingBytes + bytesOwed(besides: country.id) + Self.spareBytes
        if let free = freeSpace(), free < needed {
            download.set(.failed(.space))
            return
        }
        // A failed write leaves the list as it was, still naming whatever an
        // earlier try has out, and Try Again writes it once there is room.
        let isListed = writePending { pending in
            pending.removeAll { $0.country.id == country.id }
            pending.append(OfflineCountryStore.Pending(country: country, roles: files.map(\.role)))
        }
        guard isListed else {
            download.set(.failed(.space))
            return
        }
        // A file a transfer is still out for is left to it: a sibling's
        // failure is what this retries.
        for file in files where download.staged[file.role] == nil && !download.inFlight.contains(file.role) {
            downloader.start(
                Self.key(country, file),
                from: server.url(of: file),
                stagingAt: store.stagedURL(for: file),
                resumeData: download.resumeData[file.role]
            )
            download.began(file.role)
        }
        if download.isStaged {
            Task { await finish(download) }
        }
    }

    /// What downloading `country` asks for: every file *Extra Detail* says,
    /// less those of the same build already down and opened. One the map
    /// could not open is asked for again. Of an area down without zoom 15,
    /// the rest comes first and zoom 15 after it (``reconcile()``): in one
    /// download, a zoom 15 that failed would keep its day hikes off the
    /// device even once they had landed, and turning *Extra Detail* off,
    /// which stops a download of zoom 15 alone, would not stop it.
    func filesToFetch(for country: Country) -> [OfflineCountryManifest.File] {
        let wanted = country.files(withDetail: includesDetail)
        guard let record = installed[country.id], record.country.build == country.build else { return wanted }
        let failed = unopenable[country.id] ?? []
        let held = Set(record.files.filter { !failed.contains($0.role) }.map(\.fileName))
        let owed = wanted.filter { !held.contains($0.fileName) }
        guard !record.hasDetail, owed.contains(where: { !$0.role.isDetail }) else { return owed }
        return owed.filter { !$0.role.isDetail }
    }

    /// Stops `id`'s download and keeps nothing it brought. A launch that has
    /// yet to pick up what was coming down holds no row for it, so the list
    /// of downloads under way says whether there is one: taken off that
    /// list, it is left alone by the launch (``resumePending(_:)``) rather
    /// than installed after the hiker ended it.
    func cancel(_ id: String) {
        let download = downloads.removeValue(forKey: id)
        let waiting = store.pending().filter { $0.country.id == id }
        guard download != nil || !waiting.isEmpty else { return }
        downloader?.cancel(country: id)
        writePending { $0.removeAll { $0.country.id == id } }
        let files = (download?.files ?? []) + waiting.flatMap(\.files)
        for staged in Set(files.map(store.stagedURL(for:))) {
            try? FileManager.default.removeItem(at: staged)
        }
    }

    /// Deletes a downloaded area, and the tiles drawn from it go with the
    /// cache as any tile does. A download still under way for it, of its
    /// zoom 15 or of an update, goes too: landing later, it would put back
    /// an area with none of its other files left.
    func delete(_ id: String) {
        let before = installed
        guard let record = installed.removeValue(forKey: id), commitIndex(restoring: before) else { return }
        cancel(id)
        forgetUnopenable(record.files.map(\.role), of: id)
        reopenArchives()
        store.remove(record.files, keeping: Array(installed.values))
    }

    private func handle(_ event: OfflineCountryDownloadEvent) {
        switch event {
        case let .wrote(key, bytes):
            download(for: key)?.wrote(bytes, of: key.role)
        case let .finished(key, staged):
            guard let download = download(for: key),
                  let file = download.files.first(where: { $0.role == key.role })
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

    /// The download a transfer is for: of its area and build, and asking
    /// for its file. A try that replaced a failed one with fewer files, once
    /// *Extra Detail* was turned off, leaves the earlier try's other
    /// transfers running, and they are no part of it.
    private func download(for key: OfflineCountryDownloadKey) -> OfflineCountryDownload? {
        guard let download = downloads[key.country], download.country.build == key.build,
              download.files.contains(where: { $0.role == key.role })
        else { return nil }
        return download
    }

    /// Checks every staged file, then moves them into place.
    ///
    /// **Only while it is still the area's download.** Each check is a wait
    /// of seconds, over which the hiker can cancel this try and start another
    /// of the same build, which stages its files at the same paths. A check
    /// that resumes for a try no longer current touches nothing: deleting a
    /// file it found broken would delete the new try's, and installing would
    /// install it.
    private func finish(_ download: OfflineCountryDownload) async {
        guard download.phase != .checking else { return }
        download.set(.checking)
        let country = download.country
        for file in download.files {
            let staged = store.stagedURL(for: file)
            let isWhole = await checksFile(file, staged)
            guard downloads[country.id] === download else { return }
            guard isWhole else {
                try? FileManager.default.removeItem(at: staged)
                download.discard(file.role)
                return
            }
        }
        do {
            try store.install(download.files)
        } catch {
            let reason = String(describing: error)
            Self.logger.error("Installing \(country.id, privacy: .public): \(reason, privacy: .public)")
            stopInstalling(download)
            return
        }
        let before = installed
        let previous = installed[country.id]
        let sameBuild = previous?.country.build == country.build
        installed[country.id] = Record(
            country: country,
            installedAt: now(),
            hasDetail: download.hasDetail || (sameBuild && previous?.hasDetail == true)
        )
        // The old build goes only once the index on disk names the new one:
        // otherwise a relaunch finds neither, and sweeps the new one.
        guard commitIndex(restoring: before) else {
            store.unstage(download.files, keeping: Array(installed.values))
            stopInstalling(download)
            return
        }
        reopenArchives()
        if let previous, !sameBuild {
            store.remove(previous.files, keeping: Array(installed.values))
        }
        downloads[country.id] = nil
        // Each was checked whole just now, and the opening under way says
        // whether it opens; another build's are gone.
        forgetUnopenable(sameBuild ? download.files.map(\.role) : OfflineCountryManifest.Role.allCases, of: country.id)
        writePending { $0.removeAll { $0.country.id == country.id } }
        reconcile()
    }

    /// Fails a download whose files could not be moved into place, or named
    /// by the index once they were. What went back to staging is installed
    /// from there by the next try, here or at the next launch, since the
    /// download is still listed as under way; what did not is asked for
    /// again.
    private func stopInstalling(_ download: OfflineCountryDownload) {
        for file in download.files where !FileManager.default.fileExists(atPath: store.stagedURL(for: file).path) {
            download.forget(file.role)
        }
        download.set(.failed(.space))
    }

    /// Writes ``installed`` as the index, or puts back `previous` when the
    /// write fails, which a caller then deletes nothing for: a file is never
    /// deleted while the index on disk still names it.
    private func commitIndex(restoring previous: [String: Record]) -> Bool {
        do {
            try store.write(installed: installed.values.sorted { $0.country.id < $1.country.id })
            return true
        } catch {
            Self.logger.error("Countries index: \(String(describing: error), privacy: .public)")
            installed = previous
            return false
        }
    }

    /// Changes the list of downloads under way, and says whether the change
    /// is on disk. It never writes over a list that is kept and cannot be
    /// read, which would leave what that list names to the sweep, and a
    /// write that fails leaves the list as it was, because it is atomic.
    @discardableResult private func writePending(_ change: (inout [OfflineCountryStore.Pending]) -> Void) -> Bool {
        guard case var .holding(pending) = store.downloadsUnderWay() else {
            Self.logger.error("Countries' downloads under way: the list cannot be read")
            return false
        }
        change(&pending)
        do {
            try store.write(pending: pending)
            return true
        } catch {
            Self.logger.error("Countries' downloads under way: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func key(_ country: Country, _ file: OfflineCountryManifest.File) -> OfflineCountryDownloadKey {
        OfflineCountryDownloadKey(country: country.id, build: country.build, role: file.role)
    }
}

// MARK: - Extra Detail

extension OfflineCountries {
    /// Turns *Extra Detail* on, which brings zoom 15 to every area already
    /// down, or off, which deletes it from them and keeps the areas.
    func setIncludesDetail(_ isOn: Bool) {
        guard isOn != includesDetail else { return }
        includesDetail = isOn
        defaults?.set(isOn, forKey: SettingsKey.offlineCountriesDetail)
        if !isOn {
            // Bringing only zoom 15 to an area already down is no longer wanted.
            for (id, download) in downloads where download.files.allSatisfy(\.role.isDetail) {
                cancel(id)
            }
        }
        reconcile()
    }
}

// MARK: - The archives

extension OfflineCountries {
    /// Opens the archives of what is installed now, off the main actor, and
    /// hands them to the map. Two changes in a row open twice at once, and
    /// only the later opening is handed over, whichever finishes first.
    private func reopenArchives() {
        guard let archives else { return }
        archiveGeneration += 1
        let generation = archiveGeneration
        let records = Array(installed.values)
        Task {
            let opened = await Self.open(records, in: store)
            guard generation == archiveGeneration else { return }
            unopenable = opened.unopenable
            archives.replace(with: opened.countries)
            archivesDidChange()
        }
    }

    /// Forgets that the files in `roles` of the area `id` would not open:
    /// they are gone, or checked whole since.
    private func forgetUnopenable(_ roles: [OfflineCountryManifest.Role], of id: String) {
        guard let failed = unopenable[id] else { return }
        let left = failed.subtracting(roles)
        unopenable[id] = left.isEmpty ? nil : left
    }
}

// MARK: - Launch

extension OfflineCountries {
    /// Opens what is downloaded, picks up what was coming down, and sweeps
    /// what nothing owns. Once a launch, unless the index or the list of
    /// downloads is there and cannot be read: then nothing is opened,
    /// resumed, swept or downloaded, because what a launch cannot read it
    /// cannot call unowned, and the next call starts again. The model asks
    /// again each time a scene becomes active, by when a device that was
    /// locked since it restarted has been unlocked. Once started, it opens
    /// the archives again where one would not open, since the device may
    /// have refused a read that it allows now.
    func start() async {
        guard let archives else { return }
        // Read and marked before the first suspension, so a second call
        // meanwhile finds them read.
        guard holdings != .read else {
            if !unopenable.isEmpty { reopenArchives() }
            return
        }
        do {
            try store.prepare()
        } catch {
            Self.logger.error("Countries directory: \(String(describing: error), privacy: .public)")
        }
        guard case let .holding(records) = store.index(),
              case let .holding(waiting) = store.downloadsUnderWay()
        else {
            Self.logger.error("The countries' lists cannot be read; leaving the directory as it is")
            holdings = .unreadable
            return
        }
        holdings = .read
        isRecovering = true
        installed = Dictionary(records.map { ($0.country.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Megabytes of outlines, so read off the main actor; and a list
        // fetched while it was read is newer.
        if let cached = await Self.cachedManifest(in: store), listPhase != .loaded {
            offered = cached.readableCountries
        }
        archiveGeneration += 1
        let generation = archiveGeneration
        let opened = await Self.open(records, in: store)
        if generation == archiveGeneration {
            unopenable = opened.unopenable
            archives.replace(with: opened.countries)
            if !records.isEmpty { archivesDidChange() }
        }
        await resumePending(waiting)
        // After the recovery, which may have installed what landed while the
        // app was away: swept against the records from before it, that would
        // go with everything nothing else owns.
        if case let .holding(stillWaiting) = store.downloadsUnderWay() {
            await Self.sweep(store, keeping: Array(installed.values), pending: stillWaiting)
        }
        isRecovering = false
        reconcile()
    }

    @concurrent
    private static func sweep(
        _ store: OfflineCountryStore,
        keeping records: [Record],
        pending: [OfflineCountryStore.Pending]
    ) async {
        store.sweep(keeping: records, pending: pending)
    }

    /// The manifest last fetched, which carries every area's outline.
    @concurrent
    private static func cachedManifest(in store: OfflineCountryStore) async -> OfflineCountryManifest? {
        store.cachedManifest()
    }

    @concurrent
    private static func cache(_ manifest: OfflineCountryManifest, in store: OfflineCountryStore) async {
        try? store.cache(manifest)
    }

    /// What an opening of the archives made of the index: the areas the map
    /// draws, and the files that would not open.
    nonisolated struct Opening: Sendable {
        var countries: [OfflineCountryArchives.Country] = []
        var unopenable: [String: Set<OfflineCountryManifest.Role>] = [:]
    }

    /// Opens every file the index names. An area whose basemap will not open
    /// is on no map, and one whose other files will not open is drawn
    /// without them.
    @concurrent
    private static func open(_ records: [Record], in store: OfflineCountryStore) async -> Opening {
        var opening = Opening()
        for record in records {
            let id = record.country.id
            var failed = Set<OfflineCountryManifest.Role>()
            var opened: [OfflineCountryManifest.Role: PMTilesArchive] = [:]
            for file in record.files {
                do {
                    opened[file.role] = try PMTilesArchive(contentsOf: store.fileURL(for: file))
                } catch {
                    let reason = String(describing: error)
                    logger.error("Opening \(file.fileName, privacy: .public): \(reason, privacy: .public)")
                    failed.insert(file.role)
                }
            }
            if !failed.isEmpty { opening.unopenable[id] = failed }
            guard let basemap = opened[.basemap] else { continue }
            opening.countries.append(OfflineCountryArchives.Country(
                id: id,
                bounds: record.country.bounds,
                basemap: basemap,
                extras: opened[.extras],
                record: record,
                detail: opened[.detail],
                detailExtras: opened[.detailExtras],
                trails: opened[.trails]
            ))
        }
        return opening
    }

    /// Picks up what `pending`, read as the launch began, names. The areas
    /// are listed before the session has said what it still has, so the
    /// hiker can delete one meanwhile, or while an earlier entry is checked;
    /// each entry is read again first, and one no longer on the list is left
    /// alone.
    private func resumePending(_ pending: [OfflineCountryStore.Pending]) async {
        guard !pending.isEmpty else { return }
        let running = await downloader?.running() ?? [:]
        for entry in pending {
            guard store.pending().contains(entry) else { continue }
            let country = entry.country
            let download = OfflineCountryDownload(country: country, files: entry.files, phase: .downloading)
            downloads[country.id] = download
            for file in entry.files {
                let staged = store.stagedURL(for: file)
                if FileManager.default.fileExists(atPath: staged.path) {
                    download.landed(file, at: staged)
                } else if let written = running[Self.key(country, file)] {
                    download.began(file.role)
                    download.wrote(written, of: file.role)
                } else {
                    download.set(.failed(.connection))
                }
            }
            if download.isStaged { await finish(download) }
        }
    }
}
