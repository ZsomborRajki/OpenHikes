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
import os
@testable import OpenTrails

final class StubTileProtocol: URLProtocol, @unchecked Sendable {
    /// What the tile server says back.
    struct Response: Sendable {
        var statusCode: Int = 200
        var data: Data = Data()
        var headers: [String: String] = [:]
        /// Answer with a `URLResponse` that isn't an `HTTPURLResponse` — the
        /// case `fetchTile` refuses before it looks at any status code.
        var isHTTP: Bool = true
        /// Fail at the transport layer instead of answering at all.
        var failure: URLError?

        /// A real, decodable PNG — what a tile server actually sends.
        static func tile(statusCode: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(statusCode: statusCode, data: TileStore.tileData, headers: headers)
        }

        /// A 200 carrying something that isn't an image: a captive-portal
        /// login page, an HTML error body, a truncated download.
        static func undecodable(_ body: String = "<html>Rate limited</html>") -> Response {
            Response(statusCode: 200, data: Data(body.utf8))
        }

        static func status(_ code: Int) -> Response {
            Response(statusCode: code, data: Data("error".utf8))
        }
    }

    private struct State {
        var responder: (@Sendable (URL) -> Response)?
        var requests: [URLRequest] = []
        /// Held open until the test releases them, so two overlapping
        /// requests for the same tile can be observed as overlapping.
        var delay: Duration?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

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

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
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

    override func stopLoading() {}

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

/// A `TileCache` with its own directories and its own scripted transport, so
/// a test owns everything the cache can see. Nothing here touches the app's
/// real cache directories or `TileCache.shared`.
struct StubbedTileCache {
    let cache: TileCache
    let root: URL

    init(reachable: Bool = true) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilecache-\(UUID().uuidString)", isDirectory: true)
        StubTileProtocol.reset()
        cache = TileCache(
            storageRoot: root,
            sessionConfiguration: StubTileProtocol.sessionConfiguration(),
            monitorsNetwork: false
        )
        if !reachable { cache.setReachable(false) }
    }

    /// `TileCache` keeps its key→filename mapping private, so it's restated
    /// here exactly as `TileStore` does for the real directories.
    private func fileName(for key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "@", with: "_")
    }

    func browsedFile(for key: String) -> URL {
        root.appendingPathComponent("OSMTiles", isDirectory: true).appendingPathComponent(fileName(for: key))
    }

    func savedFile(for key: String) -> URL {
        root.appendingPathComponent("OSMTilesSaved", isDirectory: true).appendingPathComponent(fileName(for: key))
    }

    func isBrowsed(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: browsedFile(for: key).path)
    }

    func isSaved(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: savedFile(for: key).path)
    }

    /// Puts a tile in a tier directly, as a previous session would have left it.
    func place(_ key: String, in file: URL, agedByDays days: Double = 0) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try TileStore.tileData.write(to: file, options: .atomic)
        if days > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)],
                ofItemAtPath: file.path
            )
        }
    }

    func tearDown() {
        StubTileProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }
}
