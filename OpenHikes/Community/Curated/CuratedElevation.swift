//
//  CuratedElevation.swift
//  OpenHikes
//
//  Heights for a route OpenStreetMap has none for.
//
//  A hiking relation is ways and nodes, not a terrain model. Measured over one
//  Berchtesgaden box while the curated feature was built: `ele` was on **zero**
//  of 1,725 geometry nodes, on 106 relations. So a curated route opens with a
//  line, a length, a surface and a difficulty — and no profile, which is the
//  one figure a hiker uses to decide whether a trail is a walk or a day out.
//  Asking Overpass for more nodes does not change that; a second source is the
//  only thing that can.
//
//  ## Who is asked, and when
//
//  Stadia Maps, whose key this app already carries for its paid map styles,
//  whose terms it already lives under, and whose URLs ``URL/redactedForLogging``
//  already keeps out of the log. One vendor rather than two is most of the
//  argument: every provider added here is another set of terms, another line in
//  the privacy policy, and another thing to explain.
//
//  Asked **once, when a curated hike is opened**, and never for a list. A
//  nearby search offers up to a page of routes and a hiker opens one of them,
//  so fetching on the list would pay for twenty-five profiles to draw one. It
//  is the same rule the surface and difficulty analysis already follows, and
//  for the same reason.
//
//  ## And once more, for a trail somebody is drawing
//
//  The trail maker asks the same source the same question — see
//  ``TrailDraftElevation`` — because a drawn line has exactly the problem a
//  curated route has: it is geometry with no terrain under it, and the climb
//  is the figure that decides whether Saturday is a walk or a day out. What
//  differs is *when*: a curated route is opened once, while a drawn one keeps
//  changing, so that caller waits for the drawing to settle before it asks and
//  throws the answer away the moment the line moves. Everything below is
//  unchanged by it, which is the point of it being the same file.
//
//  And asked **only for an OpenHikes Pro subscriber**, because every call is
//  billed against the same key the paid map styles are already behind. A free
//  hiker's curated route opens the way it did before this file existed: a
//  line, a length, a surface, a difficulty, and no chart. See
//  ``StadiaElevationSource``, which refuses before it forms a request.
//
//  ## What is sent, and what is kept
//
//  The coordinates of a public OpenStreetMap relation, and nothing else. Not
//  the hiker's position, not their identity, and nothing that says where they
//  are — a route in Bavaria is asked about identically from Munich and from
//  Sydney. Nothing is written down: the heights ride on the detail that is
//  already in flight, are drawn, and go with the screen. A hiker who imports
//  the hike keeps them the way they keep every other route point.
//
//  ## The line that is drawn is the line that was asked about
//
//  A route is sampled down to ``CuratedElevationRequest/maximumShapePoints``
//  evenly spaced points before the request, which is one height every hundred
//  metres on a twenty-kilometre trail and finer on everything shorter. The
//  heights land back on exactly those points, and ``RouteProfile`` plots the
//  points that carry one — so the profile is a true reading of the trail at a
//  coarser interval rather than an interpolation of a finer-looking one.
//

import CoreLocation
import Foundation
import os

/// Where a curated route's heights come from.
///
/// A protocol for the reason ``CuratedTrailSourcing`` is one: the conformance
/// below reaches a billable third-party API, and no suite may.
nonisolated protocol CuratedElevationSourcing: Sendable {
    /// The height in metres at each coordinate, in the order asked.
    ///
    /// Throws rather than answering short: a caller cannot pair a partial
    /// answer with the points it asked about, and a profile drawn from the
    /// wrong pairing is worse than no profile. See
    /// ``CuratedElevationRequest/heights(from:expecting:)``.
    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double]
}

