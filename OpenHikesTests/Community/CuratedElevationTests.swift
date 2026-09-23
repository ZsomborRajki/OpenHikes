//
//  CuratedElevationTests.swift
//  OpenHikesTests
//
//  The heights a curated route has to be given, since OpenStreetMap has none.
//
//  What is asserted here is everything that can be without a network, which is
//  everything that goes wrong in practice: which points are asked about, how
//  the request is spelled, what an answer of the wrong length does, and what a
//  refusal costs the screen. The call itself is one POST to Stadia and is
//  behind ``StadiaElevationSource/Transport``, which every case below hands in.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Curated elevation")
struct CuratedElevationTests {
    private static let key = "test-key"
    /// Far enough that a moved point is a different place by any reading.
    private static let aLongWayOff = 0.01

    private static func route(_ count: Int) -> [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(
                latitude: 47.63 + Double(index) * 0.0005,
                longitude: 12.86,
                elevation: nil
            )
        }
    }

    /// A transport that answers with whatever a case asks for and records what
    /// it was handed.
    ///
    /// `final class` behind a `Mutex` rather than an actor, for the reason
    /// ``StubCuratedTrailSource`` is one: the call arrives off the main actor,
    /// and an actor would turn every read below into a suspension point.
    nonisolated private final class StubTransport: @unchecked Sendable {
        private struct State {
            var requests: [URLRequest] = []
            var statusCode = 200
            var body = Data()
        }

        private let state = Mutex(State())

        var requests: [URLRequest] { state.withLock(\.requests) }

        func refuse(with statusCode: Int) {
            state.withLock { $0.statusCode = statusCode }
        }

        func answer(_ body: Data) {
            state.withLock { $0.body = body }
        }

        func answer(heights: [Double]) {
            let numbers = heights.map { String($0) }.joined(separator: ",")
            answer(Data(#"{"height":[\#(numbers)]}"#.utf8))
        }

        var transport: StadiaElevationSource.Transport {
            { [self] request in
                state.withLock { current in
                    current.requests.append(request)
                    return (current.body, current.statusCode)
                }
            }
        }
    }

    // MARK: Which points are asked about

    /// A route shorter than the ceiling is asked about whole — no sampling, no
    /// interpolation, one height per point of the line that is drawn.
    @Test("a short route is asked about point by point")
    func shortRouteIsAskedWhole() {
        #expect(CuratedElevationRequest.sampleIndexes(count: 5, limit: 200) == [0, 1, 2, 3, 4])
    }

    /// And a long one is thinned to the ceiling, keeping both ends: the
    /// trailhead's height and the finish's are where a hiker reads a profile
    /// from, and a series that stops short draws a chart whose x-axis
    /// disagrees with the route's own length.
    @Test("a long route is thinned to the ceiling, ends included")
    func longRouteKeepsItsEnds() {
        let indexes = CuratedElevationRequest.sampleIndexes(count: 2000, limit: 200)

        #expect(indexes.count == 200)
        #expect(indexes.first == 0)
        #expect(indexes.last == 1999)
        #expect(indexes == indexes.sorted(), "a profile is read left to right")
        #expect(Set(indexes).count == indexes.count, "a point asked about twice is a height paid for twice")
    }

    @Test("a route with no points asks about nothing")
    func emptyRouteAsksNothing() {
        #expect(CuratedElevationRequest.sampleIndexes(count: 0).isEmpty)
    }

    // MARK: The request

    /// The three things a vendor notices: the method, the key, and who is
    /// asking. The body is Valhalla's spelling — `lat`/`lon` — which is the
    /// half a reader cannot check by eye.
    @Test("the request is a POST carrying the key, the agent and the shape")
    func requestCarriesWhatStadiaExpects() throws {
        let request = try CuratedElevationRequest.post(
            [CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)],
            apiKey: Self.key
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.query()?.contains("api_key=\(Self.key)") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent)
        let body = try #require(request.httpBody)
        let json = try #require(String(bytes: body, encoding: .utf8))
        #expect(json.contains("\"lat\":47.63"))
        #expect(json.contains("\"lon\":12.86"))
    }

    /// The key is in the query, which is where the app's tile URLs already
    /// carry theirs — so the one redaction rule covers both and a logged URL
    /// cannot leak a billable credential.
    @Test("a logged request URL carries no key")
    func requestURLRedactsItsKey() throws {
        let request = try CuratedElevationRequest.post([], apiKey: Self.key)
        let url = try #require(request.url)

        #expect(!url.redactedForLogging.contains(Self.key))
        #expect(url.redactedForLogging.contains("api_key"), "which request it was is still legible")
    }

    // MARK: The answer

    @Test("the heights come back in the order they were asked for")
    func heightsAreRead() throws {
        let data = Data(#"{"height":[601.5,640,712.25]}"#.utf8)

        #expect(try CuratedElevationRequest.heights(from: data, expecting: 3) == [601.5, 640, 712.25])
    }

    /// The failure that would otherwise be invisible. Heights are paired to
    /// coordinates by index, so an answer one short moves every height after
    /// the gap onto somebody else's point — a profile that looks entirely
    /// plausible and describes a different walk.
    @Test("an answer of the wrong length is refused rather than paired up")
    func shortAnswerIsRefused() {
        let data = Data(#"{"height":[601.5,640]}"#.utf8)

        #expect(throws: CuratedElevationFailure.self) {
            try CuratedElevationRequest.heights(from: data, expecting: 3)
        }
    }

    @Test("a refusal is reported as the status it was")
    func serverStatusIsReported() {
        #expect(throws: CuratedElevationFailure.server(statusCode: 403)) {
            try CuratedElevationRequest.body(of: Data(), statusCode: 403)
        }
    }

    // MARK: The source

    @Test("a source with a key asks once and hands back the heights")
    func sourceAsksOnce() async throws {
        let stub = StubTransport()
        stub.answer(heights: [600, 610])
        let source = StadiaElevationSource(apiKey: Self.key, entitlement: { .entitled }, transport: stub.transport)

        let heights = try await source.heights(at: [
            CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            CLLocationCoordinate2D(latitude: 47.64, longitude: 12.86),
        ])

        #expect(heights == [600, 610])
        #expect(stub.requests.count == 1, "one route, one billable call")
    }

    /// Every build without `Secrets.plist` — CI's included — is this one, and
    /// it must not reach the network to find out.
    @Test("a build with no key asks nobody")
    func noKeyAsksNobody() async {
        let stub = StubTransport()
        let source = StadiaElevationSource(apiKey: nil, entitlement: { .entitled }, transport: stub.transport)
        // The bundled key is absent under tests, so this is the shipping
        // no-key path rather than a contrived one.
        guard Secrets.apiKey(for: .stadiaOutdoors) == nil else { return }

        await #expect(throws: CuratedElevationFailure.noKey) {
            try await source.heights(at: [CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)])
        }
        #expect(stub.requests.isEmpty)
    }

    // MARK: Who is asked for

    /// Every call is billed against the key that already sits behind
    /// OpenHikes Pro, so a hiker who has not bought it asks nobody — and the
    /// refusal comes *before* the request is formed, which is the difference
    /// between a chart nobody drew and money nobody meant to spend.
    @Test("a hiker without Pro asks nobody")
    func notEntitledAsksNobody() async {
        let stub = StubTransport()
        stub.answer(heights: [600])
        let source = StadiaElevationSource(
            apiKey: Self.key,
            entitlement: { .notEntitled },
            transport: stub.transport
        )

        await #expect(throws: CuratedElevationFailure.notEntitled) {
            try await source.heights(at: [CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)])
        }
        #expect(stub.requests.isEmpty, "a build with a key and no subscriber asks no more than one with neither")
    }

    /// And neither does a launch whose entitlement StoreKit has not answered
    /// for yet — the first second or so of every one. The same *not yet* the
    /// tile gate turns into `.wait`, rather than a guess that costs money.
    @Test("an unresolved entitlement asks nobody either")
    func unknownEntitlementAsksNobody() async {
        let stub = StubTransport()
        let source = StadiaElevationSource(
            apiKey: Self.key,
            entitlement: { .unknown },
            transport: stub.transport
        )

        await #expect(throws: CuratedElevationFailure.notEntitled) {
            try await source.heights(at: [CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)])
        }
        #expect(stub.requests.isEmpty)
    }

    /// The entitlement is read per request rather than captured, because a
    /// subscription can be bought inside one launch and the screen after it
    /// should draw a chart.
    @Test("a subscription bought mid-launch is asked about on the next open")
    func entitlementIsReadPerRequest() async throws {
        let stub = StubTransport()
        stub.answer(heights: [600])
        let entitled = Mutex(false)
        let source = StadiaElevationSource(
            apiKey: Self.key,
            entitlement: { entitled.withLock { $0 } ? .entitled : .notEntitled },
            transport: stub.transport
        )
        let coordinates = [CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)]

        await #expect(throws: CuratedElevationFailure.notEntitled) {
            try await source.heights(at: coordinates)
        }
        entitled.withLock { $0 = true }

        #expect(try await source.heights(at: coordinates) == [600])
        #expect(stub.requests.count == 1, "and only the entitled open cost anything")
    }

    // MARK: Filling a route

    @Test("the heights land on the points they were asked about")
    func routeIsFilled() async {
        let stub = StubTransport()
        stub.answer(heights: [600, 620, 640, 660, 680])
        let source = StadiaElevationSource(apiKey: Self.key, entitlement: { .entitled }, transport: stub.transport)

        let filled = await source.filled(Self.route(5))

        #expect(filled.map(\.elevation) == [600, 620, 640, 660, 680])
        #expect(filled.map(\.latitude) == Self.route(5).map(\.latitude), "the line itself is untouched")
    }

    /// A failure costs the chart and nothing else. The hike is a line, a
    /// length, a surface and a difficulty before it is a profile, and all four
    /// are already in hand by the time this is asked.
    @Test("a refused request leaves the route exactly as it came")
    func refusedRequestKeepsTheRoute() async {
        let stub = StubTransport()
        stub.refuse(with: 403)
        let source = StadiaElevationSource(apiKey: Self.key, entitlement: { .entitled }, transport: stub.transport)

        let filled = await source.filled(Self.route(4))

        #expect(filled.allSatisfy { $0.elevation == nil })
        #expect(filled.count == 4)
    }

    /// A height that is not a number is not a height: it would reach
    /// `RouteProfile`'s samples and poison the bucket it landed in.
    @Test("a non-finite height is dropped rather than carried")
    func nonFiniteHeightsAreDropped() async {
        let stub = StubTransport()
        stub.answer(Data(#"{"height":[600,null,620]}"#.utf8))
        let source = StadiaElevationSource(apiKey: Self.key, entitlement: { .entitled }, transport: stub.transport)

        let filled = await source.filled(Self.route(3))

        #expect(
            filled.allSatisfy { $0.elevation == nil },
            "an answer this app cannot decode is an answer it does not use"
        )
    }

    // MARK: What was measured, and which line it is about

    /// The heights are kept with the points they were read at, so a caller
    /// that comes back later can tell whether they are still about its line.
    ///
    /// This is the half the trail maker needs and the curated screen does not:
    /// a curated route is opened once and never edited, while a drawing moves
    /// under the answer.
    @Test("samples describe the route they were read for")
    func samplesDescribeTheirRoute() async throws {
        let stub = StubTransport()
        stub.answer(heights: [600, 620, 640])
        let source = StadiaElevationSource(apiKey: Self.key, entitlement: { .entitled }, transport: stub.transport)
        let route = Self.route(3)

        let samples = try #require(await source.samples(of: route))

        #expect(samples.describes(route))
        #expect(samples.filling(route).compactMap(\.elevation) == [600, 620, 640])
    }

    /// And a line that has changed under them is refused rather than filled
    /// approximately.
    ///
    /// The failure this forbids is silent and entirely plausible on screen: a
    /// leg that snapped while the save alert was open lengthens the route, so
    /// every sampled index moves and a height read on a summit is written on
    /// to a point in a valley.
    @Test("samples refuse a line that has changed under them")
    func samplesRefuseAChangedRoute() async throws {
        let stub = StubTransport()
        stub.answer(heights: [600, 620, 640])
        let source = StadiaElevationSource(apiKey: Self.key, entitlement: { .entitled }, transport: stub.transport)

        let samples = try #require(await source.samples(of: Self.route(3)))
        let longer = Self.route(4)

        #expect(!samples.describes(longer), "four points is a different question")
        #expect(samples.filling(longer).allSatisfy { $0.elevation == nil })
    }

    /// A route the same length whose points have moved is refused too — the
    /// count is the cheap half of the check and not the whole of it.
    @Test("samples refuse a line whose points have moved")
    func samplesRefuseAMovedRoute() async throws {
        let stub = StubTransport()
        stub.answer(heights: [600, 620, 640])
        let source = StadiaElevationSource(apiKey: Self.key, entitlement: { .entitled }, transport: stub.transport)

        let samples = try #require(await source.samples(of: Self.route(3)))
        var moved = Self.route(3)
        moved[1].latitude += Self.aLongWayOff

        #expect(!samples.describes(moved))
        #expect(samples.filling(moved).allSatisfy { $0.elevation == nil })
    }

    /// The source a launch gets when it must not ask — a suite, or a UI test
    /// with no curated scenario.
    @Test("the dormant source answers nothing")
    func dormantSourceAnswersNothing() async {
        await #expect(throws: CuratedElevationFailure.noKey) {
            try await DormantElevationSource().heights(at: [
                CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            ])
        }
    }
}
