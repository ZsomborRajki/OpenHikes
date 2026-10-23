//
//  SharedHikeCatalogPublisher.swift
//  OpenHikes
//
//  Keeping the App Group's copy of the library in step with the real one, and
//  keeping a trail snapshot for every hike a placed widget is pinned to.
//
//  ## Why a sweep rather than a write per change
//
//  The same argument ``HikeSpotlightIndex`` makes, and this runs beside it for
//  that reason. Three things change what should be published — a hike saved, a
//  hike renamed, a hike deleted — and only the first has an obvious hook; a
//  rename happens in the detail view, a delete in two places, and an import
//  writes rows through a path that knows nothing about widgets. Four sites
//  that each have to stay correct is how a copy comes to disagree with the
//  library. A full replace cannot disagree.
//
//  The cost of being wrong the other way is small and self-correcting: a hike
//  saved this session is offered by the widget's picker next launch.
//
//  ## Why only pinned trails get a snapshot
//
//  Because writing one for every hike in a library of three hundred is not the
//  design. A snapshot carries the whole route; three hundred of them is
//  megabytes rewritten on every sweep, for trails nothing is drawing.
//
//  So the set is *what is actually on a screen*:
//  `WidgetCenter.getCurrentConfigurations()` says which hikes the placed
//  widgets are pinned to, the selected trail is kept because the unconfigured
//  widgets follow it, and ``SharedStore/pruneTrailSnapshots(keeping:)`` throws
//  away the rest. A widget pinned to a trail that has never been published
//  draws its empty state until the next sweep, which is the honest cost of not
//  keeping three hundred routes warm. When WidgetKit cannot say what is
//  pinned, nothing is thrown away, because no answer is not an empty one.
//

import Foundation
import OpenHikesData
import OpenHikesShared
import os
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What WidgetKit said about which trails the placed widgets are pinned to.
///
/// A case rather than an optional set, because the two ways of reading "no
/// answer" are opposite and each caller has to pick one out loud — see
/// ``SharedHikeCatalogPublisher/pinnedTrails()``.
nonisolated enum PinnedTrails: Sendable {
    case known(Set<UUID>)
    /// WidgetKit could not answer.
    case unknown
}

