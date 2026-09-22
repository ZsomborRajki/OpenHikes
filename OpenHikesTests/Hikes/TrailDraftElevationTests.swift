//
//  TrailDraftElevationTests.swift
//  OpenHikesTests
//
//  What the trail being drawn climbs, and what it costs to find out.
//
//  Two things are asserted here and the second is the one that matters
//  commercially. The first is ordinary: a settled drawing is measured, the
//  figures come off the sampled heights, and a refusal leaves a length and no
//  climb — the same degradation a curated route already has.
//
//  The second is **how often anything is asked at all**. Every call is billed
//  against the key the paid map styles are behind, and the drawing changes
//  under the question: a tap adds a point, a leg that snaps reshapes the line
//  without the hiker touching anything, and marking a spring changes no
//  geometry whatsoever. So a run of changes has to ask once, and an edit that
//  moves no line has to ask nothing — neither of which is visible on screen,
//  and both of which are visible on an invoice.
//
//  The debounce is driven through ``TrailDraftElevation``'s `pause` seam
//  rather than against the clock, for the reason the repository instructions
//  give under *Deliberate test seams*. Waiting two real seconds per assertion
//  would make this the slowest file in the bundle, to measure nothing the seam
//  does not already expose.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@MainActor
@Suite("Trail draft elevation")
struct TrailDraftElevationTests {
    /// A source that answers heights without a network, and counts what it was
    /// asked.
    ///
    /// `final class` behind a `Mutex` rather than an actor, for the reason
    /// ``CuratedElevationTests``' own stub is one: the call arrives off the
    /// main actor and an actor would turn every read below into a suspension
    /// point.
    nonisolated private final class StubHeightSource: CuratedElevationSourcing, @unchecked Sendable {
        /// What a refusing stub throws. Any failure would do — the caller
        /// draws all of them the same way, which is the point.
        static let serviceUnavailable = 503

        private struct State {
            var askedCounts: [Int] = []
            var heights: [Double] = []
            var refuses = false
        }

        private let state: Mutex<State>

        /// - Parameter heights: the answer. An empty one refuses, which is the
        ///   shape a build with no key, a hiker who has not subscribed and a
        ///   service that is down all arrive in.
        init(heights: [Double]) {
            state = Mutex(State(heights: heights, refuses: heights.isEmpty))
        }

        /// How many points each request asked about, in order. The *count* of
        /// this array is the interesting half: it says whether a run of edits
        /// was folded into one question.
        var askedCounts: [Int] { state.withLock(\.askedCounts) }

        @concurrent
        func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
            try state.withLock { current in
                current.askedCounts.append(coordinates.count)
                guard !current.refuses else {
                    throw CuratedElevationFailure.server(statusCode: Self.serviceUnavailable)
                }
                // Cycled to the length that was asked about, because the
                // source refuses an answer of the wrong length and every case
                // below is about something else.
                let heights = current.heights
                return (0..<coordinates.count).map { index in heights[index % heights.count] }
            }
        }
    }

    private enum Line {
        static let longitude: Double = 12.86
        static let first: Double = 47.6300
        static let second: Double = 47.6320
        static let third: Double = 47.6340
        static let fourth: Double = 47.6360
        static let fifth: Double = 47.6380
        static let all: [Double] = [first, second, third, fourth]

        static func at(_ latitude: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// A climb, a dip and a summit, and what they add up to.
    ///
    /// Every reversal here is far past ``ElevationAccumulator``'s three-metre
    /// deadband, so the figures are plain arithmetic: up a hundred, down
    /// fifty, up two hundred and fifty.
    private enum Heights {
        static let trailhead: Double = 600
        static let shoulder: Double = 700
        static let dip: Double = 650
        static let summit: Double = 900
        static let all: [Double] = [trailhead, shoulder, dip, summit]
        static let climbed: Double = 350
        static let dropped: Double = 50
    }

    /// How many main-actor turns a waiting helper spends before giving up.
    ///
    /// Generous, because what is waited on is a task hopping off the main
    /// actor and back; bounded, because a condition that never comes true
    /// should fail an assertion rather than hang the bundle. The cases that
    /// prove a negative spend the whole budget and it costs microseconds.
    private static let yieldBudget = 500

    private static func draft(_ latitudes: [Double] = Line.all) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes { draft.append(Line.at(latitude)) }
        return draft
    }

    /// An elevation holder whose debounce is instant, so a case can drive it
    /// turn by turn.
    private static func elevation(
        of draft: TrailDraft,
        source: (any CuratedElevationSourcing)?
    ) -> TrailDraftElevation {
        TrailDraftElevation(draft: draft, source: source, pause: { _ in /* instant */ })
    }

    private static func maker(source: StubHeightSource) -> TrailDraftController {
        let maker = TrailDraftController(
            elevationSource: source,
            elevationPause: { _ in /* instant */ }
        )
        maker.setEditing(true)
        return maker
    }

    /// Spins the main actor until `condition` holds, which is what waiting on
    /// the effect looks like here — see the file header.
    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<yieldBudget {
            if condition() { return }
            await Task.yield()
        }
    }

    private static func measured(
        _ elevation: TrailDraftElevation,
        by source: StubHeightSource,
        questions: Int = 1
    ) async {
        await settle { source.askedCounts.count == questions && !elevation.isMeasuring }
    }

    // MARK: - What a settled drawing is told

    /// The ordinary case: a drawing settles, one question is asked about the
    /// line's own points, and the climb and the descent come back off it.
    @Test("a settled drawing is measured once, and the figures come off the heights")
    func aSettledDrawingIsMeasured() async throws {
        let draft = Self.draft()
        let source = StubHeightSource(heights: Heights.all)
        let elevation = Self.elevation(of: draft, source: source)

        elevation.drawingDidChange()
        await Self.measured(elevation, by: source)

        #expect(source.askedCounts == [Line.all.count], "four points, asked about whole")
        let summary = try #require(elevation.summary)
        #expect(summary.gainMeters == Heights.climbed)
        #expect(summary.lossMeters == Heights.dropped)
        #expect(summary.highMeters == Heights.summit)
        #expect(summary.lowMeters == Heights.trailhead)
    }

    /// And the heights themselves are kept, on the points they were read at,
    /// so a save can put them on the line.
    @Test("the heights are kept for the line they were read for")
    func theHeightsAreKept() async {
        let draft = Self.draft()
        let source = StubHeightSource(heights: Heights.all)
        let elevation = Self.elevation(of: draft, source: source)

        elevation.drawingDidChange()
        await Self.measured(elevation, by: source)

        let filled = elevation.samples?.filling(draft.routeCoordinates) ?? []
        #expect(filled.compactMap(\.elevation) == Heights.all)
    }

    /// A line with one point on it is a place rather than a trail and has no
    /// climb to ask about — the same floor ``TrailDraftSave`` refuses below.
    @Test("a single point is not worth a question")
    func aSinglePointIsNotMeasured() async {
        let draft = Self.draft([Line.first])
        let source = StubHeightSource(heights: Heights.all)
        let elevation = Self.elevation(of: draft, source: source)

        elevation.drawingDidChange()
        await Self.settle { !source.askedCounts.isEmpty }

        #expect(source.askedCounts.isEmpty, "nothing was asked")
        #expect(elevation.summary == nil)
    }

    // MARK: - What it costs

    /// **The whole point of the debounce.** A hiker putting four points down
    /// asks one question, not four — and the one that is asked is about the
    /// line as it finally stood.
    @Test("a run of changes asks one question")
    func aRunOfChangesAsksOnce() async {
        let draft = Self.draft()
        let source = StubHeightSource(heights: Heights.all)
        let elevation = Self.elevation(of: draft, source: source)

        // Four changes with no turn of the main actor between them, which is
        // what a hiker tapping faster than the settle looks like.
        for _ in 0..<Line.all.count { elevation.drawingDidChange() }
        await Self.measured(elevation, by: source)

        #expect(
            source.askedCounts == [Line.all.count],
            "three of the four were cancelled before they asked anything"
        )
    }

    /// A launch with no source asks nothing at all and says so, rather than
    /// asking and failing — the shape ``TrailPointFinder/isAvailable`` and
    /// ``TrailDraftController/canSnapToPaths`` both take.
    @Test("a launch with no source never schedules anything")
    func aLaunchWithNoSourceAsksNothing() async {
        let elevation = Self.elevation(of: Self.draft(), source: nil)

        #expect(!elevation.isAvailable)
        elevation.drawingDidChange()
        await Self.settle { elevation.isMeasuring }

        #expect(!elevation.isMeasuring)
        #expect(elevation.summary == nil)
    }

    // MARK: - What a change and a refusal do

    /// The figure goes the instant the line does, rather than sitting beside a
    /// length that describes a different trail.
    @Test("a change to the line takes the figure away at once")
    func aChangeForgetsTheFigure() async {
        let draft = Self.draft()
        let source = StubHeightSource(heights: Heights.all)
        let elevation = Self.elevation(of: draft, source: source)

        elevation.drawingDidChange()
        await Self.measured(elevation, by: source)
        #expect(elevation.summary != nil)

        draft.append(Line.at(Line.fifth))
        elevation.drawingDidChange()

        #expect(elevation.summary == nil, "synchronously, before anything is asked")
        #expect(elevation.samples == nil)
    }

    /// Closing the maker forgets everything, so a figure never outlives the
    /// screen it was drawn on.
    @Test("clearing forgets the figure and the heights")
    func clearingForgetsEverything() async {
        let draft = Self.draft()
        let source = StubHeightSource(heights: Heights.all)
        let elevation = Self.elevation(of: draft, source: source)

        elevation.drawingDidChange()
        await Self.measured(elevation, by: source)
        elevation.clear()

        #expect(elevation.summary == nil)
        #expect(!elevation.isMeasuring)
        #expect(
            elevation.samples == nil,
            "and there is nothing left for a save to put on the line"
        )
    }

    /// A refusal is a length and no climb, which is what a free hiker's drawn
    /// trail always looks like and what a curated route with no heights
    /// already looks like. Nothing is drawn as broken.
    @Test("a refused answer leaves a length and no climb")
    func aRefusalLeavesNoFigure() async {
        let draft = Self.draft()
        let source = StubHeightSource(heights: [])
        let elevation = Self.elevation(of: draft, source: source)

        elevation.drawingDidChange()
        await Self.measured(elevation, by: source)

        #expect(elevation.summary == nil)
        #expect(elevation.samples == nil)
        #expect(draft.distanceMeters > 0, "the line is still a line")
    }

    // MARK: - What the controller asks about, and what it does not

    /// A point going down moves the line, so the climb is asked about again.
    @Test("a point going down asks about the climb")
    func aPointGoingDownAsks() async {
        let source = StubHeightSource(heights: Heights.all)
        let maker = Self.maker(source: source)

        maker.appendWaypoint(at: Line.at(Line.first))
        maker.appendWaypoint(at: Line.at(Line.third))
        await Self.measured(maker.elevation, by: source)

        #expect(source.askedCounts == [2])
    }

    /// A leg still waiting for its path is a straight placeholder, and
    /// measuring it spends a billed call on a line that is about to change.
    /// Overpass is often slower than the settle, so a long route used to pay
    /// for one of these per gap between two legs.
    @Test("a line with a leg still routing is not measured until it lands")
    func aRoutingLineWaitsForItsLegs() async {
        let source = StubHeightSource(heights: Heights.all)
        let router = StubTrailLegRouter(answering: .snapped, holding: true)
        let maker = TrailDraftController(
            router: router,
            elevationSource: source,
            elevationPause: { _ in /* instant */ }
        )
        maker.setEditing(true)

        maker.appendWaypoint(at: Line.at(Line.first))
        maker.appendWaypoint(at: Line.at(Line.third))
        await router.waitUntilAsked()
        await Self.settle { !source.askedCounts.isEmpty }
        #expect(source.askedCounts.isEmpty, "nothing is asked while the leg is out")

        await router.release()
        await Self.measured(maker.elevation, by: source)
        #expect(source.askedCounts.count == 1, "the leg landing asks once")
    }

    /// **Marking a place asks nothing**, and that is the split
    /// ``TrailDraftController/commitLine()`` exists for: a place is a spot
    /// beside the trail, the line is the number it already was, and a hiker
    /// marking the six springs along a climb would otherwise spend six billed
    /// calls being told so.
    @Test("marking, renaming, moving and removing a place ask nothing")
    func aPlaceEditAsksNothing() async throws {
        let source = StubHeightSource(heights: Heights.all)
        let maker = Self.maker(source: source)
        maker.appendWaypoint(at: Line.at(Line.first))
        maker.appendWaypoint(at: Line.at(Line.third))
        await Self.measured(maker.elevation, by: source)

        var place = try #require(
            maker.markPlace(at: Line.at(Line.second), named: "Spring", symbol: .water)
        )
        place.name = "The spring"
        maker.updatePlace(place)
        maker.movePlace(id: place.id, to: Line.at(Line.fourth))
        maker.removePlace(id: place.id)
        await Self.settle { source.askedCounts.count > 1 }

        #expect(source.askedCounts == [2], "four place edits, and not one question")
    }
}
