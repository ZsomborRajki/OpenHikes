//
//  CommonsRequestGate.swift
//  OpenHikes
//
//  One request at a time to Wikimedia Commons' Action API, from the whole
//  app.
//
//  Wikimedia's robot policy asks a client for one request in flight to the
//  Action API, and three things here ask it: a route's or an area's
//  photographs (``WikimediaCommonsSource``), a place card's photograph
//  (``WikidataPlaceSource``) and a saved copy downloaded again
//  (``CommonsPhotoRefetch``). Each kept its own requests in order, and nothing
//  kept them from each other: a copy still downloading after its screen had
//  gone could ask while a Community search did. So each asks through this.
//
//  Only the Action API. The pictures come from Wikimedia's image servers,
//  which a browser showing a gallery asks in parallel, and every caller
//  downloads them outside the gate.
//
//  A source that reaches the network goes through ``shared``. One handed a
//  transport — a suite's — gets a gate of its own, which is what keeps a
//  suite off the app's singleton: see *Deliberate test seams* in the
//  repository instructions.
//

import Foundation

/// Lets one Action API request through at a time, in the order they came.
actor CommonsRequestGate {
    /// The app's: every source that reaches the network asks through it.
    static let shared = CommonsRequestGate()

    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// The gate for a source: ``shared`` for one that reaches the network,
    /// and a new one for a suite's, which was handed a transport.
    static func forSource(reachingNetwork: Bool) -> CommonsRequestGate {
        reachingNetwork ? shared : CommonsRequestGate()
    }

    /// How many requests are waiting for the one in flight, for a suite that
    /// has to know one is before it lets the first finish.
    var waitingCount: Int { waiting.count }

    private func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate straight to the next request, so none can slip in
    /// between.
    private func leave() {
        guard !waiting.isEmpty else {
            isBusy = false
            return
        }
        waiting.removeFirst().resume()
    }
}

extension CommonsRequestGate {
    /// Runs `request` once every request that came before it has finished,
    /// and lets the next one through when it has, whether it threw or not.
    ///
    /// A request whose caller was cancelled while it waited still takes its
    /// turn, which costs nothing: `URLSession` refuses a cancelled task at
    /// once.
    nonisolated func run<Value>(_ request: () async throws -> Value) async throws -> Value {
        await enter()
        do {
            let value = try await request()
            await leave()
            return value
        } catch {
            await leave()
            throw error
        }
    }
}
