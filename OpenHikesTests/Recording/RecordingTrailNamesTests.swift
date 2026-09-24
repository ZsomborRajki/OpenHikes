//
//  RecordingTrailNamesTests.swift
//  OpenHikesTests
//
//  What a walk has to have done before OpenStreetMap's name for a trail is
//  allowed to become the hike's.
//
//  Every rule here is invisible in the result it produces. A suggestion that
//  was earned and a suggestion that was guessed are both just a name in a
//  text field, and the hiker — who was there, and knows what they walked —
//  has no way to tell which one they are looking at. The cost of guessing is
//  paid silently: a hike named after a path it crossed once.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Recording trail names")
struct RecordingTrailNamesTests {
    /// Metres, not visits. Fixes are not evenly spread — a walk logged once a
    /// second at a signpost and once a minute while moving would elect the
    /// signpost — so the tally has to be about ground covered.
    @Test("the trail with the most metres leads, not the one seen most often")
    func metresDecideRatherThanVisits() {
        var names = RecordingTrailNames()
        for _ in 0..<20 { names.add(meters: 5, on: "Signpost Path") }
        names.add(meters: 900, on: "Ridge Trail")

        #expect(names.dominantName(of: 1000) == "Ridge Trail")
    }

    /// The floor is a share of the *walk*, not of the mapped part of it. A
    /// name that covered a tenth of a hike and all of the fifth that happened
    /// to be mapped has not earned the hike's title.
    @Test("unnamed ground counts against the share")
    func unmappedGroundDilutesTheShare() {
        var names = RecordingTrailNames()
        names.add(meters: 300, on: "Ridge Trail")
        // The rest of the walk: off-path, unnamed ways, or no graph at all.
        names.add(meters: 200, on: nil)

        #expect(names.dominantName(of: 1000) == nil, "300 m of 1 km is not a hike's name")
        #expect(names.dominantName(of: 500) == "Ridge Trail")
    }

    /// Exactly half is enough. The floor is the point at which the trail
    /// describes more of the walk than everything else put together, and a
    /// hike that was half one named trail is fairly called by it.
    @Test("the floor is met, not merely exceeded")
    func theFloorIsInclusive() {
        var names = RecordingTrailNames()
        names.add(meters: 500, on: "Ridge Trail")

        #expect(names.dominantName(of: 1000) == "Ridge Trail")
        #expect(names.dominantName(of: 1000.1) == nil)
    }

    /// The case the floor exists for. Two named trails, neither of them the
    /// walk: picking the larger of two near-equal halves would be a coin toss
    /// presented as a fact, and the date is the honest answer.
    @Test("a walk split between two trails is named after neither")
    func aSplitWalkGetsNoSuggestion() {
        var names = RecordingTrailNames()
        names.add(meters: 450, on: "Ridge Trail")
        names.add(meters: 450, on: "Valley Path")

        #expect(names.dominantName(of: 1000) == nil)
    }

    /// A tie is broken the way the matcher already breaks one — alphabetically
    /// — rather than by whatever order the dictionary happens to iterate in.
    /// What matters is that two runs of the same walk produce the same name.
    @Test("an exact tie is broken by name rather than by iteration order")
    func tiesAreBrokenDeterministically() {
        var names = RecordingTrailNames()
        names.add(meters: 600, on: "Valley Path")
        names.add(meters: 600, on: "Ridge Trail")

        #expect(names.dominantName(of: 1000) == "Ridge Trail")
    }

    /// Fed from a distance accumulator on every accepted fix, including the
    /// stationary windows it retracts to zero. None of that may become a
    /// trail with a name and no distance.
    @Test("zero, negative and non-finite lengths are not walking")
    func onlyRealDistanceIsTallied() {
        var names = RecordingTrailNames()
        names.add(meters: 0, on: "Ridge Trail")
        names.add(meters: -50, on: "Ridge Trail")
        names.add(meters: .nan, on: "Ridge Trail")
        names.add(meters: .infinity, on: "Ridge Trail")

        #expect(names.metersByName.isEmpty)
        #expect(names.dominantName(of: 1000) == nil)
    }

    /// A walk that has not moved yet, and a recording with no trail graph
    /// behind it at all. Both are ordinary, and neither is an error.
    @Test("a walk with no distance and a walk with no names suggest nothing")
    func nothingToGoOnSuggestsNothing() {
        var empty = RecordingTrailNames()
        #expect(empty.dominantName(of: 1000) == nil)

        empty.add(meters: 800, on: "Ridge Trail")
        #expect(empty.dominantName(of: 0) == nil)
        #expect(empty.dominantName(of: .nan) == nil)
    }
}
