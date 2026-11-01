//
//  StoreSaves.swift
//  OpenHikes
//
//  What wakes a task that keeps something true to the Hikes store, and which
//  of its rows the store's history says were saved since the task last
//  looked. Two tasks keep such a thing: the Hilliest list's figures
//  (`HikeListMetrics+Observation.swift`, #1253) and the library's lines on the
//  map (`LibraryLines.swift`). Each reads every line once, then only the lines
//  whose rows may have been saved since, and this is the part of that they
//  share.
//
//  ## Waking
//
//  ``StoreSaves/changes`` has one element at once, for the task's first pass,
//  and one after each save of the store, however many arrive while the task
//  is busy. A save is the store's remote-change notification, which SwiftData
//  posts once for every save of a store, by every context, an import's
//  included (see `SelectedLineStoreWatch.swift`). A save of the other store,
//  the device-local one, is dropped on the thread that posted it, once the
//  task has named its store. Until then every store's saves wake it, so a
//  library that held nothing at first still hears its first import.
//
//  ## Looking
//
//  ``StoreSaves/savedRows(among:)`` reads the store's history since the last
//  look, through `StoreHistoryCheck`, which says why a look with no token
//  reads only CloudKit's imports and why it names rows rather than columns.
//  The main context's own saves are each caller's to name, because the two
//  name different things: the list watches line revisions, which only a line
//  written here moves, and the library watches the main context's saves,
//  which name a new colour too.
//
//  A look that cannot read history names no row. Naming every row would read
//  every line again, the pass both tasks exist to avoid, and a failure that
//  held would ask for one after every look. Nor can it leave the rest to the
//  next save: it took the wake of the save it was looking for, and another
//  may never come. So the first look to fail asks for one more at once. That
//  one reads the imports since the task began, which an expired token cannot
//  stop, and names any the failed look could not, while history still holds
//  it. A failure that holds asks for nothing more until a look reads history
//  again. Nothing in the app prunes history.
//
//  `SelectedLineStoreWatch` asks the same history about one row, and is left
//  apart: it checks on demand rather than from a task, and takes a look it
//  cannot read as its row saved, since one more look at one line is cheap.
//

import CoreData
import Foundation
import SwiftData
import Synchronization

@MainActor
final class StoreSaves {
    /// One element at once, for the first pass, then one after each save of
    /// the store, however many arrive while the task is busy.
    let changes: AsyncStream<Void>
    private let wakeUp: AsyncStream<Void>.Continuation
    private let container: ModelContainer
    private let checking: StoreHistoryCheck.Making
    /// When the task began: where a look with no token reads imports from, as
    /// the first does, and any after one that could not read history.
    private let since: Date
    private let store = WatchedStore()
    private var token: DefaultHistoryToken?
    /// Whether the last look could not read history: see the file header.
    private var lookFailed = false
    /// Removed by the `isolated deinit` below, on the main actor.
    private var observer: (any NSObjectProtocol)?

    /// How many times the task has been woken, the first pass included. A
    /// seam: ``changes`` gathers the wakes that arrive together into one, so
    /// without this a wake that should never have come would look like none.
    var wakes: Int { store.wakes }

    /// - Parameters:
    ///   - store: The store whose saves wake the task, when it is known now.
    ///   - checking: How the store's history is read. A seam.
    init(
        in container: ModelContainer,
        store storeID: String? = nil,
        checking: @escaping StoreHistoryCheck.Making = StoreHistoryCheck.answer
    ) {
        (changes, wakeUp) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.container = container
        self.checking = checking
        since = .now
        store.name(storeID)
        let watched = store
        let continuation = wakeUp
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: nil
        ) { notification in
            // Whichever thread posted it, and dropped there unless it may be
            // the store's.
            guard watched.admits(StoreHistoryCheck.storeID(of: notification)) else { return }
            watched.countWake()
            continuation.yield()
        }
        wake()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        wakeUp.finish()
    }

    /// Narrows the saves that wake the task to `storeID`'s. `nil` names no
    /// store, and keeps the one named before.
    func watch(store storeID: String?) {
        store.name(storeID)
    }

    /// Wakes the task once more, as a save would.
    func wake() {
        store.countWake()
        wakeUp.yield()
    }

    /// The rows of `rows` that a transaction since the last look saved, by
    /// the store's history. None when there is nothing to ask about or no
    /// store named yet, and none when history cannot be read, in which case
    /// the first such look asks for one more at once: see the file header.
    func savedRows(among rows: Set<PersistentIdentifier>) async -> Set<PersistentIdentifier> {
        guard !rows.isEmpty, let storeID = store.named else { return [] }
        let answer = await checking(StoreHistoryCheck.Request(
            container: container,
            rows: rows,
            storeID: storeID,
            since: since,
            token: token
        ))
        token = answer.token
        guard answer.wasRead else {
            if !lookFailed { wake() }
            lookFailed = true
            return []
        }
        lookFailed = false
        return answer.savedRows
    }
}

/// The store whose saves wake a task, and how many wakes it has had, both
/// read on whichever thread posts a remote change.
nonisolated private final class WatchedStore: Sendable {
    private let storeID = Mutex<String?>(nil)
    private let wakeCount = Mutex(0)

    var named: String? { storeID.withLock { $0 } }
    var wakes: Int { wakeCount.withLock { $0 } }

    func name(_ id: String?) {
        guard let id else { return }
        storeID.withLock { $0 = id }
    }

    /// Whether a save of `id` may be the store's: every store's until one is
    /// named.
    func admits(_ id: String?) -> Bool {
        storeID.withLock { named in named == nil || named == id }
    }

    func countWake() {
        wakeCount.withLock { $0 += 1 }
    }
}
