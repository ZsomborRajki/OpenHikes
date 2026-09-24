//
//  DuskWatch.swift
//  OpenHikes
//
//  Whether a followed trail will be finished after the light goes, and
//  whether that has already been said.
//
//  "Will I be down before dark?" is the question a hiker has late in the
//  afternoon, and getting it wrong is the commonest way a day walk becomes a
//  rescue call. The app holds both halves: civil dusk from the weather reading
//  (``WeatherDaylight``) and the time left from the walk (``WalkTimeLeft``).
//
//  **Civil dusk, at the crossing** — the owner's decision. Dusk rather than
//  sunset because it is when there stops being enough light to walk by, which
//  is what ends the walk; at the crossing rather than with slack because the
//  estimate is already the hiker's own pace, and a margin on top of it would
//  be the app deciding how cautious somebody else should be.
//
//  **Once per walk.** An estimate that crosses dusk moves back and forth
//  across it as the hiker speeds up and slows down, and a banner each time it
//  did would be the app nagging somebody who has already decided. What
//  re-arms it is a new walk, and nothing else.
//
//  **Nothing once dusk has passed**, and nothing with no dusk at all: a hiker
//  walking in the dark knows it is dark, and a polar-summer day has no dusk
//  to cross — ``WeatherDaylight`` treats that as a fact rather than a gap,
//  and so does this.
//
//  A value type with no clock of its own, for the reason ``OffTrailWatch``
//  is one.
//

import Foundation

nonisolated struct DuskWatch: Equatable {
    private var hasReported = false

    /// Records one estimate of when the walk will end, and answers whether
    /// the hiker should be told it ends after dusk.
    mutating func observed(finishAt: Date, civilDusk: Date?, now: Date) -> Bool {
        guard !hasReported, let civilDusk, now < civilDusk, finishAt > civilDusk else { return false }
        hasReported = true
        return true
    }

    /// Forgets that it has spoken, which is what a walk ending does.
    mutating func reset() {
        hasReported = false
    }
}
