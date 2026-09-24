//
//  RecordingCard.swift
//  OpenHikes
//
//  The recording screen as an Apple Maps place card: the phase as the title,
//  the trail underfoot as the line under it, and Pause and Stop on the title
//  row's trailing edge, where a place card keeps Share and Close. The numbers
//  under it are the hike detail's own — see ``RecordingStatsSection``.
//

import OpenHikesData
import os
import SwiftUI

struct RecordingCard: View {
    /// How close two adjacent glass controls have to come before they merge.
    private static let controlGlassSpacing: CGFloat = 8

    let recorder: HikeRecorder
    var onSaved: (Hike) -> Void
    var onDiscarded: (UUID?) -> Void

    @State private var showDiscardConfirmation = false
    @State private var showStopAlert = false
    @State private var stopNameDraft = ""
    /// The name the walk has earned, taken once when the hiker asks to stop.
    ///
    /// Held here rather than read in `body`, which is the whole reason it is
    /// a `@State`: ``HikeRecorder/suggestedTitle`` reads the live distance,
    /// and a body observing that re-runs on every accepted fix. A button's
    /// action is not a body, so reading it there costs one look and creates
    /// no dependency. `nil` when no trail covered enough of the walk.
    @State private var stopNameSuggestion: String?

    /// Reads `phase`, the recovery state and whether a save can be retried —
    /// each of which moves a handful of times a session. Everything that moves
    /// per fix is read further down, by ``RecordingTrailLine`` and
    /// ``RecordingStatsSection``, which are the boundaries for it.
    var body: some View {
        VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
            PlaceCardHeader {
                RecordingPhaseTitle(phase: recorder.phase)
            } subtitle: {
                RecordingTrailLine(stats: recorder.stats)
            } trailing: {
                titleControls
            }
            // Straight under the title: a stopped hike's route review is what
            // the hiker is deciding, and the section it is about is drawn on
            // the map above the sheet, so it has to be the first thing in view
            // at the sheet's middle height rather than under the numbers.
            phaseContent
            RecordingRecoveryNotice(recorder: recorder)
            RecordingConditionsNotice(recorder: recorder)
            RecordingStatsSection(recorder: recorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                Task {
                    let hikeID = recorder.currentHike?.id
                    await recorder.discard()
                    if recorder.phase == .idle {
                        onDiscarded(hikeID)
                    }
                }
            }
            Button("Cancel", role: .cancel) { /* no-op */ }
        } message: {
            Text("The recorded track cannot be recovered after it is discarded.")
        }
        .alert("Name Your Hike", isPresented: $showStopAlert) {
            // The trail the walk mostly followed, when there is one, and the
            // draft's own name — the time of day and the date — when there
            // is not. A placeholder is a promise about what happens if the
            // hiker types nothing, so this is the same answer ``persist``
            // writes, measured moments earlier against the live distance.
            TextField(
                stopNameSuggestion ?? recorder.currentHike?.title ?? "Hike name",
                text: $stopNameDraft
            )
            Button("Save") {
                Task { await stopAndSave() }
            }
            Button("Cancel", role: .cancel) { /* no-op */ }
        } message: {
            Text("Give this hike a name, or leave it blank to keep the default.")
        }
    }

    /// What the title row's trailing edge offers in each phase. A phase that
    /// needs more than a button or two — a route to review, a save to retry —
    /// offers nothing here and says what it needs in ``phaseContent``.
    @ViewBuilder private var titleControls: some View {
        switch recorder.phase {
        case .idle:
            Button("Start", systemImage: "record.circle") {
                Task { await recorder.start() }
            }
            .prominentGlassButtonStyle()
            .tint(.red)
        case .recovering, .saving:
            ProgressView()
        case .waitingForFix, .recording:
            // Two `.glass` buttons side by side: a container renders them in
            // one pass and lets them blend as they meet, which is what makes
            // a pair read as one control group rather than two panes.
            GlassStack(spacing: Self.controlGlassSpacing) {
                HStack(spacing: Self.controlGlassSpacing) {
                    Button("Pause", systemImage: "pause.fill") {
                        recorder.pause()
                    }
                    .glassButtonStyle()
                    .placeCardControl()

                    stopButton
                }
            }
        case .paused:
            GlassStack(spacing: Self.controlGlassSpacing) {
                HStack(spacing: Self.controlGlassSpacing) {
                    // A button of its own rather than an item in a "…" menu:
                    // XCUITest never sees an identifier on a `Menu`'s button,
                    // and the confirmation it opens is the safeguard anyway.
                    Button("Discard Recording", systemImage: "trash", role: .destructive) {
                        showDiscardConfirmation = true
                    }
                    .glassButtonStyle()
                    .placeCardControl()

                    Button("Resume", systemImage: "play.fill") {
                        Task { await recorder.resume() }
                    }
                    .glassButtonStyle()
                    .placeCardControl()

                    stopButton
                }
            }
        case .reviewing, .failed:
            EmptyView()
        }
    }

    /// The phases whose decision does not fit on the title row.
    @ViewBuilder private var phaseContent: some View {
        switch recorder.phase {
        case .reviewing:
            if let review = recorder.routeReview {
                RecordingRouteReviewControls(
                    recorder: recorder,
                    review: review
                ) { hike in
                    onSaved(hike)
                }
            }
            discardButton
        case .failed(let failure):
            if recorder.canRetrySave {
                VStack(alignment: .leading, spacing: 12) {
                    Text(failure.errorDescription ?? "The hike could not be saved.")
                        .font(.headline)
                    if let suggestion = failure.recoverySuggestion {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button("Retry Save") {
                        Task { await retrySave() }
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

    private var stopButton: some View {
        Button("Stop", systemImage: "stop.fill") {
            // Deliberately blank rather than pre-filled with the default
            // title. The alert's own copy says "leave it blank to keep the
            // default" and the field's placeholder already shows that default,
            // so pre-filling made the field impossible to leave blank —
            // tapping Stop → Save without typing sent the default through as
            // `customName`, and `normalizedCustomName` only nils out an
            // *empty* string, so the hike was permanently flagged user-named.
            // The rendered name was identical, which is why nothing looked
            // wrong; the state was just no longer true.
            stopNameDraft = ""
            stopNameSuggestion = recorder.suggestedTitle
            showStopAlert = true
        }
        .prominentGlassButtonStyle()
        .tint(.red)
        .placeCardControl()
    }

    private var discardButton: some View {
        Button("Discard Recording", role: .destructive) {
            showDiscardConfirmation = true
        }
        .glassButtonStyle()
        .frame(maxWidth: .infinity)
    }

    private func stopAndSave() async {
        let customName = stopNameDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        do {
            let outcome = try await recorder.stop(customName: customName)
            if case .saved(let hike) = outcome {
                onSaved(hike)
            }
        } catch {
            HikeRecorder.logger.error(
                "Recording save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func retrySave() async {
        do {
            onSaved(try await recorder.retrySave())
        } catch {
            HikeRecorder.logger.error(
                "Recording save retry failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// The phase as the card's title, with the coloured dot that says it at a
/// glance ahead of it.
private struct RecordingPhaseTitle: View {
    private static let dotSize: CGFloat = 10

    let phase: HikeRecorder.Phase

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .accessibilityHidden(true)
            Text(phase.accessibilityTitle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("recording-phase")
    }

    private var dotColor: Color {
        switch phase {
        case .recording: .red
        case .recovering, .waitingForFix, .saving: .orange
        case .paused: .secondary
        case .reviewing: .orange
        case .idle: .green
        case .failed: .red
        }
    }
}

extension HikeRecorder.Phase {
    var accessibilityTitle: String {
        switch self {
        case .idle: "Ready"
        case .recovering: "Recovering"
        case .waitingForFix: "Finding GPS"
        case .recording: "Recording"
        case .paused: "Paused"
        case .saving: "Saving"
        case .reviewing: "Review Route"
        case .failed: "Needs Attention"
        }
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
                ([trail.name ?? "On a mapped trail"] + trail.descriptors)
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
        let name = trail.name.map { "On \($0)" } ?? "On a mapped trail"
        guard !trail.descriptors.isEmpty else { return name }
        return "\(name). \(trail.descriptors.joined(separator: ", "))"
    }
}
