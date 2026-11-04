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
//    names. The wakes and the history are the ones the Hilliest list keeps
//    its figures true by (`StoreSaves`). Never by observing `route`, which
//    every save of any hike notifies while the hikes list's `@Query` is up
//    (#1228, #1253). Like the Hilliest list, it filters on the row: a rename
//    or a tint costs that one hike a read.
//
//  Who is in the library is asked off the main actor too, of the columns that
//  are not the line, each time the hikes' store is saved.
//
//  ## A read that fails
//
//  A save names its row once, and a fetch can fail. A hike whose read failed
//  would then keep its old line until it was next saved, however long that
//  took (#1281), so a read says which of three things it found
//  (``LibraryLines/LineRead``). A line is kept. A row that is gone asks for
//  nothing: the next listing takes its outline away, and only a listing ever
//  does. A fetch that failed says nothing about the row, so the outline stays
//  drawn and the line stays owed. Every pass asks for what is owed, whatever
//  woke it, so an unrelated save costs those hikes a read and no others.
//
//  Nor can what is owed be left to the next save, for the reason `StoreSaves`
//  gives of a look: the save it took may be the last. So a hike's first
//  failure asks for one more pass at once. A failure that holds asks for
//  nothing more, and that hike waits for whichever pass comes next.
//
//  ## What is not drawn
//
//  A recording's draft, which has no line until Stop writes one. And the
//  selected hike, which the map draws properly and leaves out of these: that
//  is the map's decision rather than this file's, so a selection costs no
//  read here.
//

import Algorithms
import CoreLocation
import Foundation
import Observation
import OpenHikesData
import os
import SwiftData

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
    typealias Reading = @concurrent @Sendable ([UUID], ModelContainer) async -> [UUID: LineRead]

    /// What a read found of one hike's line. A fetch that failed and a row
    /// that is gone are told apart, because only the first still owes a line:
    /// see the file header.
    nonisolated enum LineRead: Sendable {
        /// The line, thinned and cut at its pauses: see ``LibraryLineOutline``.
        case line([[CLLocationCoordinate2D]])
        /// No row: the hike has gone since it was listed.
        case gone
        /// The fetch failed, which says nothing about the row.
        case failed
    }

    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "LibraryLines")

    /// How many lines are read between publications: few enough that the
    /// first hikes reach the map in a moment, enough that a long library does
    /// not redraw the map once per hike.
    static let batchSize = 8

    /// Every finished hike's line, newest first.
    private(set) var lines: [LibraryLine] = []

    /// How many passes a failed read has asked for. A seam: the pass one asks
    /// for looks like any other, so without this a failure that kept asking
    /// would look like a busy store.
    @ObservationIgnored private(set) var retries = 0

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
    /// first, newest first, then each hike whose row may have been saved or
    /// whose last read failed. See the file header.
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
        let saves = StoreSaves(in: container, checking: checking)
        let savedHere = RowsSavedHere(by: container.mainContext, waking: saves)
        var isFirstPass = true
        // The hikes whose last read failed: see the file header.
        var owed: Set<UUID> = []
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
            saves.watch(store: listed.firstNonNil(\.row.storeIdentifier))
            var saved = savedHere.take()
            saved.formUnion(await saves.savedRows(among: Set(listed.map(\.row))))
            guard !Task.isCancelled else { return }
            let listedIDs = Set(listed.map(\.id))
            outlines = outlines.filter { listedIDs.contains($0.key) }
            let isStale = isFirstPass
            isFirstPass = false
            let due = listed
                .filter { hike in
                    !hike.isRecording
                        && (isStale || outlines[hike.id] == nil || saved.contains(hike.row) || owed.contains(hike.id))
                }
                .map(\.id)
            // Before any read, so a deleted hike or a new colour is on the map
            // at once rather than after the lines that are due.
            publish(listed)
            var failed: Set<UUID> = []
            for batch in due.chunks(ofCount: Self.batchSize) {
                let read = await reading(Array(batch), container)
                guard !Task.isCancelled else { return }
                failed.formUnion(keep(read, of: batch))
                publish(listed)
            }
            // A hike's first failure asks for one more pass, and one that
            // holds for none, so a failure that lasts cannot spin.
            if !failed.isSubset(of: owed) {
                retries += 1
                saves.wake()
            }
            owed = failed
        }
    }

    /// Keeps the lines `read` found of `hikeIDs`, and answers the hikes whose
    /// reads failed, which keep the outlines they have. A hike it says nothing
    /// of is one of those: nothing says its line was read.
    private func keep(_ read: [UUID: LineRead], of hikeIDs: some Sequence<UUID>) -> Set<UUID> {
        var failed: Set<UUID> = []
        for hikeID in hikeIDs {
            switch read[hikeID] {
            case .line(let runs):
                reads += 1
                outlines[hikeID] = Outline(runs: runs, revision: reads)
            case .gone:
                break // The next listing takes it off the map.
            case .failed, nil:
                failed.insert(hikeID)
            }
        }
        return failed
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

    /// What was found of each of `hikeIDs`' lines, each thinned for the map.
    /// A cancelled read leaves the rest out.
    ///
    /// A context per line, let go before the next is read, so the decoded
    /// routes do not pile up in one: see the file header.
    @concurrent
    static func readLines(_ hikeIDs: [UUID], in container: ModelContainer) async -> [UUID: LineRead] {
        assertOffMainThread("Reading the library's lines must stay off the main thread")
        var read: [UUID: LineRead] = [:]
        for hikeID in hikeIDs {
            guard !Task.isCancelled else { break }
            autoreleasepool {
                var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
                descriptor.fetchLimit = 1
                let context = ModelContext(container)
                read[hikeID] = lineRead { try context.fetch(descriptor).first }
            }
        }
        return read
    }

    /// What `fetching` a hike's row finds of its line. Apart from the read so
    /// that a suite can fail a fetch, which a real store does not do on demand.
    static func lineRead(fetching: () throws -> Hike?) -> LineRead {
        do {
            guard let hike = try fetching() else { return .gone }
            return .line(LibraryLineOutline.runs(of: hike.route))
        } catch {
            logger.error("Could not read a library line: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }
}

// MARK: - Noticing a save here

/// The hikes the main context saved since the task last asked, which a look
/// at the store's history leaves out until it holds a token (see
/// `StoreSaves.swift`). Each such save wakes the task, as a save by any other
/// context does. Made when the task starts and gone when it ends, observer
/// and all.
@MainActor
private final class RowsSavedHere {
    private let saves: StoreSaves
    private var rows: Set<PersistentIdentifier> = []
    /// Removed by the `isolated deinit` below, on the main actor.
    private var observer: (any NSObjectProtocol)?

    init(by mainContext: ModelContext, waking saves: StoreSaves) {
        self.saves = saves
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: mainContext,
            queue: nil
        ) { [weak self] note in
            let hikes = Self.hikeRows(savedIn: note)
            guard !hikes.isEmpty else { return }
            let owner = self
            onMainActor { owner?.didSave(hikes) }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Hands over the rows saved since the last call.
    func take() -> Set<PersistentIdentifier> {
        defer { rows = [] }
        return rows
    }

    private func didSave(_ saved: Set<PersistentIdentifier>) {
        rows.formUnion(saved)
        saves.wake()
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
