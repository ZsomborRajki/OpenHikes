//
//  SelectedLineStoreWatch.swift
//  OpenHikes
//
//  Notices that another context saved the selected hike, such as an edit
//  mirrored in from the hiker's other device, and has the selection's readers
//  look at its line again (#1228).
//
//  Observation cannot tell them on its own. The readers watch
//  `Hike.lineRevision`, which only a line written through the main context
//  moves (see `SelectedLine`). A line saved through any other context reaches
//  the main context's copy of the hike only through a refresh, and there are
//  two cases, both measured on iOS 18.6 and 27:
//  - With a `@Query` live in a window, every save to the store refreshes
//    every registered hike and notifies every persisted property, changed or
//    not. That is too much to redraw on, and no revision moves for it.
//  - With no live `@Query`, nothing refreshes the hike, and it keeps the old
//    line until something fetches it.
//  The saves measured were a sibling context's, a save of another hike, and a
//  Core Data context on SwiftData's own coordinator standing in for the
//  mirroring import.
//
//  What the watch listens to is the store's remote-change notification.
//  SwiftData turns it on for both stores, along with the persistent history
//  the check reads, and it is posted once for every save of a store, by every
//  context. That includes the import stand-in, which posted no
//  `ModelContext.didSave`. A save of the other store (tile claims, the walk
//  in progress) is dropped on the thread that posted it, before any hop here.
//  A save of the hike's own store costs one look at history
//  (`SelectedLineStoreCheck`), and so does following a hike: a hike selected
//  again is handed the read it had, which a line saved while it was let go
//  has not replaced, so the first check runs at once, from that read.
//
//  A save of the selected hike's row costs a refresh. The watch fetches the
//  hike where it lives, which brings the stored row into the main context's
//  copy, so a later save there cannot write the old line back and the
//  readers' columns match the stored line. Then it calls
//  `SelectedLine.refresh()`, which compares the stored line off the main
//  actor with the one the readers hold and hands it out only if it differs.
//
//  The main context's own saves are not told apart by author. An author on
//  the main context would change every transaction it writes, and what
//  mirroring's export makes of that could not be checked here. Until an
//  import gives the watch its first token, a check reads only what the import
//  wrote, which leaves those saves out (see `SelectedLineStoreCheck`). After
//  that, a line written here, such as heights filled in, costs one more
//  refresh, which finds the line its readers already have.
//
//  A hike with unsaved changes cannot take a refresh. A fetch keeps its
//  snapshot, and its next save writes that snapshot's line back over the one
//  received, measured on both. That is the last writer winning, as AGENTS.md
//  *Persistence and sync* has it: SwiftData owns sync, a save re-uploads the
//  whole row, and nothing here tries to save the other device's line. So the
//  watch waits for that save. It saves the row too, and the check it starts
//  refreshes then. The map follows whatever line the store ends up holding.
//

import CoreData
import Foundation
import OpenHikesData
import os
import SwiftData
import Synchronization

@MainActor
final class SelectedLineStoreWatch {
    private static let logger = Logger(subsystem: "OpenHikes", category: "SelectedLine")

    /// The store of the hike being followed, readable on whatever thread posts
    /// a remote change, so that a save of the other store is dropped there
    /// rather than hopping here to be dropped.
    nonisolated private final class StoreFilter: Sendable {
        private let storeID = Mutex<String?>(nil)

        func admit(_ id: String?) { storeID.withLock { $0 = id } }

        func admits(_ id: String) -> Bool { storeID.withLock { $0 == id } }
    }

    private struct Followed {
        let hike: Hike
        let container: ModelContainer
        let storeID: String
        let since: Date
        let generation: Int
        var token: DefaultHistoryToken?
    }

    private let making: SelectedLineStoreCheck.Making
    private let lineMayHaveChanged: () -> Void
    private let filter = StoreFilter()
    /// Removed by the `isolated deinit` below. SE-0371 hops that deinit back
    /// to the main actor, so this is only ever touched where it was written.
    private var observer: (any NSObjectProtocol)?
    private var followed: Followed?
    /// Identifies the current follow, so a check still in flight for the one
    /// before is dropped when it lands.
    private var generation = 0
    /// A save arrived while a check was in flight: one more check runs when
    /// it lands, however many arrived.
    private var checksAgain = false

