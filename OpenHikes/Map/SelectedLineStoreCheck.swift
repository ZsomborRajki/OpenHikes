//
//  SelectedLineStoreCheck.swift
//  OpenHikes
//
//  The off-main half of `SelectedLineStoreWatch`: does the store hold a line
//  for the selected hike other than the one its readers hold, given that
//  something has just saved to that store?
//
//  Persistent history answers whether anything since the last check updated
//  the hike's row at all. That costs about 0.3 ms, flat in the history's
//  depth: measured three thousand transactions deep on iOS 18.6 and 27. A
//  save of another hike, or of nothing since the last check, ends the check
//  there. A save of this hike's row is confirmed by decoding the stored line
//  and comparing it with the held one, about 25 ms for twenty thousand points.
//
//  The row, and not the attribute: history's `updatedAttributes` would say
//  whether `route` was written, and on iOS 27 it said so correctly, naming it
//  for every write of the line, an identical one included. On 18.6 it named
//  `route` for a rename and left it out of a write of the line, and which of
//  the two happened changed from run to run. A filter trusting it there could
//  miss a line, so a rename, a tint or a photo on the selected hike costs a
//  decode and a compare, and is never reported. Which row a change belongs to
//  was right on both.
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
//  That is why the first check after a read starts from the moment the read
//  began, and every later one from the newest token it has seen.
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
        let hikeID: UUID
        let persistentID: PersistentIdentifier
        /// The hike's own store, the one whose transactions are read.
        let storeID: String
        /// When the read of ``held`` began. A check with no ``token`` reads
        /// every transaction committed since; any the read already saw compare
        /// equal.
        let since: Date
        /// The newest transaction of the store an earlier check has read.
        let token: DefaultHistoryToken?
        /// The line the readers hold.
        let held: [RouteCoordinate]
        /// Compare whatever history says. An earlier check found the line
        /// different and could not act on it yet; see `SelectedLineStoreWatch`.
        let comparesRegardless: Bool
    }

    struct Answer: Sendable {
        /// Where the next check starts, or `nil` to start from the read again.
        let token: DefaultHistoryToken?
        let finding: Finding
    }

    enum Finding: Sendable, Equatable {
        /// The store holds this line, and the readers hold another.
        case newLine([RouteCoordinate])
        /// The stored line is the one held, the hike is gone, or nothing gave
        /// a reason to read the line at all.
        case sameLine
    }

    /// A stored line, as a read hands it back: `nil` for a hike that is not
    /// in the store.
    struct StoredLine: Sendable {
        let route: [RouteCoordinate]
    }

    /// How a check reads the stored line. A seam, so a suite can count the
    /// decodes history is there to spare and see which thread made them.
    typealias LineRead = @Sendable (ModelContext, UUID) -> StoredLine?

    static let storedLine: LineRead = { context, hikeID in
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first.map { StoredLine(route: $0.route) }
    }

    /// Reads the store's history since the last check, in a context of its
    /// own, and the stored line if that history gives a reason to.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor, and the caller is the main actor.
    @concurrent
    static func answer(_ request: Request, read: LineRead = storedLine) async -> Answer {
        assertOffMainThread("Checking the selected line against the store must stay off the main thread")
        let context = ModelContext(request.container)
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try context.fetchHistory(descriptor(for: request))
        } catch {
            // An expired token, say. With no history there is nothing to
            // filter on: compare, and start from the read again next time.
            logger.error(
                "Could not read history for the selected line: \(error.localizedDescription, privacy: .public)"
            )
            return Answer(token: nil, finding: finding(for: request, in: context, read: read))
        }
        let own = transactions.filter { $0.storeIdentifier == request.storeID }
        let newest = own.max { $0.transactionIdentifier < $1.transactionIdentifier }
        let token = newest?.token ?? request.token
        guard request.comparesRegardless || own.contains(where: { updatesRow($0, of: request.persistentID) }) else {
            return Answer(token: token, finding: .sameLine)
        }
        return Answer(token: token, finding: finding(for: request, in: context, read: read))
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
    private static func updatesRow(_ transaction: DefaultHistoryTransaction, of hike: PersistentIdentifier) -> Bool {
        transaction.changes.contains { change in
            guard case .update = change else { return false }
            return change.changedPersistentIdentifier == hike
        }
    }

    /// Whether the stored line is the one held. A hike that is gone has
    /// nothing to say here: its deselection is the selection's business.
    private static func finding(for request: Request, in context: ModelContext, read: LineRead) -> Finding {
        guard let stored = read(context, request.hikeID), stored.route != request.held else { return .sameLine }
        return .newLine(stored.route)
    }
}
