//
//  RecordingEnergyPolicy.swift
//  OpenHikes
//
//  What a recording asks of the GPS, and when it asks for less.
//
//  A hike recorder is one of the few kinds of app that legitimately runs the
//  GPS continuously for hours, which makes it one of the few where the
//  location configuration *is* the battery budget. Pinning
//  `kCLLocationAccuracyBest` for the whole walk — which is what this app did
//  until now — spends the same energy on the half hour spent at a summit as on
//  the descent, and keeps spending it after the user has told the system, by
//  turning on Low Power Mode, that they would rather it didn't.
//
//  So the configuration is a function of conditions rather than a constant.
//  Two dimensions, deliberately kept separate because they answer to different
//  authorities:
//
//  * `desiredAccuracy` answers to the *user and the system* — Low Power Mode
//    and thermal pressure. Both are explicit signals that the device would
//    like to do less, and neither is something the app should overrule for the
//    sake of a slightly smoother line.
//  * `distanceFilter` answers to those and to *standing still*. This is the
//    safer of the two to move, and the more effective: the filter is applied
//    inside `locationd`, so raising it stops the fixes before they cost this
//    process a delegate callback, a main-actor hop and a
//    ``RecordingFixPolicy`` evaluation that was only ever going to reject them.
//
//  Accuracy is deliberately *not* downgraded merely for standing still. A
//  stationary walker is one step away from a moving one, and the first fix
//  after they set off again is the one that anchors the next leg of the track;
//  buying a little energy by making that fix coarse is a bad trade for a route
//  the hiker keeps. Raising the filter costs nothing in that case, because a
//  step past the filter distance still arrives at full accuracy.
//

import CoreLocation
import Foundation

/// One `CLLocationManager` configuration, named so a signpost, a log line and
/// the recording screen can all say which one is in force without any of them
/// having to describe it in terms of metres.
nonisolated struct RecordingEnergyProfile: Equatable, Sendable {
    /// Stable, lowercase, and safe to put in a signpost detail field.
    let name: String
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance
    /// Why this profile rather than the precise one, phrased for the recording
    /// screen. `nil` when nothing is being given up.
    let reason: String?

    /// The default: what a hike is recorded at when nothing is asking for less.
    static let precise = Self(
        name: "precise",
        desiredAccuracy: kCLLocationAccuracyBest,
        distanceFilter: RecordingEnergyPolicy.walkingDistanceFilter,
        reason: nil
    )
}

nonisolated enum RecordingEnergyPolicy {
    /// The filter a moving walker is tracked with. Roughly three paces, which
    /// is fine enough that the drawn line follows a switchback and coarse
    /// enough that GPS jitter alone rarely clears it.
    static let walkingDistanceFilter: CLLocationDistance = 10
    /// Applied once ``RecordingDistanceAccumulator`` reports the walker has
    /// stopped. Sized above the horizontal accuracy a good fix reports, so
    /// noise around a stationary position no longer wakes the app, while a
    /// genuine departure does immediately.
    static let stationaryDistanceFilter: CLLocationDistance = 25
    /// What accuracy drops to when the device asks for less. Still well inside
    /// ``RecordingFixPolicy/maximumHorizontalAccuracy``, so a conserving
    /// recording keeps producing fixes the recorder will accept rather than
    /// quietly recording nothing.
    static let conservingAccuracy = kCLLocationAccuracyNearestTenMeters
    /// The filter that pairs with the above: no point asking for ten-metre
    /// accuracy and then waking for every ten metres.
    static let conservingDistanceFilter: CLLocationDistance = 20

    /// Everything the policy is allowed to look at. A struct rather than four
    /// arguments so a caller that learns about a new condition updates one
    /// place, and so the whole decision can be logged as one value.
    struct Conditions: Equatable, Sendable {
        /// The user has explicitly asked the whole system to do less.
        var isLowPowerModeEnabled = false
        /// The device is already throttling; continuing to ask for the most
        /// expensive positioning mode makes the throttle worse, not the track
        /// better.
        var thermalState: ProcessInfo.ThermalState = .nominal
        /// ``RecordingDistanceAccumulator/isStationary`` — a sustained absence
        /// of net displacement, not a single slow fix.
        var isStationary = false

        init(
            isLowPowerModeEnabled: Bool = false,
            thermalState: ProcessInfo.ThermalState = .nominal,
            isStationary: Bool = false
        ) {
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.thermalState = thermalState
            self.isStationary = isStationary
        }
    }

    /// `.fair` is deliberately not included. A phone in a jacket pocket in
    /// direct sun reaches `.fair` and stays there for an entire summer walk,
    /// so treating it as a signal would mean the conserving profile was the
    /// normal one — and a mitigation that is always on is indistinguishable
    /// from having lowered the default.
    static func conserves(_ thermalState: ProcessInfo.ThermalState) -> Bool {
        thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    static func profile(for conditions: Conditions) -> RecordingEnergyProfile {
        let lowPower = conditions.isLowPowerModeEnabled
        let hot = conserves(conditions.thermalState)
        let conserving = lowPower || hot

        let accuracy = conserving ? conservingAccuracy : kCLLocationAccuracyBest
        // The larger of the two filters wins rather than the later one: both
        // conditions are reasons to be woken less often, and standing still in
        // Low Power Mode is not a reason to be woken *more* than either alone.
        let filter = max(
            conserving ? conservingDistanceFilter : walkingDistanceFilter,
            conditions.isStationary ? stationaryDistanceFilter : 0
        )

        var components: [String] = []
        if lowPower { components.append("low-power") }
        if hot { components.append("thermal") }
        if conditions.isStationary { components.append("stationary") }
        let name = components.isEmpty ? "precise" : components.joined(separator: "+")

        return RecordingEnergyProfile(
            name: name,
            desiredAccuracy: accuracy,
            distanceFilter: filter,
            reason: reason(lowPower: lowPower, hot: hot, stationary: conditions.isStationary)
        )
    }

    /// Phrased as what the app is doing about the situation rather than as a
    /// warning about it. The recording screen already tells the walker that
    /// Low Power Mode is on; what it could not tell them before is that the
    /// app responded to it.
    private static func reason(
        lowPower: Bool,
        hot: Bool,
        stationary: Bool
    ) -> String? {
        if lowPower, hot { return "Low Power Mode and heat — recording at ten-metre accuracy to save battery." }
        if lowPower { return "Low Power Mode — recording at ten-metre accuracy to save battery." }
        if hot { return "The device is warm — recording at ten-metre accuracy until it cools." }
        if stationary { return "You've stopped — checking position less often until you move on." }
        return nil
    }
}
