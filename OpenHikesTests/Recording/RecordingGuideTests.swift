//
//  RecordingGuideTests.swift
//  OpenHikesTests
//
//  The trail shown under a recording: which trails can be chosen, that the
//  chosen one's line is read and projected, and that it goes with Stop
//  Showing, with its deletion and with the recording it was chosen during.
//  The map's half is `MapCoordinatorTests+RecordingGuide.swift`.
//

import Foundation
import Observation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

/// Stands in for the recorder's draft: something observable a test can move
/// by hand, read through the closure ``RecordingGuide`` takes.
@Observable
final class RecordingDraftStub {
    var id: UUID?
}

@Suite("Recording guide")
struct RecordingGuideTests {
    private let draft = RecordingDraftStub()
    private let container: ModelContainer
    private let trail: Hike

    init() throws {
        container = try Fixture.modelContainer()
        trail = Fixture.hike(in: container.mainContext, title: "Ridge Loop")
        try container.mainContext.save()
    }

    private func makeGuide(openRequests: HikeOpenRequests? = nil) -> RecordingGuide {
        RecordingGuide(recordingHikeID: { [draft] in draft.id }, openRequests: openRequests)
    }

    private func showProjected(_ guide: RecordingGuide) async {
        guide.show(trail)
        await settleDelegateHop(until: "the trail's line has been projected") { guide.line != nil }
    }

    @Test("nothing is shown while no recording is under way")
    func nothingWithoutARecording() {
        let guide = makeGuide()
        #expect(!guide.canShow(trail))

        guide.show(trail)

        #expect(guide.shown == nil)
        #expect(!guide.isShowing(trail.id))
    }

    @Test("a trail shown under a recording is named, and its whole line is read")
    func showingATrail() async {
        draft.id = UUID()
        let guide = makeGuide()
        #expect(guide.canShow(trail))

        await showProjected(guide)

        #expect(guide.shown == RecordingGuide.Trail(hikeID: trail.id, title: "Ridge Loop", tintHex: trail.tintHex))
        #expect(guide.isShowing(trail.id))
        #expect(guide.line?.coordinates.count == Fixture.ridgeRoute.count, "the whole line, not a thinned one")
    }

    @Test("neither the recording's own draft nor a hike with no line can be shown")
    func theDraftAndALinelessHikeAreRefused() {
        let context = container.mainContext
        let recording = Fixture.hike(in: context, title: "Draft", route: []) { $0.isRecording = true }
        let lineless = Fixture.hike(in: context, title: "Nothing", route: [])
        draft.id = recording.id
        let guide = makeGuide()

        #expect(!guide.canShow(recording))
        #expect(!guide.canShow(lineless))
        #expect(guide.canShow(trail))
    }

    @Test("a second trail takes the first one's place")
    func aSecondTrailReplacesTheFirst() async {
        draft.id = UUID()
        let second = Fixture.hike(in: container.mainContext, title: "Valley Walk")
        let guide = makeGuide()
        await showProjected(guide)

        guide.show(second)
        await settleDelegateHop(until: "the second trail's line has been projected") {
            guide.projection.drawnRoute(for: second) != nil
        }

        #expect(guide.isShowing(second.id))
        #expect(!guide.isShowing(trail.id))
        #expect(guide.line != nil)
    }

    @Test("Stop Showing takes the trail and its line away")
    func stopShowing() async {
        draft.id = UUID()
        let guide = makeGuide()
        await showProjected(guide)

        guide.stopShowing()

        #expect(guide.shown == nil)
        #expect(guide.line == nil)
        #expect(guide.projection.drawnRoute(for: trail) == nil, "the projection is let go too")
    }

    /// At once, because the map and the recording screen read ``shown``, and
    /// the line is let go a hop later, when the watch on the draft fires. A
    /// recording started after that shows nothing it did not choose.
    @Test("the guide ends with the recording it was chosen during")
    func endsWithTheRecording() async {
        draft.id = UUID()
        let guide = makeGuide()
        await showProjected(guide)

        draft.id = nil

        #expect(guide.shown == nil, "a recording that has ended shows nothing")
        await settleDelegateHop(until: "the line has been let go") {
            guide.projection.drawnRoute(for: trail) == nil
        }
        draft.id = UUID()
        #expect(guide.shown == nil, "the next recording starts with nothing shown")
    }

    @Test("a deleted trail is shown no more, and another hike's deletion leaves it")
    func deletionForgetsTheTrail() {
        draft.id = UUID()
        let guide = makeGuide()
        guide.show(trail)

        guide.forget([UUID()])
        #expect(guide.isShowing(trail.id))

        guide.forget([trail.id])
        #expect(guide.shown == nil)
    }

    /// The request asked for with no recording under way would arrive first,
    /// so a request made after both is what says it never came.
    @Test("the recording screen is asked for the way its widget asks, and only during a recording")
    func openingTheRecording() async {
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        let guide = makeGuide(openRequests: requests)
        let marker = UUID()

        guide.openRecording()
        draft.id = UUID()
        guide.openRecording()
        requests.open(hikeID: marker)

        let expected = [TrailWidgetDeepLink.recordingURL(), TrailWidgetDeepLink.url(hikeID: marker)].compactMap(\.self)
        await settleDelegateHop(until: "the marker to arrive") {
            sent.received.last == TrailWidgetDeepLink.url(hikeID: marker)
        }
        #expect(sent.received == expected)
    }
}
