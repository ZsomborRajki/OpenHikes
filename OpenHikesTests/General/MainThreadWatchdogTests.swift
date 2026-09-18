//
//  MainThreadWatchdogTests.swift
//  OpenHikesTests
//
//  The watchdog is measurement infrastructure rather than a feature, and the
//  way infrastructure fails is by quietly stopping. A watchdog that has
//  stopped turning reports no stalls, which is indistinguishable from a
//  healthy app. So both directions are asserted here: that the ping loop is
//  still turning, and that a main thread which genuinely stops answering is
//  reported.
//
//  The second one is harder than it looks, and a fixed provocation cannot do
//  it. The loop posts a ping, waits the warn threshold, and then sleeps the
//  ping interval before posting again, so a blocked main thread is only
//  observable if a post happens to land *inside* the block. Those waits are
//  `Thread.sleep` calls on a thread running below the one it measures — it
//  must not compete with it — so they are lower bounds and nothing else. How
//  weak a bound was worth measuring: on a machine carrying a load average of
//  200 the loop settles at roughly its nominal period, but a *cold*
//  simulator — booting, installing and building its first stores — starved
//  that thread badly enough to turn the loop fewer than twice in fifty
//  seconds. At any of that a block of some fixed length fits entirely between
//  two posts, nothing is observed, and the test fails while the watchdog is
//  working perfectly.
//
//  That starvation had a cause rather than being weather, and the cause is
//  fixed in `MainThreadWatchdog` rather than papered over here: the loop ran
//  at `.background` quality of service, the one band the scheduler may defer
//  indefinitely. It is `.utility` now — still below main, but actually
//  scheduled. Everything below stays anyway, because a lower bound is still
//  only a lower bound.
//
//  So the block is sized from the period the loop is *currently* running at,
//  re-measured every attempt, and a miss provokes another block rather than
//  failing. That closes the second failure mode of a one-shot too: the stall
//  the watchdog reports is the block minus however far into it the post fell,
//  so a single block yields a length varying by a whole ping interval and an
//  assertion on that length is a coin toss. Waiting for a stall that clears
//  the bound — rather than taking the first one and hoping — is the same
//  "wait on the positive effect" rule the rest of this bundle follows.
//
//  The *upper* bound on that length went the same way, and later. Asserting
//  the reported stall against the requested block assumed the block was the
//  only thing holding main, which the paragraph below already says is false:
//  this host does SwiftData and CloudKit work of its own, and one of its own
//  stalls landing against the block is reported — correctly — as their sum.
//  CI failed on exactly that, a 2.697s reading of a 1.346s block. So the bound
//  is measured now rather than assumed: from the last cycle logged before the
//  block to the moment main answers again, which is the whole window any
//  honest stall for that attempt has to fit inside. A stall is also attributed
//  to the attempt that provoked it, because one reported after its grace ran
//  out was being checked against the *next* attempt's block.
//
//  One thing deliberately not asserted: that an *idle* main thread is never
//  called a stall. It cannot be asserted from inside the process being
//  measured. The host is a real app doing SwiftData and CloudKit work of its
//  own, and a 1.34s stall was observed here during a test that did nothing
//  but sleep. A watchdog that cried wolf on every cycle would therefore pass
//  this suite; catching that needs a harness outside the app.
//
//  Nothing here starts the watchdog. `start()` is once-only and the app host
//  has already called it by the time any test runs, which is why the observer
//  is read per cycle rather than handed over at start.
//

#if DEBUG
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

