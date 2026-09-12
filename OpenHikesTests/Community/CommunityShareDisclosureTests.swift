//
//  CommunityShareDisclosureTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// What the share screen promises, held against what the upload carries.
///
/// The two are written in different files — `CommunityShareSheet` says it and
/// `CommunityPublisher` does it — and the first version of this screen told a
/// hiker sharing a hike with no photographs that it sent "your route and its
/// name, nothing else" while the draft carried the hike's description, its
/// date, and a timestamp on every point of the route. So these assert the
/// wording against a real draft rather than against itself.
@MainActor
@Suite("Community share disclosure")
struct CommunityShareDisclosureTests {
    private static func disclosure(for draft: CommunitySubmissionDraft) -> String {
        CommunityShareDisclosure.text(
            hasNotes: CommunityShareDisclosure.notes(from: draft.trackDescription) != nil,
            photoCount: draft.photoFileURLs.count
        )
    }

    private static func draft(
        describedAs description: String? = nil
    ) async throws -> CommunitySubmissionDraft {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.trackDescription = description }
        let transport = StubCommunityTransport()
        _ = await CommunityPublisher.share(hike, authorName: "Anna", transport: transport)
        return try #require(transport.recording.submissions.first)
    }

    /// The one the reviewer caught: a GPX file's description can be personal
    /// notes the hiker has not seen since the import, and it is published
    /// under their name.
    @Test("a description that is uploaded is disclosed")
    func uploadedDescriptionIsDisclosed() async throws {
        let draft = try await Self.draft(describedAs: "Parked at the end of my road")

        #expect(draft.trackDescription == "Parked at the end of my road")
        #expect(Self.disclosure(for: draft).contains("notes"))
    }

    /// And a hike that genuinely has nothing extra says so, or the sentence
    /// would be describing a field that is not there.
    @Test("a hike with no description promises no notes")
    func absentDescriptionIsNotClaimed() async throws {
        let draft = try await Self.draft()

        #expect(draft.trackDescription == nil)
        #expect(!Self.disclosure(for: draft).contains("notes"))
    }

    /// A blank description is not a description. The row is not drawn for one
    /// and the sentence must not promise one either.
    @Test("a blank description is neither shown nor promised")
    func blankDescriptionIsNotNotes() {
        #expect(CommunityShareDisclosure.notes(from: "   \n ") == nil)
        #expect(CommunityShareDisclosure.notes(from: "  Steep after the gate ") == "Steep after the gate")
    }

    /// The route is the recorded one, so the walk's pace goes up with its
    /// line. Saying "your route" alone read as a shape on a map.
    @Test("the timing carried by the route is disclosed")
    func routeTimingIsDisclosed() async throws {
        let draft = try await Self.draft()

        #expect(draft.route.contains { $0.timestamp != nil })
        #expect(Self.disclosure(for: draft).contains("the time you reached it"))
        #expect(Self.disclosure(for: draft).contains("the date you walked it"))
    }

    /// Whatever else it says, the sentence ends by claiming the list is
    /// complete — which is the claim the rest of this suite is checking.
    @Test("every wording closes the list")
    func everyWordingClosesTheList() {
        for hasNotes in [true, false] {
            for photoCount in [0, 1, 5] {
                let text = CommunityShareDisclosure.text(
                    hasNotes: hasNotes,
                    photoCount: photoCount
                )
                #expect(text.hasSuffix("Nothing else from this hike."))
            }
        }
    }

    @Test("photographs are counted and their stripping is stated")
    func photoWordingCountsAndReassures() {
        let one = CommunityShareDisclosure.text(hasNotes: false, photoCount: 1)
        #expect(one.contains("One photo goes with it"))
        #expect(one.contains("original location data"))

        let several = CommunityShareDisclosure.text(hasNotes: false, photoCount: 4)
        #expect(several.contains("4 photos go with it"))

        #expect(!CommunityShareDisclosure.text(hasNotes: false, photoCount: 0).contains("photo"))
    }
}
