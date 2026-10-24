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

import OpenHikesShared
import SwiftUI

extension WatchRecordingFigures.Caption {
    var label: LocalizedStringKey {
        switch self {
        case .distance: "Distance"
        case .climb: "Climb"
        case .averageSpeed: "Avg Speed"
        case .heartRate: "Heart"
        }
    }
}
