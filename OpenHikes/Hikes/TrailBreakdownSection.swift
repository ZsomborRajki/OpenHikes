//
//  TrailBreakdownSection.swift
//  OpenHikes
//
//  How a ``TrailBreakdown`` is drawn: a stacked bar, a legend that reads it
//  out, and the footnote that says how much of the route the measurement
//  actually covers.
//
//  The view half of the argument ``TrailBreakdown`` already makes for the
//  measurement half. Surface and difficulty were charted twice — two bars, two
//  legend rows and two sections that matched each other line for line, down to
//  the rounding rule that keeps the last segment flush with the capsule — and
//  the hazard there is the one that file names: not size, drift. A fix to the
//  rounding, or to how the legend reads a share out to VoiceOver, lands in one
//  copy and quietly not in the other.
//
//  So the drawing lives here once, generic over the category, and each tag
//  supplies only what genuinely differs: a colour per case, a heading, and the
//  sentence that credits the source. ``TrailBreakdown`` deliberately keeps no
//  view layer, so the presentation the drawing needs is a second protocol,
//  declared here and conformed to beside each category's own colours.
//

import SwiftUI

/// What drawing a breakdown needs from its category, on top of what measuring
/// one needs.
///
/// Separate from ``TrailCategory`` because the analysis has no view layer and
/// should not gain one: nothing in `TrailBreakdown.swift` can see a `Color`.
nonisolated protocol TrailCategoryPresentation: TrailCategory {
    /// Chart tint. Grey is reserved for the two cases that stand for missing
    /// data, so a hiker can tell a real category from nobody having tagged it.
    var color: Color { get }
    var displayName: String { get }
    /// A short note on what this category means in practice.
    var summary: String { get }
}

/// The figures the drawing shares.
///
/// A plain enum rather than static members on the views, because a generic
/// type cannot hold a stored static property and a computed one would put the
/// literal back at the point of use — which is the thing this file exists to
/// stop.
nonisolated enum TrailBreakdownMetrics {
    /// How faded the "not mapped" segment is drawn — present enough to read as
    /// part of the bar, muted enough not to compete with a real category.
    static let unmappedOpacity = 0.3
    /// Above this surveyed fraction, the footnote drops the coverage caveat:
    /// the shortfall is smaller than the rounding on the percentages beside it.
    static let fullCoverageThreshold = 0.995
    static let barHeight: CGFloat = 14
    static let swatchSize: CGFloat = 10
}

/// A measured breakdown, drawn: heading, bar, legend, footnote.
///
/// There is no placeholder, no spinner and no error anywhere in this family:
/// the analysis runs by itself, and a route it can't describe simply has no
/// section rather than an empty one explaining why. Which is why the absence
/// is decided by the callers — this draws what it is given.
///
/// The container deliberately carries no identifier of its own. SwiftUI pushes
/// one down onto every descendant, which would leave the bar, every legend row
/// and the footnote answering to the same name — and take the bar's own
/// identifier away from the automation that looks for it.
struct TrailBreakdownSection<Category: TrailCategoryPresentation>: View {
    let breakdown: TrailBreakdown<Category>
    /// The heading, and the noun the bar and its legend are announced by.
    let title: String
    /// Who measured this, as a sentence with no full stop: the footnote either
    /// ends it or continues it with the coverage caveat.
    let source: String
    /// What the automation looks the bar up by. Passed in rather than derived
    /// from ``title``, which is a display string and free to change.
    let identifier: String

    private static var percentStyle: FloatingPointFormatStyle<Double>.Percent {
        .percent.precision(.fractionLength(0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            TrailBreakdownBar(
                shares: breakdown.shares,
                label: "\(title) breakdown",
                identifier: identifier
            )
            VStack(spacing: 8) {
                ForEach(breakdown.shares) { share in
                    TrailBreakdownLegendRow(share: share)
                }
            }
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var footnote: String {
        let surveyed = breakdown.surveyedFraction
        guard surveyed < TrailBreakdownMetrics.fullCoverageThreshold else { return "\(source)." }
        let formatted = surveyed.formatted(Self.percentStyle)
        return "\(source), which describes \(formatted) of this route."
    }
}

// MARK: - Bar

/// One stacked bar, drawn in the breakdown's own order so the dominant
/// category leads.
struct TrailBreakdownBar<Category: TrailCategoryPresentation>: View {
    let shares: [TrailBreakdown<Category>.Share]
    let label: String
    let identifier: String

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(
                    Array(zip(shares, widths(in: proxy.size.width))),
                    id: \.0.id
                ) { share, width in
                    Rectangle()
                        .fill(share.category.color)
                        .frame(width: width)
                }
            }
        }
        .frame(height: TrailBreakdownMetrics.barHeight)
        // A track under the segments, so a share drawn at a low alpha — the
        // unmapped one — reads as a light band rather than as a hole with the
        // map showing through it. See ``Color/contentSurface``.
        .background(Color.contentSurface)
        .clipShape(.capsule)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(identifier)
    }

    /// Rounded to whole points, with the final share taking whatever is left
    /// rather than its own rounded share — otherwise a bar of six segments can
    /// end a few points short of the capsule it is clipped to, and the gap
    /// reads as a seventh, unlabelled category.
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
                return "\(percent) \(share.category.displayName)"
            }
            .formatted(.list(type: .and))
    }
}

// MARK: - Legend

struct TrailBreakdownLegendRow<Category: TrailCategoryPresentation>: View {
    let share: TrailBreakdown<Category>.Share

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(share.category.color)
                .frame(width: TrailBreakdownMetrics.swatchSize, height: TrailBreakdownMetrics.swatchSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(share.category.displayName)
                    .font(.subheadline)
                Text(share.category.summary)
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
