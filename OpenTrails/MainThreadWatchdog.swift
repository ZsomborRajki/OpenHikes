//
//  MainThreadWatchdog.swift
//  OpenTrails
//
//  Debug-only safeguard: a background thread repeatedly pings the main run
//  loop and logs whenever it doesn't answer within a frame budget. Doesn't
//  know *what* blocked the main thread — pause in Xcode (the debugger's pause
//  button, or a breakpoint) once a warning fires and check the main thread's
//  stack, or profile with Instruments' Time Profiler, to find out.
//

import Foundation
import os

/// Fails a debug build if the calling thread is main — for the top of a
/// function whose cost (disk I/O, tile-grid enumeration, image encoding, …)
/// is documented as "must run off the main thread". Catches a future call
/// site that puts it back on main as an immediate crash in debug/Simulator
/// runs, instead of a silent hitch that only shows up as a dropped frame.
/// No-ops in release builds, same as `assert`.
@inline(__always)
nonisolated func assertOffMainThread(_ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
    assert(!Thread.isMainThread, message(), file: file, line: line)
}

#if DEBUG
enum MainThreadWatchdog {
    private static let logger = Logger(subsystem: "OpenTrails", category: "MainThreadWatchdog")

    /// Longer than this and a stall is worth knowing about — a dropped frame
    /// is ~16ms, but SwiftUI/UIKit routinely coalesce several; this is set
    /// well above that so only genuine hitches (e.g. synchronous disk I/O or
    /// O(thousands) work slipping onto the main thread) get logged.
    private static let warnThreshold: TimeInterval = 0.15
    private static let pingInterval: TimeInterval = 0.2

    private static let started = OSAllocatedUnfairLock(initialState: false)

    /// Starts the watchdog. Safe to call more than once — only the first call
    /// takes effect. Call once, early, e.g. from the app's `init`.
    static func start() {
        let alreadyStarted = started.withLock { started -> Bool in
            let was = started
            started = true
            return was
        }
        guard !alreadyStarted else { return }

        let thread = Thread {
            while true {
                let sentAt = DispatchTime.now()
                let responded = OSAllocatedUnfairLock(initialState: false)

                DispatchQueue.main.async {
                    responded.withLock { $0 = true }
                }

                Thread.sleep(forTimeInterval: warnThreshold)
                if !(responded.withLock({ $0 })) {
                    // Keep waiting so the logged duration is the real stall
                    // length, not just "at least warnThreshold".
                    while !(responded.withLock({ $0 })) {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    let elapsedNanos = DispatchTime.now().uptimeNanoseconds - sentAt.uptimeNanoseconds
                    let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000
                    logger.warning("Main thread unresponsive for \(elapsedSeconds, format: .fixed(precision: 2))s — something synchronous (disk I/O, a big collection op, SwiftData work) is running on it. Pause in the debugger or profile with Instruments to find what.")
                }

                Thread.sleep(forTimeInterval: pingInterval)
            }
        }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .background
        thread.start()
    }
}
#endif
