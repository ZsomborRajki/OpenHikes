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
//  So both steps take plain values — ``HikePhotoSearchPlan/Source``, the
//  plan, the assets — and run `@concurrent`, never in a bare `Task`, which
//  would inherit the controller's actor. The controller reads the hike on the
//  main actor before the hop and writes what comes back on it after, so no
//  model crosses.
//
//  The steps themselves are closures only so a suite can see which thread
//  they ran on: ``standard`` is the plan and the matcher as they are, and
//  nothing else ever replaces them.
//

import Foundation
import OpenHikesData

nonisolated struct PhotoDiscoveryWork: Sendable {
    /// Builds the plan's indexes from what was read off the hike.
    let buildPlan: @Sendable (HikePhotoSearchPlan.Source) -> HikePhotoSearchPlan
    /// Matches the library's answer against a plan, leaving out the
    /// identifiers already attached — ``HikePhotoSearchPlan/matches(assets:alreadyImported:)``.
    let matchAssets: @Sendable (HikePhotoSearchPlan, [PhotoLibraryAsset], Set<String>) -> [LibraryPhotoMatch]

    static let standard = Self(
        buildPlan: { HikePhotoSearchPlan(source: $0) },
        matchAssets: { plan, assets, alreadyImported in
            plan.matches(assets: assets, alreadyImported: alreadyImported)
        }
    )

    /// The plan `source` supports, built off the main actor.
    @concurrent
    func plan(from source: HikePhotoSearchPlan.Source) async -> HikePhotoSearchPlan {
        assertOffMainThread("Indexing a hike's route for a photo search must stay off the main thread")
        return buildPlan(source)
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
