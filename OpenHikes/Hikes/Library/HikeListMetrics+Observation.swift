//
//  HikeListMetrics+Observation.swift
//  OpenHikes
//
//  A Hilliest list keeps its figures true for as long as its task runs. The
//  task's first pass validates every listed hike, and after that only a hike
//  whose line may have been written since:
//  - through the main context (heights filled in, a recording finished),
//    which moves that hike's line revision at once;
//  - by another context, such as an edit mirrored in from the hiker's other
//    device, which the store's history names by its row.
//  Validating a hike is what it always was: its line read in a context of
//  its own, fingerprinted, and measured only if the fingerprint cached beside
//  its figures is not that line's.
//
//  Not `route` (#1253). The hikes list's `@Query` is always up in a window,
//  and with it up every save to the Hikes store, of any hike by any context,
//  refreshes every hike in the main context and notifies every persisted
//  property, `route` included, changed or not (#1228, measured on iOS 18.6
//  and 27). Watched there, a tint, a rename, a walk or an import read every
//  listed route again: thirty hikes of 20,000 points took about 900 ms off
//  the main actor per save, while nothing on screen changed. Neither signal
//  here moves for a refresh. The revision is not stored, and history lists
//  only what was saved. History names the row and not the column, for the
//  reason `StoreHistoryCheck` gives, so a save of a listed hike that a look
//  reads, a rename, a tint or a walk, costs that one hike's line, about 30 ms
//  of 20,000 points, and a save of the other store costs nothing.
//
//  A look with no token reads only CloudKit's imports, because a read by time
//  alone returns the device-local store's transactions too, and SwiftData
//  traps building a walk's (see `StoreHistoryCheck`). So the main context's
//  own saves are in what a look reads only once it holds a token, taken from
//  the first import it finds; from then on a line written here is named twice
//  and validated once. Before then, and while history cannot be read, the
//  revision is what names it.
//
//  One thing at a time, and figures from a line already replaced are not
//  kept. After each pass the task asks what changed while it measured, before
//  it publishes. A hike whose line was written or saved meanwhile is measured
//  again, and its figures from the line before are dropped. A save in the
//  moment between that look and the publication gets past it: those figures
//  land, and the next look names the hike, so they are measured again at
//  once. The first look reads the imports committed since the first pass
//  began, because a save before then is in that pass and one after it may
//  not be. Each later look reads from the newest transaction the one before
//  saw. A task cancelled at any point, as switching the list to another order
//  cancels it, measures and publishes nothing more.
//
//  A look that cannot read history names no row, and the first such look
//  asks for one more at once; a line written here needs no history. The
//  wakes and the looks are the ones the library's lines on the map are kept
//  true by too, and `StoreSaves.swift` says why a failed look is read that
//  way.
//
//  All of it stays in the list's task, never its body. Routes are read,
//  fingerprinted and measured in a context of their own, publication reads
//  no route, and the sort keeps reading only its cached scalar figures.
//

import Algorithms
import Foundation
import OpenHikesData
import SwiftData

nonisolated extension HikeListMetrics {
    /// How listed lines are read and measured: ``measureElevation(for:in:)``,
    /// or a stand-in a suite counts and holds.
    typealias Measuring = @concurrent @Sendable ([UUID], ModelContainer) async -> [ElevationMeasurement]

    /// Keeps the figures of `hikes` true while the calling task runs: every
    /// one first, then each whose line may have changed. See the file header.
    ///
    /// - Parameters:
    ///   - measuring: How lines are read and measured. A seam.
    ///   - checking: How the store's history is read. A seam.
    ///   - didChange: Called after a publication that changed a figure.
    @MainActor
    static func observeElevation(
        in hikes: [Hike],
        container: ModelContainer,
        measuring: Measuring = HikeListMetrics.measureElevation,
        checking: @escaping StoreHistoryCheck.Making = StoreHistoryCheck.answer,
        didChange: @MainActor () -> Void
    ) async {
        let lines = ListedLines(hikes, container: container, checking: checking)
        var due = hikes.map(\.id)
        for await _ in lines.changes {
            repeat {
                var measured: [ElevationMeasurement] = []
                if !due.isEmpty { measured = await measuring(due, container) }
                guard !Task.isCancelled else { return }
                let changed = await lines.changedSinceLastLook()
                guard !Task.isCancelled else { return }
                if cacheElevation(measured.filter { !changed.contains($0.hikeID) }, in: container) {
                    didChange()
                }
                due = hikes.map(\.id).filter(changed.contains)
            } while !due.isEmpty
        }
    }

    /// What wakes a Hilliest list's task, and which listed hikes each wake is
    /// for. Made when the task starts and gone when it ends, observer and all.
    @MainActor
    private final class ListedLines {
        /// One element at once, for the first pass, then one after each
        /// change, however many arrive while the task is busy.
        var changes: AsyncStream<Void> { saves.changes }
        private let hikes: [Hike]
        /// The saves of the listed hikes' store, which wake the task, and its
        /// history: see ``StoreSaves``.
        private let saves: StoreSaves
        /// Each listed hike's line revision when last read, in `hikes`' order.
        private var revisions: [Int] = []
        /// The hikes whose revision moved since the last look.
        private var written: Set<UUID> = []

        init(_ hikes: [Hike], container: ModelContainer, checking: @escaping StoreHistoryCheck.Making) {
            self.hikes = hikes
            // The store the listed hikes live in, read when the task starts.
            // None if none of them had been saved by then, which a list never
            // meets: the app saves every hike in the turn that inserts it.
            saves = StoreSaves(
                in: container,
                store: hikes.firstNonNil(\.persistentModelID.storeIdentifier),
                checking: checking
            )
            revisions = trackLines()
        }

        /// The listed hikes whose line may have changed since the last look:
        /// written through the main context, or their row saved by any.
        func changedSinceLastLook() async -> Set<UUID> {
            var changed = written
            written = []
            var ids: [PersistentIdentifier: UUID] = [:]
            for hike in hikes { ids[hike.persistentModelID] = hike.id }
            let saved = await saves.savedRows(among: Set(ids.keys))
            changed.formUnion(saved.compactMap { ids[$0] })
            return changed
        }

        /// Registers every listed hike's line revision, which only a line
        /// written through the main context moves, and answers what each
        /// reads now. The registration is spent by the first write.
        private func trackLines() -> [Int] {
            withObservationTracking {
                hikes.map(\.lineRevision)
            } onChange: { [weak self] in
                // Mid-write: the new revision can only be read once it has
                // landed.
                Task { @MainActor in self?.linesWereWritten() }
            }
        }

        /// Notes which revisions moved, registers again, and wakes the task.
        private func linesWereWritten() {
            let current = trackLines()
            for (hike, (before, after)) in zip(hikes, zip(revisions, current)) where before != after {
                written.insert(hike.id)
            }
            revisions = current
            if !written.isEmpty { saves.wake() }
        }
    }
}
