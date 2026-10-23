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
    @Test("a cancelled question answering late leaves its successor's spinner running")
    func aLateCancelledAnswerKeepsTheSpinner() async throws {
        let draft = Self.draft()
        let source = HeldHeightSource()
        let elevation = Self.elevation(of: draft, source: source)
        defer { source.answerAll(with: Heights.all) }

        elevation.drawingDidChange()
        await Self.settle { source.outstanding == [1] }
        draft.append(Line.at(Line.fifth))
        elevation.drawingDidChange()
        await Self.settle { source.outstanding == [1, 2] }
        #expect(elevation.isMeasuring, "both questions are out")

        source.answer(1, with: Heights.all)
        await Self.settle { !elevation.isMeasuring }

        #expect(source.outstanding == [2])
        #expect(elevation.isMeasuring, "the question about the line on screen is still out")
        #expect(elevation.summary == nil, "and the cancelled answer was not kept")

        source.answer(2, with: Heights.all)
        await Self.settle { !elevation.isMeasuring }

        #expect(!elevation.isMeasuring)
        #expect(source.askedCounts == [Line.all.count, Line.all.count + 1])
        #expect(try #require(elevation.summary).gainMeters == Heights.climbed)
    }
}
