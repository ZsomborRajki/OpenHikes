//
//  HikeDifficultySection.swift
//  OpenHikes
//
//  The SAC-scale difficulty breakdown shown on a hike's detail screen: a
//  stacked bar of how demanding each stretch of trail is, and a legend that
//  reads it out.
//
//  Split into its own view so the write that fills it in — see
//  ``HikeTrailAnalysis`` — invalidates this section rather than the whole
//  detail screen.
//

import SwiftUI

nonisolated extension TrailDifficulty {
    private static let unmappedOpacity = 0.3

    var color: Color {
        switch self {
        case .hiking: .green
        case .mountainHiking: .yellow
        case .demandingMountainHiking: .orange
        case .alpineHiking: .red
        case .demandingAlpineHiking: .purple
        case .difficultAlpineHiking: Color(red: 0.5, green: 0, blue: 0)
        case .unknown: .gray
        case .unmapped: Color.gray.opacity(Self.unmappedOpacity)
        }
    }
}

/// Absent until OpenStreetMap has actually answered for this route — see
/// ``HikeSurfaceSection``, which it mirrors.
struct HikeDifficultySection: View {
    let hike: Hike

    private static let percentStyle = FloatingPointFormatStyle<Double>.Percent
        .percent
        .precision(.fractionLength(0))
    private static let fullCoverageThreshold = 0.995

    var body: some View {
        if let breakdown = hike.difficultyBreakdown {
            VStack(alignment: .leading, spacing: 12) {
                Text("Difficulty")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TrailDifficultyBar(shares: breakdown.shares)
                VStack(spacing: 8) {
                    ForEach(breakdown.shares) { share in
                        TrailDifficultyLegendRow(share: share)
                    }
                }
                Text(footnote(for: breakdown))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("difficulty-section")
        }
    }

    private func footnote(for breakdown: TrailDifficultyBreakdown) -> String {
        let surveyed = breakdown.surveyedFraction
        guard surveyed < Self.fullCoverageThreshold else {
            return "Difficulty grades from OpenStreetMap (SAC scale)."
        }
        let formatted = surveyed.formatted(Self.percentStyle)
        return "Difficulty grades from OpenStreetMap (SAC scale), which"
            + " describes \(formatted) of this route."
    }
}

// MARK: - Bar

struct TrailDifficultyBar: View {
    let shares: [TrailDifficultyBreakdown.Share]

    private static let height: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(
                    Array(zip(shares, widths(in: proxy.size.width))),
                    id: \.0.id
                ) { share, width in
                    Rectangle()
                        .fill(share.difficulty.color)
                        .frame(width: width)
                }
            }
        }
        .frame(height: Self.height)
        .clipShape(.capsule)
        .accessibilityElement()
        .accessibilityLabel("Difficulty breakdown")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("difficulty-bar")
    }

    private func widths(in total: CGFloat) -> [CGFloat] {
        var remaining = max(total, 0)
        var result: [CGFloat] = []
        result.reserveCapacity(shares.count)
        for (index, share) in shares.enumerated() {
            guard index < shares.count - 1 else {
                result.append(remaining)
                break
            }
            let width = min((total * share.fraction).rounded(), remaining)
            result.append(max(width, 0))
            remaining -= max(width, 0)
        }
        return result
    }

    private var accessibilityValue: String {
        shares
            .map { share in
                let percent = share.fraction.formatted(
                    .percent.precision(.fractionLength(0))
                )
                return "\(percent) \(share.difficulty.displayName)"
            }
            .formatted(.list(type: .and))
    }
}

// MARK: - Legend

struct TrailDifficultyLegendRow: View {
    let share: TrailDifficultyBreakdown.Share

    private static let swatchSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(share.difficulty.color)
                .frame(width: Self.swatchSize, height: Self.swatchSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(share.difficulty.displayName)
                    .font(.subheadline)
                Text(share.difficulty.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(
                    share.fraction.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                )
                .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(
                    Measurement(value: share.meters, unit: UnitLength.meters)
                        .formatted(
                            .measurement(width: .abbreviated, usage: .road)
                        )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
