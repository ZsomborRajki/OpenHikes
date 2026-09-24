//
//  CommunityPublishingEligibilityTests.swift
//  OpenHikesTests
//
//  The gate in front of publishing, and the three things it is allowed to be
//  certain about.
//
//  The bug these exist for: `CommunityImport` stamps `importedFromListingID`
//  on a hike saved from somebody else's listing, and the share button never
//  asked. `CommunityPublicationState` knew three states — not shared, awaiting
//  review, published — and a hike saved from a stranger's listing is *not
//  shared*, because this hiker has not shared it. So it got the plain **Share
//  with the community** button, and publishing from there uploaded a
//  stranger's route, their description and re-encoded copies of up to twelve
//  of their photographs, credited to whatever name the saver typed.
//
//  The terms already said a hiker may not do that, and the share form repeated
//  it as advice. This is the one case where the app knows the answer, so advice
//  was the wrong instrument.
//
//  ## And what those refusals became
//
//  Two of them are not refusals any more. What a saved trail actually
//  establishes is that the *route* is already in the list — and the hiker's
//  own photographs are not — so both answer
//  ``CommunityPublishingEligibility/photographsOnly(_:because:)`` with the
//  listing to put them on. The reasons survive unchanged and are still what
//  the screen says; what changed is what happens underneath the sentence.
//
//  So these assert both halves of each answer: the ``Reason``, which is what a
//  hiker reads, and the ``CommunityPhotoTarget``, which is what the upload
//  aims at. A target with the wrong listing id is the one failure here that
//  nothing downstream could catch — the photographs would be published, onto
//  somebody else's trail.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Community publishing eligibility")
struct CommunityPublishingEligibilityTests {
    private static func of(
        listingID: String? = nil,
        author: String? = nil,
        meters: Double = 5000,
        title: String = "Ostwand Scramble"
    ) -> CommunityPublishingEligibility {
        .of(
            importedFromListingID: listingID,
            importedAuthorName: author,
            distanceMeters: meters,
            title: title
        )
    }

    @Test("an ordinary recorded walk may be published")
    func ordinaryWalk() {
        #expect(Self.of() == .eligible)
        #expect(Self.of().isEligible)
        #expect(Self.of().reason == nil)
    }

    /// The case the issue is about, and the only one where the app is certain
    /// rather than asking the hiker to judge.
    ///
    /// The route still does not go. What goes instead is the photographs, onto
    /// the listing this hike was saved from — which is why the target's id has
    /// to be *that* listing and not this hike's anything.
    @Test("a hike saved from the community offers its photographs instead")
    func savedFromTheCommunity() {
        let eligibility = Self.of(listingID: "listing-1", author: "Anna")
        #expect(!eligibility.isEligible)
        #expect(eligibility.reason == .savedFromTheCommunity(author: "Anna"))
        #expect(eligibility.photoTarget?.listingID == "listing-1")
        #expect(eligibility.photoTarget?.authorName == "Anna")
        #expect(eligibility.photoTarget?.isCurated == false)
    }

    /// A curated route is its own case and its own sentence — there is nobody
    /// to credit — and the target has to know it came from OpenStreetMap,
    /// because that is the half of the list with no photographs at all.
    @Test("a trail saved from OpenStreetMap offers its photographs too")
    func savedFromOpenStreetMap() {
        let id = CommunityIdentity.curated(relationID: 12_345)
        let eligibility = Self.of(listingID: id, author: nil)
        #expect(eligibility.reason == .savedFromOpenStreetMap)
        #expect(eligibility.photoTarget?.listingID == id)
        #expect(eligibility.photoTarget?.isCurated == true)
        // Nobody published it, so there is nobody to name.
        #expect(eligibility.photoTarget?.authorName == nil)
    }

    /// A listing shared without a name is still somebody else's trail; the
    /// sentence just has to say it differently, and the target carries no
    /// credit to show.
    @Test("an import with no credit is still an import")
    func savedWithoutACredit() {
        let eligibility = Self.of(listingID: "listing-1")
        #expect(eligibility.reason == .savedFromTheCommunity(author: nil))
        #expect(eligibility.photoTarget?.authorName == nil)
        let explanation = CommunityPublishingEligibility.Reason
            .savedFromTheCommunity(author: nil).explanation()
        #expect(explanation.contains("Another hiker"))
    }

