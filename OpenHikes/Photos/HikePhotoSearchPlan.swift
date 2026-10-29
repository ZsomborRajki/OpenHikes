//
//  HikePhotoSearchPlan.swift
//  OpenHikes
//
//  Everything a hike can say about when its hiker was out, and in what order
//  those answers are trusted.
//
//  There are two sources and they are not equals. The route's own timestamps
//  are a measurement taken every few seconds by the phone that was there, and
//  ``HikePhotoTimeline`` is built to refuse an answer it cannot support. A
//  ``HikeWalk`` is a window and a covered stretch — enough to place a photo
//  roughly, never enough to overrule the clock.
//
//  So the rule is absolute rather than best-of: **a photograph taken inside
//  the route's own window is the route's to place, including when the route
//  refuses it.** Those refusals are the feature's best-behaved part — a
//  picture inside a GPS gap, a picture whose camera flatly disagrees with
//  where the walk says the hiker was — and a coarse second opinion that
//  overturned them would trade a screen full of correct absences for a screen
//  full of plausible mistakes. Walks answer for the moments the route cannot
//  speak to at all, which on an imported trail is every moment there is.
//
//  The fetch is the union of the windows rather than one span across them. A
//  trail imported from a track recorded in 2019 and walked this morning has
//  two windows six years apart, and the span between them is a query for every
//  photograph the user has ever taken.
//

import Algorithms
import Foundation
import OpenHikesData

nonisolated struct HikePhotoSearchPlan: Sendable {
    /// The route's own time-to-place index, when its points carry timestamps.
    let timeline: HikePhotoTimeline?
    /// Finished walks along this trail, oldest first.
    let walks: [HikeWalkPhotoTimeline]
    /// The raw route, which the picker profiles — see ``PickedPhotoPlacement``.
    let route: [RouteCoordinate]
    /// The route's measured legs, for ``LibraryPhotoMatcher``'s off-route
    /// test. Built here, once per search, rather than once per photo, and
    /// only with a ``timeline``: the walks test against ``profile`` instead.
    let legs: RecordedRouteLegs?
    /// Built only when there are walks to place photographs with, or when
    /// the caller asks for it, because building one is route-sized work and
    /// the timeline path has no use for it.
    let profile: RouteProfile?

    /// - Parameter profilesRoute: Build ``profile`` even with no walks. The
    ///   picker wants one on every trail, because it projects a photograph's
    ///   own position onto the line — see ``PickedPhotoPlacement``.
    init(
        timeline: HikePhotoTimeline?,
        walks: [HikeWalkPhotoTimeline],
        route: [RouteCoordinate],
        profilesRoute: Bool = false
    ) {
        self.timeline = timeline
        self.walks = walks
        self.route = route
        legs = timeline == nil ? nil : RecordedRouteLegs(route: route)
        profile = walks.isEmpty && !profilesRoute ? nil : RouteProfile(route: route)
    }

    /// Whether there is anything to search at all. A hike with neither a
    /// stamped route nor a walk is the one case the offer cannot be honoured
    /// on — see ``PhotoDiscoveryController/Phase/unsupported``.
    var isEmpty: Bool { timeline == nil && walks.isEmpty }

    /// The windows to ask the photo library for, merged and ascending.
    ///
    /// Overlaps are merged rather than fetched twice, which is the ordinary
    /// case and not a corner one: a recorded hike writes a ``HikeWalk``
    /// covering the recording itself, so its window and the route's are the
    /// same afternoon.
    var searchWindows: [ClosedRange<Date>] {
        var windows = walks.map(\.searchWindow)
        if let routeWindow = timeline?.searchWindow { windows.append(routeWindow) }
        windows.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Date>] = []
        for window in windows {
            if let last = merged.last, window.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    /// Every asset that belongs to this hike, in the order they were taken.
    ///
    /// - Parameters:
    ///   - assets: What the library returned for ``searchWindows``. Assets
    ///     outside every window are refused here too rather than assumed away:
    ///     a stub, a future fetch that widens its predicate, or a library that
    ///     rounds a creation date must not be able to smuggle one past.
    ///   - alreadyImported: Local identifiers already attached to the hike —
    ///     see ``Hike/importedPhotoAssetIdentifiers``.
    func matches(
        assets: [PhotoLibraryAsset],
        alreadyImported: Set<String> = []
    ) -> [LibraryPhotoMatch] {
        assets
            .filter { !alreadyImported.contains($0.localIdentifier) }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap(match)
    }

    /// The precedence in this file's header, applied to one asset.
    private func match(_ asset: PhotoLibraryAsset) -> LibraryPhotoMatch? {
        if let timeline, timeline.searchWindow.contains(asset.createdAt) {
            // The route's to answer, a refusal included. The legs are unwrapped
            // inside the branch rather than beside `timeline`, so that a plan
            // without them could never hand the route's moment to a walk.
            return legs.flatMap { LibraryPhotoMatcher.match(asset, timeline: timeline, legs: $0) }
        }
        guard let profile else { return nil }
        // The first walk whose window holds the moment. Walks along one trail
        // are afternoons apart in every ordinary case; two that genuinely
        // overlap are a walk that was never ended and one begun inside it,
        // and the earlier of those is the one the photograph was taken during.
        return walks.firstNonNil { walk in
            walk.searchWindow.contains(asset.createdAt)
                ? LibraryPhotoMatcher.match(asset, walk: walk, profile: profile)
                : nil
        }
    }
}

nonisolated extension HikePhotoSearchPlan {
    /// What a plan is built from, read off a hike: plain values and no model,
    /// so the route-sized work of indexing them can be handed off the main
    /// actor — see ``PhotoDiscoveryWork`` and ``PickedPhotoWork``.
    struct Source: Sendable {
        let route: [RouteCoordinate]
        /// Already narrowed to the walks along `route` — see
        /// ``Hike/walkPhotoTimelines``.
        let walks: [HikeWalkPhotoTimeline]
    }

    /// The plan `source` supports: the route's timeline, its legs and its
    /// profile, each built here.
    init(source: Source, profilesRoute: Bool = false) {
        self.init(
            timeline: HikePhotoTimeline(route: source.route),
            walks: source.walks,
            route: source.route,
            profilesRoute: profilesRoute
        )
    }
}

extension Hike {
    /// What a library scan of this hike has to work with.
    ///
    /// Built on demand rather than stored, for the reason
    /// ``Hike/photoTimeline`` is: it is derived entirely from the route and
    /// the walks. Only `HikeWalkPhotoRouteRevisionTests` reads it: Find
    /// Photos and the picker each take ``photoSearchSource`` and build the
    /// plan off the main actor.
    var photoSearchPlan: HikePhotoSearchPlan {
        HikePhotoSearchPlan(source: photoSearchSource)
    }

    /// The values ``photoSearchPlan`` is built from, read on whichever thread
    /// owns this row's context.
    ///
    /// The route is decoded and the walks narrowed to the ones along it here;
    /// the indexes are left to whoever builds the plan. A library scan and
    /// the picker read it in a context of their own, off the main actor,
    /// unless this row holds edits its store has not had yet — see
    /// ``HikePhotoSearchPlan/SourceRead``.
    nonisolated var photoSearchSource: HikePhotoSearchPlan.Source {
        HikePhotoSearchPlan.Source(route: route, walks: walkPhotoTimelines)
    }
}
