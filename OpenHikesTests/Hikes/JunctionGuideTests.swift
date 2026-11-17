//
//  JunctionGuideTests.swift
//  OpenHikesTests
//
//  Junction warnings on the phone: when the guide takes fixes, and what it
//  says on the way up to a fork. The fixes are handed in and the sentences
//  heard by stand-ins, so no suite reaches Core Location or the audio
//  session; the walk is a real ``TrailWalkSession``.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

// swiftlint:disable no_magic_numbers

/// Fixes the suite hands in, and whether the guide asked for any.
@MainActor
private final class HeldJunctionFeed: JunctionLocationFeeding {
    private(set) var isRunning = false
    private var deliver: (@MainActor (JunctionFix) -> Void)?

    func start(deliver: @escaping @MainActor (JunctionFix) -> Void) {
        isRunning = true
        self.deliver = deliver
    }

    func stop() {
        isRunning = false
        deliver = nil
    }

    func send(_ coordinate: CLLocationCoordinate2D) {
        deliver?(JunctionFix(coordinate: coordinate, course: nil))
    }
}

/// A graph out of reach until the suite says it is back: a trailhead with
/// no signal and nothing kept.
private actor ReturningJunctionGraph: TrailGraphProviding {
    private let graph: TrailGraph
    private var isReachable = false

    init(graph: TrailGraph) {
        self.graph = graph
    }

    func comeBack() { isReachable = true }

    nonisolated func region(containing _: CLLocationCoordinate2D) -> TrailGraphRegion? {
        TrailGraphRegion(zoom: 12, x: 1, y: 1)
    }

    func prefetch(around _: CLLocationCoordinate2D) throws {
        guard isReachable else { throw URLError(.notConnectedToInternet) }
    }

    func cachedGraph(covering _: [CLLocationCoordinate2D]) -> TrailGraph? {
        isReachable ? graph : nil
    }

    func hasCompleteCachedGraph(covering _: [CLLocationCoordinate2D]) -> Bool { isReachable }
}

/// What the guide said.
@MainActor
private final class HeardJunctionVoice: JunctionSpeaking {
    private(set) var sentences: [String] = []
    private(set) var stops = 0

    func speak(_ sentence: String) { sentences.append(sentence) }
    func stopSpeaking() { stops += 1 }
}

@MainActor
@Suite("Junction guide")
struct JunctionGuideTests {
    private let context: ModelContext
    private let defaults: UserDefaults
    private let clock = TestClock()
    private let feed = HeldJunctionFeed()
    private let voice = HeardJunctionVoice()

    init() throws {
        context = ModelContext(try Fixture.modelContainer())
        defaults = try #require(UserDefaults(suiteName: "JunctionGuideTests-\(UUID().uuidString)"))
    }

    private func walk() -> TrailWalkSession {
        TrailWalkSession(context: context, clock: clock.read)
    }

    private func guide(
        for walk: TrailWalkSession,
        graph: any TrailGraphProviding = StubTrailGraphProvider(graph: JunctionFixture.fork)
    ) -> JunctionGuide {
        JunctionGuide(
            walk: walk,
            graph: graph,
            defaults: defaults,
            feed: feed,
            voice: voice
        )
    }

    /// ``JunctionFixture/route``, walked from its start by hand.
    private func startWalking(_ session: TrailWalkSession) -> Hike {
        let hike = Fixture.hike(in: context, title: "Fork Trail", route: JunctionFixture.route)
        session.start(hike: hike, profile: RouteProfile(route: JunctionFixture.route))
        return hike
    }

    @Test("off until turned on: a walk takes no fixes for it, and the button is offered")
    func offByDefault() async {
        let session = walk()
        let guide = guide(for: session)
        #expect(!guide.isOn)
        #expect(!guide.isOffered, "no walk, no button")

        _ = startWalking(session)
        await settleDelegateHop(until: "the button is offered for the walk") { guide.isOffered }

        #expect(!feed.isRunning)
        #expect(voice.sentences.isEmpty)
    }

    @Test("turned on during a walk, it says so, finds the fork and takes fixes")
    func turningOnGuidesTheWalk() async {
        let session = walk()
        let guide = guide(for: session)
        _ = startWalking(session)

        guide.toggle()
        await settleDelegateHop(until: "the walk's junctions are found") { guide.isGuiding }

        #expect(feed.isRunning)
        #expect(voice.sentences == ["Junction warnings on"])
        #expect(guide.junctions.map(\.towardsEnd) == [.keepLeft])
        #expect(defaults.bool(forKey: SettingsKey.junctionWarningsEnabled))
    }

    @Test("walking up to the fork, the distance is said, then which way at it")
    func walkingUpToTheFork() async {
        let session = walk()
        let guide = guide(for: session)
        _ = startWalking(session)
        guide.toggle()
        await settleDelegateHop(until: "the walk's junctions are found") { guide.isGuiding }

        for north in stride(from: -300.0, through: 20, by: 5) {
            feed.send(JunctionFixture.at(1, north))
        }

        let warnings = voice.sentences.dropFirst()
        #expect(warnings.count == 2)
        #expect(warnings.first?.hasPrefix("Keep left at the fork in ") == true)
        #expect(warnings.last == "Keep left at the fork")
    }

