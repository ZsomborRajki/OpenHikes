//
//  LibraryLines.swift
//  OpenHikes
//
//  Every hike in the library, as the map draws it.
//
//  The map used to draw one of the hiker's own routes, the selected hike's.
//  Every other hike in the list was a row and nothing else, so a hiker looking
//  at a valley could not see which of its trails they had walked, saved or
//  drawn without opening them one at a time. This reads every finished hike's
//  line and hands the map a thinned copy of each, which it draws faded beneath
//  the selected route (`MapLibraryLines.swift`). A tap on one opens its hike.
//
//  ## What it costs, and where
//
//  A line is external storage, decoded whole when it is read: about 25 ms for
//  twenty thousand points (see `StoreHistoryCheck`). So no line is read on the
//  main actor, and none is read again without a reason:
//
//  - **Once each, off the main actor**, in a context of its own that is let go
//    before the next line is read, so a library of long recordings costs one
//    route's memory at a time. What survives the read is the outline, at most
//    ``LibraryLineOutline/maximumPoints`` points; the decoded route goes with
//    its context.
//  - **Newest first, a few at a time**, each batch published as it lands, so
//    the hikes at the top of the list are the first on the map.
//  - **Again only when the row may have been saved**: by the main context,
//    which `ModelContext.didSave` names, or by an import, such as an edit
//    mirrored in from the hiker's other device, which the store's history
//    names (`StoreHistoryCheck`). Never by observing `route`, which every
//    save of any hike notifies while the hikes list's `@Query` is up (#1228,
//    #1253). Like the Hilliest list, it filters on the row: a rename or a tint
//    costs that one hike a read.
//
//  Who is in the library is asked off the main actor too, of the columns that
//  are not the line, each time the hikes' store is saved.
//
//  ## What is not drawn
//
//  A recording's draft, which has no line until Stop writes one. And the
//  selected hike, which the map draws properly and leaves out of these: that
//  is the map's decision rather than this file's, so a selection costs no
//  read here.
//

import Algorithms
import CoreData
import CoreLocation
import Foundation
import Observation
import OpenHikesData
import os
import SwiftData
import Synchronization

/// One hike's line, as the map draws it when the hike is not selected.
nonisolated struct LibraryLine: Identifiable, Equatable, Sendable {
    let hikeID: UUID
    /// The hike's own colour, `#RRGGBB` or `#RRGGBBAA`, read with its row.
    let tintHex: String
    /// The line thinned and cut at its pauses: see ``LibraryLineOutline``.
    let runs: [[CLLocationCoordinate2D]]
    /// Which read of the line this is. Two lines of one hike and one revision
    /// are the same points, so equality never compares them.
    let revision: Int

    var id: UUID { hikeID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hikeID == rhs.hikeID && lhs.tintHex == rhs.tintHex && lhs.revision == rhs.revision
    }
}

/// The library's lines, kept true for the map — see the file header.
@MainActor
@Observable
final class LibraryLines {
    /// A hike as the library is listed: everything about it but its line.
    nonisolated struct ListedHike: Sendable {
        let id: UUID
        let row: PersistentIdentifier
        let tintHex: String
        let isRecording: Bool
    }

    /// How the library is listed: ``listHikes(in:)``, or a stand-in. A
    /// listing that throws keeps what is drawn rather than clearing it.
    typealias Listing = @concurrent @Sendable (ModelContainer) async throws -> [ListedHike]
    /// How lines are read and thinned: ``readLines(_:in:)``, or a stand-in a
    /// suite counts.
    typealias Reading = @concurrent @Sendable ([UUID], ModelContainer) async -> [UUID: [[CLLocationCoordinate2D]]]

    private static let logger = Logger(subsystem: "OpenHikes", category: "LibraryLines")

    /// How many lines are read between publications: few enough that the
    /// first hikes reach the map in a moment, enough that a long library does
    /// not redraw the map once per hike.
    static let batchSize = 8

    /// Every finished hike's line, newest first.
    private(set) var lines: [LibraryLine] = []

    /// What a tap on a line opens: the same way in a widget's tap takes, see
    /// ``HikeOpenRequests``.
    @ObservationIgnored private let openRequests: HikeOpenRequests
    /// Each hike's outline as last read, by hike.
    @ObservationIgnored private var outlines: [UUID: Outline] = [:]
    @ObservationIgnored private var reads = 0

    private struct Outline {
        let runs: [[CLLocationCoordinate2D]]
        let revision: Int
    }

