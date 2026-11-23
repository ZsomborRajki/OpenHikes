//
//  RecordingCard.swift
//  OpenHikes
//
//  The recording screen's card: the trail underfoot, what a failed save
//  needs, the notices, and the numbers — the hike detail's own, see
//  ``RecordingStatsSection``.
//
//  The phase and the controls are not here. They are the bar's, which is on
//  screen at every detent — see ``RecordingBar`` — and the card's title row
//  that held them was out of reach with the sheet down.
//

import Foundation
import OpenHikesData
import SwiftUI

struct RecordingCard: View {
    let recorder: HikeRecorder
    /// Asked when a failed save's recording is to be thrown away, as Stop
    /// asks it, and what saves it again — see ``RecordingStopQuestion``.
    let question: RecordingStopQuestion

    /// Reads `phase`, the recovery state and whether a save can be retried —
    /// each of which moves a handful of times a session. Everything that moves
    /// per fix is read further down, by ``RecordingTrailLine`` and
    /// ``RecordingStatsSection``, which are the boundaries for it.
    var body: some View {
        VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
            RecordingTrailLine(stats: recorder.stats)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // First under the trail: a save that failed is what the hiker is
            // deciding about, so it has to be the first thing in view at the
            // sheet's middle height rather than under the numbers.
            phaseContent
            RecordingRecoveryNotice(recorder: recorder)
            RecordingConditionsNotice(recorder: recorder)
            RecordingStatsSection(recorder: recorder)
            RecordingSegmentSection(stats: recorder.stats)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The phases whose decision does not fit in the bar.
    @ViewBuilder private var phaseContent: some View {
        switch recorder.phase {
        case .failed(let failure):
            if recorder.canRetrySave {
                VStack(alignment: .leading, spacing: 12) {
                    Text(failure.errorDescription ?? String(localized: "The hike could not be saved."))
                        .font(.headline)
                    if let suggestion = failure.recoverySuggestion {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button("Retry Save") {
                        Task { await question.retrySave() }
                    }
                    .prominentGlassButtonStyle()
                    .accessibilityIdentifier("recording-retry-save")
                    discardButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if recorder.isActive {
                discardButton
            } else {
                Button("Try Again") {
                    recorder.dismissFailure()
                }
                .prominentGlassButtonStyle()
                .frame(maxWidth: .infinity)
            }
        default:
            EmptyView()
        }
    }

    private var discardButton: some View {
        Button("Discard Recording", role: .destructive) {
            question.confirmDiscard()
        }
        .glassButtonStyle()
        .frame(maxWidth: .infinity)
    }
}

/// What OpenStreetMap knows about the ground underfoot, as the line under the
/// card's title — where a Maps place card says what kind of place it is.
///
/// The graph this reads was already being downloaded, matched against and
/// then thrown away: live matching resolves the way under every fix in order
/// to snap the line, and only the trail's *name* ever reached the screen. The
/// grade and the surface come from the same edge at no additional cost.
///
/// Its own view because the match moves per fix: reading it from
/// ``RecordingCard``'s body would put the whole card on that clock.
private struct RecordingTrailLine: View {
    private static let symbolName =
        "point.topleft.down.to.point.bottomright.curvepath"
    /// How far the line fades while the match behind it is being overtaken.
    /// Enough to read as "a moment out of date" and not so far as to read as
    /// disabled.
    private static let staleOpacity: CGFloat = 0.6

    let stats: RecordingStats

    var body: some View {
        if let trail = stats.currentTrail, !trail.isEmpty {
            Label(
                ([trail.name ?? String(localized: "On a mapped trail")] + trail.descriptors)
                    .joined(separator: " · "),
                systemImage: Self.symbolName
            )
            // Dimmed rather than removed while the match is being overtaken by
            // newer fixes, so the line never blinks — see
            // ``RecordingStats/isCurrentTrailStale``.
            .opacity(stats.isCurrentTrailStale ? Self.staleOpacity : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: trail))
        } else if let dominantTrailName = stats.dominantTrailName {
            // Past tense: the live trail is cleared when matching stops, so
            // the only way to reach this is a walk that has finished.
            Text("Followed: \(dominantTrailName)")
        }
    }

    /// One sentence rather than a glyph, a name and a middle dot. The symbol
    /// is decorative and `·` is spoken, both of which `Label` and the
    /// joined line above would otherwise hand to VoiceOver verbatim.
    private func accessibilityLabel(for trail: RecordingTrailContext) -> String {
        let name = trail.name.map { String(localized: "On \($0)") } ?? String(localized: "On a mapped trail")
        guard !trail.descriptors.isEmpty else { return name }
        return "\(name). \(trail.descriptors.joined(separator: ", "))"
    }
}
