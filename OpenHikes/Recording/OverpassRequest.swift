//
//  OverpassRequest.swift
//  OpenHikes
//
//  How this app asks Overpass anything, in one place.
//
//  There are two callers and they are unrelated — ``OverpassTrailGraphProvider``
//  fetching the walking graph a recording is matched against, and
//  ``CuratedTrailSource`` fetching the waymarked routes the community list
//  offers. What they share is not logic but *manners*: the same identifying
//  `User-Agent`, the same form encoding, the same client timeout, and the same
//  reading of a `429` and its `Retry-After`.
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

    /// How long the client waits before giving up, in seconds.
    ///
    /// Above the `[timeout:]` each query carries, so the server's own limit is
    /// what ends a slow query and the app gets a diagnosable answer rather
    /// than a cancelled socket.
    static let timeoutInterval: TimeInterval = 35

    /// How long to wait after a `429` that names no `Retry-After`, in seconds.
    static let defaultRetryDelay: TimeInterval = 60

    private static let successRange = 200..<300
    private static let rateLimitCode = 429

    /// A POST of `query` to `endpoint`, formed the way Overpass expects.
    ///
    /// The body goes through `URLComponents.percentEncodedQuery` rather than
    /// being assembled by hand, because an Overpass query is full of
    /// characters that are structural in a form body — `;`, `=`, `&`, `+` all
    /// appear in ordinary filters, and one of them unescaped truncates the
    /// query into something that parses and means something else.
    static func post(_ query: String, to endpoint: URL) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
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
