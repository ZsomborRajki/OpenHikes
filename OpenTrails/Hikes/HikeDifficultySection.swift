//
//  HikeDifficultySection.swift
//  OpenTrails
//
//  The SAC-scale difficulty breakdown shown on a hike's detail screen: a
//  stacked bar of how demanding each stretch of trail is, and a legend that
//  reads it out.
//
//  Split into its own view so the analysis states — and the model write that
//  ends them — invalidate this section rather than the whole detail screen.
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

struct HikeDifficultySection: View {
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
            Text("Difficulty").font(.headline)
            Spacer()
            if hike.difficultyBreakdown != nil, state != .analyzing {
                Button {
                    analyze()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh difficulty analysis")
                .accessibilityIdentifier("difficulty-refresh-button")
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let breakdown = hike.difficultyBreakdown {
            TrailDifficultyBar(shares: breakdown.shares)
            VStack(spacing: 8) {
                ForEach(breakdown.shares) { share in
                    TrailDifficultyLegendRow(share: share)
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
            .accessibilityIdentifier("difficulty-analyzing")

        case .idle, .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "See how demanding each section of this route is using the"
                        + " SAC hiking scale from OpenStreetMap."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("difficulty-error")
                }
                Button("Analyze Difficulty") { analyze() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("difficulty-analyze-button")
            }
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

    // MARK: Analysis

    private func analyzeFromCache() async {
        guard let provider, hike.difficultyBreakdown == nil else { return }
        let route = hike.route
        let breakdown = await TrailDifficultyAnalysis.cachedBreakdown(
            route: route,
            provider: provider
        )
        guard !Task.isCancelled, let breakdown else { return }
        hike.difficultyBreakdown = breakdown
    }

    private func analyze() {
        guard let provider else { return }
        let route = hike.route
        state = .analyzing
        Task {
            do {
                let breakdown = try await TrailDifficultyAnalysis
                    .downloadedBreakdown(route: route, provider: provider)
                guard !Task.isCancelled else { return }
                hike.difficultyBreakdown = breakdown
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
