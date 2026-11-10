//
//  SharedHikeCatalogPublisher.swift
//  OpenHikes
//
//  Keeping the App Group's copy of the library in step with the real one, and
//  keeping a trail snapshot for every hike a placed widget is pinned to.
//
//  ## Why a sweep rather than a write per change
//
//  The same argument ``HikeSpotlightIndex`` makes, and this sweep feeds it for
//  that reason: one reading of the library, handed to the catalogue, the watch
//  and Spotlight alike. Three things change what should be published — a hike saved, a
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
//  A pin is not proof that its hike exists. One deleted on another device
//  arrives here as a row that is simply gone, with none of the cleanup a
//  deletion on this device does, and a launch that died between the two
//  leaves the same. So a pinned hike the store no longer holds loses its
//  snapshot and its map in the same prune, and the widget draws its empty
//  state rather than a route nothing can open (#1378). Only a row that is
//  gone: a read that failed says nothing about the row, and keeps what it
//  has, for the reason `SelectedLine.Found` tells the two apart.
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

    /// Republishes the catalogue, the Spotlight index and the pinned trails'
    /// snapshots.
    ///
    /// Fire-and-forget and silent on failure: nothing a hiker does depends on
    /// this having worked this second, and the next sweep puts it right.
    ///
    /// - Parameter watch: the watch link, which is handed the *same* list
    ///   rather than being given a sweep of its own. Two independent readings
    ///   of one library is how the two come to disagree, and the disagreement
    ///   would be visible: a hiker's watch offering a trail their widget's
    ///   picker does not. One sweep, one list, every consumer — which is the
    ///   argument this type's header already makes about writing per change,
    ///   and the reason Spotlight is fed from here too (see
    ///   ``publishLibrary(from:to:)``).
    static func publish(
        from coordinator: HikeIntentCoordinator,
        container: ModelContainer,
        writer: BackgroundTrailTracker.SnapshotWriter,
        watch: WatchSessionCoordinator? = nil
    ) {
        Task.detached(priority: .utility) {
            await publishLibrary(from: coordinator, to: .live(watch: watch))
            await publishPinnedTrails(.live(container: container, writer: writer))
        }
    }

    /// Reads the finished hikes once and hands the one list to every
    /// consumer.
    ///
    /// Once, because each read fetches the whole library into a context of
    /// its own. Spotlight and the catalogue each used to make that read for
    /// themselves, from two detached tasks at once, so a launch held the
    /// library twice, in two readings that were free to disagree (#1025).
    ///
    /// A failed read reaches no consumer. A library that could not be read is
    /// not an empty one, and handing either an empty list would delete every
    /// entry it holds.
    static func publishLibrary(
        from coordinator: HikeIntentCoordinator,
        to consumers: LibraryConsumers
    ) async {
        let reports: [FinishedHikeReport]
        do {
            reports = try await coordinator.finishedHikes()
        } catch {
            Self.logger.debug(
                "Hike library publish failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        await consumers.catalog(reports)
        await consumers.spotlight(reports)
    }

    /// The list the pickers read, on its own: the watch link's republish.
    /// `WatchSessionCoordinator.republishLibrary()` runs it at three moments —
    /// once a walk from the watch is in the library, when the watch app comes
    /// to the front, and when the watch asks for its list. None of them
    /// rebuilds the Spotlight index, which is a launch sweep: a hike saved this
    /// session is searchable next launch (see ``HikeSpotlightIndex``).
    static func publishCatalog(
        from coordinator: HikeIntentCoordinator,
        watch: WatchSessionCoordinator? = nil
    ) async {
        do {
            await saveCatalog(try await coordinator.finishedHikes(), watch: watch)
        } catch {
            Self.logger.debug(
                "Hike catalog publish failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func saveCatalog(
        _ reports: [FinishedHikeReport],
        watch: WatchSessionCoordinator?
    ) async {
        let catalog = Self.catalog(from: reports)
        SharedStore.saveHikeCatalog(catalog)
        if let watch { await watch.publish(catalog) }
    }

    /// The catalogue the App Group and the watch are handed for `reports`,
    /// built without writing it.
    ///
    /// Its own function so that a suite names hikes against exactly the rows
    /// Siri, the shortcut picker and the widget's configuration picker read
    /// through ``HikeEntityQuery`` and ``SharedHikeCatalog/hikes(matching:)``,
    /// rather than against a matcher of its own (#1029). It reads nothing:
    /// `reports` is the reading the sweep already made, which at launch
    /// ``publishLibrary(from:to:)`` hands to Spotlight too.
    static func catalog(from reports: [FinishedHikeReport]) -> SharedHikeCatalog {
        SharedHikeCatalog(hikes: reports.map(HikeEntity.summary(of:)))
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
    ///
    /// **Only a hike that is gone loses its pin's files.** The same argument
    /// the other way round: a read that failed is no answer about the row,
    /// so its snapshot and map stay, and only a store that holds no such hike
    /// takes them (#1378). The widgets are then asked to redraw, because a
    /// timeline already holding the deleted route would otherwise draw it
    /// until its safety-net reload, hours away.
    static func publishPinnedTrails(_ sweep: PinnedTrailSweep) async {
        guard case .known(let pinned) = await sweep.pinnedTrails() else { return }
        var gone: Set<UUID> = []
        for hikeID in pinned {
            let files = await sweep.publishTrail(hikeID)
            if files == .discard { gone.insert(hikeID) }
        }
        // The selected trail's mirror survives too, because the unconfigured
        // widgets are following it. A hike that is gone does not, selected
        // or not: the one the live feed still holds was kept by
        // ``publishTrail(_:writer:publication:)``, and no other is followed.
        let kept = pinned.union(sweep.selectedHikeIDs()).subtracting(gone)
        sweep.pruneTrailSnapshots(kept)
        await sweep.pruneBasemaps(kept)
        guard !gone.isEmpty else { return }
        await sweep.reloadWidgets()
    }

    /// One hike's snapshot, built the same way the tracker builds the selected
    /// one so the two cannot describe the same trail differently.
    ///
    /// - Returns: whether the trail's files may go, which only a hike the
    ///   store no longer holds earns, and only when the live feed is not
    ///   holding it: that trail's files are the feed's, as its static route
    ///   is below, and its next write would only put the mirror back.
    static func publishTrail(
        _ hikeID: UUID,
        writer: BackgroundTrailTracker.SnapshotWriter,
        publication: PinnedTrailPublication
    ) async -> PinnedTrailFiles {
        let snapshot: SharedTrailSnapshot
        switch await publication.build(hikeID) {
        case .snapshot(let built):
            snapshot = built
        case .gone:
            return await writer.ownsTrail(hikeID) ? .keep : .discard
        case .unavailable:
            return .keep
        }
        // No live fix, and that is the shape rather than an omission.
        // `BackgroundTrailTracker` publishes a fix for the *tracked* hike only
        // — one hike is being walked — so a widget pinned to a different trail
        // has no live position to draw and renders the static route. That case
        // did not exist before this change and is the one worth a test.
        // Ownership is decided after the build, through the live feed's own
        // writer. A selection or a pause can have arrived while it suspended.
        await writer.savePinned(snapshot)
        // Framed from the same decimated polyline the widget draws, as the
        // selection's map is. A no-op when the set on disk already frames it.
        await publication.refreshBasemap(hikeID, snapshot.polyline)
        return .keep
    }

    /// One hike read into values, in a context of its own off the main actor:
    /// each pinned trail at launch, and the trail a watch asks for
    /// (``WatchTrailPackaging/answer(to:from:fetch:)``).
    ///
    /// `HikeRouteInput` reads `route`, which is external storage decoded
    /// whole, and a long recording is the likeliest thing to pin. Read inside
    /// `MainActor.run`, that decode was a main-thread stall at every launch,
    /// one per pinned widget, while the map was coming up (#1025). Here the
    /// context and the `Hike` it vends are made, read and dropped inside this
    /// call, and only the `Sendable` input leaves — the shape
    /// `BackgroundTrailTracker.match` already reads the tracked hike in.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor. ``RouteRead/gone`` for a hike deleted since its
    /// caller learned of it — a widget configured, a watch's list published —
    /// and ``RouteRead/failed`` for one that cannot be read. Neither has
    /// anything to draw or report now, and the watch draws its waiting state
    /// for both. Only the sweep tells them apart: the prune after it takes a
    /// pinned trail's files for a hike that is gone, and the widget shows its
    /// empty state, but leaves them for a read that failed.
    ///
    /// - Parameter fetch: the store's fetch of one hike, a seam so a suite can
    ///   see which thread it ran on, or make it fail.
    @concurrent
    nonisolated static func routeInput(
        for hikeID: UUID,
        in container: ModelContainer,
        fetch: @Sendable (ModelContext, UUID) throws -> Hike? = fetchHike
    ) async -> RouteRead {
        assertOffMainThread("Reading a hike's route for a widget or a watch must stay off the main thread")
        do {
            guard let hike = try fetch(ModelContext(container), hikeID) else { return .gone }
            return .found(HikeRouteInput(hike: hike))
        } catch {
            Self.logger.debug("Hike route read failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// The store's own answer for ``routeInput(for:in:fetch:)``: the one hike,
    /// if it still exists.
    nonisolated static func fetchHike(_ context: ModelContext, _ hikeID: UUID) throws -> Hike? {
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
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

    /// Where the launch's one reading of the library goes, so a suite can see
    /// how many reads feed it and what each consumer was handed. ``live(watch:)``
    /// is the app's: the App Group, the watch link and the system's Spotlight
    /// index, none of which a suite may touch.
    nonisolated struct LibraryConsumers: Sendable {
        /// The App Group's catalogue the widget's picker reads, and the
        /// watch's copy of it.
        let catalog: @Sendable ([FinishedHikeReport]) async -> Void
        /// The app's Spotlight entries.
        let spotlight: @Sendable ([FinishedHikeReport]) async -> Void

        static func live(watch: WatchSessionCoordinator?) -> Self {
            Self(
                catalog: { await SharedHikeCatalogPublisher.saveCatalog($0, watch: watch) },
                spotlight: { await HikeSpotlightIndex.replaceEntries(with: $0) }
            )
        }
    }

    /// What ``routeInput(for:in:fetch:)`` found of one hike.
    ///
    /// A fetch that failed is told from a row that is gone, as
    /// `SelectedLine.Found` tells them, because only a row that is gone may
    /// take a pinned widget's trail with it (#1378).
    nonisolated enum RouteRead: Sendable {
        /// The fetch failed, which says nothing about the row.
        case failed
        /// The hike, read into values.
        case found(HikeRouteInput)
        /// No row: the hike was deleted, on this device or another.
        case gone

        /// The hike's values, or `nil` either way of not having them, which
        /// is all a watch's answer needs to know.
        var input: HikeRouteInput? {
            switch self {
            case .found(let input): input
            case .failed, .gone: nil
            }
        }
    }

    /// What the sweep does with one pinned trail's snapshot and map, once
    /// ``publishTrail(_:writer:publication:)`` has tried it.
    nonisolated enum PinnedTrailFiles: Sendable, Equatable {
        /// The store holds no such hike, so the prune takes them.
        case discard
        /// They stay: published just now, the live feed's own, or not read
        /// this time.
        case keep
    }

    /// The expensive build and map render, injectable so a suite can hold a
    /// static build open while the live writer publishes a fix or a pause.
    /// The snapshot commit stays in ``publishTrail(_:writer:publication:)``.
    nonisolated struct PinnedTrailPublication: Sendable {
        /// What a build found of one pinned trail.
        nonisolated enum Build: Sendable {
            /// The store holds no such hike.
            case gone
            /// The trail, ready to commit.
            case snapshot(SharedTrailSnapshot)
            /// Nothing to publish this time — a read that failed, or a route
            /// with nothing to draw — which says nothing about the files
            /// already on disk.
            case unavailable
        }

        let build: @Sendable (UUID) async -> Build
        let refreshBasemap: @Sendable (UUID, [SharedTrailSnapshot.CodableCoordinate]) async -> Void

        static func live(container: ModelContainer) -> Self {
            Self(
                build: { hikeID in await liveBuild(of: hikeID, in: container) },
                refreshBasemap: { hikeID, polyline in
                    await TrailBasemapRenderer.shared.refreshPinned(hikeID: hikeID, polyline: polyline)
                }
            )
        }

        /// The app's build: the hike read off the main actor, and its
        /// snapshot built as the tracker builds the selected one. Its own
        /// function so a suite can drive the real read with a fetch of its
        /// own, beside a map lane that never reaches the renderer.
        static func liveBuild(
            of hikeID: UUID,
            in container: ModelContainer,
            fetch: @Sendable (ModelContext, UUID) throws -> Hike? = SharedHikeCatalogPublisher.fetchHike
        ) async -> Build {
            switch await SharedHikeCatalogPublisher.routeInput(for: hikeID, in: container, fetch: fetch) {
            case .found(let input):
                guard let snapshot = await BackgroundTrailTracker.buildSnapshotOffMain(from: input, liveFix: nil)
                else { return .unavailable }
                return .snapshot(snapshot)
            case .gone:
                return .gone
            case .failed:
                return .unavailable
            }
        }
    }

    /// Everything the pinned-trail sweep reads and writes, so a suite can hand
    /// it an answer WidgetKit never gives the test host and see what it does
    /// with it. ``live(container:writer:)`` is the app's.
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
        /// Writes one pinned trail's map, and its static snapshot unless the
        /// live feed owns that trail: the feed's own writes keep that one.
        /// Answers whether the trail's files may go, which only a hike that
        /// is gone earns.
        let publishTrail: @Sendable (UUID) async -> PinnedTrailFiles
        /// Deletes every per-hike snapshot but these.
        let pruneTrailSnapshots: @Sendable (Set<UUID>) -> Void
        /// Deletes every trail's map but these.
        let pruneBasemaps: @Sendable (Set<UUID>) async -> Void
        /// Redraws the widgets once a pinned trail's files have gone, unless
        /// a live recording owns them: see `TrailWidgetReload`.
        let reloadWidgets: @Sendable () async -> Void

        /// WidgetKit, the app's own defaults, `container` and the App Group.
        static func live(container: ModelContainer, writer: BackgroundTrailTracker.SnapshotWriter) -> Self {
            Self(
                pinnedTrails: SharedHikeCatalogPublisher.pinnedTrails,
                selectedHikeIDs: SharedHikeCatalogPublisher.selectedHikeIDs,
                publishTrail: { hikeID in
                    await SharedHikeCatalogPublisher.publishTrail(
                        hikeID,
                        writer: writer,
                        publication: .live(container: container)
                    )
                },
                pruneTrailSnapshots: { SharedStore.pruneTrailSnapshots(keeping: $0) },
                pruneBasemaps: { await TrailBasemapRenderer.shared.prune(keeping: $0) },
                reloadWidgets: { await writer.reloadWidget() }
            )
        }
    }
}