/// Collects cycles off the watchdog thread for a main-actor test to poll.
/// `nonisolated` because the watchdog calls it from its own `Thread`, and the
/// target's default isolation would otherwise make every append a hop onto the
/// very thread the watchdog exists to measure.
nonisolated private final class CycleLog: Sendable {
    private struct Entry: Sendable {
        let stall: Duration?
        let at: ContinuousClock.Instant
    }

    private let entries = Mutex<[Entry]>([])

    var count: Int { entries.withLock { $0.count } }

    /// The gap between the two most recent cycles, or `nil` before there are
    /// two of them. What the loop's period actually is right now, which is the
    /// only figure worth sizing a provocation from.
    var latestPeriod: Duration? {
        entries.withLock { logged in
            guard logged.count >= 2 else { return nil }
            return logged[logged.count - 1].at - logged[logged.count - 2].at
        }
    }

    /// When the most recent cycle was logged, or `nil` before there are any.
    ///
    /// The anchor an attempt's bound is measured from: the watchdog posts its
    /// next ping after this instant, so no stall it goes on to report can have
    /// begun before it.
    var latestInstant: ContinuousClock.Instant? {
        entries.withLock { $0.last?.at }
    }

    /// The first stall of at least `minimum` logged after `index` cycles, with
    /// the instant its cycle was logged, if one has been reported.
    ///
    /// Scoped to one attempt rather than to the whole log, and that is not
    /// tidiness. A block's stall is sometimes reported after the grace this
    /// test waits for it, so it lands in the log while the *next* attempt is
    /// measuring its period. Scanning from the beginning picked that stall up
    /// on the later attempt and checked it against the later attempt's block,
    /// which is a comparison between two different provocations — and the
    /// larger the earlier block, the more certainly it failed.
    ///
    /// The instant comes back with it because the bound is measured to it: the
    /// watchdog had stopped timing by the time it logged the cycle, so a stall
    /// reported there cannot be longer than the run-up to it.
    func firstStall(
        atLeast minimum: Duration,
        after index: Int
    ) -> (stall: Duration, at: ContinuousClock.Instant)? {
        entries.withLock { logged -> (Duration, ContinuousClock.Instant)? in
            for entry in logged.dropFirst(index) {
                if let stall = entry.stall, stall >= minimum { return (stall, entry.at) }
            }
            return nil
        }
    }

    func record(_ cycle: MainThreadWatchdog.Cycle) {
        entries.withLock { $0.append(Entry(stall: cycle.stall, at: .now)) }
    }
}

/// Stops the calling thread — the main one — for `duration`.
///
/// `Thread.sleep` is unavailable from an asynchronous context, which is the
/// compiler objecting to precisely what has to happen here on purpose: the
/// only way to learn whether the watchdog notices a main thread that has
/// stopped answering is to stop it answering. Wrapped in a synchronous
/// function to say that deliberately rather than to route around a diagnostic.
private func blockMainThread(for duration: Duration) {
    let attosecondsPerSecond = 1e18
    let seconds = TimeInterval(duration.components.seconds)
        + TimeInterval(duration.components.attoseconds) / attosecondsPerSecond
    Thread.sleep(forTimeInterval: seconds)
}

@MainActor
@Suite("Main thread watchdog")
struct MainThreadWatchdogTests {
    /// Far longer than the ~0.35s a healthy cycle takes, because the watchdog
    /// thread runs *below* the thread it measures by design — it must not
    /// compete with it — so its period is not bounded by its own sleeps on a
    /// loaded machine. Two cycles have been seen taking 11.2s, so a tight
    /// budget here would be measuring the build machine rather than the
    /// watchdog — an earlier 8s one failed on a busy host with the loop
    /// turning perfectly well. It is a real deadline all the same, because a
    /// test that gives up and says so is worth far more than one that hangs.
    private static let cycleDeadline: Duration = .seconds(25)

    /// The whole provocation, however many attempts it takes.
    private static let stallDeadline: Duration = .seconds(60)

    /// The shortest stall this will accept as proof. Chosen well above the
    /// watchdog's own 0.15s threshold, so a watchdog reporting the threshold
    /// instead of the elapsed time it measured fails rather than passes.
    private static let minimumStall: Duration = .milliseconds(500)

    /// Added to the period on top of ``minimumStall`` so the post the block is
    /// aimed at lands comfortably inside it rather than against its edge.
    private static let provocationMargin: Duration = .milliseconds(250)

    /// However slow the loop is, main is never held longer than this. Past it
    /// the provocation would be doing more damage to the run than the reading
    /// is worth, and another attempt is the cheaper way to the same answer.
    /// Only a starved machine ever reaches it: a healthy loop asks for ~1.1s.
    private static let blockCap: Duration = .seconds(8)

    /// How long to wait after unblocking for the stall to be reported. The
    /// watchdog notices main answering on a 0.05s retry tick, so this is
    /// generous rather than tuned.
    private static let reportGrace: Duration = .seconds(2)

