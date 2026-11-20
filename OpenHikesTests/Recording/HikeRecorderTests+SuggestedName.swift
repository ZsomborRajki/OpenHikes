//
//  HikeRecorderTests+SuggestedName.swift
//  OpenHikesTests
//
//  What a finished recording is called, once the live matcher has spent the
//  walk saying which trail it was on: that trail and the day, and "Loop"
//  beside the trail when the walk came back by other ground than it went out
//  on — see ``RecordingTitle`` for the order, and `HikeRecorder+PlaceName.swift`
//  for where the parts come from.
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
import OpenHikesData
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
    ///
    /// Shared with `HikeRecorderTests+PlaceName.swift`, where the trail
    /// stands beside the town a walk started in.
    func walk(
        _ recorder: HikeRecorder,
        to latitude: Double,
        on trailName: String?,
        longitude: Double = 12.86
    ) {
        recorder.applyCurrentTrail(
            trailName.map { name in
                RecordingTrailContext(name: name, surface: .gravel, difficulty: .hiking)
            },
            isCurrent: true
        )
        source.deliver(fix(latitude: latitude, longitude: longitude))
        clock.advance(by: 60)
    }

    /// Where the two walks below set off from, and the stride they take: two
    /// thousandths of a degree, some 220 m of latitude and 150 m of longitude
    /// here, a minute apart.
    private static let trailheadLatitude = 47.63
    private static let trailheadLongitude = 12.86
    private static let stride = 0.002

    /// Walks to the point so many strides north and east of the trailhead.
    private func walk(
        _ recorder: HikeRecorder,
        north: Int,
        east: Int,
        on trailName: String
    ) {
        walk(
            recorder,
            to: Self.trailheadLatitude + Double(north) * Self.stride,
            on: trailName,
            longitude: Self.trailheadLongitude + Double(east) * Self.stride
        )
    }

    /// Walks round a block some 440 m by 300 m, along `trailName`, and back
    /// to where it set off: north, east, south and west again.
    private func walkRoundABlock(_ recorder: HikeRecorder, on trailName: String) {
        let corners = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1), (0, 0)]
        for (north, east) in corners {
            walk(recorder, north: north, east: east, on: trailName)
        }
    }

    /// Walks some 440 m up `trailName` and back down it.
    private func walkThereAndBack(_ recorder: HikeRecorder, on trailName: String) {
        for north in [0, 1, 2, 1, 0] {
            walk(recorder, north: north, east: 0, on: trailName)
        }
    }

    /// `trailPart` and the day `recorder`'s walk started: the name of a walk
    /// no town was asked about.
    private func name(_ trailPart: String, of recorder: HikeRecorder) throws -> String {
        let startedAt = try #require(recorder.sessionStartedAt)
        return trailPart + RecordingTitle.separator + RecordingTitle.day(startedAt)
    }

    /// The name the stop alert opens with, read while the walk is still
    /// running — which is the only time it can be read, since the hiker is
    /// asked for a name before the recording is prepared.
    @Test("a walk along one trail is offered that trail's name and the day")
    func aWalkAlongOneTrailIsOfferedItsName() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walk(recorder, to: 47.63, on: "Ridge Path")
        walk(recorder, to: 47.631, on: "Ridge Path")
        walk(recorder, to: 47.632, on: "Ridge Path")
        let offered = try name("Ridge Path", of: recorder)

        #expect(recorder.suggestedTitle == offered)
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
        let offered = try name("Ridge Path", of: recorder)
        #expect(recorder.suggestedTitle == offered)
        #expect(draft.title == HikeRecorder.defaultTitle(for: draft.date))
    }

    /// A Stop that showed no name — Siri's, the watch's — is named at the
    /// save, for the trail, in `title`: the field a default lives in.
    @Test("a hike saved with no typed name takes the trail's")
    func savingWithoutANameTakesTheTrails() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walk(recorder, to: 47.63, on: "Ridge Path")
        walk(recorder, to: 47.631, on: "Ridge Path")
        walk(recorder, to: 47.632, on: "Ridge Path")
        let offered = try name("Ridge Path", of: recorder)

        let hike = try savedHike(from: await recorder.stop())

        #expect(hike.title == offered)
        #expect(hike.displayTitle == offered)
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
        let offered = try name("Ridge Path", of: recorder)

        let hike = try savedHike(from: await recorder.stop(customName: "Sunday Walk"))

        #expect(hike.displayTitle == "Sunday Walk")
        #expect(hike.title == offered)
    }

    /// The floor, through the recorder. Two thirds of this walk is ground the
    /// matcher had no name for, and the date says something true about it
    /// where "Ridge Path" would not.
    @Test("a walk that mostly left the trail keeps the time of day in its name")
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
    @Test("a walk the matcher never named keeps the time of day in its name")
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

    /// The word is read off the line drawn so far when the hiker asks to
    /// stop, which is when the alert needs it.
    @Test("a walk round a trail and back to its start is offered a loop")
    func aWalkRoundATrailIsOfferedALoop() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walkRoundABlock(recorder, on: "Ridge Path")
        let offered = try name("Ridge Path Loop", of: recorder)

        #expect(recorder.suggestedTitle == offered)
    }

    /// The two ends of this walk meet as a loop's do. What it came back
    /// along is what tells them apart.
    @Test("a walk up a trail and back down it is not called a loop")
    func aWalkThereAndBackIsNotALoop() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walkThereAndBack(recorder, on: "Ridge Path")
        let offered = try name("Ridge Path", of: recorder)

        #expect(recorder.suggestedTitle == offered)
    }

    /// A Stop that showed no name reads the word off the saved line, which
    /// is the one the hike keeps.
    @Test("a loop saved with no name shown is named a loop from its saved line")
    func aLoopSavedUnshownIsNamedALoop() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        walkRoundABlock(recorder, on: "Ridge Path")
        let offered = try name("Ridge Path Loop", of: recorder)

        let hike = try savedHike(from: await recorder.stop())

        #expect(hike.title == offered)
        #expect(hike.customName == nil, "nobody typed this name")
    }
}
