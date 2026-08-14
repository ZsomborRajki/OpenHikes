//
//  HikeSurfaceSection.swift
//  OpenHikes
//
//  The surface breakdown shown on a hike's detail screen: a stacked bar of
//  what the route runs on, and the legend that reads it out.
//
//  Split into its own view so the analysis states — and the model write that
//  ends them — invalidate this section rather than the whole detail screen.
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

struct HikeSurfaceSection: View {
    nonisolated enum AnalysisState: Equatable, Sendable {
        case idle
        case analyzing
        case failed(String)
    }

    let hike: Hike
    /// `nil` in previews and in UI-test launches without a bundled graph;
    /// the section hides itself rather than offering an action that can't run.
    let provider: (any TrailGraphProviding)?

    @State private var state: AnalysisState = .idle

    private static let percentStyle = FloatingPointFormatStyle<Double>.Percent
        .percent
        .precision(.fractionLength(0))
    /// Above this, the footnote drops the coverage caveat: the shortfall is
    /// smaller than the rounding on the percentages beside it.
    private static let fullCoverageThreshold = 0.995

    var body: some View {
        if provider != nil, hike.route.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                header
                content
            }
            .task(id: hike.id) { await analyzeFromCache() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Surface").font(.headline)
            Spacer()
            if hike.surfaceBreakdown != nil, state != .analyzing {
                Button {
                    analyze()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh surface analysis")
                .accessibilityIdentifier("surface-refresh-button")
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let breakdown = hike.surfaceBreakdown {
            TrailSurfaceBar(shares: breakdown.shares)
            VStack(spacing: 8) {
                ForEach(breakdown.shares) { share in
                    TrailSurfaceLegendRow(share: share)
                }
            }
            Text(footnote(for: breakdown))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            unanalyzed
        }
    }

    @ViewBuilder private var unanalyzed: some View {
        switch state {
        case .analyzing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking up trail data…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("surface-analyzing")

        case .idle, .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "See how much of this route runs on pavement, gravel, or"
                        + " open ground, using OpenStreetMap trail data."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("surface-error")
                }
                Button("Analyze Surface") { analyze() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("surface-analyze-button")
            }
        }
    }

    private func footnote(for breakdown: TrailSurfaceBreakdown) -> String {
        let surveyed = breakdown.surveyedFraction
        guard surveyed < Self.fullCoverageThreshold else {
            return "Surfaces from OpenStreetMap."
        }
        let formatted = surveyed.formatted(Self.percentStyle)
        return "Surfaces from OpenStreetMap, which describes \(formatted)"
            + " of this route."
    }

    // MARK: Analysis

    /// Free pass on open: a hike recorded with the graph already prefetched
    /// along the way gets its surfaces without anyone asking, and without a
    /// request.
    private func analyzeFromCache() async {
        guard let provider, hike.surfaceBreakdown == nil else { return }
        let route = hike.route
        let breakdown = await TrailSurfaceAnalysis.cachedBreakdown(
            route: route,
            provider: provider
        )
        guard !Task.isCancelled, let breakdown else { return }
        hike.surfaceBreakdown = breakdown
    }

    private func analyze() {
        guard let provider else { return }
        let route = hike.route
        state = .analyzing
        Task {
            do {
                let breakdown = try await TrailSurfaceAnalysis
                    .downloadedBreakdown(route: route, provider: provider)
                guard !Task.isCancelled else { return }
                hike.surfaceBreakdown = breakdown
                state = .idle
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
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
