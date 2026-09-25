//
//  OverpassRequest.swift
//  OpenHikes
//
//  How this app asks Overpass anything, in one place.
//
//  There are three callers and they are unrelated —
//  ``OverpassTrailGraphProvider`` fetching the walking graph a recording is
//  matched against, ``CuratedTrailSource`` fetching the waymarked routes the
//  community list offers, and ``TrailPointSource`` fetching the places along a
//  trail. What they share is not logic but *manners*: the same identifying
//  `User-Agent`, the same form encoding, the same arithmetic behind how long
//  to wait, the same reading of a `429` and its `Retry-After` — and the same
//  reading of the failure that arrives dressed as a success, see
//  ``abort(_:)``.
//
//  Those are the half a volunteer-run API notices, and the half that would
//  drift silently if it were written twice. A second copy that forgot the
//  `User-Agent` would not fail a test or a build; it would make this app
//  anonymous traffic against a service that asks not to be, and nothing in the
//  tree would say so.
//

import Foundation

/// The shape of every Overpass request this app makes, and the reading of
/// every response.
nonisolated enum OverpassRequest {
    /// The public Overpass instance both callers ask by default.
    ///
    /// Here rather than spelled at each `init` for the reason the rest of this
    /// file is here: two copies of a host name is the drift nobody notices.
    /// Changing mirrors by editing one of two literals leaves the other
    /// pointed at the old one, and nothing fails a test or a build until a
    /// hiker's request 404s.
    static let defaultEndpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// How long to wait after a `429` that names no `Retry-After`, in seconds.
    static let defaultRetryDelay: TimeInterval = 60

    /// The longest Overpass holds a request before a slot frees, in seconds.
    ///
    /// Its own figure: "requests stay enqueued up to 15 seconds on the server
    /// if not yet a slot is available to them". It is dead time on the wire —
    /// the query has not started, so nothing is sent — which is exactly the
    /// time a client idle timeout is counting.
    static let queueAllowance: TimeInterval = 15

    /// What the answer itself is allowed to take once the query is done, in
    /// seconds.
    ///
    /// A geometry page is 420 KB to 1.4 MB — see
    /// ``CuratedTrailQuery/geometryBatchLimit`` — and the hiker asking for it
    /// is by disposition somewhere with one bar of signal.
    static let transferAllowance: TimeInterval = 20

    /// How long to leave a request that has gone quiet, for a query that asked
    /// the server for `serverTimeout` seconds.
    ///
    /// **Derived rather than flat, because a flat one was below the sum it has
    /// to cover.** `URLRequest.timeoutInterval` is an *idle* timeout, and
    /// Overpass sends nothing at all until the query is finished: the silence
    /// a client sits through is the queue wait plus the whole execution. The
    /// old 35 seconds sat under a `[timeout:30]` query with 15 seconds of
    /// queue in front of it, so the socket could be cancelled while the server
    /// was still working — and a cancelled socket says nothing, where the
    /// answer that was coming would have said *rate-limited*, *busy*, or here
    /// are your trails.
    ///
    /// The server also overruns its own limit: measured against
    /// `overpass-api.de` (0.7.62.11) on 2026-09-17, a `[timeout:2]` query was
    /// aborted after 39 seconds, because the limit is checked where the
    /// evaluation reaches a boundary rather than on a timer. That is what the
    /// transfer allowance is really buying on top of the queue — slack for a
    /// server clock that is not a clock.
    static func idleTimeout(forServerTimeout serverTimeout: Int) -> TimeInterval {
        queueAllowance + TimeInterval(serverTimeout) + transferAllowance
    }

    /// How long to leave a server that answered *busy* before asking again.
    ///
    /// Short, because the condition it is about is short: a dispatcher
    /// refusal means every slot was taken at the instant we knocked, which is
    /// the ordinary weather of a shared instance rather than a state that
    /// takes a minute to clear. The `429` this is deliberately *not* used for
    /// is the one that takes a minute, and it names its own wait.
    static let busyRetryDelay: TimeInterval = 2

    /// Whether `error` is Overpass saying *not this second*, as opposed to
    /// *not you* or *not at all*.
    ///
    /// The three that qualify are a gateway refusing before the query starts,
    /// an overloaded dispatcher, and a query the server abandoned — all of
    /// which the next request may well be admitted for. A `429` is excluded on
    /// purpose: it is a request to stop asking for a named number of seconds,
    /// and asking again inside it is what turns one rate limit into a block.
    static func isMomentarilyBusy(_ error: any Error) -> Bool {
        guard let overpass = error as? TrailGraphProviderError else { return false }
        switch overpass {
        case .aborted:
            return true
        case .server(let statusCode):
            return busyStatusCodes.contains(statusCode)
        case .invalidResponse, .malformedGraph, .rateLimited, .storage:
            return false
        }
    }

    /// What a gateway in front of a busy Overpass answers with.
    ///
    /// `504` is the measured one — the dispatcher refusing before the query
    /// starts — and the other two are its neighbours: every one of them is a
    /// server saying it cannot serve this *now*.
    static let busyStatusCodes: Set<Int> = [badGatewayCode, serviceUnavailableCode, gatewayTimeoutCode]

    private static let successRange = 200..<300
    private static let rateLimitCode = 429
    private static let badGatewayCode = 502
    private static let serviceUnavailableCode = 503
    private static let gatewayTimeoutCode = 504

    /// A POST of `query` to `endpoint`, formed the way Overpass expects.
    ///
    /// The body goes through `URLComponents.percentEncodedQuery` rather than
    /// being assembled by hand, because an Overpass query is full of
    /// characters that are structural in a form body — `;`, `=`, `&`, `+` all
    /// appear in ordinary filters, and one of them unescaped truncates the
    /// query into something that parses and means something else.
    /// - Parameter serverTimeout: The `[timeout:]` the query itself carries,
    ///   which is what the client's own patience is derived from — see
    ///   ``idleTimeout(forServerTimeout:)``. Passed rather than parsed out of
    ///   the query so that the caller that wrote the number is the one that
    ///   states it.
    static func post(
        _ query: String,
        to endpoint: URL,
        awaiting serverTimeout: Int
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = idleTimeout(forServerTimeout: serverTimeout)
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The one header a volunteer-run API asks for by name. See
        // ``TileCache/userAgent``, which is where the string is built and
        // which `TileUserAgentTests` holds to its shape.
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    /// The body of a successful response, or the typed failure it was.
    ///
    /// A `429` becomes ``TrailGraphProviderError/rateLimited(retryAfter:)``
    /// carrying whatever `Retry-After` said, which is what lets a caller stop
    /// asking rather than retry into the same refusal.
    static func body(of response: OverpassHTTPResponse) throws -> Data {
        switch response.statusCode {
        case successRange:
            return response.data
        case rateLimitCode:
            let delay = response.headers["retry-after"]
                .flatMap(TimeInterval.init) ?? defaultRetryDelay
            throw TrailGraphProviderError.rateLimited(retryAfter: delay)
        default:
            throw TrailGraphProviderError.server(statusCode: response.statusCode)
        }
    }

    /// The failure a `200` is carrying, if it is carrying one.
    ///
    /// **An aborted query answers with HTTP 200 and well-formed JSON.**
    /// Measured against `overpass-api.de` (0.7.62.11) on 2026-09-17: a query
    /// the server gave up on came back `200`, with `"elements": []` and
    ///
    ///     "remark": "runtime error: Query timed out in \"query\" at line 1
    ///                after 39 seconds."
    ///
    /// Nothing about the status line or the shape of the body says anything is
    /// wrong, which is why this has to be read explicitly: a caller that only
    /// decodes `elements` reads *the server gave up* as *there is nothing
    /// here*, and in this app that is the difference between a caption saying
    /// OpenStreetMap is busy and one telling a hiker there are no trails where
    /// they are standing.
    ///
    /// A partial answer wears the same remark — the elements are whatever had
    /// been collected when the clock ran out, which is a biased slice of an
    /// area rather than a short answer about it — so this is read *instead of*
    /// the rows rather than beside them. What the caller draws in their place
    /// is its own decision; see ``MergedCommunityTransport``'s fall back to
    /// the routes already on the device.
    ///
    /// The other runtime errors arrive the same way and are the same kind of
    /// thing: `Query run out of memory` for one past `[maxsize:]`, and the
    /// dispatcher's `request_read_and_idx::timeout` when the server is too
    /// busy to start at all. They are one case here because there is one thing
    /// a hiker can do about any of them.
    static func abort(_ remark: String?) -> TrailGraphProviderError? {
        guard let remark, !remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return .aborted(remark)
    }

    /// The live transport both callers use unless a suite hands them one of
    /// its own — see *Deliberate test seams* in the repository instructions.
    ///
    /// It is three steps and the middle one is the reason this is here rather
    /// than written at each `init`: an Overpass mirror that answers something
    /// other than HTTP, or a proxy that answers nothing at all, arrives as a
    /// `URLResponse` that is not an `HTTPURLResponse`, and a caller that
    /// force-cast it would trap on a bad network instead of reporting one. The
    /// `guard` is the whole difference and it was written twice.
    ///
    /// Reading the headers here rather than at the call site is the other
    /// half: ``headers(of:)`` exists because mirrors vary in the case they
    /// send, and a transport that skipped it would hand its caller a
    /// dictionary the rate-limit reader cannot look anything up in.
    ///
    /// - Parameter span: A MetricKit span to time the request inside, for the
    ///   one caller whose request is an unavoidable radio wake-up during a
    ///   hike. The curated-trail fetch passes none: it happens with the app in
    ///   the hiker's hand and is not the wake-up worth the telemetry budget —
    ///   see the note at the top of ``FieldSignpost``.
    static func liveTransport(
        timing span: FieldSignpost.Span? = nil
    ) -> @Sendable (URLRequest) async throws -> OverpassHTTPResponse {
        { request in
            let token = span.map(FieldSignpost.begin)
            defer {
                if let token { FieldSignpost.end(token) }
            }
            let (data, urlResponse) = try await URLSession.shared.data(for: request)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw TrailGraphProviderError.invalidResponse
            }
            return OverpassHTTPResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                headers: headers(of: httpResponse)
            )
        }
    }

    /// Lowercased header names, the way both callers read them.
    ///
    /// `HTTPURLResponse.allHeaderFields` preserves whatever case the server
    /// sent, and Overpass mirrors vary — a lookup for `"retry-after"` against
    /// an unnormalised dictionary misses a `Retry-After` and turns a
    /// rate-limit into a sixty-second guess.
    static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return headers
    }
}
