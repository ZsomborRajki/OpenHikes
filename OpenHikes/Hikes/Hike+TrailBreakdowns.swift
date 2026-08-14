//
//  Hike+TrailBreakdowns.swift
//  OpenHikes
//
//  How a measured surface or difficulty breakdown is stored on a hike, and
//  read back out of it.
//
//  Both are kept as metres per category rather than as percentages, so a
//  breakdown restored from the store recomputes its fractions the same way a
//  freshly measured one does.
//

import Foundation

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

    /// The stored breakdown, rebuilt from ``difficultyMetersByGrade``.
    ///
    /// Unrecognised grades are dropped for the same reason unrecognised
    /// surfaces are.
    var difficultyBreakdown: TrailDifficultyBreakdown? {
        get {
            var recognised: [TrailDifficulty: Double] = [:]
            for (grade, meters) in difficultyMetersByGrade {
                guard let difficulty = TrailDifficulty(rawValue: grade) else {
                    continue
                }
                recognised[difficulty] = meters
            }
            guard !recognised.isEmpty else { return nil }
            let breakdown = TrailDifficultyBreakdown(
                metersByDifficulty: recognised
            )
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
