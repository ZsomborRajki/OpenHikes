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

import Foundation

nonisolated struct HikePhotoSearchPlan: Sendable {
    /// The route's own time-to-place index, when its points carry timestamps.
    let timeline: HikePhotoTimeline?
    /// Finished walks along this trail, oldest first.
    let walks: [HikeWalkPhotoTimeline]
    /// The raw route, for ``LibraryPhotoMatcher``'s off-route test.
    let route: [RouteCoordinate]
    /// Built only when there are walks to place photographs with, because
    /// building one is route-sized work and the timeline path has no use for
    /// it.
    let profile: RouteProfile?

    init(
        timeline: HikePhotoTimeline?,
        walks: [HikeWalkPhotoTimeline],
        route: [RouteCoordinate]
    ) {
        self.timeline = timeline
        self.walks = walks
        self.route = route
        profile = walks.isEmpty ? nil : RouteProfile(route: route)
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
            return LibraryPhotoMatcher.match(asset, timeline: timeline, route: route)
        }
        guard let profile else { return nil }
        // The first walk whose window holds the moment. Walks along one trail
        // are afternoons apart in every ordinary case; two that genuinely
        // overlap are a walk that was never ended and one begun inside it,
        // and the earlier of those is the one the photograph was taken during.
        for walk in walks where walk.searchWindow.contains(asset.createdAt) {
            if let match = LibraryPhotoMatcher.match(asset, walk: walk, profile: profile) {
                return match
            }
        }
        return nil
    }
}

extension Hike {
    /// What a library scan of this hike has to work with.
    ///
    /// Built on demand rather than stored, for the reason
    /// ``Hike/photoTimeline`` is: it is derived entirely from the route and
    /// the walks, and the one screen that wants it wants it behind a button
    /// tap.
    var photoSearchPlan: HikePhotoSearchPlan {
        HikePhotoSearchPlan(
            timeline: photoTimeline,
            walks: walkPhotoTimelines,
            route: route
        )
    }
}
