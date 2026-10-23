//
//  TrailDraftElevationTests+Ordering.swift
//  OpenHikesTests
//
//  Two questions out at once, answered oldest first. A drawing edit cancels
//  the question in flight and asks a new one, and cancellation is
//  cooperative, so the older answer can arrive while the newer question is
//  still out — see ``HeldHeightSource``.
//

@testable import OpenHikes
import OpenHikesData
import Testing

extension TrailDraftElevationTests {
    /// A cancelled question that answers late is not the question the spinner
    /// is about. Nothing promises a source returns before its successor is
    /// asked, so the older one answering used to stop the spinner while the
    /// newer one was still out — #933.
    ///
    /// Each question's task is awaited rather than settled on. A cancelled
    /// question that answers changes nothing, so there is no effect to wait
    /// for, and an assertion made before its task has finished would pass
    /// whether or not that task switches the spinner off.
    @Test("a cancelled question answering late leaves its successor's spinner running")
    func aLateCancelledAnswerKeepsTheSpinner() async throws {
        let draft = Self.draft()
        let source = HeldHeightSource()
        let elevation = Self.elevation(of: draft, source: source)
        defer { source.answerAll(with: Heights.all) }

        elevation.drawingDidChange()
        let older = try #require(elevation.task)
        await settleDelegateHop(until: "the first question to be asked") { source.outstanding == [1] }
        // Required rather than expected. The answers below go by number, so
        // questions asked out of turn would send each answer to the other
        // task, and the one awaited would wait forever.
        try #require(source.outstanding == [1])
        draft.append(Line.at(Line.fifth))
        elevation.drawingDidChange()
        let newer = try #require(elevation.task)
        await settleDelegateHop(until: "the second question to be asked") { source.outstanding == [1, 2] }
        try #require(source.outstanding == [1, 2])
        #expect(elevation.isMeasuring, "both questions are out")

        source.answer(1, with: Heights.all)
        await older.value

        #expect(source.outstanding == [2])
        #expect(elevation.isMeasuring, "the question about the line on screen is still out")
        #expect(elevation.summary == nil, "and the cancelled answer was not kept")

        source.answer(2, with: Heights.all)
        await newer.value

        #expect(!elevation.isMeasuring)
        #expect(source.askedCounts == [Line.all.count, Line.all.count + 1])
        #expect(try #require(elevation.summary).gainMeters == Heights.climbed)
    }
}