/// The shape of the request, and the reading of the answer.
///
/// Pure and separate from the transport for the reason
/// ``OverpassRequest`` is: what can be asserted without a network is the whole
/// of what this file gets wrong in practice — which points are asked about,
/// how they are spelled, and what a short or unusable answer does.
nonisolated enum CuratedElevationRequest {
    /// Stadia's elevation service, which is Valhalla's `/height` under their
    /// key.
    static let endpoint = URL(string: "https://api.stadiamaps.com/elevation/v1")!

    /// How many points one request asks about.
    ///
    /// Two hundred, which is a height every hundred metres on a twenty-
    /// kilometre trail — the longest a curated route can be, since
    /// ``CuratedTrailQuery`` refuses a bounding box wider than that — and
    /// finer on everything below it. The chart plots at most 500 samples in any
    /// case, so a denser request would buy resolution the screen cannot show,
    /// on a call that is billed.
    static let maximumShapePoints = 200

    /// How long the client waits before giving up, in seconds. Shorter than
    /// ``OverpassRequest/timeoutInterval``: this is a commercial API answering
    /// a fixed-size question, and the screen it is for has already drawn.
    static let timeoutInterval: TimeInterval = 15

    private static let successRange = 200..<300

    /// Evenly spaced indexes into a route of `count` points, always including
    /// the first and the last.
    ///
    /// The ends are kept because they are where a hiker reads the profile from
    /// — the trailhead's height and the finish's — and because a series that
    /// stops short draws a chart whose x-axis disagrees with the route's own
    /// length. A route already short enough is asked about whole.
    static func sampleIndexes(count: Int, limit: Int = maximumShapePoints) -> [Int] {
        guard count > 0 else { return [] }
        guard count > limit, limit > 1 else { return Array(0..<count) }
        let last = count - 1
        // `limit - 1` intervals over the route, so the first and last indexes
        // are the two ends exactly rather than nearly.
        return (0..<limit).map { step in
            Int((Double(step) * Double(last) / Double(limit - 1)).rounded())
        }
    }

    /// The POST Stadia expects, with the key in the query and nowhere else.
    ///
    /// The key is a query item rather than a header because that is the form
    /// their tile URLs already take here, so one redaction rule covers both —
    /// see ``URL/redactedForLogging``, which replaces every query *value* and
    /// therefore needs no list of credential names to keep in step.
    static func post(_ coordinates: [CLLocationCoordinate2D], apiKey: String) throws -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components?.url else {
            throw CuratedElevationFailure.unusable("the endpoint could not be formed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The same identifying header every other outbound request here
        // carries — see ``TileCache/userAgent``.
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Body(shape: coordinates.map(Point.init)))
        return request
    }

    /// The heights in `data`, or the failure it was.
    ///
    /// - Parameter expecting: how many points were asked about. An answer of a
    ///   different length is refused rather than paired up as far as it goes:
    ///   the heights are matched to the request by *index*, so a short answer
    ///   silently moves every height after the gap onto somebody else's
    ///   coordinate — a profile that looks entirely plausible and describes a
    ///   different walk.
    static func heights(from data: Data, expecting: Int) throws -> [Double] {
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        guard answer.height.count == expecting else {
            throw CuratedElevationFailure.unusable(
                "asked about \(expecting) points and \(answer.height.count) came back"
            )
        }
        return answer.height
    }

    /// The body of a successful response, or the failure its status was.
    static func body(of data: Data, statusCode: Int) throws -> Data {
        guard successRange.contains(statusCode) else {
            throw CuratedElevationFailure.server(statusCode: statusCode)
        }
        return data
    }

    private struct Body: Encodable {
        let shape: [Point]
    }

    /// Valhalla's spelling: `lat`/`lon`, not `latitude`/`longitude`.
    private struct Point: Encodable {
        let lat: Double
        let lon: Double

        init(_ coordinate: CLLocationCoordinate2D) {
            lat = coordinate.latitude
            lon = coordinate.longitude
        }
    }

    /// The answer echoes the shape it was given; only the heights are read.
    private struct Answer: Decodable {
        let height: [Double]
    }
}

/// Why a height request produced nothing usable.
///
/// Never shown to a hiker. A curated hike with no profile draws no chart at
/// all — see ``CommunityHikeView/elevationSection`` — so these exist to be
/// logged and to keep the failing branches apart in a test.
nonisolated enum CuratedElevationFailure: LocalizedError, Equatable {
    /// No Stadia key in this build. Every build without `Secrets.plist` is
    /// this one, including CI's.
    case noKey
    /// The hiker is not an OpenHikes Pro subscriber, or StoreKit has not said
    /// yet. Nothing is asked and nothing is billed — see
    /// ``StadiaElevationSource``.
    case notEntitled
    case server(statusCode: Int)
    case unusable(String)

    var errorDescription: String? {
        switch self {
        case .noKey: "This build has no elevation key."
        case .notEntitled: "Elevation for these routes comes with OpenHikes Pro."
        case .server(let statusCode): "The elevation service answered \(statusCode)."
        case .unusable(let reason): "The elevation service's answer was unusable: \(reason)."
        }
    }
}

