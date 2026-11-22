//
//  MapActivityCapsuleView.swift
//  OpenHikes
//
//  What the map's activity capsule draws: Stop or End, Pause or Resume, and
//  the status a tap on which goes back to the activity's screen — see
//  ``MapActivityCapsule``.
//
//  SwiftUI, hosted on the map by `MapCoordinator+ActivityCapsule.swift`,
//  which places it in the leading column and fades it with the sheet as the
//  pills are faded. Its own root, so what it reads — the phase, the distance
//  per fix — re-runs this and nothing on the map or in the sheet. The clock
//  ticks by itself, as the Live Activity's does, through
//  `Text(timerInterval:)`: no body runs for it, and nothing ticks while the
//  map is not drawn.
//

import OpenHikesData
import SwiftUI

struct MapActivityCapsuleView: View {
    /// How close the capsule's three pieces of glass come before they merge,
    /// as the pills' do — see ``MapGlassPill``.
    private static let glassSpacing: CGFloat = 10
    private static let pieceSpacing: CGFloat = 4

    let capsule: MapActivityCapsule

    /// The last activity the capsule stood for, kept while it fades out so
    /// the fade has something to show.
    @State private var shown: MapActivityCapsule.Activity?

    var body: some View {
        let activity = capsule.activity ?? shown
        GlassStack(spacing: Self.glassSpacing) {
            HStack(spacing: Self.pieceSpacing) {
                switch activity {
                case .recording:
                    RecordingCapsuleControls(capsule: capsule)
                case let .walk(hikeID):
                    WalkCapsuleControls(capsule: capsule, hikeID: hikeID)
                case nil:
                    EmptyView()
                }
            }
        }
        .fixedSize()
        .onChange(of: capsule.activity, initial: true) { _, activity in
            if let activity { shown = activity }
        }
    }
}

// MARK: - Recording

/// A recording's three: Stop, Pause or Resume, and its status.
private struct RecordingCapsuleControls: View {
    let capsule: MapActivityCapsule

    private var recorder: HikeRecorder { capsule.recorder }

    var body: some View {
        let phase = recorder.phase
        if recorder.isStoppable {
            CapsuleGlyphButton(
                title: "Stop",
                symbol: "stop.fill",
                identifier: "activity-capsule-stop",
                tint: .red
            ) {
                Task { await capsule.recordingStop.ask() }
            }
        }
        switch phase {
        case .waitingForFix, .recording:
            CapsuleGlyphButton(title: "Pause", symbol: "pause.fill", identifier: "activity-capsule-pause") {
                recorder.pause()
            }
        case .paused:
            CapsuleGlyphButton(title: "Resume", symbol: "play.fill", identifier: "activity-capsule-pause") {
                Task { await recorder.resume() }
            }
        case .idle, .recovering, .saving, .failed:
            EmptyView()
        }
        CapsuleStatusButton(dot: phase.dotColor, title: phase.accessibilityTitle) {
            capsule.open(.recording)
        } figures: {
            RecordingClockAndDistance(recorder: recorder)
        }
    }
}

// MARK: - Walk

/// A walk's three: End, Pause or Resume, and its status.
private struct WalkCapsuleControls: View {
    let capsule: MapActivityCapsule
    let hikeID: UUID

    private var walk: TrailWalkSession { capsule.walk }

    var body: some View {
        if let phase = walk.phase, walk.walkedHikeID == hikeID {
            CapsuleGlyphButton(
                title: "End and Save Hike",
                symbol: "stop.fill",
                identifier: "activity-capsule-stop",
                tint: .red
            ) {
                capsule.walkEnd.ask()
            }
            CapsuleGlyphButton(
                title: phase.toggleTitle,
                symbol: phase.toggleSymbol,
                identifier: "activity-capsule-pause"
            ) {
                capsule.walkEnd.togglePhase()
            }
            CapsuleStatusButton(
                dot: phase == .following ? .accentColor : .secondary,
                title: phase == .following ? String(localized: "Hike Active") : String(localized: "Hike Paused")
            ) {
                capsule.open(.walk(hikeID: hikeID))
            } figures: {
                ActivityClock(elapsed: walk.activeSeconds(), isRunning: phase == .following)
            }
        }
    }
}

// MARK: - Pieces

/// One glyph in a circle of glass, the size every control on the map is.
private struct CapsuleGlyphButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let identifier: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .foregroundStyle(tint == nil ? Color.primary : Color.white)
                .frame(width: MapGlassPill.controlSize, height: MapGlassPill.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(GlassSurface.regular.tint(tint).interactive(), in: Circle())
        .accessibilityIdentifier(identifier)
    }
}

/// The status's figures, apart from its view, because a generic type stores
/// no statics.
private enum CapsuleStatusMetrics {
    static let dotSize: CGFloat = 8
    static let horizontalPadding: CGFloat = 14
    /// How far the status may shrink before it gives up a character, so a
    /// long figure at a large text size still fits beside the tracking pill.
    static let minimumScale: CGFloat = 0.8
}

/// The phase and its figures, in a capsule of glass that opens the
/// activity's screen.
private struct CapsuleStatusButton<Figures: View>: View {
    private typealias Metrics = CapsuleStatusMetrics

    let dot: Color
    let title: String
    let action: () -> Void
    @ViewBuilder let figures: () -> Figures

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dot)
                        .frame(width: Metrics.dotSize, height: Metrics.dotSize)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.footnote.weight(.semibold))
                }
                figures()
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(Metrics.minimumScale)
            .padding(.horizontal, Metrics.horizontalPadding)
            .frame(minHeight: MapGlassPill.controlSize)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(GlassSurface.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Goes back to the hike."))
        .accessibilityIdentifier("activity-capsule-status")
    }
}