    init(openRequests: HikeOpenRequests) {
        self.openRequests = openRequests
    }

    /// Opens the hike whose line was tapped, as its widget would: selected,
    /// drawn properly and pushed, or left alone when its screen is already up.
    func open(hikeID: UUID) {
        openRequests.open(hikeID: hikeID)
    }

    /// Keeps ``lines`` true for as long as the calling task runs: every line
    /// first, newest first, then each hike whose row may have been saved. See
    /// the file header.
    ///
    /// Every line first even when an earlier task left some read: what a save
    /// between that task's end and this one's start wrote, nothing here was
    /// watching for. Those lines stay drawn until their new reads land.
    ///
    /// - Parameters:
    ///   - listing: How the library is listed. A seam.
    ///   - reading: How lines are read and thinned. A seam.
    ///   - checking: How the store's history is read. A seam.
    func follow(
        in container: ModelContainer,
        listing: Listing = LibraryLines.listHikes,
        reading: Reading = LibraryLines.readLines,
        checking: @escaping StoreHistoryCheck.Making = StoreHistoryCheck.answer
    ) async {
        let saves = LibrarySaves(of: container.mainContext)
        var history = LibraryHistory(container: container, since: .now, checking: checking)
        var isFirstPass = true
        for await _ in saves.changes {
            let listed: [ListedHike]
            do {
                listed = try await listing(container)
            } catch {
                // What is drawn stays drawn, and the next save asks again.
                Self.logger.error("Could not list the library: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard !Task.isCancelled else { return }
            saves.watch(storeOf: listed)
            var saved = saves.takeSavedRows()
            saved.formUnion(await history.savedRows(among: listed, waking: saves))
            guard !Task.isCancelled else { return }
            let listedIDs = Set(listed.map(\.id))
            outlines = outlines.filter { listedIDs.contains($0.key) }
            let isStale = isFirstPass
            isFirstPass = false
            let due = listed
                .filter { hike in
                    !hike.isRecording && (isStale || outlines[hike.id] == nil || saved.contains(hike.row))
                }
                .map(\.id)
            // Before any read, so a deleted hike or a new colour is on the map
            // at once rather than after the lines that are due.
            publish(listed)
            for batch in due.chunks(ofCount: Self.batchSize) {
                let read = await reading(Array(batch), container)
                guard !Task.isCancelled else { return }
                for (hikeID, runs) in read {
                    reads += 1
                    outlines[hikeID] = Outline(runs: runs, revision: reads)
                }
                publish(listed)
            }
        }
    }

    /// The listed hikes that have a line, in the order they were listed.
    private func publish(_ listed: [ListedHike]) {
        lines = listed.compactMap { hike in
            guard !hike.isRecording, let outline = outlines[hike.id], !outline.runs.isEmpty else { return nil }
            return LibraryLine(hikeID: hike.id, tintHex: hike.tintHex, runs: outline.runs, revision: outline.revision)
        }
    }
}

// MARK: - Reading the store

nonisolated extension LibraryLines {
    /// Every hike in the library, newest first, without its line: the order
    /// the hikes list draws by default, so the lines read first are the rows
    /// at its top.
    @concurrent
    static func listHikes(in container: ModelContainer) async throws -> [ListedHike] {
        assertOffMainThread("Listing the library's lines must stay off the main thread")
        var descriptor = FetchDescriptor<Hike>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.propertiesToFetch = [\.id, \.tintHex, \.isRecording]
        return try ModelContext(container).fetch(descriptor).map { hike in
            ListedHike(
                id: hike.id,
                row: hike.persistentModelID,
                tintHex: hike.tintHex,
                isRecording: hike.isRecording
            )
        }
    }

    /// Each of `hikeIDs`' lines, thinned for the map. A hike gone since it was
    /// listed is left out, and goes from the map at the next listing.
    ///
    /// A context per line, let go before the next is read, so the decoded
    /// routes do not pile up in one: see the file header.
    @concurrent
    static func readLines(_ hikeIDs: [UUID], in container: ModelContainer) async -> [UUID: [[CLLocationCoordinate2D]]] {
        assertOffMainThread("Reading the library's lines must stay off the main thread")
        var read: [UUID: [[CLLocationCoordinate2D]]] = [:]
        for hikeID in hikeIDs {
            guard !Task.isCancelled else { break }
            autoreleasepool {
                var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
                descriptor.fetchLimit = 1
                guard let hike = try? ModelContext(container).fetch(descriptor).first else { return }
                read[hikeID] = LibraryLineOutline.runs(of: hike.route)
            }
        }
        return read
    }
}

// MARK: - Noticing a save

/// What wakes ``LibraryLines/follow(in:listing:reading:checking:)``, and the
/// rows the main context saved since it last asked. Made when the task
/// starts and gone when it ends, observers and all.
@MainActor
private final class LibrarySaves {
    /// One element at once, for the first pass, then one after each save,
    /// however many arrive while the task is busy.
    let changes: AsyncStream<Void>
    private let wakeUp: AsyncStream<Void>.Continuation
    /// The hikes' store, once a listing has named it: a save of the
    /// device-local one is dropped on the thread that posted it.
    private let storeID = StoreIdentity()
    private var savedRows: Set<PersistentIdentifier> = []
    /// Removed by the `isolated deinit` below, on the main actor.
    private var observers: [any NSObjectProtocol] = []

    init(of mainContext: ModelContext) {
        (changes, wakeUp) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let wake = wakeUp
        let store = storeID
        let center = NotificationCenter.default
        observers = [
            // The main context's own saves, named by row, which a look at the
            // store's history leaves out until it holds a token.
            center.addObserver(forName: ModelContext.didSave, object: mainContext, queue: nil) { [weak self] note in
                let rows = Self.hikeRows(savedIn: note)
                guard !rows.isEmpty else { return }
                let saves = self
                onMainActor { saves?.didSave(rows) }
            },
            // Every save of the store by any context, an import's included.
            center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { note in
                guard store.admits(StoreHistoryCheck.storeID(of: note)) else { return }
                wake.yield()
            },
        ]
        wakeUp.yield()
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        wakeUp.finish()
    }

    /// Hands over the rows the main context saved since the last call.
    func takeSavedRows() -> Set<PersistentIdentifier> {
        defer { savedRows = [] }
        return savedRows
    }

    /// Narrows the store's saves to the listed hikes' store.
    func watch(storeOf listed: [LibraryLines.ListedHike]) {
        storeID.set(listed.firstNonNil(\.row.storeIdentifier))
    }

    func wake() {
        wakeUp.yield()
    }

    private func didSave(_ rows: Set<PersistentIdentifier>) {
        savedRows.formUnion(rows)
        wakeUp.yield()
    }

    /// The hikes a save inserted, updated or deleted. Read on the thread that
    /// posted it, and reduced to values before anything hops.
    nonisolated private static func hikeRows(savedIn note: Notification) -> Set<PersistentIdentifier> {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        let hike = Schema.entityName(for: Hike.self)
        return Set(keys.flatMap { key in
            (note.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []).filter { $0.entityName == hike }
        })
    }
}

/// The hikes' store, read on whichever thread posts a remote change.
nonisolated private final class StoreIdentity: Sendable {
    private let value = Mutex<String?>(nil)

    func set(_ storeID: String?) {
        guard let storeID else { return }
        value.withLock { $0 = storeID }
    }

    /// Whether a save of `storeID` may be the hikes' store: every store until
    /// a listing has named one.
    func admits(_ storeID: String?) -> Bool {
        value.withLock { known in known == nil || known == storeID }
    }
}

/// The store's history, looked at once per wake: which listed rows another
/// context saved since the last look.
///
/// A look that cannot read history names no row, as the Hilliest list's does
/// (`HikeListMetrics+Observation.swift`): naming every row would read every
/// line again. The first look of such a run asks for one more at once, which
/// reads from the start again, and the rest wait for the next save.
private struct LibraryHistory {
    let container: ModelContainer
    let since: Date
    let checking: StoreHistoryCheck.Making
    private var token: DefaultHistoryToken?
    private var lookFailed = false

    init(container: ModelContainer, since: Date, checking: @escaping StoreHistoryCheck.Making) {
        self.container = container
        self.since = since
        self.checking = checking
    }

    @MainActor
    mutating func savedRows(
        among listed: [LibraryLines.ListedHike],
        waking saves: LibrarySaves
    ) async -> Set<PersistentIdentifier> {
        guard let storeID = listed.firstNonNil(\.row.storeIdentifier) else { return [] }
        let answer = await checking(StoreHistoryCheck.Request(
            container: container,
            rows: Set(listed.map(\.row)),
            storeID: storeID,
            since: since,
            token: token
        ))
        token = answer.token
        guard answer.wasRead else {
            if !lookFailed { saves.wake() }
            lookFailed = true
            return []
        }
        lookFailed = false
        return answer.savedRows
    }
}
