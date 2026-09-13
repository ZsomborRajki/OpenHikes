//
//  HikeRecorderTests+SuggestedName.swift
//  OpenHikesTests
//
//  What a finished recording is called, once the live matcher has spent the
//  walk saying which trail it was on.
//
//  The trail is published the way the live matcher publishes it — through
//  ``HikeRecorder/applyCurrentTrail(_:isCurrent:)`` — rather than by handing
//  the recorder a graph and waiting. A recorder with a real provider matches
//  asynchronously against whatever OpenStreetMap has for the fixtures'
//  coordinates, which would make what these assert a timing and a map extract
//  rather than the rule: metres walked while the matcher said "Ridge Path"
//  are metres credited to Ridge Path.
//
//  A recorder without a provider blanks the trail after every accepted fix —
//  `scheduleLiveMatching` finds nothing to match against — so each fix here
//  is preceded by the publication a live match would have made. That is also
//  what the real thing does: it republishes on every completed match.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeRecorderTests {
    /// Walks to `latitude` along `trailName`, at the pace the rest of these
    /// suites use: roughly 111 m of latitude per thousandth of a degree, a
    /// minute apart.
    ///
    /// The trail is published *before* the fix, because the metres a fix buys
    /// are credited to the trail the matcher had already named — a verdict
    /// arriving after them belongs to the ground after them.
    private func walk(
        _ recorder: HikeRecorder,
        to latitude: Double,
        on trailName: String?
    ) {
        recorder.applyCurrentTrail(
            trailName.map { name in
                RecordingTrailContext(name: name, surface: .gravel, difficulty: .hiking)
            },
            isCurrent: true
        )
        source.deliver(fix(latitude: latitude))
        clock.advance(by: 60)
    }

    /// The placeholder the stop alert shows, read while the walk is still
    /// running — which is the only time it can be read, since the hiker is
    /// asked for a name before the recording is prepared.
    @Test("a walk along one trail is offered that trail's name")
    func aWalkAlongOneTrailIsOfferedItsName() async {
        let recorder = makeRecorder()
        await recorder.start()
        walk(recorder, to: 47.63, on: "Ridge Path")
        walk(recorder, to: 47.631, on: "Ridge Path")
        walk(recorder, to: 47.632, on: "Ridge Path")

        #expect(recorder.suggestedTitle == "Ridge Path")
    }

    /// The draft keeps the name it was created with for the length of the
    /// walk, on purpose. It is a mirrored row and it is what the Live
    /// Activity draws, so a title that changed every time one trail overtook
    /// another would be a CloudKit export per flip and a Lock Screen renaming
    /// itself under the hiker.
    @Test("the draft is not renamed while the walk is still going")
    func theDraftKeepsItsNameUntilTheWalkEnds() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walk(recorder, to: 47.63, on: "Ridge Path")
        walk(recorder, to: 47.631, on: "Ridge Path")

        let draft = try #require(recorder.currentHike)
        #expect(recorder.suggestedTitle == "Ridge Path")
        #expect(draft.title == HikeRecorder.defaultTitle(for: draft.date))
    }

    /// The promise the placeholder makes. A hiker who types nothing gets the
    /// name they were shown, in `title` — the field a default lives in.
    @Test("a hike saved with no typed name takes the trail's")
    func savingWithoutANameTakesTheTrails() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walk(recorder, to: 47.63, on: "Ridge Path")
        walk(recorder, to: 47.631, on: "Ridge Path")
        walk(recorder, to: 47.632, on: "Ridge Path")

        let hike = try savedHike(from: await recorder.stop())

        #expect(hike.title == "Ridge Path")
        #expect(hike.displayTitle == "Ridge Path")
        #expect(hike.customName == nil, "nobody typed this name")
    }

    /// A name the hiker typed is theirs and wins, which is what keeps the
    /// suggestion a default rather than an override. It lands in
    /// `customName`, so the trail stays underneath it as the title the app
    /// chose — exactly the arrangement a hike imported with a name already
    /// has.
    @Test("a name the hiker typed wins over the trail's")
    func aTypedNameWins() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walk(recorder, to: 47.63, on: "Ridge Path")
        walk(recorder, to: 47.631, on: "Ridge Path")
        walk(recorder, to: 47.632, on: "Ridge Path")

        let hike = try savedHike(from: await recorder.stop(customName: "Sunday Walk"))

        #expect(hike.displayTitle == "Sunday Walk")
        #expect(hike.title == "Ridge Path")
    }

    /// The floor, through the recorder. Two thirds of this walk is ground the
    /// matcher had no name for, and the date says something true about it
    /// where "Ridge Path" would not.
    @Test("a walk that mostly left the trail keeps the date in its name")
    func aWalkThatLeftTheTrailKeepsTheDate() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walk(recorder, to: 47.63, on: "Ridge Path")
        walk(recorder, to: 47.631, on: "Ridge Path")
        // Off the path, and twice as far again.
        walk(recorder, to: 47.633, on: nil)
        walk(recorder, to: 47.635, on: nil)

        #expect(recorder.suggestedTitle == nil)
        let hike = try savedHike(from: await recorder.stop())
        #expect(hike.title == HikeRecorder.defaultTitle(for: hike.date))
    }

    /// A recording with no trail graph behind it at all — no provider, an
    /// Overpass outage, a valley nobody has mapped. The name it had before
    /// this existed is the name it still gets.
    @Test("a walk the matcher never named keeps the date in its name")
    func anUnmatchedWalkKeepsTheDate() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        #expect(recorder.suggestedTitle == nil)
        let hike = try savedHike(from: await recorder.stop())
        #expect(hike.title == HikeRecorder.defaultTitle(for: hike.date))
    }
}
