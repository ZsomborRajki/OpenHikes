//
//  OpenHikesModel+TrailSources.swift
//  OpenHikes
//
//  Where a launch's trails and places come from: the trail graphs and the
//  place search, each of which asks OpenStreetMap's pre-built squares in the
//  public database before Overpass, and none of which a suite may reach.
//

import Foundation

extension OpenHikesModel {
    /// The launch's two trail graphs.
    ///
    /// The recorder, a hike's breakdowns and the route's colours read trails
    /// alone, which the pre-built squares hold, so ``trails`` asks the squares
    /// first and keeps its regions apart. The trail maker routes over the
    /// roads that join trails too, which those squares leave out, so
    /// ``routing`` asks the maker's own archive on the tile server first,
    /// and Overpass where it cannot answer, in the directory every earlier
    /// build kept the maker's regions in. See ``TrailGraphSquareGrid`` and
    /// ``RoutingGraphArchive``.
    struct TrailGraphProviders {
        let trails: OverpassTrailGraphProvider
        let routing: OverpassTrailGraphProvider
    }

    ///
    /// Two providers, and still one address to Overpass, so a `429` either
    /// earns stops both: they share its deadline (``OverpassRetryDeadline``).
    static func makeTrailGraphProviders() -> TrailGraphProviders {
        let retryDeadline = OverpassRetryDeadline()
        return TrailGraphProviders(
            trails: OverpassTrailGraphProvider(
                directory: OverpassTrailGraphProvider.trailsDirectory(),
                squares: TrailGraphSquareLibrary.forThisLaunch(),
                retryDeadline: retryDeadline
            ),
            routing: OverpassTrailGraphProvider(
                squares: TrailGraphSquareLibrary.routingForThisLaunch(),
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
        // The places' squares, under their own manifest: see
        // ``PlaceSquareGrid``. Behind the same guard as Overpass, because
        // there is no sandbox for a public database either.
        let squares = CloudKitTrailCellDatabase(manifestRecordName: PlaceSquareGrid.manifestRecordName)
        return TrailPointSource(squares: PlaceSquareLibrary(database: squares))
    }
}
