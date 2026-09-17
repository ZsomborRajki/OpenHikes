//
//  OverpassRequestTests.swift
//  OpenHikesTests
//
//  The manners both Overpass callers share, and the arithmetic one of them
//  used to get backwards.
//
//  Nothing here reaches a network: every function under test is a pure reading
//  of a request or a response, which is exactly why they are worth pinning.
//  They are the rules that decide whether this app is a well-behaved client of
//  a volunteer-run API or an anonymous one hammering it — and a rule that is
//  wrong here is wrong in a way no feature test would notice, because the
//  feature still works against a server that happens not to be busy.
//
//  The measurements quoted are from `overpass-api.de` (0.7.62.11) on
//  2026-09-17, taken while this was written.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Overpass request")
struct OverpassRequestTests {
    private static let endpoint = URL(string: "https://overpass.invalid/api/interpreter")!

    /// **The order that was wrong, and the reason it mattered.**
    /// `URLRequest.timeoutInterval` is an *idle* timeout, and Overpass sends
    /// nothing until the query has finished — so the silence a client sits
    /// through is the queue wait plus the whole execution. A flat 35 seconds
    /// sat underneath a `[timeout:30]` query with up to 15 seconds of queue in
    /// front of it: the socket could be cancelled while the server was still
    /// working, and a cancelled socket says nothing, where the answer that was
    /// coming would have said *rate-limited*, *busy*, or here are your trails.
    @Test("the client outwaits the queue and the query together")
    func theClientOutwaitsTheServer() {
        for serverTimeout in [
            CuratedTrailQuery.listingTimeoutSeconds,
            CuratedTrailQuery.geometryTimeoutSeconds,
            OverpassTrailGraphProvider.queryTimeoutSeconds,
        ] {
            let patience = OverpassRequest.idleTimeout(forServerTimeout: serverTimeout)

            #expect(
                patience > TimeInterval(serverTimeout) + OverpassRequest.queueAllowance,
                "a query asking for \(serverTimeout)s can be queued for 15s before it starts"
            )
        }
    }

    /// The number the query carries is the number the patience is built from,
    /// so the two cannot drift into the order above by somebody editing one
    /// of them.
    @Test("a request's patience is derived from the query it carries")
    func patienceFollowsTheQuery() {
        let brief = OverpassRequest.post("[out:json][timeout:5];", to: Self.endpoint, awaiting: 5)
        let long = OverpassRequest.post("[out:json][timeout:90];", to: Self.endpoint, awaiting: 90)

        #expect(long.timeoutInterval - brief.timeoutInterval == 85)
    }

    /// What *busy* is, which is the whole of the retry policy's input. A
    /// gateway refusing in front of Overpass and a query the server abandoned
    /// are both "not this second"; the next request may well be admitted.
    @Test("a gateway refusal and an abandoned query are momentary")
    func busyIsAGatewayOrAnAbort() {
        for statusCode in [502, 503, 504] {
            #expect(
                OverpassRequest.isMomentarilyBusy(
                    TrailGraphProviderError.server(statusCode: statusCode)
                )
            )
        }
        #expect(
            OverpassRequest.isMomentarilyBusy(
                TrailGraphProviderError.aborted("runtime error: Query timed out")
            )
        )
    }

    /// **A `429` is not momentary and must never be treated as one.** It names
    /// the seconds it wants to be left alone, and asking again inside them is
    /// what turns one rate limit into a block — against an address shared by
    /// everyone on that network.
    @Test("a rate limit is not a momentary condition")
    func aRateLimitIsNotMomentary() {
        #expect(!OverpassRequest.isMomentarilyBusy(
            TrailGraphProviderError.rateLimited(retryAfter: 60)
        ))
    }

    /// Nor is anything else. A 404 is this app asking the wrong question, a
    /// body that would not decode is one nobody here can claim to understand,
    /// and neither is improved by being asked twice.
    @Test("everything else is answered once")
    func nothingElseIsRetried() {
        let errors: [any Error] = [
            TrailGraphProviderError.server(statusCode: 404),
            TrailGraphProviderError.invalidResponse,
            TrailGraphProviderError.malformedGraph("not JSON"),
            TrailGraphProviderError.storage("no room"),
            URLError(.notConnectedToInternet),
        ]

        for error in errors {
            #expect(!OverpassRequest.isMomentarilyBusy(error))
        }
    }

    /// The `200` that is not an answer — see ``OverpassRequest/abort(_:)``.
    /// The remark is the whole signal, so an absent or blank one has to read
    /// as *nothing to report* rather than as an empty failure.
    @Test("a remark is a failure and nothing else is")
    func onlyARemarkIsAnAbort() {
        #expect(OverpassRequest.abort(nil) == nil)
        #expect(OverpassRequest.abort("") == nil)
        #expect(OverpassRequest.abort("   \n ") == nil)
        #expect(
            OverpassRequest.abort("runtime error: Query timed out")
                == .aborted("runtime error: Query timed out")
        )
    }

    /// The header a volunteer-run API asks for by name, on every request this
    /// app makes. Without it the traffic is anonymous against a service that
    /// asks not to be.
    @Test("every request identifies this app")
    func everyRequestIdentifiesItself() {
        let request = OverpassRequest.post("[out:json];", to: Self.endpoint, awaiting: 25)

        #expect(request.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent)
        #expect(request.httpMethod == "POST")
    }
}
