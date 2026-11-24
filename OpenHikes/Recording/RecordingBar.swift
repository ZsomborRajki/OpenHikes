//
//  RecordingBar.swift
//  OpenHikes
//
//  The recording screen's navigation bar: what the recording is doing in the
//  middle, and Pause or Resume and Stop on the trailing edge.
//
//  In the bar because the bar is what is still on screen with the sheet at
//  its smallest detent, which is where a hiker who has put the phone away
//  and wants the map leaves it — and the controls were on the card's title
//  row under it, out of reach from there. The owner's "mini player"
//  (2026-11-20): the bar on the recording's own screen, and the capsule on
//  the map on every other — see ``MapActivityCapsule``.
//
//  Stop asks the question the capsule's Stop asks, through the one object
//  both hold — see ``RecordingStopQuestion``. Throwing a recording away is
//  one of its answers, so a paused recording has no discard button of its
//  own any more.
//
//  Each item is a view of its own, because a `.toolbar` closure is inlined
//  into the body that declares it: the phase, the clock and the distance are
//  read here and never in ``RecordingView``'s body.
//

import Foundation
import SwiftUI

/// The bar's three items.
struct RecordingBar: ToolbarContent {
    let recorder: HikeRecorder
    /// What the idle Start goes through, as the map's record button does —
    /// see ``RecordingStartButton``.
    let entry: RecordingEntry
    let question: RecordingStopQuestion

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            RecordingBarStatus(recorder: recorder)
        }
        ToolbarItem(placement: .topBarTrailing) {
            RecordingPauseButton(recorder: recorder)
        }
        ToolbarItem(placement: .topBarTrailing) {
            RecordingBarAction(recorder: recorder, entry: entry, question: question)
        }
    }
}

/// The phase, its dot, and under them the clock and the distance.
private struct RecordingBarStatus: View {
    private static let dotSize: CGFloat = 8

    let recorder: HikeRecorder

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(recorder.phase.dotColor)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .accessibilityHidden(true)
                Text(recorder.phase.accessibilityTitle)
                    .font(.subheadline.weight(.semibold))
            }
            RecordingClockAndDistance(recorder: recorder)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("recording-phase")
    }
}

/// The recording's clock and how far it has come. Its own view because the
/// distance moves per fix. The clock ticks by itself — see ``ActivityClock``.
///
/// Drawn by the bar and by the map's capsule alike.
struct RecordingClockAndDistance: View {
    let recorder: HikeRecorder

    var body: some View {
        HStack(spacing: 4) {
            if recorder.sessionStartedAt != nil {
                ActivityClock(elapsed: recorder.elapsedSeconds(), isRunning: true)
                Text(verbatim: "·").accessibilityHidden(true)
            }
            Text(
                Measurement(value: recorder.stats.distanceMeters, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
            )
        }
    }
}

/// Pause while the recording takes fixes, Resume while it is paused, and
/// nothing otherwise.
private struct RecordingPauseButton: View {
    let recorder: HikeRecorder

    var body: some View {
        switch recorder.phase {
        case .waitingForFix, .recording:
            Button("Pause", systemImage: "pause.fill") { recorder.pause() }
        case .paused:
            Button("Resume", systemImage: "play.fill") {
                Task { await recorder.resume() }
            }
        case .idle, .recovering, .saving, .failed:
            EmptyView()
        }
    }
}

/// Stop while there is a recording to stop, Start while there is none, and a
/// spinner while one is being recovered or saved. A failed save says what it
/// needs on the screen itself — see ``RecordingCard``.
private struct RecordingBarAction: View {
    let recorder: HikeRecorder
    let entry: RecordingEntry
    let question: RecordingStopQuestion

    var body: some View {
        switch recorder.phase {
        case .idle:
            RecordingStartButton(entry: entry)
        case .recovering, .saving:
            ProgressView()
        case .waitingForFix, .recording, .paused:
            Button("Stop", systemImage: "stop.fill") {
                Task { await question.ask() }
            }
            .prominentGlassButtonStyle()
            .tint(.red)
            .accessibilityIdentifier("recording-stop")
        case .failed:
            EmptyView()
        }
    }
}

/// The idle screen's Start, which starts a recording the way the map's record
/// button does — through ``RecordingEntry`` — rather than asking the recorder.
///
/// This screen is up with nothing recording more often than it looks: a row
/// carrying another device's draft, or one a reinstall left behind, opens it
/// on this phone's idle recorder, and a Start that asked the recorder itself
/// began a recording beside a walk the hiker had paused. A hiker walks a trail
/// or records one, never both, so mid-walk this asks first, with the map
/// button's menu and words, and *End Hike and Record* ends the walk before
/// anything records. A refused End is said by the map's alert, which is
/// attached above this screen — see ``MapScreenAlerts``.
///
/// After a *Record Instead* whose start failed here, it is that handoff
/// tried again, beginning with what the walk covered — see
/// ``RecordingEntry/startOnRecordingScreen()``.
///
/// Its own view so that the walk it asks about is read here, rather than in
/// the bar's other items.
struct RecordingStartButton: View {
    let entry: RecordingEntry

    var body: some View {
        Group {
            if let trail = entry.walkToEnd {
                Menu {
                    // The menu's title, as `UIMenu` gives the map's button one.
                    Section(String(localized: "End your hike on \(trail) and start recording?")) {
                        Button("End Hike and Record", systemImage: "record.circle") {
                            entry.endWalkAndRecord()
                        }
                    }
                } label: {
                    startLabel
                }
            } else {
                Button {
                    entry.startOnRecordingScreen()
                } label: {
                    startLabel
                }
            }
        }
        .menuStyle(.button)
        .prominentGlassButtonStyle()
        .tint(.red)
    }

    /// A key of its own for the "Start" that a route's first stop and a
    /// hike's start time also read in English, because French names those
    /// « Départ » and this button « Démarrer ».
    private var startLabel: some View {
        Label(String(localized: "recording.start", defaultValue: "Start"), systemImage: "record.circle")
    }
}
