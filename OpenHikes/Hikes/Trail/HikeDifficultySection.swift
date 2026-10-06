//
//  HikeDifficultySection.swift
//  OpenHikes
//
//  The SAC-scale difficulty breakdown: how demanding each stretch of trail is.
//
//  Split exactly as ``HikeSurfaceSection`` is, and for its reasons — the
//  drawing is ``TrailBreakdownSection``'s, shared with surface; what is here is
//  the colours, the wording, and the wrapper that reads a breakdown off a
//  ``Hike`` so the write filling it in redraws the section rather than the
//  detail screen.
//

import OpenHikesData
import SwiftUI

nonisolated extension TrailDifficulty: TrailCategoryPresentation {
    /// Where this grade sits on the scale the map colours a line on — one
    /// step per SAC grade, so the six grades are the six shades. `nil` for
    /// the two ways of not knowing, which have no place on a scale of how
    /// hard something is.
    var shade: RouteShade? {
        switch self {
        case .hiking: .easiest
        case .mountainHiking: .easy
        case .demandingMountainHiking: .moderate
        case .alpineHiking: .hard
        case .demandingAlpineHiking: .harder
        case .difficultAlpineHiking: .hardest
        case .unknown, .unmapped: nil
        }
    }

    var color: Color {
        if let shade { return shade.color }
        return self == .unmapped ? Color.gray.opacity(TrailBreakdownMetrics.unmappedOpacity) : .gray
    }
}

/// The section itself, for anything holding a measured breakdown — see
/// ``TrailSurfaceSection``, which it mirrors.
struct TrailDifficultySection: View {
    let breakdown: TrailDifficultyBreakdown

    var body: some View {
        TrailBreakdownSection(
            breakdown: breakdown,
            title: "Difficulty",
            source: "Difficulty grades from OpenStreetMap (SAC scale)",
            identifier: "difficulty-bar"
        )
    }
}

/// Absent until OpenStreetMap has actually answered for this hike's route.
struct HikeDifficultySection: View {
    let hike: Hike

    var body: some View {
        if let breakdown = hike.difficultyBreakdown {
            TrailDifficultySection(breakdown: breakdown)
        }
    }
}