/// Stadia Maps' elevation service, behind the subscription that pays for it.
///
/// **Every call here is billed, so every call here is a subscriber's.** The
/// same key draws the paid map styles, which are already behind OpenHikes Pro;
/// a free hiker opening curated routes all afternoon would otherwise run up a
/// bill against a screen they are not paying for, which is the one thing the
/// issue that asked for this feature flagged about the vendor. So the
/// entitlement is asked *before* the request rather than after — nothing is
/// sent, nothing is billed, and the hike opens without a chart exactly as it
/// does when the service refuses.
///
/// `.unknown` — StoreKit has not answered yet, which is the first second or so
/// of a launch — is treated as *not yet*, the same way
/// ``MapEntitlementState/tapAction(for:)`` turns it into `.wait` rather than
/// into an unlock prompt. A screen opened in that window draws no chart and
/// the next open draws one; the alternative is spending money on a question
/// nobody has answered.
nonisolated struct StadiaElevationSource: CuratedElevationSourcing {
    /// The seam a suite replaces. Same shape as
    /// ``CuratedTrailSource/Transport``, and for the same reason: nothing here
    /// may reach the network from a test.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    private let apiKey: String?
    private let entitlement: @Sendable () -> MapEntitlementState
    private let transport: Transport

    /// - Parameter apiKey: `nil` resolves the bundled Stadia key, which is the
    ///   same key the paid map styles use. A build without one — every build
    ///   without `Secrets.plist` — answers ``CuratedElevationFailure/noKey``
    ///   and therefore draws no chart, exactly as it draws no Stadia tiles.
    /// - Parameter entitlement: read per request rather than captured, because
    ///   a subscription can be bought, lapse or be restored inside one launch —
    ///   and because the answer is `.unknown` for the first moments of every
    ///   one. ``MapEntitlement/current`` is the process-wide answer the tile
    ///   pipeline already resolves against, so the map and the chart cannot
    ///   disagree about who is a subscriber.
    init(
        apiKey: String? = nil,
        entitlement: @escaping @Sendable () -> MapEntitlementState = { MapEntitlement.current },
        transport: Transport? = nil
    ) {
        self.apiKey = apiKey ?? Secrets.apiKey(for: .stadiaOutdoors)
        self.entitlement = entitlement
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        // Before the key is even read: a refusal that costs nothing is the
        // point, and a build with a key and no subscriber must ask no more
        // than a build with neither.
        guard entitlement() == .entitled else { throw CuratedElevationFailure.notEntitled }
        guard let apiKey else { throw CuratedElevationFailure.noKey }
        let request = try CuratedElevationRequest.post(coordinates, apiKey: apiKey)
        let (data, statusCode) = try await transport(request)
        return try CuratedElevationRequest.heights(
            from: CuratedElevationRequest.body(of: data, statusCode: statusCode),
            expecting: coordinates.count
        )
    }
}

