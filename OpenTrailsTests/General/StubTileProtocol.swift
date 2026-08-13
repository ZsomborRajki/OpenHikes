//
//  StubTileProtocol.swift
//  OpenTrailsTests
//
//  A `URLProtocol` that answers every tile request from a script the test
//  writes, and records what was asked for.
//
//  A `URLProtocol` rather than a closure swapped in for `URLSession.data`,
//  because half of what's worth testing here is what URLSession itself
//  produces: the User-Agent OSM's usage policy requires, the request that
//  a cache hit is supposed to *not* make, and the two separate requests the
//  map and the bulk downloader currently make for the same tile. A stub
//  further up would take all of that on trust.
//

import Foundation
@testable import OpenTrails
import Synchronization

/// `@unchecked` because of the superclass: `URLProtocol` is not declared
/// `Sendable` by the SDK. The one piece of shared state is a `Mutex`.
nonisolated final class StubTileProtocol: URLProtocol, @unchecked Sendable {
    private static let httpOK = 200

    /// What the tile server says back.
    struct Response: Sendable {
        var statusCode: Int = 200
        var data = Data()
        var headers: [String: String] = [:]
        /// Answer with a `URLResponse` that isn't an `HTTPURLResponse` — the
        /// case `fetchTile` refuses before it looks at any status code.
        var isHTTP: Bool = true
        /// Fail at the transport layer instead of answering at all.
        var failure: URLError?

        /// A real, decodable PNG — what a tile server actually sends.
        static func tile(statusCode: Int = 200, headers: [String: String] = [:]) -> Self {
            Self(statusCode: statusCode, data: TileStore.tileData, headers: headers)
        }

        /// A 200 carrying something that isn't an image: a captive-portal
        /// login page, an HTML error body, a truncated download.
        static func undecodable(_ body: String = "<html>Rate limited</html>") -> Self {
            Self(statusCode: httpOK, data: Data(body.utf8))
        }

        static func status(_ code: Int) -> Self {
            Self(statusCode: code, data: Data("error".utf8))
        }
    }

    private struct State {
        var responder: (@Sendable (URL) -> Response)?
        var requests: [URLRequest] = []
        /// Held open until the test releases them, so two overlapping
        /// requests for the same tile can be observed as overlapping.
        var delay: Duration?
    }

    private static let state = Mutex(State())

    /// A session configuration that routes every request here.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTileProtocol.self]
        return configuration
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    /// Answers every request the same way.
    static func alwaysRespond(with response: Response) {
        state.withLock { $0.responder = { _ in response } }
    }

    /// Answers per URL — for tier-precedence tests, where the point is which
    /// tile was asked for.
    static func respond(_ responder: @escaping @Sendable (URL) -> Response) {
        state.withLock { $0.responder = responder }
    }

    /// Holds every response open for `duration`, so concurrent requests
    /// genuinely overlap rather than completing one after another.
    static func setDelay(_ duration: Duration?) {
        state.withLock { $0.delay = duration }
    }

    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static var requestCount: Int { state.withLock { $0.requests.count } }

    static func requestCount(forPathSuffix suffix: String) -> Int {
        state.withLock { $0.requests.filter { $0.url?.path.hasSuffix(suffix) ?? false }.count }
    }

    // MARK: URLProtocol

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let (response, delay) = Self.state.withLock { state -> (Response?, Duration?) in
            state.requests.append(request)
            return (state.responder.map { $0(request.url ?? URL(string: "https://example.invalid")!) }, state.delay)
        }

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // No script for this URL is a test bug, not a server behaviour —
        // surface it as a distinctive failure rather than a silent empty body.
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        Task {
            if let delay { try? await Task.sleep(for: delay) }
            self.deliver(response, for: url)
        }
    }

    override func stopLoading() { /* no-op: responses are delivered asynchronously */ }

    private func deliver(_ response: Response, for url: URL) {
        if let failure = response.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        let urlResponse: URLResponse
        if response.isHTTP {
            guard let http = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            urlResponse = http
        } else {
            urlResponse = URLResponse(
                url: url,
                mimeType: "image/png",
                expectedContentLength: response.data.count,
                textEncodingName: nil
            )
        }

        client?.urlProtocol(self, didReceive: urlResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A ``TileSandbox`` whose transport is this scripted `URLProtocol`, so a test
/// owns everything the cache can see: its two directories, its auto-save
/// store, and every response it gets back.
struct StubbedTileCache {
    let sandbox: TileSandbox

    var cache: TileCache { sandbox.cache }
    var store: AutoSaveTileStore { sandbox.store }
    var root: URL { sandbox.root }

    init(reachable: Bool = true) {
        StubTileProtocol.reset()
        sandbox = TileSandbox(
            reachable: reachable,
            sessionConfiguration: StubTileProtocol.sessionConfiguration()
        )
    }

    func browsedFile(for key: String) -> URL { sandbox.browsedFile(for: key) }
    func savedFile(for key: String) -> URL { sandbox.savedFile(for: key) }
    func isBrowsed(_ key: String) -> Bool { sandbox.isBrowsed(key) }
    func isSaved(_ key: String) -> Bool { sandbox.isSaved(key) }

    /// Puts a tile in a tier directly, as a previous session would have left it.
    func place(_ key: String, in file: URL, agedByDays days: Double = 0) throws {
        try sandbox.place(key, in: file, agedByDays: days)
    }

    /// Clears the process-wide response script. The directories go with the
    /// sandbox when it falls out of scope.
    func tearDown() {
        StubTileProtocol.reset()
    }
}
