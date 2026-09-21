//
//  OverpassConversation.swift
//  OpenHikes
//
//  One request to Overpass, made politely, by whichever feature is asking.
//
//  ``OverpassRequest`` is the *manners* — the identifying `User-Agent`, the
//  form encoding, the reading of a `429` and of the failure that arrives
//  dressed as a `200`. This is the **policy** that sits on top of them, and it
//  is the half that was written twice before there was a third caller to write
//  it a third time:
//
//  - a `429` names the seconds it wants to be left alone, so the *next*
//    request is refused before it leaves rather than after it is turned away;
//  - a refusal that came back *quickly* is a dispatcher saying every slot was
//    taken at the instant we knocked, and one more knock is usually admitted;
//  - a refusal that arrives after the whole budget is a server that spent the
//    budget, and asking again buys another minute of the same.
//
//  Those three sentences are about the service rather than about trails,
//  places or graphs, which is why they live here now. ``CuratedTrailSource``
//  and ``TrailPointSource`` both hold one of these; what stays theirs is what
//  they ask and what they do with the answer.
//
//  **``OverpassTrailGraphProvider`` deliberately keeps its own.** It is not a
//  third copy of this: it has no busy retry at all, because its unit of work
//  is a z12 tile shared with every other caller and its answer to a refusal is
//  to skip the region and assemble what it has. What it shares is the
//  rate-limit gate, which is four lines, and folding a coalescing tile
//  downloader into a per-request policy object to save them would be the tail
//  wagging the dog.
//
//  ## The decode is inside the retry, and has to be
//
//  Half of what *busy* looks like arrives as an HTTP 200 carrying a `remark`
//  — see ``OverpassRequest/abort(_:)`` — so a retry wrapped around the request
//  alone would miss the half that never reaches a status line. That is why
//  this takes a decoding closure rather than answering `Data`: the caller's
//  own parser is what turns that body into the typed failure this retries on.
//

import Foundation
import os

