//
//  TrailDifficultyAnalysis.swift
//  OpenHikes
//
//  Gets the trail graph a difficulty breakdown needs, and decides whether it
//  can be had without going to the network. Mirrors TrailSurfaceAnalysis.
//

import Foundation

nonisolated enum TrailDifficultyAnalysis {
    nonisolated enum Failure: LocalizedError, Equatable, Sendable {
        case download(String)
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
    /// Never touches the network — a hike recorded with the graph prefetched
    /// along the way gets its difficulty breakdown for free; everything else
    /// waits for the user to ask.
    static func cachedBreakdown(
        route: [RouteCoordinate],
        provider: any TrailGraphProviding
    ) async -> TrailDifficultyBreakdown? {
        guard route.count > 1 else { return nil }
        let coordinates = route.map(\.clCoordinate)
        guard await provider.hasCompleteCachedGraph(covering: coordinates),
              let graph = try? await provider.cachedGraph(covering: coordinates),
              !graph.isEmpty
        else { return nil }
        guard let breakdown = try? await TrailDifficultyAnalyzer.breakdown(
            route: route,
            graph: graph
        ), !breakdown.isEmpty else { return nil }
        return breakdown
    }

    /// Downloads whatever the route needs, then measures it.
    static func downloadedBreakdown(
        route: [RouteCoordinate],
        provider: any TrailGraphProviding
    ) async throws -> TrailDifficultyBreakdown {
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

        let breakdown = try await TrailDifficultyAnalyzer.breakdown(
            route: route,
            graph: graph
        )
        guard !breakdown.isEmpty else { throw Failure.noTrailData }
        return breakdown
    }
}

// MARK: - Persistence

extension Hike {
    /// The stored breakdown, rebuilt from ``difficultyMetersByGrade``.
    var difficultyBreakdown: TrailDifficultyBreakdown? {
        get {
            var recognised: [TrailDifficulty: Double] = [:]
            for (grade, meters) in difficultyMetersByGrade {
                guard let difficulty = TrailDifficulty(rawValue: grade) else { continue }
                recognised[difficulty] = meters
            }
            guard !recognised.isEmpty else { return nil }
            let breakdown = TrailDifficultyBreakdown(metersByDifficulty: recognised)
            return breakdown.isEmpty ? nil : breakdown
        }
        set {
            var stored: [String: Double] = [:]
            for share in newValue?.shares ?? [] {
                stored[share.difficulty.rawValue] = share.meters
            }
            difficultyMetersByGrade = stored
        }
    }
}
