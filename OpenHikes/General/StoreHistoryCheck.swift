//
//  StoreHistoryCheck.swift
//  OpenHikes
//
//  Has anything saved these rows since the last check? The off-main half of
//  the things that notice a line another context saved, such as an edit
//  mirrored in from the hiker's other device: `SelectedLineStoreWatch`, which
//  asks about the selected hike's row (#1228), and `StoreSaves`, which asks
//  about every listed hike's for the Hilliest list's task (#1253, see
//  `HikeListMetrics+Observation.swift`) and the library's lines on the map.
//
//  Persistent history answers that in about 0.3 ms, flat in its depth:
//  measured three thousand transactions deep on iOS 18.6 and 27. A save of
//  any other row, or nothing new since the last check, ends there. A save of
//  a row asked about costs the caller one look at that hike's line, read
//  from the store off the main actor (about 25 ms for twenty thousand
//  points) and compared with what it holds: the line the selection's readers
//  have, or the fingerprint the list cached beside its figures.
//
//  It filters on the row, not the attribute. History's `updatedAttributes`
//  would say whether `route` was written, and on iOS 27 it named `route` for
//  every write of the line it recorded. On 18.6 it named `route` for a rename
//  and left it out of a write of the line, and which of the two happened
//  changed from run to run. A filter that trusted it there could miss a line.
//  So a rename, a tint or a photo on a hike asked about costs that look once a
//  check reads its save, and the look finds the same line. Which row a change
//  belongs to was right on both. (An
//  unchanged line saved on its own was not always recorded at all, on
//  either: 15 of 80 such saves on 27, and 11 of 80 on 18.6, left no
//  transaction, and so nothing to look at.)
//
//  History's rules, measured on both:
//  - A token belongs to one store, so a query after a token returns only that
//    store's later transactions.
//  - A query after a moment in time returns both stores' transactions, unless
//    it also names an author only one store's transactions carry.
//  - `storeIdentifier` is refused in a predicate, so a query cannot name its
//    store. What one returns is still filtered by store here, in memory.
//  - `fetchLimit` counts per store, so it cannot ask for "the newest".
//  - A token's own `<` cannot be trusted in memory. On iOS 18.6 the first
//    transaction's token compared greater than every later one, so `max()`
//    picked the oldest. The newest is picked by transaction identifier, and a
//    query's `token >`, compared by the store, was right on both.
//
//  No query may return a transaction of the device-local store, even one this
//  file would drop: SwiftData traps while it builds the transaction, before
//  the fetch returns. Two of that store's columns are composite, saved as one
//  column per member. Neither OS could build a write of the walk in progress
//  ("Failed to materialize a keypath for walkInProgress.phaseChangedAt from
//  HikeLocalState"), and iOS 18.6 could not build a drawing's travel mode. A
//  check that read by time alone took the app down in the middle of a walk.
//  The Hikes store's models have no composite column.
//
//  So a check with no token reads only the transactions CloudKit's import
//  committed since the read of what the caller holds began, picked by their
//  author. The import writes only the mirrored store, so the device-local
//  store returns nothing: measured on both with a walk saved since, with no
//  trap, in about half a millisecond three thousand transactions deep. The
//  newest import such a check finds is the first token, and every later check
//  reads from the newest token it has seen, which returns that store's saves
//  by any author. Until then, from the start of a follow or of a
//  `StoreSaves` task, or from a read that failed, no check has one.
//
//  What a check with no token leaves out is every save under another author.
//  In the app, the only context that saves a hike already in the store is the
//  main context, and each caller hears its saves another way: its writes of
//  a line move the revision that the selection's readers and the list watch,
//  and the library's lines hear each of its saves (`ModelContext.didSave`).
//  If the import's author ever changes, such a check finds nothing: a line
//  received from another device is missed, and nothing traps.
//

import CoreData
import Foundation
import os
import SwiftData