/// A route's heights, at the points that were actually asked about.
///
/// Kept as a value of its own rather than folded straight into the route,
/// because the two callers want different things out of one answer. A curated
/// hike wants the route *filled* and nothing else: it opens once, draws a
/// chart, and never has to ask again. The trail maker wants the figures while
/// the hiker goes on drawing, and then — possibly many edits later — has to be
/// able to say whether the line it is about to save is still the line these
/// were read for.
///
/// Carrying the coordinates is what answers that second question. They are the
/// ones that were sent, so a route whose sampled points still stand where
/// these stood is the route these describe. Comparing them is exact rather
/// than approximate on purpose: these *are* the route's own values, copied,
/// and a tolerance would only be a way of accepting a height for a point that
/// has moved.
nonisolated struct RouteHeightSamples: Equatable, Sendable {
    /// How many points the route had when these were read.
    ///
    /// Which indexes were asked about is a function of this alone — see
    /// ``CuratedElevationRequest/sampleIndexes(count:limit:)`` — so a route of
    /// a different length is a different question, and the indexes below are
    /// not necessarily even in bounds for it.
    let routePointCount: Int
    /// The indexes asked about, ascending, both ends included.
    let indexes: [Int]
    /// The route's points at those indexes, as they were sent.
    let coordinates: [RouteCoordinate]
    /// The height in metres at each, in the same order.
    let heights: [Double]

    /// What the sampled heights add up to: the climb, the drop and the two
    /// extremes.
    ///
    /// Read off the samples rather than off a filled route, and they are the
    /// same numbers either way — ``RouteProfile`` walks the points that carry
    /// a height and these are all of them. Computed on demand because it is
    /// two hundred additions and the caller stores the answer.
    var summary: RouteElevationSummary {
        var accumulator = ElevationAccumulator()
        for height in heights { accumulator.record(height) }
        return RouteElevationSummary(accumulator)
    }

    /// Whether `route` is still the route these heights were read for.
    func describes(_ route: [RouteCoordinate]) -> Bool {
        guard route.count == routePointCount, indexes.count == coordinates.count else { return false }
        return zip(indexes, coordinates).allSatisfy { index, sampled in
            route[index].latitude == sampled.latitude
                && route[index].longitude == sampled.longitude
        }
    }

    /// `route` with these heights on the points they were read at, or `route`
    /// untouched when it is not the route they were read for.
    ///
    /// Non-finite heights are dropped rather than carried: a height that is
    /// not a number is not a height, and the chart's downsampling compares
    /// them.
    func filling(_ route: [RouteCoordinate]) -> [RouteCoordinate] {
        guard describes(route) else { return route }
        var filled = route
        for (index, height) in zip(indexes, heights) where height.isFinite {
            filled[index].elevation = height
        }
        return filled
    }
}

/// Where the log for this half of the feature goes. File-scoped so the
/// protocol extension below can reach it without every conformance carrying
/// one.
nonisolated private let elevationLogger = Logger(subsystem: "OpenHikes", category: "Community")

nonisolated extension CuratedElevationSourcing {
    /// The heights at the points `route` samples down to, or `nil` when the
    /// service could not answer.
    ///
    /// **A failure here is not a failure of the screen.** A curated hike is a
    /// line, a length, a surface and a difficulty before it is a profile, and
    /// every one of those is already in hand by the time this is asked. So a
    /// refusal, a timeout, a build with no key — all of them draw the hike
    /// without a chart, which is what the screen did before this existed and
    /// what it still does for a route the service has no data for. The trail
    /// maker's header is the same bargain: no figure rather than a wrong one.
    ///
    /// Two of the refusals are logged at `info` rather than `error`, and that
    /// is about the second caller. A build with no key and a hiker who is not
    /// a subscriber are both states this is *designed* to have, and the maker
    /// asks again every time a drawing settles — so at `error` those two would
    /// be the loudest thing in the log for an ordinary launch by an ordinary
    /// hiker, and the refusals worth reading would be buried under them.
    func samples(of route: [RouteCoordinate]) async -> RouteHeightSamples? {
        let indexes = CuratedElevationRequest.sampleIndexes(count: route.count)
        guard indexes.count > 1 else { return nil }
        let coordinates = indexes.map { route[$0] }
        do {
            return RouteHeightSamples(
                routePointCount: route.count,
                indexes: indexes,
                coordinates: coordinates,
                heights: try await heights(at: coordinates.map(\.clCoordinate))
            )
        } catch CuratedElevationFailure.noKey, CuratedElevationFailure.notEntitled {
            elevationLogger.info("No heights for a route: this launch does not ask for any.")
            return nil
        } catch {
            elevationLogger.error(
                """
                No heights for a route: \(error.localizedDescription, privacy: .public). \
                It is drawn without a profile.
                """
            )
            return nil
        }
    }

    /// `route` with heights on the points that were asked about, or `route`
    /// exactly as it came when the service could not answer.
    ///
    /// The whole of what a curated hike wants from one of these: it opens
    /// once, draws, and has no reason to remember which points carried the
    /// answer. See ``RouteHeightSamples`` for the caller that does.
    func filled(_ route: [RouteCoordinate]) async -> [RouteCoordinate] {
        guard let samples = await samples(of: route) else { return route }
        return samples.filling(route)
    }
}

/// A source that answers nothing, for the launches that must not ask.
///
/// The elevation half of ``DormantLocationSource``'s argument: a suite, or a
/// UI-test launch with no curated scenario, gets one of these rather than a
/// real one holding a key it would spend.
nonisolated struct DormantElevationSource: CuratedElevationSourcing {
    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
        throw CuratedElevationFailure.noKey
    }
}
