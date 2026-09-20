//
//  HikeLiveActivityViews.swift
//  OpenWidget
//
//  The pieces the Live Activity's Lock Screen banner and Dynamic Island are
//  assembled from.
//
//  Split from `HikeLiveActivity.swift` for the same reason
//  `TrailWidgetComponents.swift` is split from `TrailWidget.swift`: an
//  `ActivityConfiguration` is a pair of builder closures the system renders
//  out of process, so anything left inside one can only be looked at, never
//  reasoned about. Nothing here decides *what* to say — that is
//  ``HikeActivityPresentation``, which lives in the shared package where a
//  test can reach it — only how to lay it out.
//

import AppIntents
import OpenHikesShared
import SwiftUI
import WidgetKit

/// How many stat chips each surface has room for, applied the way
/// ``TrailWidgetLayout`` applies it in the widget: the chips are ordered
/// most-useful-first, so truncating drops the least useful one.
enum HikeActivityLayout {
    /// The Lock Screen banner is the full width of the display.
    static let lockScreenMetricLimit = 3
    /// The expanded Dynamic Island loses width to the sensor housing, and its
    /// bottom region sits under two other regions rather than beside them.
    static let expandedMetricLimit = 2

    static let progressBarPadding: Double = 2
    /// How far a figure may shrink before it truncates instead. A distance
    /// grows a digit at 10 km and again at 100 km, and the banner is narrow
    /// enough that "12.3 km" and "123 km" have to share one slot.
    static let figureScaleFloor: Double = 0.7
}

/// The elapsed clock.
///
/// Two shapes rather than one, and the difference is the whole reason
/// ``HikeActivityPresentation/showsElapsedTimer`` exists: a running recording
/// gets `Text(timerInterval:)`, which the *system* ticks once a second without
/// the app spending an update from ActivityKit's budget on it, and a paused
/// one gets plain text, because a `Text(timerInterval:)` cannot be told to
/// stop.
///
/// `.monospacedDigit()` on both so the width doesn't jitter as the seconds
/// turn over, which on a Lock Screen reads as the whole row twitching.
struct HikeActivityElapsed: View {
    let presentation: HikeActivityPresentation
    var font: Font = .title2.weight(.semibold)

    /// Far enough ahead that no walk reaches it. `Text(timerInterval:)` needs
    /// a bounded range, and counting *up* means the upper bound is only there
    /// to satisfy the type — a hike this outlasts is not a case worth writing
    /// code for.
    private static let openEnded: TimeInterval = 60 * 60 * 24 * 7

    var body: some View {
        Group {
            if presentation.showsElapsedTimer {
                Text(
                    timerInterval: presentation.timerStart...presentation
                        .timerStart.addingTimeInterval(Self.openEnded),
                    countsDown: false
                )
            } else {
                Text(presentation.elapsedText)
            }
        }
        .font(font)
        .monospacedDigit()
        // VoiceOver reads a live `Text(timerInterval:)` as a number that keeps
        // changing under it. The whole activity is one element and speaks
        // `accessibilityValue`, which carries the elapsed time as words.
        .accessibilityHidden(true)
    }
}

/// The title row: a glyph, the trail's name, and — only when there is
/// something wrong — a short word about what.
struct HikeActivityHeader: View {
    let presentation: HikeActivityPresentation
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: presentation.symbolName)
                .font(.caption)
                .foregroundStyle(tint)
            Text(presentation.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let statusLabel = presentation.statusLabel {
                Text(statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }
}

/// One large number over its caption. The activity's two headline figures are
/// both drawn with this so they cannot end up different sizes.
struct HikeActivityFigure: View {
    let value: String
    let caption: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(HikeActivityLayout.figureScaleFloor)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }
}

/// The full-width Lock Screen banner, and what the Dynamic Island falls back
/// to on a device that doesn't have one.
/// The panel's own pause and resume, and whatever the last tap could not do.
///
/// Its own view, and deliberately *outside* the combined accessibility element
/// the figures above it form: that block is one tap target and reads as one
/// sentence, but a button has to be reachable on its own or VoiceOver cannot
/// press it.
///
/// Drawn only for a recording that is still going. A followed trail has no
/// pause worth putting here — the walk is the hiker's, not the app's — and a
/// `.finished` panel is a result rather than something still waiting for them.
///
/// Stop is deliberately absent; ``PauseHikeActivityIntent``'s header gives the
/// argument.
struct HikeActivityControls: View {
    let subject: HikeActivityAttributes.Subject
    let state: HikeActivityAttributes.ContentState
    let tint: Color

