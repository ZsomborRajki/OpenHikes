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
