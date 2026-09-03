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
//     "0s" destroys the only evidence there is for the question
//     `PERFORMANCE.md` leaves open under *Blind spots*: whether the
//     conserving GPS profile is ever reached on a real walk. Every entry point
//     here takes an optional and says ``notReported`` when it is `nil`.
//  2. **A histogram statistic is an upper bound, and has to look like one.**
//     ``HistogramSummary`` cannot produce a true median — see its own note —
//     so the strings say "≤", every time, rather than presenting a bucket edge
//     as though it were a measurement.
//
//  Every entry point that formats a number or a date takes a `locale`
//  defaulting to `.autoupdatingCurrent`, the same test seam `HikeFormat.speed`
//  and `WeatherReadingFormat` carry and for the same reason: a suite that
//  could only ask about the machine's own region would assert whatever that
//  machine happened to be set to, and both rules above are claims about a
//  *string* — the "≤", the unit, the separator, the digits that survive
//  rounding. Pinning one region is what lets them be asserted whole rather
//  than by substring. Nothing in the app passes it.
//

import Foundation

nonisolated enum FieldMetricsFormat {
    static let notReported = "Not reported"

    private static let percentFractionDigits = 1
    private static let ratioFractionDigits = 4
    private static let secondsPerMinute = 60.0
    private static let secondsPerHour = 3600.0
    private static let millisecondsPerSecond = 1000.0

    /// A span of time in the largest unit that still says something: hours,
    /// minutes, seconds, or — below a second — milliseconds.
    static func duration(_ seconds: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let seconds else { return notReported }
        if seconds == 0 { return "0s" }
        if seconds < 1 {
            // Seconds at one fraction digit rounds everything under 50 ms to
            // "0s", which is the same string a span that cost nothing gets —
            // and a signpost's CPU cost per occurrence lives down here: an
            // import is a parse and a prefetch is a decode. Written in
            // milliseconds, at significant digits rather than a fixed fraction
            // length, so a fraction of a millisecond still reads as something.
            let milliseconds = seconds * millisecondsPerSecond
            let style = FloatingPointFormatStyle<Double>.number
                .precision(.significantDigits(1...3))
                .locale(locale)
            return "\(milliseconds.formatted(style)) ms"
        }
        if seconds < secondsPerMinute {
            return "\(seconds.formatted(Self.oneFractionDigit(locale)))s"
        }
        if seconds < secondsPerHour {
            let minutes = seconds / secondsPerMinute
            return "\(minutes.formatted(Self.oneFractionDigit(locale))) min"
        }
        let hours = seconds / secondsPerHour
        return "\(hours.formatted(Self.oneFractionDigit(locale))) h"
    }

    /// Milliseconds, for the launch and hang histograms, where seconds would
    /// round every interesting value to the same number.
    static func milliseconds(_ value: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value else { return notReported }
        return "\(value.formatted(Self.wholeNumber(locale))) ms"
    }

    static func bytes(_ value: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value else { return notReported }
        return Measurement(value: value, unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .memory).locale(locale))
    }

    static func percentage(_ share: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let share else { return notReported }
        return share.formatted(
            .percent.precision(.fractionLength(percentFractionDigits)).locale(locale)
        )
    }

    /// A hitch time ratio is a small dimensionless fraction — thousandths —
    /// so it is shown at full precision rather than as a percentage that would
    /// read "0.0%" for every value the app will ever produce.
    static func ratio(_ value: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value else { return notReported }
        return value.formatted(
            .number.precision(.fractionLength(ratioFractionDigits)).locale(locale)
        )
    }

    /// "≤ 500 ms median · ≤ 900 ms p90 · 42 samples", or ``notReported``.
    static func histogram(
        _ summary: HistogramSummary?,
        unit: String,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let summary, !summary.isEmpty else { return notReported }
        var parts: [String] = []
        if let median = summary.medianUpperBound {
            parts.append("≤ \(median.formatted(Self.wholeNumber(locale))) \(unit) median")
        }
        if let p90 = summary.p90UpperBound {
            parts.append("≤ \(p90.formatted(Self.wholeNumber(locale))) \(unit) p90")
        }
        parts.append("\(summary.sampleCount) samples")
        return parts.joined(separator: " · ")
    }

    static func period(_ report: FieldMetricsReport, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        let start = report.periodStart.formatted(style)
        let end = report.periodEnd.formatted(style)
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

    /// Count always leads. Median duration, CPU per occurrence, logical writes
    /// and average memory follow, in that order, when reported.
    static func signpostValue(
        _ signpost: SignpostDigest,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var parts = ["\(signpost.count)×"]
        if let median = signpost.duration?.medianUpperBound {
            parts.append("≤ \(milliseconds(median, locale: locale)) median")
        }
        if let cpu = signpost.cpuSecondsPerOccurrence {
            parts.append("\(duration(cpu, locale: locale)) CPU each")
        }
        if let writes = signpost.logicalWriteBytes {
            parts.append("\(bytes(writes, locale: locale)) written")
        }
        if let memory = signpost.averageMemoryBytes {
            parts.append("\(bytes(memory, locale: locale)) average")
        }
        return parts.joined(separator: " · ")
    }

    static func diagnosticValue(
        _ entry: FieldDiagnosticDigest,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if let seconds = entry.seconds { return duration(seconds, locale: locale) }
        if let byteCount = entry.bytes { return bytes(byteCount, locale: locale) }
        return entry.reason ?? "No detail"
    }

    private static func oneFractionDigit(_ locale: Locale) -> FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...1)).locale(locale)
    }

    private static func wholeNumber(_ locale: Locale) -> FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0)).locale(locale)
    }
}
