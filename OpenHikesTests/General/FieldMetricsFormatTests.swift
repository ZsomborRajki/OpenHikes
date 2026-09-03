//
//  FieldMetricsFormatTests.swift
//  OpenHikesTests
//
//  What a field report is allowed to say, and what it must never say instead.
//
//  `FieldMetricsFormat` is the last thing standing between a MetricKit
//  payload and the walker reading it, and its header names the two rules it
//  exists to enforce. Both are claims about a *string*, and both are the kind
//  a refactor breaks without failing anything:
//
//  1. **An absent measurement is not a zero.** Every entry point takes an
//     optional, and every one of them has to answer `notReported` for `nil`
//     rather than formatting a zero — because "the GPS never dropped to ten
//     metres" and "this payload carried no location metrics" are opposite
//     findings, and "0s" is what makes them indistinguishable. It is also the
//     evidence for the question `PERFORMANCE.md` leaves open under *Blind
//     spots*, so losing it at the last step loses it entirely.
//  2. **A histogram statistic is an upper bound.** `HistogramSummary` cannot
//     produce a true median, so every statistic drawn from one keeps its "≤".
//
//  Everything here is pinned to one region through the formatter's `locale`
//  seam. Separators, grouping and byte units are all regional, so a suite that
//  read `Locale.current` would agree with whatever the machine was set to —
//  which is how a formatting bug survives a green run. Pinning is also what
//  lets the assertions be whole strings rather than "contains", so a change to
//  a unit, a rounding or a separator has to be argued for rather than
//  discovered.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Field metrics format")
nonisolated struct FieldMetricsFormatTests {
    private static let locale = Locale(identifier: "en_US")

    private static func duration(_ seconds: Double?) -> String {
        FieldMetricsFormat.duration(seconds, locale: locale)
    }

    private static func histogram(_ summary: HistogramSummary?) -> String {
        FieldMetricsFormat.histogram(summary, unit: "ms", locale: locale)
    }

    /// The shape the doc comment on ``FieldMetricsFormat/histogram(_:unit:)``
    /// advertises: ten samples split evenly across a 500 ms and a 900 ms
    /// bucket, so the median lands on the first edge and the p90 on the second.
    private static let sampled = HistogramSummary(buckets: [
        .init(start: 0, end: 500, count: 5),
        .init(start: 500, end: 900, count: 5),
    ])

    // MARK: - An absent measurement is not a zero

    /// The rule the whole file exists for, asked of every entry point that can
    /// be handed a `nil` — because it only takes one of them to lose it.
    @Test("no entry point turns a missing measurement into a number")
    func absentMeasurements() {
        let reported = FieldMetricsFormat.notReported
        #expect(Self.duration(nil) == reported)
        #expect(FieldMetricsFormat.milliseconds(nil, locale: Self.locale) == reported)
        #expect(FieldMetricsFormat.bytes(nil, locale: Self.locale) == reported)
        #expect(FieldMetricsFormat.percentage(nil, locale: Self.locale) == reported)
        #expect(FieldMetricsFormat.ratio(nil, locale: Self.locale) == reported)
        #expect(Self.histogram(nil) == reported)
    }

    /// The other half of the same claim: a measured zero still reads as a
    /// zero, and it must not read as the absence.
    @Test("a measured zero is not the absence either")
    func measuredZeroes() {
        let reported = FieldMetricsFormat.notReported
        #expect(Self.duration(0) == "0s")
        #expect(FieldMetricsFormat.milliseconds(0, locale: Self.locale) == "0 ms")
        #expect(FieldMetricsFormat.percentage(0, locale: Self.locale) == "0.0%")
        #expect(FieldMetricsFormat.ratio(0, locale: Self.locale) == "0.0000")
        #expect(FieldMetricsFormat.bytes(0, locale: Self.locale) != reported)
    }

    // MARK: - Durations, by magnitude

    /// Milliseconds below a second. Seconds at one fraction digit rounded
    /// everything under 50 ms to "0s" — the same string a span that cost
    /// nothing gets — and a signpost's CPU cost per occurrence lives down
    /// here: an import is a parse, a prefetch is a decode.
    @Test("below a second, a duration is written in milliseconds", arguments: [
        (0.015, "15 ms"),
        (0.049, "49 ms"),
        (0.0005, "0.5 ms"),
        (0.9994, "999 ms"),
    ])
    func subSecondDurations(seconds: Double, expected: String) {
        #expect(Self.duration(seconds) == expected)
    }

    @Test("every value the old fraction length flattened stays distinct")
    func flattenedValuesStayDistinct() {
        let strings = [0.0, 0.015, 0.040, 0.049].map(Self.duration)
        #expect(Set(strings).count == strings.count)
    }

    /// The three bands above a second and the two boundaries between them.
    /// 60 s is the first minute rather than the last second, and 3600 s the
    /// first hour rather than the last minute.
    @Test("seconds, minutes and hours, and the boundaries between them", arguments: [
        (1.0, "1s"),
        (59.94, "59.9s"),
        (60.0, "1 min"),
        (90.0, "1.5 min"),
        (3599.0, "60 min"),
        (3600.0, "1 h"),
        (5400.0, "1.5 h"),
    ])
    func magnitudeBands(seconds: Double, expected: String) {
        #expect(Self.duration(seconds) == expected)
    }

    // MARK: - The other scalars

    @Test("milliseconds are whole, and grouped as the region groups them")
    func millisecondValues() {
        #expect(FieldMetricsFormat.milliseconds(1234.6, locale: Self.locale) == "1,235 ms")
    }

    @Test("a share is a percentage at one decimal")
    func percentageValues() {
        #expect(FieldMetricsFormat.percentage(0.1234, locale: Self.locale) == "12.3%")
        #expect(FieldMetricsFormat.percentage(1, locale: Self.locale) == "100.0%")
    }

    /// A hitch ratio is thousandths. At percent precision every value the app
    /// will ever produce reads "0.0%", which is the collapse this avoids.
    @Test("a hitch ratio keeps the digits a percentage would round away")
    func ratioValues() {
        #expect(FieldMetricsFormat.ratio(0.0012, locale: Self.locale) == "0.0012")
        #expect(FieldMetricsFormat.ratio(0.0004, locale: Self.locale) == "0.0004")
        #expect(FieldMetricsFormat.percentage(0.0004, locale: Self.locale) == "0.0%")
    }

    @Test("bytes are memory units, not decimal ones")
    func byteValues() {
        #expect(FieldMetricsFormat.bytes(1_048_576, locale: Self.locale) == "1 MB")
        #expect(FieldMetricsFormat.bytes(4_194_304, locale: Self.locale) == "4 MB")
    }

    // MARK: - A histogram statistic is an upper bound

    @Test("both statistics say so, and the sample count says how many")
    func histogramStatistics() {
        #expect(Self.histogram(Self.sampled) == "≤ 500 ms median · ≤ 900 ms p90 · 10 samples")
    }

    /// A summary with buckets but no samples in them is not a distribution of
    /// zeroes — it is a period nothing was measured in.
    @Test("a summary nothing was sampled into is not reported", arguments: [
        HistogramSummary(),
        HistogramSummary(buckets: [.init(start: 0, end: 500, count: 0)]),
    ])
    func emptyHistogram(summary: HistogramSummary) {
        #expect(Self.histogram(summary) == FieldMetricsFormat.notReported)
    }

    @Test("the unit is the caller's, and reaches both bounds")
    func histogramUnit() {
        let bars = FieldMetricsFormat.histogram(Self.sampled, unit: "bars", locale: Self.locale)
        #expect(bars == "≤ 500 bars median · ≤ 900 bars p90 · 10 samples")
    }

    // MARK: - Signposts

    @Test("a span the app emits is named for a person, not for a signpost", arguments: [
        (FieldSignpost.Span.hikeImport, "Importing a hike"),
        (FieldSignpost.Span.offlineDownload, "Saving maps for offline"),
        (FieldSignpost.Span.recordingSession, "Recording a hike"),
        (FieldSignpost.Span.trailGraphPrefetch, "Fetching trail data"),
    ])
    func knownSignpostTitles(span: FieldSignpost.Span, expected: String) {
        #expect(FieldMetricsFormat.signpostTitle(span.rawValue) == expected)
    }

    /// A payload can name a span this build no longer emits — the report is a
    /// day old and may have been written by an older version. The raw name is
    /// worse to read and better than nothing.
    @Test("a span this build does not know keeps its raw name")
    func unknownSignpostTitle() {
        #expect(FieldMetricsFormat.signpostTitle("RetiredSpan") == "RetiredSpan")
        #expect(FieldMetricsFormat.signpostTitle("").isEmpty)
    }

    /// Count always leads, and the four measurements follow it in a fixed
    /// order: median duration, CPU per occurrence, logical writes, average
    /// memory.
    @Test("a fully populated span emits every decoded measurement in order")
    func fullyPopulatedSignpost() {
        let signpost = SignpostDigest(
            name: FieldSignpost.Span.recordingSession.rawValue,
            category: FieldSignpost.category,
            count: 2,
            duration: HistogramSummary(buckets: [.init(start: 100, end: 200, count: 2)]),
            cpuSeconds: 0.030,
            averageMemoryBytes: 4_194_304,
            logicalWriteBytes: 1_048_576
        )
        #expect(
            FieldMetricsFormat.signpostValue(signpost, locale: Self.locale)
                == "2× · ≤ 200 ms median · 15 ms CPU each · 1 MB written · 4 MB average"
        )
    }

    /// The columns MetricKit did not send are absent from the row rather than
    /// present as zeroes — the same rule as ``notReported``, one level up.
    @Test("a span carrying nothing but a count says only that")
    func sparseSignpost() {
        let signpost = SignpostDigest(
            name: FieldSignpost.Span.hikeImport.rawValue,
            category: FieldSignpost.category,
            count: 3
        )
        #expect(FieldMetricsFormat.signpostValue(signpost, locale: Self.locale) == "3×")
    }

    /// CPU per occurrence is a division, and a payload can carry a cumulative
    /// figure against a count of zero. The row drops the column rather than
    /// printing the result of that division.
    @Test("a span with no occurrences reports no per-occurrence cost")
    func signpostWithoutOccurrences() {
        let signpost = SignpostDigest(
            name: FieldSignpost.Span.trailGraphPrefetch.rawValue,
            category: FieldSignpost.category,
            count: 0,
            cpuSeconds: 4
        )
        #expect(FieldMetricsFormat.signpostValue(signpost, locale: Self.locale) == "0×")
    }

    @Test("a sub-second CPU cost reaches the row it is drawn in")
    func signpostCPUColumn() {
        let signpost = SignpostDigest(
            name: FieldSignpost.Span.hikeImport.rawValue,
            category: FieldSignpost.category,
            count: 4,
            cpuSeconds: 0.060
        )
        #expect(signpost.cpuSecondsPerOccurrence == 0.015)
        #expect(
            FieldMetricsFormat.signpostValue(signpost, locale: Self.locale)
                == "4× · 15 ms CPU each"
        )
    }

    // MARK: - Diagnostics

    /// One diagnostic kind carries seconds, one carries bytes, and the rest
    /// carry a reason. Each says the one thing its own kind measured.
    @Test("a diagnostic says the measurement its kind carries")
    func diagnosticValues() {
        let hang = FieldDiagnosticDigest(kind: .hang, seconds: 2.5)
        let write = FieldDiagnosticDigest(kind: .diskWriteException, bytes: 1_048_576)
        let crash = FieldDiagnosticDigest(kind: .crash, reason: "EXC_BAD_ACCESS")

        #expect(FieldMetricsFormat.diagnosticValue(hang, locale: Self.locale) == "2.5s")
        #expect(FieldMetricsFormat.diagnosticValue(write, locale: Self.locale) == "1 MB")
        #expect(FieldMetricsFormat.diagnosticValue(crash, locale: Self.locale) == "EXC_BAD_ACCESS")
    }

    /// A crash MetricKit sent no termination reason for still gets a row, and
    /// the row says there is no detail rather than being blank.
    @Test("a diagnostic carrying nothing says so")
    func diagnosticWithoutDetail() {
        let bare = FieldDiagnosticDigest(kind: .crash)
        #expect(FieldMetricsFormat.diagnosticValue(bare, locale: Self.locale) == "No detail")
    }

    // MARK: - The report's own header

    /// The period is the two dates in order, separated by an en dash. The
    /// dates themselves are the region's; the order and the separator are not.
    @Test("a period reads from its start to its end")
    func period() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86_400)
        let report = Self.report(from: start, to: end)
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Self.locale)

        #expect(
            FieldMetricsFormat.period(report, locale: Self.locale)
                == "\(start.formatted(style)) – \(end.formatted(style))"
        )
    }

    /// A build number is what separates two uploads of the same version, so it
    /// is shown when there is one and nothing stands in for it when there is
    /// not.
    @Test("a version carries its build only when the payload named one")
    func version() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var report = Self.report(from: start, to: start.addingTimeInterval(86_400))
        #expect(FieldMetricsFormat.version(report) == "1.4")

        report.appBuild = "312"
        #expect(FieldMetricsFormat.version(report) == "1.4 (312)")
    }

    private static func report(from start: Date, to end: Date) -> FieldMetricsReport {
        FieldMetricsReport(
            receivedAt: end,
            periodStart: start,
            periodEnd: end,
            appVersion: "1.4",
            content: .metrics(FieldMetricsDigest())
        )
    }
}