    private var isDrawn: Bool {
        subject.isRecording && state.runState != .finished
    }

    var body: some View {
        if isDrawn {
            VStack(alignment: .leading, spacing: 4) {
                control
                if let refusal = state.controlRefusal {
                    Text(Self.wording(for: refusal))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var control: some View {
        if state.isPaused {
            Button(intent: ResumeHikeActivityIntent()) {
                Label("Resume", systemImage: "play.fill")
            }
            .tint(tint)
        } else {
            Button(intent: PauseHikeActivityIntent()) {
                Label("Pause", systemImage: "pause.fill")
            }
            .tint(tint)
        }
    }

    /// What a refusal says out loud, spelled here rather than in the shared
    /// package because a sentence would have to cross the wire on every
    /// update and the panel has a 4 KB budget — the payload carries the case.
    ///
    /// `.needsPreciseLocation` is the one that matters, and it says what to do
    /// rather than what went wrong, matching `RecordingFailure`'s own recovery
    /// wording on the recording screen.
    static func wording(for refusal: HikeActivityControlRefusal) -> LocalizedStringKey {
        switch refusal {
        case .needsPreciseLocation: "Turn on Precise Location in Settings to carry on."
        case .notRecording: "That hike isn't recording any more."
        case .failed: "OpenHikes couldn't do that."
        }
    }
}

struct HikeActivityLockScreenView: View {
    let attributes: HikeActivityAttributes
    let state: HikeActivityAttributes.ContentState

    private var tint: Color { Color(hex: attributes.tintHex) ?? .green }

    /// Built once per body rather than read as a computed property in five
    /// places — see the "a computed property that sorts looks like a field
    /// access" note in the repository instructions.
    private var resolved: HikeActivityPresentation {
        attributes.presentation(
            for: state,
            metricLimit: HikeActivityLayout.lockScreenMetricLimit
        )
    }

    var body: some View {
        let presentation = resolved
        HStack(alignment: .bottom, spacing: 12) {
            figures(presentation)
            HikeActivityControls(
                subject: attributes.subject,
                state: state,
                tint: tint
            )
        }
        .padding(.horizontal, 4)
    }

    /// Everything the panel says, as one element.
    ///
    /// Split out of ``body`` so the accessibility grouping lands on the
    /// figures alone: this block is one tap target and reads as one sentence,
    /// but a button inside a combined element is a button VoiceOver cannot
    /// press, so the control sits beside it rather than within it.
    private func figures(_ presentation: HikeActivityPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HikeActivityHeader(presentation: presentation, tint: tint)

            HStack(alignment: .firstTextBaseline) {
                HikeActivityFigure(
                    value: presentation.primaryValue,
                    caption: presentation.primaryCaption
                )
                Spacer(minLength: 12)
                trailingFigure(presentation)
            }

            if let progress = presentation.progress {
                TrailWidgetProgressBar(
                    fraction: progress,
                    tint: tint,
                    onMap: false
                )
                .padding(.vertical, HikeActivityLayout.progressBarPadding)
            }

            TrailWidgetMetricRow(metrics: presentation.metrics, onMap: false)
        }
        // One tap target, so one element — the same rule the widget bodies
        // follow, and for the same reason: a row of unlabelled glyphs read out
        // one at a time says nothing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }

    /// The second figure: a running recording's clock, a paused one's frozen
    /// clock, or a followed trail's distance remaining. Absent when there is
    /// nothing to put there — a hiker off the trail has no "remaining" that
    /// means anything.
    @ViewBuilder
    private func trailingFigure(
        _ presentation: HikeActivityPresentation
    ) -> some View {
        switch presentation.secondaryFigure {
        case .elapsed:
            VStack(alignment: .trailing, spacing: 0) {
                HikeActivityElapsed(presentation: presentation)
                Text("Elapsed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
        case let .figure(value, caption):
            HikeActivityFigure(
                value: value,
                caption: caption,
                alignment: .trailing
            )
        case nil:
            EmptyView()
        }
    }
}
