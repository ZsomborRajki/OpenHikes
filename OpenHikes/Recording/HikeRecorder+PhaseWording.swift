//
//  HikeRecorder+PhaseWording.swift
//  OpenHikes
//
//  How a recording's phase is said and coloured, wherever it is shown: the
//  recording screen's bar, the map's capsule, and the announcement the screen
//  makes when the phase moves. A file of its own so the words stay measured
//  while the views that draw them are not — see
//  `Scripts/coverage-exclusions.txt`.
//

import SwiftUI

extension HikeRecorder.Phase {
    var accessibilityTitle: String {
        switch self {
        case .idle: String(localized: "Ready")
        case .recovering: String(localized: "Recovering")
        case .waitingForFix: String(localized: "Finding GPS")
        case .recording: String(localized: "Recording")
        case .paused: String(localized: "Paused")
        case .saving: String(localized: "Saving")
        case .failed: String(localized: "Needs Attention")
        }
    }

    /// The dot ahead of the phase, on the bar and on the map's capsule.
    var dotColor: Color {
        switch self {
        case .recording, .failed: .red
        case .recovering, .waitingForFix, .saving: .orange
        case .paused: .secondary
        case .idle: .green
        }
    }
}
