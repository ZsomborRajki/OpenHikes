//
//  CommunityPublishingCheckTests+FailedReads.swift
//  OpenHikesTests
//
//  A read that failed is not a read that found nothing. The retread check
//  compares this hike's line with the line of every hike already shared, and
//  a line with no points retraces nothing, so a fetch that failed, of either,
//  used to answer the check as eligible (#1354). A real store does not fail a
//  fetch on demand, so the check's two fetch seams fail the calls a test
//  names.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

/// What the fetch of the hikes already shared throws, when a test fails it.
nonisolated private struct SharedHikesFailure: Error {}

extension CommunityPublishingCheckTests {
    /// A hike sent yesterday and still waiting for review, and the same walk
    /// again, saved, as an upload's own save has them: a retread, refused,
    /// whenever both lines can be read.
    private static func walkedAgain(in context: ModelContext) throws -> Hike {
        _ = hike(in: context, title: "Sent yesterday", route: line(), submissionID: "sub-1")
        let again = hike(in: context, title: "Same walk", route: line())
        try context.save()
        return again
    }

    /// The first failure in a row is read again at once, as a selection's
    /// line is (`SelectedLine`), so a store that failed one fetch still
    /// finds the trail already shared.
    @Test("a line that fails to read is read once more, and the retread is still found")
    func aFailedLineIsReadAgain() async throws {
        let context = try Fixture.modelContext()
        let again = try Self.walkedAgain(in: context)
        let fetch = FailingLineFetch(failing: [1])

        let eligibility = await CommunityPublishingCheck.eligibility(of: again, in: context, fetchLine: fetch.fetch)

        #expect(eligibility == .refused(.retreads(title: "Sent yesterday")))
        #expect(fetch.count == 2, "the read that failed and the one more it asked for")
    }

    /// The case #1354 reported: the failed read's line has no points, so it
    /// retraced nothing, and the hike was offered as eligible.
    @Test("a line that cannot be read is not counted as retracing nothing")
    func anUnreadLineIsNotEligible() async throws {
        let context = try Fixture.modelContext()
        let again = try Self.walkedAgain(in: context)
        let fetch = FailingLineFetch(failing: [1, 2])

        let eligibility = await CommunityPublishingCheck.eligibility(of: again, in: context, fetchLine: fetch.fetch)

        #expect(eligibility == nil, "the check could not be made")
        #expect(fetch.count == 2, "one more read, and no more")
    }

    /// The same for the other half of the comparison: no hikes already shared
    /// is an answer, and a fetch of them that failed is not.
    @Test("hikes already shared that cannot be fetched are not counted as none")
    func unreadSharedHikesAreNotNone() async throws {
        let context = try Fixture.modelContext()
        let again = try Self.walkedAgain(in: context)

        let eligibility = await CommunityPublishingCheck.eligibility(
            of: again,
            in: context,
            fetchShared: { _ in throw SharedHikesFailure() }
        )

        #expect(eligibility == nil, "the check could not be made")
    }

    /// Nothing already shared is nothing to retrace, whatever this hike's
    /// line is, so its line is not needed and a read of it that fails is not
    /// a reason to hold the form.
    @Test("with nothing already shared, a line that cannot be read changes nothing")
    func nothingSharedNeedsNoLine() async throws {
        let context = try Fixture.modelContext()
        let first = Self.hike(in: context, title: "Ridge", route: Self.line())
        try context.save()
        let fetch = FailingLineFetch(failing: [1, 2])

        let eligibility = await CommunityPublishingCheck.eligibility(of: first, in: context, fetchLine: fetch.fetch)

        #expect(eligibility == .eligible)
    }
}
