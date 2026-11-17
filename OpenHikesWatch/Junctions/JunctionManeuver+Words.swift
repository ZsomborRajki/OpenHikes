//
//  JunctionManeuver+Words.swift
//  OpenHikesWatch
//
//  What the watch shows at a junction: the words the phone says there, in
//  the watch's own catalog, which a watch build extracts for itself.
//

import Foundation
import OpenHikesShared

extension JunctionManeuver {
    var instruction: String {
        switch self {
        case .keepLeft: String(localized: "Keep left at the fork")
        case .keepRight: String(localized: "Keep right at the fork")
        case .turnLeft: String(localized: "Turn left at the junction")
        case .turnRight: String(localized: "Turn right at the junction")
        case .sharpLeft: String(localized: "Turn sharp left at the junction")
        case .sharpRight: String(localized: "Turn sharp right at the junction")
        case .straight: String(localized: "Go straight on at the junction")
        }
    }
}
