//
//  FieldMetricsFormat.swift
//  OpenHikes
//
//  How a MetricKit number is written down for somebody to read.
//
//  Two rules the whole file exists to enforce, both of which were mistakes
//  waiting to be made:
//
//  1. **An absent measurement is not a zero.** "The GPS never dropped to ten
//     metres" and "this payload carried no location metrics" are different
//     facts with opposite implications, and a formatter that turns both into
//     "0s" destroys the only evidence Finding E1's open question has. Every
//     entry point here takes an optional and says ``notReported`` when it is
//     `nil`.
//  2. **A histogram statistic is an upper bound, and has to look like one.**
//     ``HistogramSummary`` cannot produce a true median — see its own note —
//     so the strings say "≤", every time, rather than presenting a bucket edge
//     as though it were a measurement.
//

import Foundation

nonisolated enum FieldMetricsFormat {
    static let notReported = "Not reported"

    private static let percentFractionDigits = 1
    private static let ratioFractionDigits = 4
    private static let secondsPerMinute = 60.0
    private static let secondsPerHour = 3600.0

    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return notReported }
        if seconds < secondsPerMinute {
            return "\(seconds.formatted(.number.precision(.fractionLength(0...1))))s"
        }
        if seconds < secondsPerHour {
            let minutes = seconds / secondsPerMinute
            return "\(minutes.formatted(.number.precision(.fractionLength(0...1)))) min"
        }
        let hours = seconds / secondsPerHour
        return "\(hours.formatted(.number.precision(.fractionLength(0...1)))) h"
    }

    /// Milliseconds, for the launch and hang histograms, where seconds would
    /// round every interesting value to the same number.
    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return notReported }
        return "\(value.formatted(.number.precision(.fractionLength(0)))) ms"
    }

    static func bytes(_ value: Double?) -> String {
        guard let value else { return notReported }
        return Measurement(value: value, unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .memory))
    }

    static func percentage(_ share: Double?) -> String {
        guard let share else { return notReported }
        return share.formatted(
            .percent.precision(.fractionLength(percentFractionDigits))
        )
    }

    /// A hitch time ratio is a small dimensionless fraction — thousandths —
    /// so it is shown at full precision rather than as a percentage that would
    /// read "0.0%" for every value the app will ever produce.
    static func ratio(_ value: Double?) -> String {
        guard let value else { return notReported }
        return value.formatted(.number.precision(.fractionLength(ratioFractionDigits)))
    }

    /// "≤ 500 ms median · ≤ 900 ms p90 · 42 samples", or ``notReported``.
    static func histogram(_ summary: HistogramSummary?, unit: String) -> String {
        guard let summary, !summary.isEmpty else { return notReported }
        var parts: [String] = []
        if let median = summary.medianUpperBound {
            parts.append("≤ \(median.formatted(.number.precision(.fractionLength(0)))) \(unit) median")
        }
        if let p90 = summary.p90UpperBound {
            parts.append("≤ \(p90.formatted(.number.precision(.fractionLength(0)))) \(unit) p90")
        }
        parts.append("\(summary.sampleCount) samples")
        return parts.joined(separator: " · ")
    }

    static func period(_ report: FieldMetricsReport) -> String {
        let start = report.periodStart.formatted(date: .abbreviated, time: .shortened)
        let end = report.periodEnd.formatted(date: .abbreviated, time: .shortened)
        return "\(start) – \(end)"
    }

    static func version(_ report: FieldMetricsReport) -> String {
        guard let build = report.appBuild else { return report.appVersion }
        return "\(report.appVersion) (\(build))"
    }

    /// `RecordingSession` reads as "Recording session" rather than as an
    /// identifier. The spans are named for signposts, not for people.
    static func signpostTitle(_ name: String) -> String {
        switch FieldSignpost.Span(rawValue: name) {
        case .hikeImport: "Importing a hike"
        case .offlineDownload: "Saving maps for offline"
        case .recordingSession: "Recording a hike"
        case .trailGraphPrefetch: "Fetching trail data"
        case nil: name
        }
    }

    /// The three columns worth reading off a signpost, in the order they
    /// answer a question: how often, what it cost the processor, what it wrote.
    static func signpostValue(_ signpost: SignpostDigest) -> String {
        var parts = ["\(signpost.count)×"]
        if let median = signpost.duration?.medianUpperBound {
            parts.append("≤ \(milliseconds(median)) median")
        }
        if let cpu = signpost.cpuSecondsPerOccurrence {
            parts.append("\(duration(cpu)) CPU each")
        }
        if let writes = signpost.logicalWriteBytes {
            parts.append("\(bytes(writes)) written")
        }
        if let memory = signpost.averageMemoryBytes {
            parts.append("\(bytes(memory)) average")
        }
        return parts.joined(separator: " · ")
    }

    static func diagnosticValue(_ entry: FieldDiagnosticDigest) -> String {
        if let seconds = entry.seconds { return duration(seconds) }
        if let byteCount = entry.bytes { return bytes(byteCount) }
        return entry.reason ?? "No detail"
    }
}
