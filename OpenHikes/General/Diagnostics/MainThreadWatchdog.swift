//
//  MainThreadWatchdog.swift
//  OpenHikes
//
//  Debug-only safeguard: a background thread repeatedly pings the main run
//  loop and logs whenever it doesn't answer within a frame budget. Doesn't
//  know *what* blocked the main thread — pause in Xcode (the debugger's pause
//  button, or a breakpoint) once a warning fires and check the main thread's
//  stack, or profile with Instruments' Time Profiler, to find out.
//

import Foundation
import os
import Synchronization

/// Fails a debug build if the calling thread is main — for the top of a
/// function whose cost (disk I/O, tile-grid enumeration, image encoding, …)
/// is documented as "must run off the main thread". Catches a future call
/// site that puts it back on main as an immediate crash in debug/Simulator
/// runs, instead of a silent hitch that only shows up as a dropped frame.
/// No-ops in release builds, same as `assert`.
@inline(__always)
nonisolated func assertOffMainThread(
    _ message: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    assert(!Thread.isMainThread, message(), file: file, line: line)
}

#if DEBUG
/// `nonisolated` because the watchdog's whole point is a background thread
/// that outlives any actor: the ping loop below reads these constants and the
/// logger from a `Thread`, and inheriting main-actor isolation from the
/// target's default would make every one of those reads a hop back onto the
/// thread being measured.
nonisolated enum MainThreadWatchdog {
    private static let logger = Logger(subsystem: "OpenHikes", category: "MainThreadWatchdog")

    /// Longer than this and a stall is worth knowing about — a dropped frame
    /// is ~16ms, but SwiftUI/UIKit routinely coalesce several; this is set
    /// well above that so only genuine hitches (e.g. synchronous disk I/O or
    /// O(thousands) work slipping onto the main thread) get logged.
    private static let warnThreshold: TimeInterval = 0.15
    private static let pingInterval: TimeInterval = 0.2
    private static let retryInterval: TimeInterval = 0.05

    /// One turn of the ping loop, reported whether or not the main thread
    /// stalled.
    struct Cycle: Sendable {
        /// How long the main thread took to answer, when that was longer than
        /// ``warnThreshold``. `nil` on a healthy cycle.
        ///
        /// Carried even though the only thing checking cycles today counts
        /// them, because a report of "a turn happened" that threw away what
        /// the turn found would be a strange thing to hand anyone, and this is
        /// the sole channel through which the stall figure is visible at all —
        /// the log is write-only from inside the process, and
        /// `PerformanceLog.shared` is `nil` outside a performance run.
        let stall: Duration?
    }

    /// An extra sink for every cycle, alongside the log.
    ///
    /// This is measurement infrastructure, and a watchdog that has quietly
    /// stopped turning scores perfectly against every budget in the
    /// performance suite — so that it is running at all has to be checkable,
    /// and it is not observable through either of the sinks this otherwise
    /// writes to: `Logger` is write-only from inside the process, and
    /// `PerformanceLog.shared` is a `static let` that is `nil` outside a
    /// `--ui-test-performance-log` launch.
    ///
    /// Read from inside the loop on every cycle rather than captured once at
    /// `start()`, because starting is once-only and the app has already done
    /// it before any test runs.
    private static let observer = Mutex<(@Sendable (Cycle) -> Void)?>(nil)

    /// Installs `body` as the cycle observer, replacing any previous one.
    /// Pass `nil` to remove it.
    static func observeCycles(_ body: (@Sendable (Cycle) -> Void)?) {
        observer.withLock { $0 = body }
    }

    /// Set on the main queue, polled from the watchdog thread. A reference box
    /// because the ping closure escapes, and `Atomic` — like `Mutex` — is
    /// non-copyable and so cannot itself be captured.
    private final class PingFlag: Sendable {
        private let answered = Atomic<Bool>(false)

        func markAnswered() { answered.store(true, ordering: .releasing) }

        var isAnswered: Bool { answered.load(ordering: .acquiring) }
    }

    /// Once-only start guard. `compareExchange` states the whole intent in one
    /// operation — "claim the start if nobody else has" — where a lock had to
    /// read, test and write as three.
    private static let hasStarted = Atomic<Bool>(false)

    /// Starts the watchdog. Safe to call more than once — only the first call
    /// takes effect. Call once, early, e.g. from the app's `init`.
    static func start() {
        let (claimed, _) = hasStarted.compareExchange(
            expected: false,
            desired: true,
            ordering: .relaxed
        )
        guard claimed else { return }

        // Deliberately a dedicated `Thread` rather than a `Task`: the
        // cooperative pool is one of the things a stall backs up (see
        // `CachingTileOverlayRenderer`'s note on tile loads jamming it), so a
        // watchdog scheduled on that pool would be starved by the very
        // condition it exists to report, and would time its own delay as the
        // main thread's. A watchdog has to be scheduled independently of
        // everything it measures.
        let thread = Thread {
            while true {
                let sentAt = ContinuousClock.now
                let ping = PingFlag()
                var stall: Duration?

                // Also deliberately the main *queue* rather than a `@MainActor`
                // hop, which would route the ping through the cooperative pool
                // first and measure that scheduling too.
                DispatchQueue.main.async {
                    ping.markAnswered()
                }

                Thread.sleep(forTimeInterval: warnThreshold)
                if !ping.isAnswered {
                    // Keep waiting so the logged duration is the real stall
                    // length, not just "at least warnThreshold".
                    while !ping.isAnswered {
                        Thread.sleep(forTimeInterval: retryInterval)
                    }
                    let elapsed = ContinuousClock.now - sentAt
                    stall = elapsed
                    PerformanceLog.shared?.record(
                        kind: .stall,
                        name: "MainThread",
                        value: milliseconds(elapsed)
                    )
                    let stallMsg = "Main thread unresponsive for"
                        + " \(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2))))"
                        + " — something synchronous (disk I/O, a big collection op,"
                        + " SwiftData work) is running on it."
                        + " Pause in the debugger or profile with Instruments to find what."
                    logger.warning("\(stallMsg, privacy: .public)")
                }

                // Lifted out of the lock before it is called: an observer that
                // reached back into the watchdog would otherwise deadlock.
                let observe = observer.withLock { $0 }
                observe?(Cycle(stall: stall))

                Thread.sleep(forTimeInterval: pingInterval)
            }
        }
        thread.name = "MainThreadWatchdog"
        // `.utility` rather than `.background`, and the distinction is not
        // cosmetic. The requirement is that this thread never competes with
        // the thread it measures, and `.utility` already satisfies it — main
        // is `.userInteractive`, two bands above. What `.background`
        // additionally buys is the one thing a watchdog cannot afford: it is
        // the band the scheduler is entitled to defer indefinitely, so under
        // load the loop stops turning, and a watchdog that has stopped
        // turning reports no stalls while scoring perfectly against every
        // budget in `PerformanceUITests`. Measured by running
        // `MainThreadWatchdogTests` against a machine held at load average
        // 124–177: `.utility` finished the suite in 4.1 seconds, `.background`
        // in 58.4 — a fourteenfold difference, and 1.6 seconds inside the
        // 60-second deadline the suite gives up at. CI, being slower, saw the
        // far side of it: a loop that turned three times in sixty seconds, so
        // a main thread blocked for four seconds was never pinged at all.
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let attosecondsPerMillisecond = 1e15
        let millisecondsPerSecond = 1000.0
        return Double(duration.components.seconds) * millisecondsPerSecond
            + Double(duration.components.attoseconds) / attosecondsPerMillisecond
    }
}
#endif
