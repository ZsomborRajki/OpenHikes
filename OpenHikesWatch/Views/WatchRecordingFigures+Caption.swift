//
//  WatchRecordingFigures+Caption.swift
//  OpenHikesWatch
//
//  What each live figure on the recording screen is called. Which figure
//  takes which caption is decided in `OpenHikesShared`, where `swift test`
//  pins it; the words are here, because only this target's build extracts
//  strings into the watch's String Catalog — a literal in the package was
//  drawn but listed nowhere (#1028).
//
//  Two sets of words, because a tile under a number has room for less than
//  VoiceOver should say: the average is drawn "Avg Speed" and spoken
//  "Average Speed" (*Settled decisions* in the repository instructions).
//

import OpenHikesShared
import SwiftUI

extension WatchRecordingFigures.Caption {
    /// The words drawn under the figure.
    var label: LocalizedStringKey {
        switch self {
        case .distance: "Distance"
        case .climb: "Climb"
        case .averageSpeed: "Avg Speed"
        case .heartRate: "Heart"
        }
    }

    /// The words VoiceOver reads the figure by: ``label``, except where the
    /// tile shortens it.
    var spokenLabel: LocalizedStringKey {
        switch self {
        case .averageSpeed: "Average Speed"
        case .distance, .climb, .heartRate: label
        }
    }
}