    /// The check in flight, if any, and how many have landed. Readable so a
    /// suite can wait on the effect rather than on a duration.
    private(set) var check: Task<Void, Never>?
    private(set) var completedChecks = 0
    /// How many remote changes got past the posting thread's filter and hopped
    /// here. A seam: the check behind it drops the same ones, so without this
    /// a filter that let every store through would look exactly like one that
    /// works, while costing a hop per tile claim.
    private(set) var deliveredChanges = 0
    var isSettled: Bool { check == nil && !checksAgain }

    /// - Parameter lineMayHaveChanged: Called once the followed hike's own
    ///   copy holds what the store does, after a save of its row: the app's
    ///   is ``SelectedLine/refresh()``.
    init(
        making: @escaping SelectedLineStoreCheck.Making = SelectedLineStoreCheck.answer,
        lineMayHaveChanged: @escaping () -> Void
    ) {
        self.making = making
        self.lineMayHaveChanged = lineMayHaveChanged
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Follows `hike`, whose readers hold a line from a read that began at
    /// `since`, and checks the store from then at once. A hike that is not
    /// saved yet has no store to watch.
    ///
    /// The check cannot wait for the next save. A hike selected again is
    /// handed the read it had, and a line saved elsewhere while nothing was
    /// followed has replaced nothing: it moves no revision, and its remote
    /// change was dropped where it was posted. Nor was anything listening
    /// between the start of a new selection's read and this call.
    func follow(_ hike: Hike, since: Date) {
        guard let container = hike.modelContext?.container,
              let storeID = hike.persistentModelID.storeIdentifier else {
            stopFollowing()
            return
        }
        generation &+= 1
        followed = Followed(hike: hike, container: container, storeID: storeID, since: since, generation: generation)
        filter.admit(storeID)
        observeIfNeeded()
        startCheck()
    }

    /// Follows nothing: no save wakes the watch until the next ``follow(_:since:)``.
    func stopFollowing() {
        generation &+= 1
        followed = nil
        filter.admit(nil)
    }

    /// Whether `hike` is the hike followed now. A hike's screen asks, to
    /// read the line the selection's readers read only while it is theirs —
    /// see ``ShownLine``.
    func follows(_ hike: Hike) -> Bool {
        followed?.hike === hike
    }

    private func observeIfNeeded() {
        guard observer == nil else { return }
        let admitted = filter
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Whichever thread posted it. That was never the main one when
            // measured, not even for the main context's own saves, but
            // `onMainActor` copes either way.
            guard let storeID = Self.storeID(of: notification), admitted.admits(storeID) else { return }
            onMainActor { [weak self] in self?.storeDidChange(storeID) }
        }
    }

    nonisolated private static func storeID(of notification: Notification) -> String? {
        let value = notification.userInfo?[NSStoreUUIDKey]
        return (value as? String) ?? (value as? UUID)?.uuidString
    }

    private func storeDidChange(_ storeID: String) {
        deliveredChanges &+= 1
        guard followed?.storeID == storeID else { return }
        startCheck()
    }

    private func startCheck() {
        guard check == nil else {
            checksAgain = true
            return
        }
        guard let followed else { return }
        let request = SelectedLineStoreCheck.Request(
            container: followed.container,
            persistentID: followed.hike.persistentModelID,
            storeID: followed.storeID,
            since: followed.since,
            token: followed.token
        )
        let started = followed.generation
        let make = making
        check = Task { [weak self] in
            let answer = await make(request)
            self?.land(answer, generation: started)
        }
    }

    private func land(_ answer: SelectedLineStoreCheck.Answer, generation: Int) {
        check = nil
        completedChecks &+= 1
        if var current = followed, current.generation == generation {
            current.token = answer.token
            followed = current
            if answer.savedRow { refresh(current.hike) }
        }
        if checksAgain {
            checksAgain = false
            startCheck()
        }
    }

    /// Brings the stored row into the hike's own copy, then has the readers
    /// look at its line. The fetch does it silently, which is why they are
    /// told.
    ///
    /// Not while the hike holds unsaved changes. A fetch keeps that snapshot,
    /// and the save that follows decides which line the store keeps. That
    /// save posts a remote change of its own, for this row, and the check it
    /// starts comes back here.
    private func refresh(_ hike: Hike) {
        guard !hike.hasChanges, let context = hike.modelContext else { return }
        do {
            _ = try SelectedLine.fetchHike(context, hike.persistentModelID)
        } catch {
            Self.logger.error(
                "Could not refresh the selected hike: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        lineMayHaveChanged()
    }
}
