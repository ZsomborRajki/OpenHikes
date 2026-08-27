//
//  PerformanceLog.swift
//  OpenHikes
//
//  A text sink for everything the diagnostics in this folder already know.
//
//  `RenderSignpost` answers "how often did this body run?" and
//  `MainThreadWatchdog` answers "did the main thread stall?", but both only
//  ever speak to a console or an Instruments track — a human has to be sitting
//  there watching. That rules them out of a UI test, which runs headless and
//  has to *assert* on the answer.
//
//  So when the app is launched with `--ui-test-performance-log=<scenario>`,
//  every mark, interval and stall is also appended to a tab-separated file in
//  the app's own Documents directory, alongside a 1 Hz memory/CPU sample. The
//  host pulls it back out with
//  `xcrun simctl get_app_container booted tappium.com.OpenHikes data`, which
//  is why the destination is the app container and not the App Group: no
//  entitlement has to be provisioned for a performance run to work.
//
//  Two rules shaped the design, because an instrument that changes what it
//  measures is worse than no instrument:
//
//  1. The recording path takes a lock, appends a struct, and returns. No
//     formatting of the line, no I/O.
//  2. Rendering and every write happen on a utility-priority serial queue, one
//     batch per second. No line is formatted or written on the main thread.
//
//  Debug-only, like the rest of this folder — release builds have no sink
//  because `RenderSignpost` has nothing to feed it.
//

import Foundation
import os
import Synchronization