nonisolated enum StoreHistoryCheck {
    private static let logger = Logger(subsystem: "OpenHikes", category: "StoreHistory")

    /// What a check needs, as values: the rows stay where their contexts live.
    struct Request: Sendable {
        let container: ModelContainer
        /// The rows asked about, all in ``storeID``.
        let rows: Set<PersistentIdentifier>
        /// The rows' own store, the one whose transactions are read.
        let storeID: String
        /// When the read of what the caller holds began. A check with no
        /// ``token`` reads every import committed since (see the header); one
        /// the read already saw costs a look that finds what the caller
        /// already has.
        let since: Date
        /// The newest transaction of the store an earlier check has read.
        let token: DefaultHistoryToken?
    }

    struct Answer: Sendable {
        /// Where the next check starts, or `nil` to start from the read again.
        let token: DefaultHistoryToken?
        /// The rows asked about that a transaction since the last check
        /// saved: every one of them when history could not be read, because
        /// none can be ruled out.
        let savedRows: Set<PersistentIdentifier>
        /// Whether history was read. When it was not, ``savedRows`` is a
        /// precaution rather than a finding, and what it costs is the
        /// caller's to decide.
        let wasRead: Bool
    }

    /// How a check is made. A seam, so a suite can hold one in flight while
    /// the caller moves on around it.
    typealias Making = @concurrent @Sendable (Request) async -> Answer

    /// Reads the store's history since the last check, in a context of its
    /// own.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor, and both callers are on the main actor.
    @concurrent
    static func answer(_ request: Request) async -> Answer {
        assertOffMainThread("Reading the store's history must stay off the main thread")
        let context = ModelContext(request.container)
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try context.fetchHistory(descriptor(for: request))
        } catch {
            // An expired token, say. With no history there is nothing to rule
            // out, and the next check starts from the read again.
            logger.error("Could not read the store's history: \(error.localizedDescription, privacy: .public)")
            return Answer(token: nil, savedRows: request.rows, wasRead: false)
        }
        let own = transactions.filter { $0.storeIdentifier == request.storeID }
        let newest = own.max { $0.transactionIdentifier < $1.transactionIdentifier }
        return Answer(
            token: newest?.token ?? request.token,
            savedRows: savedRows(in: own, among: request.rows),
            wasRead: true
        )
    }

    /// The store a `.NSPersistentStoreRemoteChange` is for, read on whatever
    /// thread posted it, so that a save of the other store can be dropped
    /// there rather than hopping anywhere to be dropped.
    static func storeID(of notification: Notification) -> String? {
        let value = notification.userInfo?[NSStoreUUIDKey]
        return (value as? String) ?? (value as? UUID)?.uuidString
    }

    /// The author CloudKit's mirroring gives the transactions it imports, and
    /// the only one a check with no token reads. No context of the app saves
    /// under it.
    private static let importAuthor = "NSCloudKitMirroringDelegate.import"

    private static func descriptor(for request: Request) -> HistoryDescriptor<DefaultHistoryTransaction> {
        if let token = request.token {
            return HistoryDescriptor(predicate: #Predicate { $0.token > token })
        }
        // Never by time alone, which reads the device-local store too: see
        // the header.
        let since = request.since
        let importer = importAuthor
        return HistoryDescriptor(predicate: #Predicate { $0.timestamp >= since && $0.author == importer })
    }

    /// The rows of `rows` that a transaction in `transactions` updated; see
    /// the header for why not whether it wrote the line.
    private static func savedRows(
        in transactions: [DefaultHistoryTransaction],
        among rows: Set<PersistentIdentifier>
    ) -> Set<PersistentIdentifier> {
        var saved: Set<PersistentIdentifier> = []
        for transaction in transactions {
            for change in transaction.changes {
                guard case .update = change, rows.contains(change.changedPersistentIdentifier) else { continue }
                saved.insert(change.changedPersistentIdentifier)
            }
        }
        return saved
    }
}
