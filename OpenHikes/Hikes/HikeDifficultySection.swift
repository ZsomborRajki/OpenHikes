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

import SwiftUI

nonisolated extension TrailDifficulty: TrailCategoryPresentation {
    var color: Color {
        switch self {
        case .hiking: .green
        case .mountainHiking: .yellow
        case .demandingMountainHiking: .orange
        case .alpineHiking: .red
        case .demandingAlpineHiking: .purple
        case .difficultAlpineHiking: Color(red: 0.5, green: 0, blue: 0)
        case .unknown: .gray
        case .unmapped: Color.gray.opacity(TrailBreakdownMetrics.unmappedOpacity)
        }
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
