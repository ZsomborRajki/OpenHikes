//
//  PerformanceCounters.swift
//  OpenTrailsUITests
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

    init(rawValue: String) {
        var parsed: [String: Double] = [:]
        for entry in rawValue.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  let count = parts[1].split(separator: "/").first,
                  let value = Double(count) else { continue }
            parsed[String(parts[0])] = value
        }
        values = parsed
    }

    func value(of name: String) -> Double { values[name] ?? 0 }

    var names: [String] { values.keys.sorted() }

    /// True when the two readings describe the same amount of *work*.
    ///
    /// The sampler's own entries are excluded on purpose: elapsed process
    /// time, CPU seconds and footprint move every second whether or not the
    /// app is doing anything, so a comparison that included them could never
    /// report a quiet app and `settle(in:)` would spin until its timeout.
    func isEquivalent(to other: Self) -> Bool {
        let sampled: Set<String> = ["Process", "CPU.s", "Footprint.MB"]
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
