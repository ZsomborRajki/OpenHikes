//
//  JunctionManeuver+Words.swift
//  OpenHikes
//
//  What the phone says at a junction.
//
//  A whole sentence for each maneuver, before the junction and at it, rather
//  than a phrase with a distance glued on, because a translation puts the
//  distance where its own grammar wants it. The distance arrives already
//  formatted and in words — ``JunctionCue/spokenDistance(locale:)`` — so no
//  word in a sentence agrees with it.
//
//  The watch shows the second of each pair under its own catalog's key
//  (`JunctionCueBanner.swift` in `OpenHikesWatch`).
//

import Foundation
import OpenHikesShared

extension JunctionManeuver {
    /// What to do, said at the junction.
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

    /// What to do, said before the junction: `distance` is how far ahead it
    /// is, in words.
    func instruction(in distance: String) -> String {
        switch self {
        case .keepLeft: String(localized: "Keep left at the fork in \(distance)")
        case .keepRight: String(localized: "Keep right at the fork in \(distance)")
        case .turnLeft: String(localized: "Turn left at the junction in \(distance)")
        case .turnRight: String(localized: "Turn right at the junction in \(distance)")
        case .sharpLeft: String(localized: "Turn sharp left at the junction in \(distance)")
        case .sharpRight: String(localized: "Turn sharp right at the junction in \(distance)")
        case .straight: String(localized: "Go straight on at the junction in \(distance)")
        }
    }
}

extension JunctionCue {
    /// The sentence this cue is spoken as.
    var sentence: String {
        guard let distance = spokenDistance() else { return maneuver.instruction }
        return maneuver.instruction(in: distance)
    }
}
