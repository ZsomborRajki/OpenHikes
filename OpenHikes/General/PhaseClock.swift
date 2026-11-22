//
//  PhaseClock.swift
//  OpenHikes
//

import SwiftUI

/// The elapsed-time readout at the end of a recording or walk header, and the
/// app's last per-second wake-up.
///
/// Its own view so the 1 Hz tick redraws a `Text` rather than the header
/// around it — the header carries a coloured dot, a title and a `Spacer`, none
/// of which have changed in a second.
///
/// **It stores the formatted readout rather than the session or the recorder,
/// and that is not a style choice.** A view holding only a reference is
/// structurally identical on every tick, so SwiftUI skips its body and the
/// clock silently freezes — which is exactly what happened the first time this
/// was extracted. The string is what makes the tick visible to the diff.
///
/// ``WalkControls`` draws one while a trail is being followed. The recording
/// screen's clock is a ``StatFigure`` in its stats strip instead, and keeps
/// the same rule for the same reason: it stores the formatted value, never
/// the recorder.
struct PhaseClock: View {
    let readout: String

    var body: some View {
        Text(readout)
            .font(.headline.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// A recording's or a walk's clock in the space of a caption — the recording
/// screen's bar and the map's activity capsule — that ticks by itself while
/// it runs and stands still while it does not.
///
/// It ticks as the Live Activity's does, through `Text(timerInterval:)`: no
/// body runs for it, and nothing ticks while it is not drawn, so it needs
/// neither the `TimelineView` nor the scene-phase gate ``PhaseClock``'s
/// readers keep.
///
/// Started from the figure handed in rather than from a start date: a
/// recording counts from a monotonic source wherever it has one — see
/// ``HikeRecorder/elapsedSeconds()`` — and a walk leaves its pauses out. The
/// figure is read when this is built, which is when the phase moves.
struct ActivityClock: View {
    let elapsed: TimeInterval
    let isRunning: Bool

    var body: some View {
        if isRunning {
            let start = Date.now.addingTimeInterval(-elapsed)
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
        } else {
            Text(Duration.seconds(elapsed.rounded(.down)).formatted(.time(pattern: .hourMinuteSecond)))
        }
    }
}
