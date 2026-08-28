//
//  HikeActivityPresentation.swift
//  OpenHikesShared
//
//  What a Live Activity says, decided here rather than in the widget
//  extension's view bodies.
//
//  Same argument as ``TrailWidgetMetric``: the app decides when an activity
//  starts and what goes in it, the extension draws it, and the wording,
//  rounding and choice of which fact is worth the width have to be made once.
//  It also means the interesting half — a percentage, an off-trail warning, a
//  paused clock — is reachable from `swift test` on the macOS host, where a
//  rendered `ActivityConfiguration` is not.
//

import Foundation

/// One rendered Live Activity, in the smallest form every family can be built
/// from: the Lock Screen banner, the expanded Dynamic Island, and the two
/// compact regions all read this.
public struct HikeActivityPresentation: Sendable, Equatable {
    /// The trail's name, or the recording's.
    public var title: String
    /// The glyph beside ``title``, and the one the minimal Dynamic Island
    /// presentation shows on its own.
    public var symbolName: String
    /// A short word about what is wrong or unusual — "Paused", "Off trail" —
    /// or `nil` when the walk is simply proceeding. Never used for anything
    /// routine: a label that is always there is a label nobody reads.
    public var statusLabel: String?
    /// The one number worth the largest type on the screen.
    public var primaryValue: String
    public var primaryCaption: String
    /// The second number, where there is one. `nil` for a running recording,
    /// whose second slot is the self-ticking clock — see ``showsElapsedTimer``.
    public var secondaryValue: String?
    public var secondaryCaption: String?
    public var metrics: [TrailWidgetMetric]
    /// Fraction of the trail walked, 0...1, or `nil` when there is nothing to
    /// measure against — every recording, and a follow with no live fix.
    public var progress: Double?
    /// Whether the view should draw a system-ticked `Text(timerInterval:)`
    /// from ``timerStart`` rather than ``elapsedText``.
    ///
    /// The distinction is the whole reason both exist: a running clock must
    /// tick without the app sending an update, and a paused one must not tick
    /// at all.
    public var showsElapsedTimer: Bool
    public var timerStart: Date
    /// The clock as text, for the paused case and for VoiceOver — which reads
    /// a `Text(timerInterval:)` as an unhelpful running number.
    public var elapsedText: String
    public var accessibilityLabel: String
    public var accessibilityValue: String
}

public extension HikeActivityAttributes {
    /// The presentation for `state`.
    ///
    /// - Parameter metricLimit: how many stat chips the family has room for,
    ///   applied the way ``TrailWidgetLayout`` applies it in the widget —
    ///   most useful first, so truncating drops the least useful.
    func presentation(
        for state: ContentState,
        metricLimit: Int = 3,
        locale: Locale = .current
    ) -> HikeActivityPresentation {
        switch subject {
        case .recording:
            recordingPresentation(
                for: state,
                metricLimit: metricLimit,
                locale: locale
            )
        case .following:
            followingPresentation(
                for: state,
                metricLimit: metricLimit,
                locale: locale
            )
        }
    }

    /// A recording leads with how far has been walked and how long it has
    /// taken, because nothing knows how far it is going to be. There is no
    /// progress bar for the same reason — a bar with no end is a decoration.
    private func recordingPresentation(
        for state: ContentState,
        metricLimit: Int,
        locale: Locale
    ) -> HikeActivityPresentation {
        let metrics = Array(
            [
                TrailWidgetMetric.ascent(
                    meters: state.elevationGainMeters,
                    locale: locale
                ),
                TrailWidgetMetric.pace(
                    metersPerSecond: state.averageSpeedMetersPerSecond,
                    locale: locale
                ),
                TrailWidgetMetric.points(state.pointCount, locale: locale),
            ]
            .compactMap(\.self)
            .prefix(metricLimit)
        )
        let distance = WidgetFormat.length(
            meters: state.distanceMeters,
            locale: locale
        )
        let elapsed = WidgetFormat.duration(seconds: state.elapsedSeconds)
        let status = Self.recordingStatus(for: state.runState)
        return HikeActivityPresentation(
            title: title,
            symbolName: status.symbolName,
            statusLabel: status.label,
            primaryValue: distance,
            primaryCaption: "Distance",
            // Only when the clock has stopped. A running recording puts the
            // live timer in this slot instead, which the view builds from
            // `timerStart`.
            secondaryValue: state.isTicking ? nil : elapsed,
            secondaryCaption: "Elapsed",
            metrics: metrics,
            progress: nil,
            showsElapsedTimer: state.isTicking,
            timerStart: state.timerStart,
            elapsedText: elapsed,
            accessibilityLabel: status.label.map { "\(title), \($0.lowercased())" }
                ?? title,
            accessibilityValue: Self.spoken(
                ["\(distance) walked", elapsed],
                metrics: metrics
            )
        )
    }