nonisolated enum SharedHikeCatalogPublisher {
    private static let logger = Logger(subsystem: "OpenHikes", category: "WidgetCatalog")

    /// Republishes the catalogue and the pinned trails' snapshots.
    ///
    /// Fire-and-forget and silent on failure, for the reason the Spotlight
    /// sweep beside it is: nothing a hiker does depends on this having worked
    /// this second, and the next sweep puts it right.
    ///
    /// - Parameter watch: the watch link, which is handed the *same* list
    ///   rather than being given a sweep of its own. Two independent readings
    ///   of one library is how the two come to disagree, and the disagreement
    ///   would be visible: a hiker's watch offering a trail their widget's
    ///   picker does not. One sweep, one list, two consumers — which is the
    ///   argument this type's header already makes about writing per change.
    static func publish(
        from coordinator: HikeIntentCoordinator,
        container: ModelContainer,
        watch: WatchSessionCoordinator? = nil
    ) {
        Task.detached(priority: .utility) {
            await publishCatalog(from: coordinator, watch: watch)
            await publishPinnedTrails(.live(container: container))
        }
    }

    /// The list the pickers read.
    static func publishCatalog(
        from coordinator: HikeIntentCoordinator,
        watch: WatchSessionCoordinator? = nil
    ) async {
        do {
            let summaries = try await MainActor.run {
                try coordinator.finishedHikes().map(HikeEntity.summary(of:))
            }
            let catalog = SharedHikeCatalog(hikes: summaries)
            SharedStore.saveHikeCatalog(catalog)
            if let watch { await watch.publish(catalog) }
        } catch {
            Self.logger.debug(
                "Hike catalog publish failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// A trail snapshot for each hike a placed widget is pinned to, and
    /// nothing for the hikes none is.
    ///
    /// The selected trail is deliberately **not** published here for being
    /// selected: it has its own file, written by ``BackgroundTrailTracker``,
    /// and mirroring it into the per-hike store is `SharedStore.save(_:)`'s
    /// job. What this adds is the trails nothing would otherwise publish.
    ///
    /// Each pinned trail gets its **map** here too. The renderer keeps a set
    /// per trail, but only the selection's feed ever asked it for one, so a
    /// trail pinned without being selected — or pinned before sets were kept
    /// per trail — drew its line on a grey fill for good.
    ///
    /// **Only an answer prunes.** When WidgetKit cannot say what is pinned,
    /// this publishes nothing and deletes nothing, the snapshots and the maps
    /// alike. Reading the failure as "nothing is pinned" deleted the snapshot
    /// a pinned widget draws its trail from while sparing the map under it,
    /// and with one sweep a launch the widget drew its empty state until the
    /// next. A snapshot nothing draws costs bytes until WidgetKit answers; one
    /// deleted on the guess costs a pinned widget its trail.
    static func publishPinnedTrails(_ sweep: PinnedTrailSweep) async {
        guard case .known(let pinned) = await sweep.pinnedTrails() else { return }
        for hikeID in pinned {
            await sweep.publishTrail(hikeID)
        }
        // The selected trail's mirror survives too, because the unconfigured
        // widgets are following it.
        let kept = pinned.union(sweep.selectedHikeIDs())
        sweep.pruneTrailSnapshots(kept)
        await sweep.pruneBasemaps(kept)
    }

    /// One hike's snapshot, built the same way the tracker builds the selected
    /// one so the two cannot describe the same trail differently.
    private static func publishTrail(_ hikeID: UUID, container: ModelContainer) async {
        let input = await MainActor.run { () -> HikeRouteInput? in
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
            // A hike deleted since the widget was configured. Nothing to draw
            // and nothing to report: the prune below takes its file, and the
            // widget shows its empty state.
            guard let hike = try? context.fetch(descriptor).first else { return nil }
            return HikeRouteInput(hike: hike)
        }
        guard let input,
              let snapshot = await BackgroundTrailTracker.buildSnapshotOffMain(
                  from: input,
                  liveFix: nil
              )
        else { return }
        // No live fix, and that is the shape rather than an omission.
        // `BackgroundTrailTracker` publishes a fix for the *tracked* hike only
        // — one hike is being walked — so a widget pinned to a different trail
        // has no live position to draw and renders the static route. That case
        // did not exist before this change and is the one worth a test.
        SharedStore.saveTrailSnapshot(snapshot)
        // Framed from the same decimated polyline the widget draws, as the
        // selection's map is. A no-op when the set on disk already frames it.
        await TrailBasemapRenderer.shared.refreshPinned(
            hikeID: hikeID,
            polyline: snapshot.polyline
        )
    }

    /// The hikes the placed widgets are pinned to, or that WidgetKit cannot
    /// answer.
    ///
    /// What no answer means depends on the question, because the safe reading
    /// is opposite for the two. For what to *publish* it reads as "nothing is
    /// pinned" — publishing every hike because the system was momentarily
    /// unavailable is the cost this whole policy exists to avoid. For what to
    /// *delete* it reads as "keep everything", the snapshots and the maps
    /// alike — see ``publishPinnedTrails(_:)`` and
    /// `TrailBasemapRenderer.PinnedHikes`.
    static func pinnedTrails() async -> PinnedTrails {
        #if canImport(WidgetKit)
        let configurations = try? await WidgetCenter.shared.currentConfigurations()
        guard let configurations else { return .unknown }
        return .known(Set(
            configurations.compactMap { info in
                (info.widgetConfigurationIntent(of: TrailWidgetConfiguration.self))?.hike?.id
            }
        ))
        #else
        return .known([])
        #endif
    }

    /// The selected trail, whose snapshot must survive the prune because the
    /// unconfigured widgets are all following it.
    private static func selectedHikeIDs() -> Set<UUID> {
        guard let stored = UserDefaults.standard.string(
            forKey: SettingsKey.lastSelectedHikeID
        ), let id = UUID(uuidString: stored) else { return [] }
        return [id]
    }

    /// Everything the pinned-trail sweep reads and writes, so a suite can hand
    /// it an answer WidgetKit never gives the test host and see what it does
    /// with it. ``live(container:)`` is the app's.
    ///
    /// A seam for the reason `TrailBasemapRenderer.PinnedHikes` is one, and
    /// wider: the sweep's writes land in the App Group the renderer's own
    /// suite checks for strays, and a pinned trail's map is a MapKit render.
    nonisolated struct PinnedTrailSweep: Sendable {
        /// Which trails the placed widgets are pinned to, or that WidgetKit
        /// cannot say.
        let pinnedTrails: @Sendable () async -> PinnedTrails
        /// The selected trail, which every unconfigured widget follows.
        let selectedHikeIDs: @Sendable () -> Set<UUID>
        /// Writes one pinned trail's snapshot and map.
        let publishTrail: @Sendable (UUID) async -> Void
        /// Deletes every per-hike snapshot but these.
        let pruneTrailSnapshots: @Sendable (Set<UUID>) -> Void
        /// Deletes every trail's map but these.
        let pruneBasemaps: @Sendable (Set<UUID>) async -> Void

        /// WidgetKit, the app's own defaults, `container` and the App Group.
        static func live(container: ModelContainer) -> Self {
            Self(
                pinnedTrails: SharedHikeCatalogPublisher.pinnedTrails,
                selectedHikeIDs: SharedHikeCatalogPublisher.selectedHikeIDs,
                publishTrail: { hikeID in
                    await SharedHikeCatalogPublisher.publishTrail(hikeID, container: container)
                },
                pruneTrailSnapshots: { SharedStore.pruneTrailSnapshots(keeping: $0) },
                pruneBasemaps: { await TrailBasemapRenderer.shared.prune(keeping: $0) }
            )
        }
    }
}
