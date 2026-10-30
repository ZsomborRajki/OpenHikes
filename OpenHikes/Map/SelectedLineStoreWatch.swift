//
//  SelectedLineStoreWatch.swift
//  OpenHikes
//
//  Notices that the store holds a new line for the selected hike that nobody
//  wrote through the main context (an edit mirrored in from another device),
//  brings it into the main context's copy of the hike, and says so (#1228).
//
//  Observation cannot say so on its own. The main context's hike hears its
//  own writes. A line saved through any other context reaches it only through
//  a refresh, and there are two cases, both measured on iOS 18.6 and 27:
//  - With a `@Query` live in a window, every save to the store refreshes
//    every registered hike and notifies every observer of every persisted
//    property, whether or not anything changed.
//  - With no live `@Query`, nothing refreshes the hike, and it keeps the old
//    line until something fetches it.
//  The saves measured were a sibling context's, a save of another hike, and a
//  Core Data context on SwiftData's own coordinator standing in for the
//  mirroring import. The first case is too much to redraw on and the second
//  too little. So a reader of the line watches `Hike.lineRevision`, which no
//  refresh reaches, and this watch is what moves it for a line written
//  elsewhere.
//
//  What it listens to is the store's remote-change notification. SwiftData
//  turns it on for both stores, along with the persistent history the check
//  reads, and it is posted once for every save of a store by every context.
//  That includes the import stand-in, which posted no `ModelContext.didSave`.
//  A save of the other store (tile claims, the walk in progress) is dropped on
//  the thread that posted it, before any hop here. What a save of the hike's
//  own store costs is `SelectedLineStoreCheck`'s to say.
//
//  The main context's own writes are not told apart by author. An author on
//  the main context would change every transaction it writes, and what
//  mirroring's export makes of that could not be checked here. So a local
//  *Edit Route* is read and compared once more, then dropped as overtaken; see
//  `take(_:)`.
//
//  A hike with unsaved changes cannot take a refresh. A fetch keeps its
//  snapshot, and its next save writes that snapshot's line back over the one
//  received, measured on both. That is the last writer winning, as AGENTS.md
//  *Persistence and sync* has it: SwiftData owns sync, a save re-uploads the
//  whole row, and nothing here tries to save the other device's line. So the
//  watch waits for that save, which posts a remote change of its own, and
//  compares again. The map follows whatever line the store ends up holding.
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
        /// The line the readers hold, and the hike's ``Hike/lineRevision``
        /// when they read it.
        var line: [RouteCoordinate]
        var lineRevision: Int
        var token: DefaultHistoryToken?
        /// The store's line differed from ``line`` and could not be taken
        /// yet: the next check compares whatever history says.
        var differs = false
    }

    private let read: SelectedLineStoreCheck.LineRead
    private let lineReplaced: (Hike) -> Void
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

    /// - Parameter lineReplaced: Called once the followed hike holds a new
    ///   line from the store and its ``Hike/lineRevision`` has moved. It is
    ///   for the readers that do not watch the revision.
    init(
        read: @escaping SelectedLineStoreCheck.LineRead = SelectedLineStoreCheck.storedLine,
        lineReplaced: @escaping (Hike) -> Void = { _ in /* nobody to tell */ }
    ) {
        self.read = read
        self.lineReplaced = lineReplaced
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Follows `hike`, whose readers hold `line` from a read that began at
    /// `readAt`.
    ///
    /// Called again after every read, including the reads this watch's own
    /// reports cause. A write through the main context moves the hike's
    /// revision past the one recorded here, and the watch stays quiet about
    /// that hike until it is told what the readers made of the write. A hike
    /// that is not saved yet has no store to watch.
    func follow(_ hike: Hike, holding line: [RouteCoordinate], readAt: Date) {
        guard let container = hike.modelContext?.container,
              let storeID = hike.persistentModelID.storeIdentifier else {
            stopFollowing()
            return
        }
        generation &+= 1
        followed = Followed(
            hike: hike,
            container: container,
            storeID: storeID,
            since: readAt,
            generation: generation,
            line: line,
            lineRevision: hike.lineRevision
        )
        filter.admit(storeID)
        observeIfNeeded()
    }

    /// Follows nothing: no save wakes the watch until the next ``follow(_:holding:readAt:)``.
    func stopFollowing() {
        generation &+= 1
        followed = nil
        filter.admit(nil)
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
            hikeID: followed.hike.id,
            persistentID: followed.hike.persistentModelID,
            storeID: followed.storeID,
            since: followed.since,
            token: followed.token,
            held: followed.line,
            comparesRegardless: followed.differs
        )
        let started = followed.generation
        let reading = read
        check = Task { [weak self] in
            let answer = await SelectedLineStoreCheck.answer(request, read: reading)
            self?.land(answer, generation: started)
        }
    }

    private func land(_ answer: SelectedLineStoreCheck.Answer, generation: Int) {
        check = nil
        completedChecks &+= 1
        if var current = followed, current.generation == generation {
            current.token = answer.token
            current.differs = false
            followed = current
            if case .newLine(let replacement) = answer.finding { take(replacement) }
        }
        if checksAgain {
            checksAgain = false
            startCheck()
        }
    }

    /// Brings a line the store holds, and the readers do not, into the main
    /// context's hike, and says so.
    private func take(_ replacement: [RouteCoordinate]) {
        guard var current = followed else { return }
        let hike = current.hike
        // Written through this instance since the readers' line was read. They
        // are reading the write now, and will say what they hold. This is also
        // where a local *Edit Route* lands, read and compared once more,
        // because the main context writes under no author of its own.
        guard hike.lineRevision == current.lineRevision else { return }
        // A fetch keeps an unsaved hike's snapshot, and that hike's next save
        // decides which line the store keeps. That save posts a remote change
        // of its own, and the check it starts compares regardless.
        guard !hike.hasChanges, refresh(hike) else {
            current.differs = true
            followed = current
            return
        }
        hike.lineWasReplacedInStore()
        current.line = replacement
        current.lineRevision = hike.lineRevision
        followed = current
        lineReplaced(hike)
    }

    /// Fetches the hike again where it lives, which is what brings the stored
    /// line into this instance. It does so silently, which is why the revision
    /// moves after it.
    private func refresh(_ hike: Hike) -> Bool {
        guard let context = hike.modelContext else { return false }
        let hikeID = hike.id
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        descriptor.fetchLimit = 1
        do {
            _ = try context.fetch(descriptor)
            return true
        } catch {
            Self.logger.error(
                "Could not refresh the selected hike: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
