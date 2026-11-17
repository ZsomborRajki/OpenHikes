//
//  WatchJunctionCue.swift
//  OpenHikesWatch
//
//  A junction warning on the wrist: a tap, and which way, for a few seconds.
//
//  The phone speaks its warnings; the watch taps, because a voice from a
//  wrist is not one a hiker wants, and a tap is felt under a sleeve. Both are
//  decided by the same ``JunctionAnnouncer``, against the junctions the phone
//  found and sent with the trail (``WatchTrailPackage/junctions``), so a
//  hiker with both hears and feels the same fork at the same distance.
//
//  The tap is played from here rather than by a view's `sensoryFeedback`,
//  because a warning matters most with the wrist down, when nothing is
//  drawing and the workout session is what keeps the app running.
//
//  The tap is `.notification`, the same for every maneuver: the haptics
//  WatchKit has for a left and a right turn are only for an app running a
//  navigation session, which this is not. The words say which way.
//

import Foundation
import Observation
import OpenHikesShared
import WatchKit

@MainActor
@Observable
final class WatchJunctionCue {
    /// What the banner shows.
    struct Shown: Equatable {
        /// Which cue this is, so a dismissal timed for one never takes down
        /// the next.
        let id: Int
        let maneuver: JunctionManeuver
        /// How far ahead, as a figure, or `nil` for the cue at the junction.
        let distance: String?
    }

    private(set) var shown: Shown?
    @ObservationIgnored private var shownCount = 0

    func show(_ cue: JunctionCue) {
        shownCount += 1
        shown = Shown(id: shownCount, maneuver: cue.maneuver, distance: cue.shortDistance())
        WKInterfaceDevice.current().play(.notification)
    }

    /// Takes down cue `id`, if it is still the one shown.
    func dismiss(_ id: Int) {
        guard shown?.id == id else { return }
        shown = nil
    }

    /// Takes down whatever is shown, for a trail or a switch that has gone.
    func clear() {
        shown = nil
    }
}
