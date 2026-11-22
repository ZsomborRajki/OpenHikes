//
//  OpenHikesModel+TrailSources.swift
//  OpenHikes
//
//  Where a launch's trails and places come from: the trail graphs and the
//  place search, each of which asks OpenStreetMap's pre-built squares on the
//  tile server before Overpass, and none of which a suite may reach.
//

import Foundation

extension OpenHikesModel {
    /// The launch's two trail graphs.
    ///
    /// The recorder, a hike's breakdowns and the route's colours read trails
    /// alone, and the trail maker routes over the roads that join them too.
    /// Both read the same archive on the tile server first, and Overpass
    /// where it cannot answer, which give both: the readers that want trails
    /// alone keep the edges that are trails. They keep their regions apart,
    /// ``trails`` in a directory of its own and ``routing`` in the one every
    /// earlier build kept the maker's in, because builds before this one
    /// filled the first from the public database's squares, which held the
    /// trails alone. See ``RoutingGraphArchive``.
    struct TrailGraphProviders {
        let trails: OverpassTrailGraphProvider
        let routing: OverpassTrailGraphProvider
    }

    ///
    /// Two providers, and still one address to Overpass, so a `429` either
    /// earns stops both: they share its deadline (``OverpassRetryDeadline``).
    static func makeTrailGraphProviders() -> TrailGraphProviders {
        let retryDeadline = OverpassRetryDeadline()
        // One library, so a region both ask for is one request.
        let squares = TrailGraphSquareLibrary.forThisLaunch()
        return TrailGraphProviders(
            trails: OverpassTrailGraphProvider(
                directory: OverpassTrailGraphProvider.trailsDirectory(),
                squares: squares,
                retryDeadline: retryDeadline
            ),
            routing: OverpassTrailGraphProvider(
                squares: squares,
                retryDeadline: retryDeadline
            )
        )
    }

    /// Where the maker's *Search this area* asks, or `nil` for a launch that
    /// must not ask anything.
    ///
    /// Guarded on ``AppLaunchEnvironment/isRunningTests`` exactly as
    /// ``makeCommunityTransport()`` is, and for the harder half of the same
    /// reason: this one reaches a **volunteer-run** public API that hands out
    /// a handful of slots per address, so a suite that fell into it would be
    /// spending a real hiker's quota to assert on a stub's worth of rows.
    ///
    /// The `nil` is not a stub and is not a failure either: it withdraws the
    /// pill, the same shape ``TrailDraftController/canSnapToPaths`` takes for
    /// a launch with no trail graph. A control that cannot answer is worse
    /// than no control.
    ///
    /// The one way past the guard is ``SeededTrailPointSource``, which a
    /// scenario has to ask for by name — the exception
    /// ``makeCommunityTransport()`` makes, and on the same terms.
    static func makeTrailPointSource() -> (any TrailPointSourcing)? {
        #if DEBUG
        if let scenario = SeededTrailPointSource.Scenario(argument: AppLaunchEnvironment.trailPointScenarioName) {
            return SeededTrailPointSource(scenario: scenario)
        }
        #endif
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        // The places' squares on the tile server: see ``PlaceSquareGrid``.
        // Behind the same guard as Overpass, because no suite reaches the
        // tile server either.
        let squares = SquareArchiveServer.live(
            .places,
            requestTimeout: TrailCellLibrary.requestTimeout,
            resourceTimeout: TrailCellLibrary.resourceTimeout
        )
        return TrailPointSource(squares: PlaceSquareLibrary(database: squares))
    }
}
