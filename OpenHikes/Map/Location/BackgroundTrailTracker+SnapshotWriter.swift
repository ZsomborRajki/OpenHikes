//
//  BackgroundTrailTracker+SnapshotWriter.swift
//  OpenHikes
//
//  The tracker's off-main App Group write path: the selection counter the
//  detached work checks itself against, and the actor that owns every read and
//  write of the widget's trail payload.
//
//  Split out rather than left in the class body for the reason `HikeRecorder`
//  is split: `BackgroundTrailTracker.swift` had reached the file-length limit,
//  and this is the part of it with a boundary of its own — nothing here
//  touches the tracker's main-actor state, and everything here runs off the
//  main thread. Nesting is kept, so both types are still reached as
//  `BackgroundTrailTracker.SnapshotWriter` and read as belonging to it.
//
//  `internal` rather than `private` is the cost of that split, and it is the
//  same trade `TrailBasemapRenderer.RenderInput` already makes: a nested type
//  is only reachable through the type that nests it, which is where the
//  narrowing that matters comes from.
//

import Foundation
import OpenHikesShared
import Synchronization

extension BackgroundTrailTracker {
    /// The revision of the current selection, shared between the main-actor
    /// tracker that bumps it and the detached snapshot work that has to ask
    /// whether its result is still wanted.
    ///
    /// A box rather than a plain `UInt64` because those two hold the same
    /// counter, and `Atomic` — which is what a shared scalar needs, without
    /// the mutual exclusion a mutex would also impose — makes it `Sendable`
    /// outright instead of by assertion.
    nonisolated final class SelectionGeneration: Sendable {
        private let value = Atomic<UInt64>(0)

        func update(to newValue: UInt64) {
            value.store(newValue, ordering: .releasing)
        }

        func matches(_ candidate: UInt64) -> Bool {
            value.load(ordering: .acquiring) == candidate
        }
    }

    /// Every read and write of the App Group snapshot this type makes, away
    /// from the main actor. The generation gate prevents canceled selection
    /// work from committing stale data.
    ///
    /// One place rather than two, so a live fix and the trail it belongs to
    /// cannot interleave: `SharedStore` is a read-modify-write over one file,
    /// and the mutual exclusion here is what makes each of the methods below
    /// atomic against the others. It is not, on its own, enough to *order*
    /// them — an actor says nothing about which suspended caller resumes
    /// first — which is why the ordering guarantee lives at the call sites,
    /// in the task chains they await.
    actor SnapshotWriter {
        private let generation: SelectionGeneration
        /// The redraw seam — see ``TrailWidgetReload``, which also holds the
        /// precedence rule this feed's redraws are gated on.
        private let widgetReload: TrailWidgetReload

        init(generation: SelectionGeneration, widgetReload: TrailWidgetReload) {
            self.generation = generation
            self.widgetReload = widgetReload
        }

        func save(_ snapshot: SharedTrailSnapshot, ifCurrent revision: UInt64) -> Bool {
            assertOffMainThread("Widget snapshot writes must stay off the main thread")
            guard generation.matches(revision) else { return false }
            SharedStore.save(snapshot)
            return generation.matches(revision)
        }

        func clear(ifCurrent revision: UInt64) -> Bool {
            assertOffMainThread("Widget snapshot deletion must stay off the main thread")
            guard generation.matches(revision) else { return false }
            SharedStore.clear()
            return generation.matches(revision)
        }

        func load() -> SharedTrailSnapshot? {
            assertOffMainThread("Reading the widget snapshot must stay off the main thread")
            return SharedStore.load()
        }

        /// Redraws the widget unless a live recording owns it — the
        /// precedence rule, and the argument for gating it here, are in
        /// ``TrailWidgetReload``.
        ///
        /// On the writer rather than at the three call sites because the
        /// decision costs an App Group read, and every other read this feed
        /// makes is already behind this actor for exactly that reason. It
        /// deliberately takes no revision: a redraw asked for by a superseded
        /// selection is at worst a redraw of what is already on screen, and
        /// every caller has re-checked its own revision on the line above.
        func reloadWidget() { widgetReload.requestUnlessRecording() }

        /// Replaces just the live-fix portion of the stored snapshot,
        /// rebuilding the trail from `input` first when the store holds a
        /// different one — which is what a background relaunch finds, and
        /// what makes this the expensive half of the feed rather than the
        /// cheap one.
        ///
        /// Returns what landed, so the caller knows whether to re-render the
        /// widget's basemaps, or `nil` when the selection moved on while this
        /// was queued and the write would have restored a superseded trail.
        func applyLiveFix(
            _ fix: SharedTrailSnapshot.LiveFix?,
            input: SnapshotInput,
            elevation: RouteElevationSummary,
            walk: SharedTrailSnapshot.Walk?,
            ifCurrent revision: UInt64
        ) -> LiveFixWrite? {
            assertOffMainThread("Widget live-fix writes must stay off the main thread")
            guard generation.matches(revision) else { return nil }
            var stored = SharedStore.load()
            let isNewTrail = stored?.hikeID != input.hikeID
            if isNewTrail {
                stored = BackgroundTrailTracker.buildSnapshot(
                    from: input,
                    elevation: elevation,
                    liveFix: nil
                )
            }
            guard var snapshot = stored, generation.matches(revision) else { return nil }
            snapshot.liveFix = fix
            snapshot.walk = walk
            snapshot.updatedAt = .now
            SharedStore.save(snapshot)
            return LiveFixWrite(snapshot: snapshot, isNewTrail: isNewTrail)
        }

        /// Replaces just the walk portion of the stored snapshot, leaving the
        /// fix where it is — a pause does not move the walker.
        ///
        /// Returns what landed, or `nil` when the store holds a different
        /// trail: a walk's state belongs beside its own trail and nowhere
        /// else, and the selection publication that put the other trail
        /// there has already been deferred by the tracker while the walk
        /// lives, so this is a guard rather than a path.
        func applyWalk(
            _ walk: SharedTrailSnapshot.Walk?,
            hikeID: UUID,
            ifCurrent revision: UInt64
        ) -> SharedTrailSnapshot? {
            assertOffMainThread("Widget walk writes must stay off the main thread")
            guard generation.matches(revision),
                  var snapshot = SharedStore.load(),
                  snapshot.hikeID == hikeID
            else { return nil }
            snapshot.walk = walk
            snapshot.updatedAt = .now
            SharedStore.save(snapshot)
            return snapshot
        }
    }
}