    /// Whitespace is not a credit. A target carrying `"  "` would put an empty
    /// row on the share form under the heading *Shared by*.
    @Test("a blank credit is no credit")
    func blankCreditIsNoCredit() {
        #expect(Self.of(listingID: "listing-1", author: "   ").photoTarget?.authorName == nil)
    }

    /// The hiker's own copy's name, which is what the form calls the trail
    /// they are adding to. Nothing writes it anywhere — see
    /// ``CommunityPhotoTarget/title`` — but a form headed with the wrong walk
    /// is a hiker sending pictures to a trail they did not mean.
    @Test("the target is named by the hike it was saved as")
    func targetCarriesTheTitle() {
        let eligibility = Self.of(listingID: "listing-1", title: "Almbachklamm")
        #expect(eligibility.photoTarget?.title == "Almbachklamm")
    }

    /// **A GPX imported from anywhere else is not an import in this sense.**
    ///
    /// A route downloaded from another provider, walked, and given the hiker's
    /// own photographs is exactly what this feature is for, and it carries no
    /// `importedFromListingID` — only a hike saved out of this app's own
    /// community does. A rule that refused every imported file would empty the
    /// list of the hikes most worth having in it.
    @Test("a hike imported from a file is not refused")
    func importedFromAFile() {
        #expect(Self.of(listingID: nil, author: nil) == .eligible)
    }

    /// The floor, from both sides of it. Pinned against the constant rather
    /// than against 1,000 written out again, so moving the floor moves the
    /// test with it rather than leaving it asserting a number nothing uses.
    @Test("a walk under the floor is refused and one on it is not")
    func theFloor() {
        let floor = CommunityPublishingEligibility.minimumDistanceMeters
        #expect(Self.of(meters: floor) == .eligible)
        #expect(Self.of(meters: floor - 1) == .refused(.tooShort(meters: floor - 1)))
        #expect(Self.of(meters: 0) == .refused(.tooShort(meters: 0)))
    }

    /// Provenance first, and the floor never reached. A saved trail offers its
    /// photographs however short the walk was, which is the ordering doing
    /// something rather than merely deciding which sentence to show: the floor
    /// asks *is this a walk worth listing*, and a contribution is not listing a
    /// walk. Half a mile up a gorge can still be the photograph the trail was
    /// missing.
    @Test("a short walk on a saved trail still offers its photographs")
    func provenanceOutranksLength() {
        let eligibility = Self.of(listingID: "listing-1", author: "Anna", meters: 10)
        #expect(eligibility.reason == .savedFromTheCommunity(author: "Anna"))
        #expect(eligibility.photoTarget?.listingID == "listing-1")
    }

    /// The one refusal with nothing behind it. A short walk that retraces
    /// nothing has no trail in the list to attach to, so the offer has to be
    /// absent rather than aimed at the hike itself.
    @Test("a short walk that retraces nothing offers nothing")
    func tooShortOffersNothing() {
        let eligibility = Self.of(meters: 10)
        #expect(eligibility == .refused(.tooShort(meters: 10)))
        #expect(eligibility.photoTarget == nil)
        #expect(!eligibility.offersPhotographs)
    }

    /// Every reason has to name the thing the hiker can still do. A dead end
    /// reads as the feature being broken rather than as a rule.
    @Test("every reason says what to do instead", arguments: [
        CommunityPublishingEligibility.Reason.savedFromTheCommunity(author: "Anna"),
        .savedFromOpenStreetMap,
        .tooShort(meters: 300),
        .retreads(title: "Thumsee Ridge Traverse"),
    ])
    func refusalsAreActionable(reason: CommunityPublishingEligibility.Reason) {
        #expect(!reason.title.isEmpty)
        #expect(!reason.shortLabel.isEmpty)
        #expect(reason.explanation().count > reason.title.count)
    }

