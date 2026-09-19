//
//  HikeSurfaceSection.swift
//  OpenHikes
//
//  The surface breakdown: what a route runs on.
//
//  Everything about *drawing* a breakdown lives in
//  ``TrailBreakdownSection``, which surface and difficulty share. What is left
//  here is what is genuinely about surfaces: a colour per case, the heading,
//  the sentence crediting OpenStreetMap, and the wrapper that reads a
//  breakdown off a ``Hike``.
//
//  That wrapper is the second split and it matters as much as the first.
//  ``TrailSurfaceSection`` draws a breakdown and knows nothing about where it
//  came from; ``HikeSurfaceSection`` is the one line that reads one off a
//  `Hike`. That keeps the write that fills it in — see ``HikeTrailAnalysis`` —
//  invalidating the wrapper rather than the whole detail screen, and it is
//  what lets the community preview draw the identical section from a breakdown
//  it measured for a stranger's route, with no `Hike` anywhere in sight. The
//  same shape ``HikeElevationChart`` has around ``ElevationChartView``.
//

import SwiftUI

nonisolated extension TrailSurface: TrailCategoryPresentation {
    /// Paved is deliberately not grey: grey belongs to the two categories that
    /// stand for missing data, and a hiker reading the bar should be able to
    /// tell "asphalt" from "nobody tagged it".
    var color: Color {
        switch self {
        case .paved: .blue
        case .gravel: .orange
        case .ground: .brown
        case .rock: .purple
        case .unknown: .gray
        case .unmapped: Color.gray.opacity(TrailBreakdownMetrics.unmappedOpacity)
        }
    }
}

/// The section itself, for anything holding a measured breakdown.
struct TrailSurfaceSection: View {
    let breakdown: TrailSurfaceBreakdown

    var body: some View {
        TrailBreakdownSection(
            breakdown: breakdown,
            title: "Surface",
            source: "Surfaces from OpenStreetMap",
            identifier: "surface-bar"
        )
    }
}

/// Absent until OpenStreetMap has actually answered for this hike's route.
///
/// Reads the breakdown here rather than in the detail screen's body, so the
/// write that fills it in redraws this and nothing above it.
struct HikeSurfaceSection: View {
    let hike: Hike

    var body: some View {
        if let breakdown = hike.surfaceBreakdown {
            TrailSurfaceSection(breakdown: breakdown)
        }
    }
}