/// The rate-limit gate and the one busy retry, in front of one Overpass
/// endpoint.
///
/// An actor for the reason its two owners are: the deadline a `429` sets is
/// mutable state that arrives from concurrent requests, and two of them
/// refused at once must not be able to disagree about which deadline holds.
actor OverpassConversation {
    typealias Transport = @Sendable (URLRequest) async throws -> OverpassHTTPResponse

    private static let logger = Logger(subsystem: "OpenHikes", category: "Overpass")

    /// How long a busy answer may have taken and still be worth asking again,
    /// in seconds.
    ///
    /// Above a dispatcher refusal, which is immediate — 8 seconds measured
    /// against `overpass-api.de` on 2026-09-17, and 9 seconds measured again
    /// on 2026-09-21 — and well below the whole budget a query that ran and
    /// was abandoned spends. See ``retryingWhenBusy(_:)``.
    private static let busyRetryCeiling: TimeInterval = 20

    private let endpoint: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date
    /// How this waits between a busy answer and asking once more.
    ///
    /// A seam beside ``clock`` and for the same reason: the retry below is
    /// only observable against time somebody else is holding, and a suite that
    /// waited two real seconds per case would be a suite nobody runs. See
    /// *Deliberate test seams* in the repository instructions.
    private let pause: @Sendable (TimeInterval) async throws -> Void
    /// What this conversation is about, for the log line a rate limit writes.
    /// Two words, because it is read in Console beside a delay and nothing
    /// else.
    private let subject: String

    /// When Overpass will accept another request, if it has told us to wait.
    private var retryAfter: Date?

    init(
        subject: String,
        endpoint: URL = OverpassRequest.defaultEndpoint,
        clock: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        transport: Transport? = nil
    ) {
        self.subject = subject
        self.endpoint = endpoint
        self.clock = clock
        self.pause = pause
        self.transport = transport ?? OverpassRequest.liveTransport()
    }

    /// Throws while a `429`'s `Retry-After` is still running.
    ///
    /// Checked before a request rather than after, so a rate-limited hiker
    /// costs nothing at all rather than one refused round trip per tap.
    ///
    /// Callable on its own as well as through ``fetch(_:awaiting:decoding:)``,
    /// because one of the callers has a loop to get out of rather than a
    /// request to make — see ``CuratedTrailSource``'s `gather`.
    func checkRateLimit() throws {
        guard let retryAfter, retryAfter > clock() else { return }
        throw TrailGraphProviderError.rateLimited(
            retryAfter: retryAfter.timeIntervalSince(clock())
        )
    }

    /// Runs one pass: the gate, the request, the caller's own decode, and one
    /// more attempt when the server answered *not this second*.
    ///
    /// - Parameters:
    ///   - serverTimeout: The `[timeout:]` this query carries, which decides
    ///     how long the client waits on it — see
    ///     ``OverpassRequest/idleTimeout(forServerTimeout:)``. Stated by the
    ///     caller that chose the query rather than parsed back out of it.
    ///   - decoding: What turns the body into an answer, and what turns a
    ///     `200` carrying a `remark` into the failure it is. Inside the retry
    ///     deliberately; see this file's header.
    func fetch<T: Sendable>(
        _ query: String,
        awaiting serverTimeout: Int,
        decoding: @Sendable (Data) throws -> T
    ) async throws -> T {
        try checkRateLimit()
        return try await retryingWhenBusy {
            try decoding(try await send(query, awaiting: serverTimeout))
        }
    }

    /// Runs `work`, and runs it once more when the server answered *not this
    /// second*.
    ///
    /// **One retry, and only for a refusal that came back quickly.** A
    /// dispatcher refusal means every slot was taken at the instant we
    /// knocked and the next request is often admitted; a refusal that arrives
    /// after the whole budget is a different animal — the server spent that
    /// budget and gave up, so asking again buys another minute of the same,
    /// and a pill would spin for two minutes to reach the sentence it could
    /// have drawn after one. ``OverpassRequest/busyRetryDelay`` is the pause
    /// between them, short because the condition is.
    ///
    /// A `429` is not retried and must not be: it names the seconds it wants
    /// to be left alone, and ``checkRateLimit()`` refuses the second attempt
    /// anyway — which is also why this re-checks it, since a parallel request
    /// can be refused during the pause.
    private func retryingWhenBusy<T>(_ work: () async throws -> T) async throws -> T {
        let startedAt = clock()
        do {
            return try await work()
        } catch {
            guard OverpassRequest.isMomentarilyBusy(error),
                  clock().timeIntervalSince(startedAt) < Self.busyRetryCeiling
            else { throw error }
            let waited = Int(clock().timeIntervalSince(startedAt))
            Self.logger.notice(
                "Overpass was busy after \(waited, privacy: .public)s; asking once more."
            )
            try await pause(OverpassRequest.busyRetryDelay)
            try Task.checkCancellation()
            try checkRateLimit()
            return try await work()
        }
    }

    /// One request, and the reading of a `429` into the gate above.
    private func send(_ query: String, awaiting serverTimeout: Int) async throws -> Data {
        try Task.checkCancellation()
        let response = try await transport(
            OverpassRequest.post(query, to: endpoint, awaiting: serverTimeout)
        )
        do {
            return try OverpassRequest.body(of: response)
        } catch let error as TrailGraphProviderError {
            if case .rateLimited(let delay) = error {
                // `max` rather than assignment: two requests can be refused at
                // once, and the later deadline is the one that holds.
                let candidate = clock().addingTimeInterval(delay)
                retryAfter = max(retryAfter ?? .distantPast, candidate)
                // Read into a local first: an interpolation inside
                // `Logger`'s autoclosure is a capture, so naming the property
                // there needs an explicit `self` — which is the one thing
                // `redundant_self` will not allow. The local satisfies both.
                let asked = subject
                Self.logger.error(
                    """
                    Overpass rate-limited \(asked, privacy: .public) \
                    for \(delay, privacy: .public)s.
                    """
                )
            }
            throw error
        }
    }
}