    @Test("fixes well off the trail say nothing")
    func offTrailIsSilent() async {
        let session = walk()
        let guide = guide(for: session)
        _ = startWalking(session)
        guide.toggle()
        await settleDelegateHop(until: "the walk's junctions are found") { guide.isGuiding }

        for north in stride(from: -300.0, through: 20, by: 5) {
            feed.send(JunctionFixture.at(300, north))
        }

        #expect(voice.sentences == ["Junction warnings on"])
    }

    @Test("a pause stops the fixes and a resume takes them up again")
    func pauseAndResume() async {
        let session = walk()
        let guide = guide(for: session)
        _ = startWalking(session)
        guide.toggle()
        await settleDelegateHop(until: "the walk's junctions are found") { guide.isGuiding }

        session.pause()
        await settleDelegateHop(until: "the feed stops for the pause") { !feed.isRunning }
        #expect(guide.isOffered, "the button stays for a paused walk")
        #expect(voice.stops == 1)

        session.resume()
        await settleDelegateHop(until: "the walk's junctions are found again") { guide.isGuiding }
        #expect(feed.isRunning)
    }

    @Test("the walk ending stops the fixes and withdraws the button")
    func endingStops() async {
        let session = walk()
        let guide = guide(for: session)
        _ = startWalking(session)
        guide.toggle()
        await settleDelegateHop(until: "the walk's junctions are found") { guide.isGuiding }

        session.end()
        await settleDelegateHop(until: "the button is withdrawn") { !guide.isOffered }

        #expect(!feed.isRunning)
        #expect(!guide.isGuiding)
    }

    @Test("turned off, the fixes stop and nothing more is said; the answer is kept")
    func turningOffStops() async {
        let session = walk()
        let guide = guide(for: session)
        _ = startWalking(session)
        guide.toggle()
        await settleDelegateHop(until: "the walk's junctions are found") { guide.isGuiding }

        guide.toggle()

        #expect(!feed.isRunning)
        #expect(voice.sentences == ["Junction warnings on"])
        #expect(defaults.object(forKey: SettingsKey.junctionWarningsEnabled) as? Bool == false)
    }

    @Test("a line with no junction worth a word takes no fixes")
    func noJunctionsNoFixes() async {
        let session = walk()
        // The stem and the left arm alone: one trail, no fork.
        let oneTrail = TrailGraph(
            nodes: JunctionFixture.fork.nodes.filter { $0.id != 3 },
            edges: JunctionFixture.fork.edges.filter { $0.toNodeID != 3 }
        )
        let guide = guide(for: session, graph: StubTrailGraphProvider(graph: oneTrail))
        _ = startWalking(session)

        guide.toggle()
        await settleDelegateHop(until: "the walk's line is read") { guide.isGuiding }

        #expect(guide.junctions.isEmpty)
        #expect(!feed.isRunning)
    }

    @Test("a graph out of reach takes no fixes, and is asked for again when the app comes back")
    func unreachableGraphIsOwed() async {
        let session = walk()
        let graph = ReturningJunctionGraph(graph: JunctionFixture.fork)
        let guide = guide(for: session, graph: graph)
        _ = startWalking(session)

        guide.toggle()
        await settleDelegateHop(until: "the junctions are owed") { guide.isOwed }
        #expect(!feed.isRunning)

        await graph.comeBack()
        guide.sceneDidBecomeActive()
        await settleDelegateHop(until: "the walk's junctions are found") { guide.isGuiding }

        #expect(guide.junctions.map(\.towardsEnd) == [.keepLeft])
        #expect(feed.isRunning)
    }

    @Test("a fix far from the line parks the feed until the app comes back")
    func farFromTheLineParks() async {
        let session = walk()
        let guide = guide(for: session)
        _ = startWalking(session)
        guide.toggle()
        await settleDelegateHop(until: "the walk's junctions are found") { guide.isGuiding }

        // Driven home, with the walk still following.
        feed.send(JunctionFixture.at(5000, 0))
        #expect(!feed.isRunning)
        #expect(guide.isGuiding)

        guide.sceneDidBecomeActive()
        #expect(feed.isRunning)
        // Still far off: parked again by the first fix.
        feed.send(JunctionFixture.at(5000, 0))
        #expect(!feed.isRunning)
    }

    @Test("a hiker who turned the warnings on has them on the next launch's walks")
    func theSwitchIsKept() async {
        guide(for: walk()).toggle()

        let session = walk()
        let next = guide(for: session)
        _ = startWalking(session)
        await settleDelegateHop(until: "the next launch guides the walk") { next.isGuiding }

        #expect(next.isOn)
        #expect(feed.isRunning)
    }
}

// swiftlint:enable no_magic_numbers
