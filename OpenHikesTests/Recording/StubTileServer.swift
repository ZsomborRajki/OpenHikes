//
//  StubTileServer.swift
//  OpenHikesTests
//
//  What a suite's trail maker graph is read from instead of the OpenHikes
//  tile server: an answer for each path, and every request kept. No suite
//  reaches the server — see ``RoutingGraphServer``.
//

import Foundation
@testable import OpenHikes
import Synchronization

/// The tile server as a suite scripts it.
///
/// `final class` behind a `Mutex`, for the reason ``StubTrailCellDatabase``
/// gives: the reader's requirement is `@concurrent`, so requests arrive off
/// the main actor.
nonisolated final class StubTileServer: Sendable {
    struct Answer: Sendable {
        private static let okStatus = 200
        private static let notFoundStatus = 404
        static let notFound = Self(status: notFoundStatus)

        var status: Int
        var body = Data()

        /// A `200` carrying `body`.
        static func ok(_ body: Data) -> Self {
            Self(status: okStatus, body: body)
        }
    }

    private struct State {
        /// Each path's answers, given in turn; the last one is given again.
        var answers: [String: [Answer]]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    /// - Parameter answers: What each path, from the server's root without
    ///   its leading slash, answers. A path with none answers 404.
    init(_ answers: [String: [Answer]]) {
        state = Mutex(State(answers: answers))
    }

    /// Gives `path` these answers from now on.
    func answer(_ path: String, with answers: [Answer]) {
        state.withLock { $0.answers[path] = answers }
    }

    /// The paths asked for, in order.
    var paths: [String] {
        state.withLock { $0.requests.compactMap { $0.url.map { String($0.path().dropFirst()) } } }
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    var transport: RoutingGraphServer.Transport {
        { request in self.respond(to: request) }
    }

    private func respond(to request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(filePath: "/")
        let path = String(url.path().dropFirst())
        let answer = state.withLock { state -> Answer in
            state.requests.append(request)
            guard var queued = state.answers[path], let first = queued.first else { return .notFound }
            if queued.count > 1 {
                queued.removeFirst()
                state.answers[path] = queued
            }
            return first
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: [:])
        return (answer.body, response ?? HTTPURLResponse())
    }

    /// A tile server's `manifest.json` that lists `routing`, newest first, at
    /// `revision`.
    static func manifest(revision: Int, routing: [RoutingGraphServer.Listing.Archive]) -> Answer {
        let listing = RoutingGraphServer.Listing(version: 1, revision: revision, routing: routing)
        return .ok((try? JSONEncoder().encode(listing)) ?? Data())
    }
}
