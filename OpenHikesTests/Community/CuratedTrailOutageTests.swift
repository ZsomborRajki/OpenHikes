//
//  CuratedTrailOutageTests.swift
//  OpenHikesTests
//
//  The reading of an Overpass failure, and the one sentence it turns into.
//
//  Small, and worth having anyway: this is the only place that decides whether
//  a thrown error is something to put under the *Search this area* button. Two
//  of its three answers are easy to get wrong in a way nothing else would
//  catch — a cancelled search must not caption the button, and a `429` must
//  keep its `Retry-After`, since a notice that said only *unavailable* would
//  leave the hiker retrying into the same refusal.
//
//  Nothing here asserts the *wording* of the notice. It is a localised string
//  built through `Duration.UnitsFormatStyle`, so an assertion on its text
//  would be an assertion about the simulator's locale — see the repository
//  instructions on why a regional figure is never pinned in a test.
//

import Foundation
@testable import OpenHikes
import Testing

/// What an Overpass failure amounts to, as far as the map's button is
/// concerned.
@Suite("Curated trail outage")
struct CuratedTrailOutageTests {
    /// The wait is the whole difference between this case and the other one.
    /// It is what the notice counts down and what makes *try again* advice
    /// rather than a guess.
    @Test("a rate limit keeps the interval it was refused for")
    func rateLimitKeepsItsWait() {
        let outage = CuratedTrailOutage(
            TrailGraphProviderError.rateLimited(retryAfter: 60)
        )

        #expect(outage == .rateLimited(retryAfter: 60))
    }

    /// The server saying *not this second*: a gateway refusing in front of
    /// Overpass, and a query it started and abandoned — the `200` that is not
    /// an answer, see ``OverpassRequest/abort(_:)``.
    ///
    /// Its own case rather than more of ``unavailable`` because the two ask
    /// different things of the hiker. *Unavailable* reads as *you are offline*
    /// and sends somebody looking for signal on a mountain that has none; a
    /// busy public instance is a shared server with a queue, and the answer is
    /// to tap again in a moment.
    @Test("a busy server is a different sentence from an unreachable one")
    func aBusyServerIsItsOwnCase() {
        let errors: [any Error] = [
            TrailGraphProviderError.server(statusCode: 504),
            TrailGraphProviderError.server(statusCode: 503),
            TrailGraphProviderError.aborted("runtime error: Query timed out"),
        ]

        for error in errors {
            #expect(CuratedTrailOutage(error) == .busy)
        }
        #expect(CuratedTrailOutage.busy.text != CuratedTrailOutage.unavailable.text)
    }

    /// Everything left: no network, a status code that is not about load, or
    /// an answer nobody here can claim to understand. One sentence covers them
    /// because there is one thing for the hiker to do about any of them.
    @Test("every other failure is the one honest generality")
    func otherFailuresAreUnavailable() {
        let errors: [any Error] = [
            TrailGraphProviderError.server(statusCode: 404),
            TrailGraphProviderError.invalidResponse,
            TrailGraphProviderError.malformedGraph("not JSON"),
            URLError(.notConnectedToInternet),
        ]

        for error in errors {
            #expect(CuratedTrailOutage(error) == .unavailable)
        }
    }

    /// The case that must answer nothing. A superseded search cancels the
    /// curated half mid-flight, and reporting that as an outage would caption
    /// the button *rate-limited* because the hiker panned twice quickly.
    @Test("a cancellation is not an outage")
    func cancellationReportsNothing() {
        #expect(CuratedTrailOutage(CancellationError()) == nil)
    }

    /// Both cases have something to say, and they do not say the same thing —
    /// which is the only claim about the text that holds in every locale.
    @Test("each outage has a notice of its own")
    func eachOutageSaysSomething() {
        let limited = CuratedTrailOutage.rateLimited(retryAfter: 60).text
        let unavailable = CuratedTrailOutage.unavailable.text

        #expect(!limited.isEmpty)
        #expect(!unavailable.isEmpty)
        #expect(limited != unavailable)
    }

    /// A wait that has already run out is not something to promise a hiker.
    /// `CuratedTrailSource` recomputes what is left on every refused tap, so
    /// zero is reachable and has to drop the figure rather than print `0 sec`.
    @Test("an expired wait is left off the notice")
    func anExpiredWaitIsOmitted() {
        #expect(
            CuratedTrailOutage.rateLimited(retryAfter: 0).text
                != CuratedTrailOutage.rateLimited(retryAfter: 60).text
        )
    }
}
