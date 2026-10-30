//
//  SelectedLineStoreCheck.swift
//  OpenHikes
//
//  The off-main half of `SelectedLineStoreWatch`: has anything saved the
//  selected hike's row since the last check?
//
//  Persistent history answers that in about 0.3 ms, flat in its depth:
//  measured three thousand transactions deep on iOS 18.6 and 27. A save of
//  another hike, or nothing new since the last check, ends there. A save of
//  this hike's row is answered by `SelectedLine.refresh()`. That reads the
//  line from the store and compares it with the one the readers hold, about
//  25 ms for twenty thousand points off the main actor, and hands it out only
//  if it differs.
//
//  It filters on the row, not the attribute. History's `updatedAttributes`
//  would say whether `route` was written, and on iOS 27 it named `route` for
//  every write of the line it recorded. On 18.6 it named `route` for a rename
//  and left it out of a write of the line, and which of the two happened
//  changed from run to run. A filter that trusted it there could miss a line.
//  So a rename, a tint or a photo on the selected hike costs a refresh, which
//  finds the same line and hands out nothing. Which row a change belongs to
//  was right on both. (An unchanged line saved on its own was not always
//  recorded at all, on either: 15 of 80 such saves on 27, and 11 of 80 on
//  18.6, left no transaction, and so nothing to look at.)
//
//  History's rules, measured on both:
//  - A token belongs to one store, so a query after a token returns only that
//    store's later transactions.
//  - A query after a moment in time returns both stores' transactions.
//  - `storeIdentifier` is refused in a predicate, so the other store's
//    transactions are dropped here, in memory.
//  - `fetchLimit` counts per store, so it cannot ask for "the newest".
//  - A token's own `<` cannot be trusted in memory. On iOS 18.6 the first
//    transaction's token compared greater than every later one, so `max()`
//    picked the oldest. The newest is picked by transaction identifier, and a
//    query's `token >`, compared by the store, was right on both.
//  That is why the first check after a selection starts from the moment its
//  line's read began, and every later one from the newest token it has seen.
//

import Foundation
import OpenHikesData
import os
import SwiftData

nonisolated enum SelectedLineStoreCheck {
    private static let logger = Logger(subsystem: "OpenHikes", category: "SelectedLine")

    /// What a check needs, as values: the hike stays where its context lives.
    struct Request: Sendable {
        let container: ModelContainer
        let persistentID: PersistentIdentifier
        /// The hike's own store, the one whose transactions are read.
        let storeID: String
        /// When the read of the line the readers hold began. A check with no
        /// ``token`` reads every transaction committed since; one the read
        /// already saw is found the same line by the refresh it costs.
        let since: Date
        /// The newest transaction of the store an earlier check has read.
        let token: DefaultHistoryToken?
    }

    struct Answer: Sendable {
        /// Where the next check starts, or `nil` to start from the read again.
        let token: DefaultHistoryToken?
        /// Whether a transaction since the last check saved the hike's row.
        let savedRow: Bool
    }

    /// How a check is made. A seam, so a suite can hold one in flight while
    /// the selection moves on around it.
    typealias Making = @concurrent @Sendable (Request) async -> Answer

    /// Reads the store's history since the last check, in a context of its
    /// own.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor, and the caller is the main actor.
    @concurrent
    static func answer(_ request: Request) async -> Answer {
        assertOffMainThread("Reading the store's history for the selected line must stay off the main thread")
        let context = ModelContext(request.container)
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try context.fetchHistory(descriptor(for: request))
        } catch {
            // An expired token, say. With no history there is nothing to rule
            // out: let the refresh compare, and start from the read again.
            logger.error(
                "Could not read history for the selected line: \(error.localizedDescription, privacy: .public)"
            )
            return Answer(token: nil, savedRow: true)
        }
        let own = transactions.filter { $0.storeIdentifier == request.storeID }
        let newest = own.max { $0.transactionIdentifier < $1.transactionIdentifier }
        return Answer(
            token: newest?.token ?? request.token,
            savedRow: own.contains { savesRow($0, of: request.persistentID) }
        )
    }

    private static func descriptor(for request: Request) -> HistoryDescriptor<DefaultHistoryTransaction> {
        if let token = request.token {
            return HistoryDescriptor(predicate: #Predicate { $0.token > token })
        }
        let since = request.since
        return HistoryDescriptor(predicate: #Predicate { $0.timestamp >= since })
    }

    /// Whether `transaction` updated the row of the hike `hike` identifies;
    /// see the header for why not whether it wrote the line.
    private static func savesRow(_ transaction: DefaultHistoryTransaction, of hike: PersistentIdentifier) -> Bool {
        transaction.changes.contains { change in
            guard case .update = change else { return false }
            return change.changedPersistentIdentifier == hike
        }
    }
}
