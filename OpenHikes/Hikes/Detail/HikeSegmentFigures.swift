//
//  HikeSegmentFigures.swift
//  OpenHikes
//
//  One segment of a hike in the words its row draws and speaks (#1470): how
//  far, how long and how fast, and how much it climbed.
//
//  Apart from ``HikeSegmentList``, which is all body, so that the wording is
//  where a hosted suite can read it.
//

import Foundation
import OpenHikesData

nonisolated struct HikeSegmentFigures: Equatable, Sendable {
    /// The segment's length, as the *Distance* figure above it is written.
    let distance: String
    /// Its time and its average speed, or whichever of the two it has: a
    /// route with no clock has neither.
    let pace: String?
    /// What it climbed, or `nil` for a segment with no heights.
    let climb: String?
    /// The whole row in words, for VoiceOver: the drawn line is shorthand.
    let spoken: String

    /// - Parameter locale: a test seam, as it is on ``HikeFormat/speed(_:locale:)``.
    init(_ segment: RouteSegment, locale: Locale = .autoupdatingCurrent) {
        let length = Measurement(value: segment.distanceMeters, unit: UnitLength.meters)
        distance = length.formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
        let speed = segment.averageSpeedMetersPerSecond.map { metersPerSecond in
            HikeFormat.speed(Measurement(value: metersPerSecond, unit: .metersPerSecond), locale: locale)
        }
        let time = segment.seconds.map(HikeFormat.duration)
        pace = if let time, let speed {
            String(localized: "\(time) · \(speed)")
        } else {
            time ?? speed
        }
        let gain = segment.elevationGainMeters.map { Measurement(value: $0, unit: UnitLength.meters) }
        climb = gain.map { HikeFormat.elevation($0, locale: locale) }
        spoken = [
            length.formatted(.measurement(width: .wide, usage: .road).locale(locale)),
            segment.seconds.map(HikeFormat.spokenDuration),
            speed,
            gain.map { String(localized: "\(HikeFormat.spokenElevation($0, locale: locale)) of climb") },
        ]
        .compactMap(\.self)
        .joined(separator: ", ")
    }
}