    /// The specifics are what make a refusal checkable: a hiker who is told
    /// "too short" and not how short, or "already shared" and not which one,
    /// has been given a verdict rather than a reason.
    @Test("a refusal names the hike and the author")
    func refusalsCarryTheirSpecifics() {
        #expect(
            CommunityPublishingEligibility.Reason
                .savedFromTheCommunity(author: "Anna").explanation().contains("Anna")
        )
        #expect(
            CommunityPublishingEligibility.Reason
                .retreads(title: "Thumsee Ridge Traverse")
                .explanation()
                .contains("Thumsee Ridge Traverse")
        )
    }

    /// The other specific, and the one that is regional: the floor and the
    /// walk, in the same unit as the stat grid the hiker just read.
    ///
    /// This was half of the test above, asked of `Locale.current` and pinned
    /// as `"1 km" || "0.6 mi"`. That passes on a metric machine and fails on
    /// CI, whose simulator is `en_US` and renders the floor as "0.62 mi" —
    /// which is neither string. `ElevationFormatTests`' two rules apply here
    /// for the same reason they do there: nothing regional may be asked of
    /// `Locale.current`, and each figure is pinned whole rather than as
    /// "contains mi", so a change to the unit, the rounding or the grouping
    /// separator has to be argued for rather than discovered.
    ///
    /// Both figures per region, because the pair is the point: a floor quoted
    /// in a different unit from the distance it is being compared against is a
    /// refusal nobody can check.
    @Test("the floor and the walk are quoted in the reader's own units", arguments: [
        ("de_DE", "1 km", "300 m"),
        ("ja_JP", "1 km", "300 m"),
        ("en_US", "0.62 mi", "1,000 ft"),
        ("en_GB", "0.62 mi", "350 yd"),
    ])
    func theFloorAndTheWalkAreRegional(identifier: String, floor: String, walked: String) {
        let explanation = CommunityPublishingEligibility.Reason
            .tooShort(meters: 300)
            .explanation(locale: Locale(identifier: identifier))
        #expect(explanation.contains(floor), "\(identifier) drew \"\(explanation)\"")
        #expect(explanation.contains(walked), "\(identifier) drew \"\(explanation)\"")
    }

    /// The two sentences that are now *promises* rather than advice, and the
    /// one that deliberately is not.
    ///
    /// A saved trail always has somewhere for its pictures to go, so both of
    /// those explanations may say so. ``retreads`` reaches both answers —
    /// published is a target and awaiting-review is not — so its sentence has
    /// to hold either way, and promising the photographs there would be a
    /// promise half its readers cannot have. The offer is the control's job,
    /// not the sentence's.
    @Test("only the two that always offer say the photographs can go")
    func onlyTheCertainOnesPromise() {
        let saved = CommunityPublishingEligibility.Reason
            .savedFromTheCommunity(author: "Anna").explanation()
        let curated = CommunityPublishingEligibility.Reason
            .savedFromOpenStreetMap.explanation()
        let retread = CommunityPublishingEligibility.Reason
            .retreads(title: "Thumsee Ridge Traverse").explanation()
        #expect(saved.contains("photographs") || saved.contains("photos"))
        #expect(curated.contains("photograph") || curated.contains("photo"))
        #expect(!retread.contains("photograph") && !retread.contains("photo"))
    }

    /// Only a hiker's own credit is ever shown beside a contribution, and only
    /// one of the four reasons has one. A curated trail has nobody; a retread
    /// is the hiker themselves, and naming them back to themselves would read
    /// as a stranger.
    @Test("only a community import names somebody to credit")
    func onlyACommunityImportHasAnAuthor() {
        #expect(
            CommunityPublishingEligibility.Reason
                .savedFromTheCommunity(author: "Anna").creditedAuthor == "Anna"
        )
        #expect(CommunityPublishingEligibility.Reason.savedFromOpenStreetMap.creditedAuthor == nil)
        #expect(
            CommunityPublishingEligibility.Reason
                .retreads(title: "Anything").creditedAuthor == nil
        )
        #expect(CommunityPublishingEligibility.Reason.tooShort(meters: 1).creditedAuthor == nil)
    }
}
