//
//  HikeTrailAnalysis.swift
//  OpenHikes
//
//  Gets what OpenStreetMap knows about a route — its surfaces and its SAC
//  difficulty grades — from a single trail graph.
//
//  This runs unprompted the first time a hike is opened, which is why it is
//  deliberately quiet: anything it cannot answer comes back as `nil`, and the
//  sections that read it stay hidden rather than putting an Overpass outage,
//  an aeroplane-mode failure, or an unmapped valley in front of someone who
//  only wanted to look at their walk.
//

import CoreLocation
import Foundation

/// Everything one pass over the trail graph can say about a route. Either
/// half is `nil` when it could not be measured.
nonisolated struct HikeTrailBreakdowns: Equatable, Sendable {
    let surface: TrailSurfaceBreakdown?
    let difficulty: TrailDifficultyBreakdown?

    static let empty = Self(surface: nil, difficulty: nil)

    var isEmpty: Bool { surface == nil && difficulty == nil }
}

nonisolated enum HikeTrailAnalysis {
    /// Both breakdowns for `route`, measured from one graph.
    ///
    /// Surface and difficulty read different tags off the same ways, so they
    /// share the fetch rather than each paying for their own — one round of
    /// Overpass requests, and one decode of the cached regions behind them.
    ///
    /// Never throws. A failed download, a region OpenStreetMap has nothing in,
    /// and a view torn down mid-analysis all come back as
    /// ``HikeTrailBreakdowns/empty``; the caller tells the last of those apart
    /// with `Task.isCancelled` before writing anything to the store.
    @concurrent
    static func breakdowns(
        route: [RouteCoordinate],
        provider: any TrailGraphProviding
    ) async -> HikeTrailBreakdowns {
        assertOffMainThread("Hike trail analysis must stay off the main thread")
        guard route.count > 1 else { return .empty }
        // Timed so an open that waits on Overpass can be told apart from one
        // that measured a graph already on disk.
        let state = RenderSignpost.beginInterval("HikeTrailAnalysis")
        defer { RenderSignpost.endInterval("HikeTrailAnalysis", state) }

        guard let graph = await graph(covering: route, provider: provider) else { return .empty }
        let surface = try? await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: route,
            graph: graph
        )
        let difficulty = try? await TrailBreakdownAnalyzer.breakdown(
            of: TrailDifficulty.self,
            route: route,
            graph: graph
        )
        return HikeTrailBreakdowns(
            surface: surface.flatMap { $0.isEmpty ? nil : $0 },
            difficulty: difficulty.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The cached graph when it already covers the whole route, and a
    /// downloaded one otherwise.
    ///
    /// The completeness check is what keeps the free case honest.
    /// ``TrailGraphProviding/cachedGraph(covering:)`` merges whatever happens
    /// to be on disk, and a region that was never downloaded is
    /// indistinguishable from a region with no trails in it — measuring
    /// against a partial graph would report the former as unmapped trail,
    /// which is a wrong number rather than a missing one.
    private static func graph(
        covering route: [RouteCoordinate],
        provider: any TrailGraphProviding
    ) async -> TrailGraph? {
        let coordinates = route.map(\.clCoordinate)
        if await provider.hasCompleteCachedGraph(covering: coordinates),
           let cached = try? await provider.cachedGraph(covering: coordinates),
           !cached.isEmpty { return cached }
        guard let downloaded = try? await provider.graph(covering: coordinates),
              !downloaded.isEmpty
        else { return nil }
        return downloaded
    }
}
