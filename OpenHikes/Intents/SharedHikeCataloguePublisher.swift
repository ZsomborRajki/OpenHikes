//
//  SharedHikeCataloguePublisher.swift
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
//  keeping three hundred routes warm.
//

import Foundation
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
/// ``SharedHikeCataloguePublisher/pinnedTrails()``.
nonisolated enum PinnedTrails: Sendable {
    case known(Set<UUID>)
    /// WidgetKit could not answer.
    case unknown
}

nonisolated enum SharedHikeCataloguePublisher {
    private static let logger = Logger(subsystem: "OpenHikes", category: "WidgetCatalogue")

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
            await publishCatalogue(from: coordinator, watch: watch)
            await publishPinnedTrails(container: container)
        }
    }

    /// The list the pickers read.
    static func publishCatalogue(
        from coordinator: HikeIntentCoordinator,
        watch: WatchSessionCoordinator? = nil
    ) async {
        do {
            let summaries = try await MainActor.run {
                try coordinator.finishedHikes().map(HikeEntity.summary(of:))
            }
            let catalogue = SharedHikeCatalogue(hikes: summaries)
            SharedStore.saveHikeCatalogue(catalogue)
            if let watch { await watch.publish(catalogue) }
        } catch {
            Self.logger.debug(
                "Hike catalogue publish failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// A trail snapshot for each hike a placed widget is pinned to, and
    /// nothing for the hikes none is.
    ///
    /// The selected trail is deliberately **not** in the kept set here: it has
    /// its own file, written by ``BackgroundTrailTracker``, and mirroring it
    /// into the per-hike store is `SharedStore.save(_:)`'s job. What this adds
    /// is the trails nothing would otherwise publish.
    ///
    /// Each pinned trail gets its **map** here too. The renderer keeps a set
    /// per trail, but only the selection's feed ever asked it for one, so a
    /// trail pinned without being selected — or pinned before sets were kept
    /// per trail — drew its line on a grey fill for good.
    static func publishPinnedTrails(container: ModelContainer) async {
        let answer = await pinnedTrails()
        let pinned: Set<UUID> = if case .known(let hikeIDs) = answer { hikeIDs } else { [] }
        guard !pinned.isEmpty else {
            // Nothing pinned: keep only whatever the selected trail's mirror
            // left behind, which `selectedHikeID` answers.
            SharedStore.pruneTrailSnapshots(keeping: selectedHikeIDs())
            await pruneBasemaps(given: answer)
            return
        }
        for hikeID in pinned {
            await publishTrail(hikeID, container: container)
        }
        SharedStore.pruneTrailSnapshots(keeping: pinned.union(selectedHikeIDs()))
        await pruneBasemaps(given: answer)
    }

    /// The basemap half of the prune, and only when WidgetKit answered: the
    /// snapshots above can afford to read a failure as "nothing pinned",
    /// because a missing snapshot is rebuilt by the next sweep, where a
    /// deleted map is four network renders.
    private static func pruneBasemaps(given answer: PinnedTrails) async {
        guard case .known(let pinned) = answer else { return }
        await TrailBasemapRenderer.shared.prune(keeping: pinned.union(selectedHikeIDs()))
    }

    /// One hike's snapshot, built the same way the tracker builds the selected
    /// one so the two cannot describe the same trail differently.
    private static func publishTrail(_ hikeID: UUID, container: ModelContainer) async {
        let input = await MainActor.run { () -> BackgroundTrailTracker.SnapshotInput? in
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
            // A hike deleted since the widget was configured. Nothing to draw
            // and nothing to report: the prune below takes its file, and the
            // widget shows its empty state.
            guard let hike = try? context.fetch(descriptor).first else { return nil }
            return BackgroundTrailTracker.SnapshotInput(hike: hike)
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
    /// Each caller decides what no answer means, because the safe reading is
    /// opposite for the two. For the snapshots it reads as "nothing is pinned"
    /// — publishing every hike because the system was momentarily unavailable
    /// is the cost this whole policy exists to avoid. For the basemaps it
    /// reads as "keep everything" — see `TrailBasemapRenderer.PinnedHikes`.
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
}