    /// The glyph and the word for each thing a recording can be doing.
    ///
    /// `nil` for a running one deliberately: a status line that is always
    /// populated is a status line nobody reads, so the ordinary case says
    /// nothing and the two that need attention stand out.
    private static func recordingStatus(
        for runState: ContentState.RunState
    ) -> (symbolName: String, label: String?) {
        switch runState {
        case .running: ("figure.hiking", nil)
        case .paused: ("pause.circle.fill", "Paused")
        case .finished: ("checkmark.circle.fill", "Finished")
        }
    }

    /// A followed trail leads with the percentage and what is left, because
    /// both of those are only answerable when there *is* an end — and drops
    /// straight back to the trail's own length when the walker has no usable
    /// fix, rather than claiming 0%.
    private func followingPresentation(
        for state: ContentState,
        metricLimit: Int,
        locale: Locale
    ) -> HikeActivityPresentation {
        let metrics = Array(
            [
                TrailWidgetMetric.currentElevation(
                    meters: state.currentElevationMeters,
                    locale: locale
                ),
                TrailWidgetMetric.ascent(
                    meters: state.elevationGainMeters,
                    locale: locale
                ),
            ]
            .compactMap(\.self)
            .prefix(metricLimit)
        )
        let progress = fractionComplete(for: state)
        let elapsed = WidgetFormat.duration(seconds: state.elapsedSeconds)
        let isOnRoute = state.offRouteMeters != nil
        let remaining = remainingDistanceMeters(for: state).map { meters in
            WidgetFormat.length(meters: meters, locale: locale)
        }
        let total = WidgetFormat.length(
            meters: routeDistanceMeters ?? 0,
            locale: locale
        )
        return HikeActivityPresentation(
            title: title,
            symbolName: isOnRoute ? "figure.hiking" : "exclamationmark.triangle.fill",
            statusLabel: isOnRoute ? nil : "Off trail",
            primaryValue: progress.map { fraction in
                "\(Int((fraction * 100).rounded()))%"
            } ?? total,
            primaryCaption: progress == nil ? "Trail length" : "Complete",
            secondaryValue: remaining,
            secondaryCaption: "Remaining",
            metrics: metrics,
            progress: progress,
            // A follow has no clock of its own: the walker may have opened the
            // trail hours before setting off, so counting from `startedAt`
            // would report the wrong thing with great confidence.
            showsElapsedTimer: false,
            timerStart: state.timerStart,
            elapsedText: elapsed,
            accessibilityLabel: isOnRoute
                ? title
                : "\(title), off trail",
            accessibilityValue: Self.spoken(
                [
                    progress.map { fraction in
                        "\(Int((fraction * 100).rounded())) percent complete"
                    } ?? "\(total) long",
                    remaining.map { "\($0) remaining" },
                ],
                metrics: metrics
            )
        )
    }

    /// Fraction of the followed trail walked, or `nil` when there is no live
    /// fix or no route length to measure against.
    ///
    /// Mirrors ``SharedTrailSnapshot/fractionComplete`` rather than
    /// reimplementing it — same clamp, same refusal on a zero-length route.
    func fractionComplete(for state: ContentState) -> Double? {
        guard state.offRouteMeters != nil,
              let routeDistanceMeters,
              routeDistanceMeters > 0
        else { return nil }
        return min(1, max(0, state.distanceMeters / routeDistanceMeters))
    }

    /// Distance left to the end of the followed trail, or `nil` on the same
    /// terms as ``fractionComplete(for:)``.
    func remainingDistanceMeters(for state: ContentState) -> Double? {
        guard state.offRouteMeters != nil, let routeDistanceMeters
        else { return nil }
        return max(0, routeDistanceMeters - state.distanceMeters)
    }

    /// Joins the spoken figures and the chips into the single phrase VoiceOver
    /// reads, dropping whatever the state had nothing to say about.
    private static func spoken(
        _ parts: [String?],
        metrics: [TrailWidgetMetric]
    ) -> String {
        (parts.compactMap(\.self) + metrics.map(\.accessibilityPhrase))
            .joined(separator: ", ")
    }
}
