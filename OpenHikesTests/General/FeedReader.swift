//
//  FeedReader.swift
//  OpenHikesTests
//
//  Reads one ``EventFeed`` stream the way `OpenHikesView` does, and keeps
//  what arrived.
//

import Foundation

/// Everything a stream delivered while this was reading it, in order.
///
/// Reading is asynchronous — the stream is drained by a task of its own, as
/// the view's `.task` drains it — so a suite waits for what it expects with
/// `settleDelegateHop(until:)` rather than checking straight after the send.
/// Take the stream before sending: it is asked for when the caller builds
/// this, so nothing sent afterwards is missed however late the task first
/// runs, and nothing sent before is ever seen.
@MainActor
final class FeedReader<Element: Sendable> {
    var received: [Element] { log.items }

    private let log = Log()
    private let reader: Task<Void, Never>

    init(_ events: AsyncStream<Element>) {
        reader = Task { [log] in
            for await element in events {
                log.items.append(element)
            }
        }
    }

    /// Ends the read, which is also what takes this reader out of its feed —
    /// the same termination a torn-down view's task causes.
    func stop() {
        reader.cancel()
    }

    nonisolated deinit {
        reader.cancel()
    }

    @MainActor
    private final class Log {
        var items: [Element] = []
    }
}
