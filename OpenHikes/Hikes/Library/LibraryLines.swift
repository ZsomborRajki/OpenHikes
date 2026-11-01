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
        let saves = StoreSaves(in: container, checking: checking)
        let savedHere = RowsSavedHere(by: container.mainContext, waking: saves)
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
