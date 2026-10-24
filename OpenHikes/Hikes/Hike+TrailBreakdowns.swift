//
//  Hike+TrailBreakdowns.swift
//  OpenHikes
//
//  How a measured surface or difficulty breakdown is stored on a hike, how it
//  is read back out of it, and when opening the hike measures one.
//
//  Both are kept as metres per category rather than as percentages, so a
//  breakdown restored from the store recomputes its fractions the same way a
//  freshly measured one does.
//

import Foundation
import OpenHikesData

extension Hike {
    /// The stored breakdown, rebuilt from ``surfaceMetersByCategory``.
    ///
    /// Categories this build doesn't recognise are dropped rather than
    /// refused, so a store written by a later version that adds a surface
    /// still opens — the percentages simply renormalise over what's left.
    var surfaceBreakdown: TrailSurfaceBreakdown? {
        get {
            var recognized: [TrailSurface: Double] = [:]
            for (category, meters) in surfaceMetersByCategory {
                guard let surface = TrailSurface(rawValue: category) else { continue }
                recognized[surface] = meters
            }
            guard !recognized.isEmpty else { return nil }
            let breakdown = TrailSurfaceBreakdown(metersByCategory: recognized)
            return breakdown.isEmpty ? nil : breakdown
        }
        set {
            var stored: [String: Double] = [:]
            for share in newValue?.shares ?? [] {
                stored[share.category.rawValue] = share.meters
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
            var recognized: [TrailDifficulty: Double] = [:]
            for (grade, meters) in difficultyMetersByGrade {
                guard let difficulty = TrailDifficulty(rawValue: grade) else { continue }
                recognized[difficulty] = meters
            }
            guard !recognized.isEmpty else { return nil }
            let breakdown = TrailDifficultyBreakdown(metersByCategory: recognized)
            return breakdown.isEmpty ? nil : breakdown
        }
        set {
            var stored: [String: Double] = [:]
            for share in newValue?.shares ?? [] {
                stored[share.category.rawValue] = share.meters
            }
            difficultyMetersByGrade = stored
        }
    }

    /// Whether opening this hike should measure its surface and difficulty:
    /// true while either breakdown reads as never analyzed, which includes a
    /// store holding only categories this build doesn't recognize.
    ///
    /// Once both are stored they are kept, even if the analyzer that measured
    /// them has changed since. ``Hike/surfaceMetersByCategory`` says why.
    var needsTrailBreakdowns: Bool {
        surfaceBreakdown == nil || difficultyBreakdown == nil
    }
}
