//
//  TrailSurfaceAnalysis.swift
//  OpenTrails
//
//  Gets the trail graph a surface breakdown needs, and decides whether it can
//  be had without going to the network.
//

import Foundation

nonisolated enum TrailSurfaceAnalysis {
    nonisolated enum Failure: LocalizedError, Equatable, Sendable {
        /// The trail graph could not be downloaded.
        case download(String)
        /// A graph arrived, but nothing in it explains this route.
        case noTrailData

        var errorDescription: String? {
            switch self {
            case .download(let reason):
                reason
            case .noTrailData:
                "OpenStreetMap has no mapped trails along this route."
            }
        }
    }

    /// A breakdown from data already on disk, or `nil` if there isn't enough.
    ///
    /// Runs when a hike is opened, so it must never reach the network — a hike
    /// recorded with the graph prefetched along the way gets its surfaces for
    /// free, and everything else waits for the walker to ask.
    static func cachedBreakdown(
        route: [RouteCoordinate],
        provider: any TrailGraphProviding
    ) async -> TrailSurfaceBreakdown? {
        guard route.count > 1 else { return nil }
        let coordinates = route.map(\.clCoordinate)
        guard await provider.hasCompleteCachedGraph(covering: coordinates),
              let graph = try? await provider.cachedGraph(covering: coordinates),
              !graph.isEmpty
        else { return nil }
        guard let breakdown = try? await TrailSurfaceAnalyzer.breakdown(
            route: route,
            graph: graph
        ), !breakdown.isEmpty else { return nil }
        return breakdown
    }

    /// Downloads whatever the route needs, then measures it.
    ///
    /// Throws ``Failure`` for anything worth showing the walker, and
    /// `CancellationError` when the view goes away mid-analysis — which the
    /// caller should swallow rather than report.
    static func downloadedBreakdown(
        route: [RouteCoordinate],
        provider: any TrailGraphProviding
    ) async throws -> TrailSurfaceBreakdown {
        guard route.count > 1 else { throw Failure.noTrailData }
        let coordinates = route.map(\.clCoordinate)

        let downloaded: TrailGraph?
        do {
            downloaded = try await provider.graph(covering: coordinates)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        guard let graph = downloaded, !graph.isEmpty else {
            throw Failure.noTrailData
        }

        let breakdown = try await TrailSurfaceAnalyzer.breakdown(
            route: route,
            graph: graph
        )
        guard !breakdown.isEmpty else { throw Failure.noTrailData }
        return breakdown
    }
}

// MARK: - Persistence

extension Hike {
    /// The stored breakdown, rebuilt from ``surfaceMetersByCategory``.
    ///
    /// Categories this build doesn't recognise are dropped rather than
    /// refused, so a store written by a later version that adds a surface
    /// still opens — the percentages simply renormalise over what's left.
    var surfaceBreakdown: TrailSurfaceBreakdown? {
        get {
            var recognised: [TrailSurface: Double] = [:]
            for (category, meters) in surfaceMetersByCategory {
                guard let surface = TrailSurface(rawValue: category) else {
                    continue
                }
                recognised[surface] = meters
            }
            guard !recognised.isEmpty else { return nil }
            let breakdown = TrailSurfaceBreakdown(metersBySurface: recognised)
            return breakdown.isEmpty ? nil : breakdown
        }
        set {
            var stored: [String: Double] = [:]
            for share in newValue?.shares ?? [] {
                stored[share.surface.rawValue] = share.meters
            }
            surfaceMetersByCategory = stored
        }
    }
}
