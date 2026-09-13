//
//  RecordingTrailNames.swift
//  OpenHikes
//
//  How much of the walk so far ran along each trail OpenStreetMap has a name
//  for, and the one name — if any — that has earned the right to title the
//  hike.
//
//  A recording is named "Morning Hike – 14 Sept 2026" because at the moment
//  the draft is created that is everything the app knows: the first fix has
//  not arrived. By the time the hiker stops, the live matcher has spent the
//  whole walk deciding which mapped way they were on, and ``HikeRecorder``
//  has been publishing the answer as ``RecordingStats/currentTrail``. This
//  keeps the running total that turns a sequence of those answers into a
//  claim about the walk as a whole.
//
//  Metres rather than fixes, because fixes are not evenly spread: a walk
//  logged once a second while resting at a signpost and once a minute while
//  moving would elect the signpost. Metres are what the claim is about — "this
//  walk was mostly the Kéktúra" is a statement about ground covered.
//
//  The denominator is deliberately *not* kept here. It is the walk's own
//  distance, passed in, so that every metre the matcher could not name —
//  off-path, no graph downloaded, no `name` on the way, a recording recovered
//  from a journal after a crash — counts against the share rather than
//  vanishing from it. A name that covered a tenth of a walk and all of the
//  fifth of it that happened to be mapped has not earned the hike's title.
//

import Foundation

nonisolated struct RecordingTrailNames: Equatable, Sendable {
    /// The share of the walk one trail has to cover before its name may be
    /// offered as the hike's.
    ///
    /// Half, because this is a name for the *whole walk* rather than a label
    /// on part of it. Below half the honest answer is the one the app already
    /// gives — the time of day and the date — and a hiker who wants the trail
    /// in the name is one tap from typing it. Above half the date is the
    /// worse answer: it describes every hike ever recorded equally well.
    ///
    /// A loop that spends 45% on each of two named trails deliberately gets
    /// no suggestion. Picking the larger of two near-equal halves would be a
    /// coin toss presented as a fact.
    static let coverageFloor = 0.5

    /// Metres walked on each named trail. A trail the matcher named but the
    /// hiker covered no ground on never appears — see ``add(meters:on:)``.
    private(set) var metersByName: [String: Double] = [:]

    /// Attributes `meters` of walking to whatever the matcher last called the
    /// ground underfoot.
    ///
    /// A `nil` name — the matcher has no confident answer, or the way it
    /// found carries no `name` and belongs to no hiking route — is not an
    /// error and is not recorded. Those metres are still part of the walk,
    /// and the share they dilute is exactly the point of measuring against
    /// the walk's own distance.
    ///
    /// Guarded against zero and non-finite lengths rather than trusting the
    /// caller: this is fed from a distance accumulator on every accepted fix,
    /// including the stationary windows it retracts to zero.
    mutating func add(meters: Double, on trailName: String?) {
        guard let trailName, meters > 0, meters.isFinite else { return }
        metersByName[trailName, default: 0] += meters
    }

    /// The trail that covered at least `floor` of `totalMeters`, or `nil` when
    /// no trail did.
    ///
    /// - Parameter totalMeters: The whole walk's distance, named ground and
    ///   unnamed ground together.
    ///
    /// Ties are broken by taking the alphabetically first name, which is the
    /// convention ``TrailMatcher`` already uses for the same question in
    /// `matchedTrailName` and for the name of a leg that crossed several ways.
    /// A tie here is two trails with identical metres to the millimetre, so
    /// what the rule is matters far less than that it is the same rule twice
    /// and that it is not the dictionary's iteration order.
    func dominantName(
        of totalMeters: Double,
        clearing floor: Double = coverageFloor
    ) -> String? {
        guard totalMeters > 0, totalMeters.isFinite else { return nil }
        let leader = metersByName.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }
        guard let leader, leader.value / totalMeters >= floor else { return nil }
        return leader.key
    }
}
