//
//  RecordingStopTests.swift
//  OpenHikesTests
//
//  What a tap on Stop asks, by what the recording holds, and whose name the
//  save writes, by what the alert's field says when it is saved.
//
//  The second half is the one with a history: a field that opened holding
//  the default once sent it through as a typed name, and every hike saved
//  without typing was flagged as named by hand. The field holds the offered
//  name again, so each way of leaving it alone is pinned here.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Recording stop")
struct RecordingStopTests {
    private static let offered = "Schönau am Königssee – Malerwinkel Loop – 20 Nov 2026"

    @Test("a recording with a line to save is asked for its name", arguments: [2, 3, 5000])
    func aLineIsNamed(pointCount: Int) {
        #expect(RecordingStopStep(pointCount: pointCount, holdsKeepsakes: false) == .askName)
        #expect(RecordingStopStep(pointCount: pointCount, holdsKeepsakes: true) == .askName)
    }

    /// A recording started by mistake. There is nothing to name and nothing
    /// to lose, so there is nothing to ask.
    @Test("a recording with no line and nothing on it is ended without a question", arguments: [0, 1])
    func anEmptyRecordingIsEnded(pointCount: Int) {
        #expect(RecordingStopStep(pointCount: pointCount, holdsKeepsakes: false) == .endEmpty)
    }

    /// It cannot be saved, and the photograph has no second copy.
    @Test("a recording with no line but a photograph or a place on it asks before it goes", arguments: [0, 1])
    func keepsakesAreAskedAbout(pointCount: Int) {
        #expect(RecordingStopStep(pointCount: pointCount, holdsKeepsakes: true) == .confirmDiscard)
    }

    @Test("the fewest points Stop saves is the fewest a recording is prepared from")
    func theFloorIsPreparationsOwn() {
        let start = Date(timeIntervalSinceReferenceDate: 817_000_000)
        let onePoint = [RecordingPoint(latitude: 47.6, longitude: 12.98, timestamp: start, horizontalAccuracy: 8)]

        #expect(throws: RecordingFailure.tooShort) {
            try RecordingPreparation.prepare(points: onePoint, startedAt: start)
        }
        #expect(RecordingPreparation.minimumPointCount == onePoint.count + 1)
        #expect(RecordingStopStep(pointCount: onePoint.count, holdsKeepsakes: false) == .endEmpty)
    }

    @Test("a field left as it opened is not a name anybody typed")
    func anUntouchedFieldIsNotTyped() {
        #expect(RecordingStopName.typed(Self.offered, over: Self.offered) == nil)
        #expect(RecordingStopName.typed("  \(Self.offered)\n", over: Self.offered) == nil)
    }

    /// The offered name is still under it, as the field's placeholder.
    @Test("a field cleared and saved keeps the offered name")
    func aClearedFieldIsNotTyped() {
        #expect(RecordingStopName.typed("", over: Self.offered) == nil)
        #expect(RecordingStopName.typed("  ", over: Self.offered) == nil)
        #expect(RecordingStopName.typed("", over: nil) == nil)
    }

    @Test("a name typed over the offered one is the hiker's")
    func aTypedNameIsTyped() {
        #expect(RecordingStopName.typed("Sunday Walk", over: Self.offered) == "Sunday Walk")
        #expect(RecordingStopName.typed(" Sunday Walk ", over: nil) == "Sunday Walk")
    }

    /// What the text is there for: changing a word rather than typing a name.
    @Test("the offered name with a word changed is the hiker's too")
    func anEditedNameIsTyped() {
        let edited = "Schönau am Königssee – Malerwinkel with Anna – 20 Nov 2026"

        #expect(RecordingStopName.typed(edited, over: Self.offered) == edited)
    }
}
