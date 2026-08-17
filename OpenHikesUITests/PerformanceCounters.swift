//
//  PerformanceCounters.swift
//  OpenHikesUITests
//
//  A reading of the app's live `RenderSignpost` tally, taken through
//  `PerformanceCounterProbe`'s accessibility value.
//
//  Everything here is expressed as a *difference* between two readings rather
//  than as an absolute. A UI test cannot control what the app did before the
//  gesture it cares about — a launch, an import, a navigation push all leave
//  counts behind — and it runs on whatever simulator is free, so wall-clock
//  budgets drift. The count of body evaluations caused by one drag does not.
//

import Foundation

/// One reading. `Name=count` for a point marker, `Name=count/maxMillis` for a
/// timed span; the maximum is kept out of the comparison and reported instead,
/// because a duration is the part a loaded machine distorts.
struct PerformanceCounters {
    private let values: [String: Double]
    private let maximums: [String: Double]

    init(rawValue: String) {
        var parsed: [String: Double] = [:]
        var parsedMaximums: [String: Double] = [:]
        for entry in rawValue.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let fields = parts[1].split(separator: "/")
            guard let value = fields.first.flatMap({ Double($0) }) else { continue }
            parsed[String(parts[0])] = value
            if fields.count > 1, let maximum = Double(fields[1]) {
                parsedMaximums[String(parts[0])] = maximum
            }
        }
        values = parsed
        maximums = parsedMaximums
    }

    func value(of name: String) -> Double { values[name] ?? 0 }

    /// The worst single occurrence, in milliseconds, for a timed span or a
    /// stall. Absolute rather than a delta on purpose: the thing worth a
    /// ceiling — the launch stall — is over before any phase begins, so a
    /// difference between two readings would always be zero.
    func maximum(of name: String) -> Double { maximums[name] ?? 0 }

    var names: [String] { values.keys.sorted() }

    /// True when the two readings describe the same amount of *work*.
    ///
    /// The sampler's own entries are excluded on purpose: the once-a-second
    /// sample count, CPU seconds and footprint move every second whether or
    /// not the app is doing anything, so a comparison that included them could
    /// never report a quiet app and `settle(in:)` would spin until its
    /// timeout.
    ///
    /// `RecordingClockTick` is excluded for the same reason and not for the
    /// same purpose. It is genuine app work — a 1 Hz `TimelineView` redrawing
    /// the elapsed readout — but it is work no gesture caused and no gesture
    /// can stop, so a recording screen would never look settled with it in the
    /// comparison. It is still counted and still asserted on; it just cannot
    /// be evidence about whether the *previous interaction* has finished.
    func isEquivalent(to other: Self) -> Bool {
        let sampled: Set<String> = [
            "Process", "CPU.s", "Footprint.MB", "RecordingClockTick",
        ]
        let compared = Set(values.keys).union(other.values.keys)
            .subtracting(sampled)
        return compared.allSatisfy { name in
            value(of: name) == other.value(of: name)
        }
    }
}

/// What the counters did across one phase.
struct PerformanceCounterDelta {
    let before: PerformanceCounters
    let after: PerformanceCounters

    /// Clamped at zero: the probe is read while the app is running, so a
    /// reading can in principle be taken mid-update.
    func count(of name: String) -> Double {
        max(0, after.value(of: name) - before.value(of: name))
    }

    var names: [String] { after.names }
}
