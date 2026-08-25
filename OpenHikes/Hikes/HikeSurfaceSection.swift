//
//  HikeSurfaceSection.swift
//  OpenHikes
//
//  The surface breakdown shown on a hike's detail screen: a stacked bar of
//  what the route runs on, and the legend that reads it out.
//
//  Split into its own view so the write that fills it in — see
//  ``HikeTrailAnalysis`` — invalidates this section rather than the whole
//  detail screen.
//

import SwiftUI

nonisolated extension TrailSurface {
    /// How faded the "not mapped" segment is drawn — present enough to read as
    /// part of the bar, muted enough not to compete with a real surface.
    private static let unmappedOpacity = 0.3

    /// Chart tint. Paved is deliberately not grey: grey belongs to the two
    /// categories that stand for missing data, and a hiker reading the bar
    /// should be able to tell "asphalt" from "nobody tagged it".
    var color: Color {
        switch self {
        case .paved: .blue
        case .gravel: .orange
        case .ground: .brown
        case .rock: .purple
        case .unknown: .gray
        case .unmapped: Color.gray.opacity(Self.unmappedOpacity)
        }
    }
}

/// Absent until OpenStreetMap has actually answered for this route.
///
/// There is no placeholder, no spinner and no error: the analysis runs by
/// itself when the hike is opened, and a route it can't describe simply has no
/// surface section rather than an empty one explaining why.
///
/// The container deliberately carries no identifier of its own. SwiftUI pushes
/// one down onto every descendant, which would leave the bar, all three legend
/// rows and the footnote answering to the same name — and take
/// ``TrailSurfaceBar``'s own identifier away from the automation that looks
/// for it.
struct HikeSurfaceSection: View {
    let hike: Hike

    private static let percentStyle = FloatingPointFormatStyle<Double>.Percent
        .percent
        .precision(.fractionLength(0))
    /// Above this, the footnote drops the coverage caveat: the shortfall is
    /// smaller than the rounding on the percentages beside it.
    private static let fullCoverageThreshold = 0.995

    var body: some View {
        if let breakdown = hike.surfaceBreakdown {
            VStack(alignment: .leading, spacing: 12) {
                Text("Surface")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                TrailSurfaceBar(shares: breakdown.shares)
                VStack(spacing: 8) {
                    ForEach(breakdown.shares) { share in
                        TrailSurfaceLegendRow(share: share)
                    }
                }
                Text(footnote(for: breakdown))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func footnote(for breakdown: TrailSurfaceBreakdown) -> String {
        let surveyed = breakdown.surveyedFraction
        guard surveyed < Self.fullCoverageThreshold else { return "Surfaces from OpenStreetMap." }
        let formatted = surveyed.formatted(Self.percentStyle)
        return "Surfaces from OpenStreetMap, which describes \(formatted)"
            + " of this route."
    }
}

// MARK: - Bar

/// One stacked bar, drawn in the breakdown's own order so the dominant surface
/// leads.
struct TrailSurfaceBar: View {
    let shares: [TrailSurfaceBreakdown.Share]

    private static let height: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(
                    Array(zip(shares, widths(in: proxy.size.width))),
                    id: \.0.id
                ) { share, width in
                    Rectangle()
                        .fill(share.surface.color)
                        .frame(width: width)
                }
            }
        }
        .frame(height: Self.height)
        .clipShape(.capsule)
        .accessibilityElement()
        .accessibilityLabel("Surface breakdown")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("surface-bar")
    }

    /// Rounded to whole points, with the final share taking whatever is left
    /// rather than its own rounded share — otherwise a bar of six segments can
    /// end a few points short of the capsule it is clipped to, and the gap
    /// reads as a seventh, unlabelled surface.
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
                return "\(percent) \(share.surface.displayName)"
            }
            .formatted(.list(type: .and))
    }
}

// MARK: - Legend

struct TrailSurfaceLegendRow: View {
    let share: TrailSurfaceBreakdown.Share

    private static let swatchSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(share.surface.color)
                .frame(width: Self.swatchSize, height: Self.swatchSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(share.surface.displayName)
                    .font(.subheadline)
                Text(share.surface.summary)
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
