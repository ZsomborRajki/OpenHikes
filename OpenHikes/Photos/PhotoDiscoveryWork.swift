//
//  PhotoDiscoveryWork.swift
//  OpenHikes
//
//  The two route-sized steps of "Find Photos of This Hike", and where they
//  run.
//
//  Building a ``HikePhotoSearchPlan`` indexes the route — its timeline, its
//  measured legs and, when the trail has been walked, a whole
//  ``RouteProfile`` — and matching the library's answer against it projects
//  every geotagged photograph a walk places onto the whole route. On a long
//  trail with a few hundred photographs that is most of a second of work.
//  ``PhotoDiscoveryController`` is main-actor isolated, and awaiting the
//  photo library before the match did nothing to move it: the match ran on
//  the main thread after the fetch came back, with the sheet's spinner frozen
//  in front of it (#1119).
//
//  So both steps take plain values — a ``HikePhotoSearchPlan/SourceRead``,
//  the plan, the assets — and run `@concurrent`, never in a bare `Task`,
//  which would inherit the controller's actor. The first reads the hike as
//  well as indexing it, in a context of its own, because the read decodes
//  the route and hashes it, which is route-sized too (#1215) — unless the
//  hike holds edits its store has not had yet, which only its own context
//  can read. The controller names or reads the hike on the main actor before
//  the hop and writes what comes back on it after, so no model crosses.
//
//  The steps themselves are closures only so a suite can see which thread
//  they ran on: ``standard`` is the fetch, the plan and the matcher as they
//  are, and nothing else ever replaces them.
//

import Foundation
import OpenHikesData
import SwiftData

nonisolated struct PhotoDiscoveryWork: Sendable {
    /// Fetches the hike a search reads, into the context the read made for
    /// it — ``HikePhotoSearchPlan/SourceRead/fetchHike(_:_:)``.
    let fetchHike: @Sendable (ModelContext, PersistentIdentifier) throws -> Hike?
    /// Builds the plan's indexes from what was read off the hike.
    let buildPlan: @Sendable (HikePhotoSearchPlan.Source) -> HikePhotoSearchPlan
    /// Matches the library's answer against a plan, leaving out the
    /// identifiers already attached — ``HikePhotoSearchPlan/matches(assets:alreadyImported:)``.
    let matchAssets: @Sendable (HikePhotoSearchPlan, [PhotoLibraryAsset], Set<String>) -> [LibraryPhotoMatch]

    static let standard = Self(
        fetchHike: HikePhotoSearchPlan.SourceRead.fetchHike,
        buildPlan: { HikePhotoSearchPlan(source: $0) },
        matchAssets: { plan, assets, alreadyImported in
            plan.matches(assets: assets, alreadyImported: alreadyImported)
        }
    )

    /// The plan the hike `read` names supports, read and built off the main
    /// actor.
    ///
    /// `nil` for a hike the store no longer holds, or cannot read. Its own
    /// context can go on holding it after a deletion elsewhere, and an empty
    /// plan would then say what ``PhotoDiscoveryController/Phase/unsupported``
    /// says, that the route has no clock. So the controller writes nothing,
    /// as it does for a hike its context has let go.
    @concurrent
    func plan(for read: HikePhotoSearchPlan.SourceRead) async -> HikePhotoSearchPlan? {
        assertOffMainThread("Reading and indexing a hike's route for a photo search must stay off the main thread")
        return read.source(fetch: fetchHike).map(buildPlan)
    }

    /// What `plan` makes of `assets`, matched off the main actor.
    ///
    /// Nothing for a search already cancelled: its caller drops whatever
    /// comes back, so a route's worth of projections would be spent on no
    /// one.
    @concurrent
    func matches(
        in plan: HikePhotoSearchPlan,
        of assets: [PhotoLibraryAsset],
        alreadyImported: Set<String>
    ) async -> [LibraryPhotoMatch] {
        assertOffMainThread("Matching a photo search must stay off the main thread")
        guard !Task.isCancelled else { return [] }
        return matchAssets(plan, assets, alreadyImported)
    }
}