    /// Room above the window an attempt's stall could honestly have occupied,
    /// for the retry tick the watchdog notices main answering on and for the
    /// hop back onto main once it does.
    ///
    /// Small because the window it is added to is now measured rather than
    /// assumed — see ``stallIsReported``. The figure this replaced was a
    /// second of room above the *requested block*, which asserted something
    /// the watchdog never promised: it times from its own last ping, not from
    /// the moment this test began blocking, so anything else holding main in
    /// between is inside the stall it reports and outside the block. This
    /// file's header records a 1.34s stall observed while a test did nothing
    /// but sleep, and the host is a real app doing SwiftData and CloudKit work
    /// — so one of those landing against a ~1.3s block produced a perfectly
    /// correct 2.7s reading and a red suite on CI.
    private static let lengthSlack: Duration = .milliseconds(500)

    /// Installs `log` for the duration of `body`, then takes it back off.
    private func observing(_ log: CycleLog, _ body: () async -> Void) async {
        MainThreadWatchdog.observeCycles { log.record($0) }
        defer { MainThreadWatchdog.observeCycles(nil) }
        await body()
    }

    /// Polls until `count` further cycles have arrived, or `deadline` passes.
    /// A condition rather than a duration, for the same reason everything else
    /// in this bundle waits on one: a fixed wait buys an amount of progress
    /// that depends on load.
    private func awaitCycles(
        _ count: Int,
        in log: CycleLog,
        before deadline: ContinuousClock.Instant
    ) async -> Bool {
        let target = log.count + count
        while log.count < target {
            guard ContinuousClock.now < deadline, await settlePollTick() else { return false }
        }
        return true
    }

    /// Two cycles rather than one, because a single one could be the tail of a
    /// loop about to stop; two means it completed a whole ping-sleep-ping turn
    /// while the test watched.
    @Test("the ping loop is still turning")
    func loopIsRunning() async {
        let log = CycleLog()

        await observing(log) {
            _ = await awaitCycles(2, in: log, before: ContinuousClock.now + Self.cycleDeadline)
        }

        #expect(
            log.count >= 2,
            "the watchdog produced \(log.count) ping cycles before the deadline"
        )
    }

    /// Blocks main for longer than one turn of the loop, so a ping is posted
    /// into the block rather than around it, and repeats that until a stall
    /// long enough to be unambiguous comes back.
    @Test("a blocked main thread is reported, at its real length")
    func stallIsReported() async throws {
        let log = CycleLog()
        var observed: Duration?
        var block: Duration = .zero
        var window: Duration = .zero
        var attempts = 0

        await observing(log) {
            let deadline = ContinuousClock.now + Self.stallDeadline
            while observed == nil, ContinuousClock.now < deadline {
                // Two fresh cycles: the gap between them is the period the
                // loop is running at now, uncontaminated by the previous
                // attempt's block, and the second is the moment to start
                // blocking from — the next ping goes out one ping interval
                // later, which is inside a block sized from that period.
                guard await awaitCycles(2, in: log, before: deadline),
                      let period = log.latestPeriod,
                      let anchor = log.latestInstant else { break }
                attempts += 1
                block = min(period + Self.minimumStall + Self.provocationMargin, Self.blockCap)

                // Everything this attempt is allowed to report has to fit
                // between the last cycle logged before the block and the cycle
                // that reports the stall. The watchdog's next ping goes out
                // after `anchor`, so no stall it reports here can have started
                // earlier; and it has stopped timing by the time it hands the
                // cycle over, so none can end later. That window is the honest
                // bound — wider than the block by however long anything *else*
                // held main in between, which is the part the old assertion
                // against the block alone denied could happen.
                let mark = log.count
                blockMainThread(for: block)

                let grace = ContinuousClock.now + max(period, Self.reportGrace)
                _ = await awaitCycles(1, in: log, before: min(deadline, grace))
                if let found = log.firstStall(atLeast: Self.minimumStall, after: mark) {
                    observed = found.stall
                    window = found.at - anchor
                }
            }
        }

        let stall = try #require(
            observed,
            """
            the watchdog reported no stall of \(Self.minimumStall) or longer \
            after \(attempts) attempt(s), the last blocking main for \(block); \
            it turned \(log.count) times, so it is running but not measuring
            """
        )
        #expect(
            stall <= window + Self.lengthSlack,
            """
            a \(block) block inside a \(window) window of unanswered main was \
            reported as a stall of \(stall)
            """
        )
    }
}
#endif