#if DEBUG
nonisolated final class PerformanceLog: Sendable {
    enum Kind: String, Sendable {
        /// A point event: a body ran, an update call fired.
        case mark = "mark"
        /// A bracketed span, carrying its duration in milliseconds.
        case interval = "interval"
        /// The main run loop failed to answer within the watchdog's budget.
        case stall = "stall"
        /// A periodic process-wide memory and CPU reading.
        case sample = "sample"
    }

    private struct Event: Sendable {
        let epochSeconds: Double
        let elapsedSeconds: Double
        let kind: Kind
        let name: String
        let value: Double?
        let detail: String
    }

    /// Buffered events and the running tallies, under one lock: the recording
    /// path takes it once per event, and ``snapshotDescription`` — which UI
    /// automation reads through an accessibility element rather than through
    /// the file — needs a tally that agrees with the events it was drawn from.
    private struct Buffer {
        var pending: [Event] = []
        var counts: [String: Int] = [:]
        var maximums: [String: Double] = [:]
        var footprintMegabytes = 0.0
        var cpuSeconds = 0.0
    }

    /// One log per launch, created only when the launch asked for one. Every
    /// other launch pays a single optional check per recorded event.
    static let shared: PerformanceLog? = AppLaunchEnvironment
        .performanceLogScenario
        .flatMap(PerformanceLog.init(scenario:))

    private static let logger = Logger(subsystem: "OpenHikes", category: "PerformanceLog")
    private static let flushInterval: TimeInterval = 1
    private static let attosecondsPerSecond = 1e18
    private static let bytesPerMegabyte = 1_048_576.0
    private static let columnHeader = "# epoch_s\telapsed_s\tkind\tname\tvalue\tdetail"

    private let start = ContinuousClock.now
    private let startEpoch = Date().timeIntervalSince1970
    private let buffer = Mutex(Buffer())
    private let queue = DispatchQueue(label: "OpenHikes.PerformanceLog", qos: .utility)
    private let timer: DispatchSourceTimer
    /// Written to only from `queue`. One stated owner rather than a lock that
    /// would never be contended, matching how the rest of the app's off-main
    /// state is held.
    private let handle: FileHandle

    private init?(scenario: String) {
        let directory = URL.documentsDirectory
            .appending(path: "PerformanceLogs", directoryHint: .isDirectory)
        let destination = directory.appending(
            path: "\(scenario).tsv",
            directoryHint: .notDirectory
        )
        // A re-run must not read as one long session: the app container
        // survives a UI-test relaunch even though its SwiftData store does not.
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.createFile(
                atPath: destination.path,
                contents: nil
            ) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            Self.logger.error(
                "Performance log unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        timer = DispatchSource.makeTimerSource(queue: queue)

        let preamble = [
            Self.columnHeader,
            "# scenario\t\(scenario)",
            "# started_epoch_s\t\(startEpoch)",
            "# arguments\t\(ProcessInfo.processInfo.arguments.joined(separator: " "))",
        ].joined(separator: "\n")
        queue.async { [handle] in
            try? handle.write(contentsOf: Data((preamble + "\n").utf8))
        }

        timer.schedule(
            deadline: .now() + Self.flushInterval,
            repeating: Self.flushInterval
        )
        timer.setEventHandler { [weak self] in
            self?.sampleResources()
            self?.drain()
        }
        timer.resume()
        Self.logger.notice("Performance log at \(destination.path, privacy: .public)")
    }

    func record(
        kind: Kind,
        name: String,
        value: Double? = nil,
        detail: String = ""
    ) {
        let elapsed = elapsedSeconds()
        let event = Event(
            epochSeconds: startEpoch + elapsed,
            elapsedSeconds: elapsed,
            kind: kind,
            name: name,
            value: value,
            detail: detail
        )
        buffer.withLock { buffer in
            buffer.pending.append(event)
            buffer.counts[name, default: 0] += 1
            if let value, kind != .sample {
                buffer.maximums[name] = max(buffer.maximums[name] ?? 0, value)
            }
        }
    }

    /// A one-line tally UI automation can read straight out of the running
    /// process, so a render budget can be asserted while the app is still up
    /// rather than reconstructed from the file afterwards. Shaped for a
    /// parser: `Name=count[/max];…`, then the two process gauges.
    var snapshotDescription: String {
        let snapshot = buffer.withLock { buffer in
            (buffer.counts, buffer.maximums, buffer.footprintMegabytes, buffer.cpuSeconds)
        }
        let tallies = snapshot.0.keys.sorted().map { name -> String in
            let count = snapshot.0[name] ?? 0
            guard let maximum = snapshot.1[name] else { return "\(name)=\(count)" }
            return "\(name)=\(count)/\(maximum)"
        }
        return (tallies + [
            "Footprint.MB=\(snapshot.2)",
            "CPU.s=\(snapshot.3)",
        ]).joined(separator: ";")
    }

    /// Writes everything buffered so far and waits for it to reach the file.
    /// Called when the scene resigns active, which is the last moment a UI
    /// test can rely on before it terminates the app.
    func flush() {
        queue.sync {
            self.drain()
            try? self.handle.synchronize()
        }
    }

    /// `ContinuousClock` rather than `Date`, for the same reason
    /// ``RenderSignpost`` uses it: a clock correction mid-run must not make one
    /// event look like it happened before the one that caused it. The wall
    /// clock column is derived from this, so the two stay consistent.
    private func elapsedSeconds() -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / Self.attosecondsPerSecond
    }

    private func sampleResources() {
        guard let sample = ProcessResourceSample.current() else { return }
        let footprint = Double(sample.footprintBytes) / Self.bytesPerMegabyte
        buffer.withLock { buffer in
            buffer.footprintMegabytes = footprint
            buffer.cpuSeconds = sample.cpuSeconds
        }
        // Power state rides along with the sample rather than being its own
        // event: it changes a handful of times per hike, and what a reader
        // actually wants to ask of it is "what was the thermal state while
        // this CPU was being burned", which needs the two on one row.
        record(
            kind: .sample,
            name: "Process",
            value: footprint,
            detail: "cpu_s=\(sample.cpuSeconds) \(PowerState.current.signpostDetail)"
        )
    }

    /// Must run on `queue`.
    private func drain() {
        let batch = buffer.withLock { buffer -> [Event] in
            let snapshot = buffer.pending
            buffer.pending.removeAll(keepingCapacity: true)
            return snapshot
        }
        guard !batch.isEmpty else { return }
        let text = batch.map(Self.line(for:)).joined(separator: "\n") + "\n"
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private static func line(for event: Event) -> String {
        let value = event.value.map { "\($0)" } ?? ""
        return "\(event.epochSeconds)\t\(event.elapsedSeconds)\t\(event.kind.rawValue)"
            + "\t\(event.name)\t\(value)\t\(event.detail)"
    }
}
#endif
