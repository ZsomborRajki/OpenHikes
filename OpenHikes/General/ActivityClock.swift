//
//  ActivityClock.swift
//  OpenHikes
//

import SwiftUI

/// A recording's or a walk's clock — the recording screen's bar, a walked
/// trail's bar and its phase row, and the map's activity capsule — that
/// ticks by itself while it runs and stands still while it does not.
///
/// It ticks as the Live Activity's does, through `Text(timerInterval:)`: no
/// body runs for it, and nothing ticks while it is not drawn, so it needs
/// neither a 1 Hz `TimelineView` nor a scene-phase gate to stop one in the
/// background.
///
/// Started from the figure handed in rather than from a start date: a
/// recording counts from a monotonic source wherever it has one — see
/// ``HikeRecorder/elapsedSeconds()`` — and a walk leaves its pauses out. The
/// figure is read when this is built, which is when the phase moves.
///
/// A stopped clock is the same timer paused where it stands, rather than the
/// figure formatted apart: a formatter of its own read `0:05:12` where the
/// running clock had read `5:12` a moment before.
struct ActivityClock: View {
    let elapsed: TimeInterval
    let isRunning: Bool

    var body: some View {
        let now = Date.now
        let start = now.addingTimeInterval(-elapsed)
        Text(timerInterval: start...Date.distantFuture, pauseTime: isRunning ? nil : now, countsDown: false)
    }
}
