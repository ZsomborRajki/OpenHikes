//
//  FieldMetricsFormatTests.swift
//  OpenHikesTests
//
//  The magnitudes `FieldMetricsFormat.duration(_:)` has to survive.
//
//  A signpost's CPU cost is reported per occurrence, and two of the app's
//  four spans are short: an import is a parse, a prefetch is a fetch and a
//  decode, both plausibly tens of milliseconds each. Seconds at a fixed
//  fraction length rounded all of that to "0s" — the same string a span that
//  cost nothing gets — which is the collapse of an absent measurement into a
//  zero that this file's subject exists to prevent.
//
//  Formatted numbers carry the host's locale, so the cases assert on the
//  digits and the unit rather than on a whole string, and — where the point
//  is that two facts must not look alike — on the two strings differing.
//

@testable import OpenHikes
import Testing

@Suite("Field metrics format")
nonisolated struct FieldMetricsFormatTests {
    // MARK: - Sub-second durations

    @Test("a fifteen millisecond cost is not written down as a zero")
    func subSecondDuration() {
        let fifteenMilliseconds = FieldMetricsFormat.duration(0.015)
        #expect(fifteenMilliseconds.contains("15"))
        #expect(fifteenMilliseconds.hasSuffix(" ms"))
        #expect(fifteenMilliseconds != FieldMetricsFormat.duration(0))
    }

    @Test("every value the old fraction length flattened stays distinct")
    func flattenedValuesStayDistinct() {
        let strings = [0.0, 0.015, 0.040, 0.049].map(FieldMetricsFormat.duration)
        #expect(Set(strings).count == strings.count)
    }

    @Test("a true zero still reads as a zero")
    func zeroDuration() {
        #expect(FieldMetricsFormat.duration(0) == "0s")
    }

    @Test("a missing duration is not a zero")
    func absentDuration() {
        #expect(FieldMetricsFormat.duration(nil) == FieldMetricsFormat.notReported)
    }

    // MARK: - The larger bands

    @Test("seconds, minutes and hours are unchanged")
    func magnitudeBands() {
        #expect(FieldMetricsFormat.duration(1).hasSuffix("s"))
        #expect(!FieldMetricsFormat.duration(1).hasSuffix(" ms"))
        #expect(FieldMetricsFormat.duration(59).hasSuffix("s"))
        #expect(FieldMetricsFormat.duration(60).hasSuffix(" min"))
        #expect(FieldMetricsFormat.duration(3599).hasSuffix(" min"))
        #expect(FieldMetricsFormat.duration(3600).hasSuffix(" h"))
    }

    // MARK: - The column it was reported from

    @Test("a span's sub-second CPU cost reaches the row it is drawn in")
    func signpostCPUColumn() {
        let signpost = SignpostDigest(
            name: FieldSignpost.Span.hikeImport.rawValue,
            category: FieldSignpost.category,
            count: 4,
            cpuSeconds: 0.060
        )
        #expect(signpost.cpuSecondsPerOccurrence == 0.015)
        #expect(FieldMetricsFormat.signpostValue(signpost).contains("15 ms CPU each"))
    }
}
