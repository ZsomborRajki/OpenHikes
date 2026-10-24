//
//  CommunitySharePhotoChoicesTests.swift
//  OpenHikesTests
//
//  Which tiles on a send form's strip go, and which the cap holds back (#1031).
//
//  The strip drew two states, ticked or struck off, and a ticked tile past
//  ``CommunityPublisher/maximumPhotos`` looked and read exactly like one that
//  goes. ``CommunitySharePhotoChoices`` is what tells the three apart, worked
//  out from the upload's own rule; the strip and the viewer that draw it are
//  body code, so this is where the rule is reachable.
//
//  The rows carry no pixels: which of them have a file here is an input, the
//  answer a form keeps from ``CommunityPublisher/photosOnThisDevice(among:store:)``.
//  `CommunitySharePhotoCountTests` follows the same rule into a real upload.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Community share photo choices")
struct CommunitySharePhotoChoicesTests {
    private static let cap = CommunityPublisher.maximumPhotos

    private static func photos(_ count: Int) -> [HikePhoto] {
        (0..<count).map { index in
            HikePhoto(capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60))
        }
    }

    @Test("a ticked tile past the cap is over the limit, not shared")
    func tilesPastTheCapAreOverTheLimit() {
        let photos = Self.photos(Self.cap + 2)

        let choices = CommunitySharePhotoChoices(
            photos: photos,
            excluding: [],
            files: .answered(Set(photos.map(\.id)))
        )

        #expect(photos.prefix(Self.cap).allSatisfy { choices.choice(for: $0) == .shared })
        #expect(photos.suffix(2).allSatisfy { choices.choice(for: $0) == .overTheLimit })
        #expect(choices.sharedCount == Self.cap)
    }

    /// Which tiles fall past the cap moves as the hiker strikes pictures off,
    /// because an exclusion lets the next one in.
    @Test("striking one off brings the first tile past the cap in")
    func anExclusionMovesTheLimit() {
        let photos = Self.photos(Self.cap + 2)

        let choices = CommunitySharePhotoChoices(
            photos: photos,
            excluding: [photos[0].id],
            files: .answered(Set(photos.map(\.id)))
        )

        #expect(choices.choice(for: photos[0]) == .struckOff)
        #expect(choices.choice(for: photos[Self.cap]) == .shared)
        #expect(choices.choice(for: photos[Self.cap + 1]) == .overTheLimit)
        #expect(choices.sharedCount == Self.cap)
    }

    /// The issue's own case: rows with no file here lead the strip. They hold
    /// no place under the cap, so the pictures behind them are not over it.
    @Test("rows with no file here do not push a picture past the cap")
    func missingFilesHoldNoPlace() {
        let elsewhere = Self.photos(4)
        let here = Self.photos(Self.cap)

        let choices = CommunitySharePhotoChoices(
            photos: elsewhere + here,
            excluding: [],
            files: .answered(Set(here.map(\.id)))
        )

        #expect(here.allSatisfy { choices.choice(for: $0) == .shared })
        #expect(
            elsewhere.allSatisfy { choices.choice(for: $0) != .overTheLimit },
            "a picture with no file here is drawn as unavailable, not as over the limit"
        )
        #expect(choices.sharedCount == Self.cap)
    }

    /// Before the disk answers, every row is taken to have its file — the
    /// estimate the count row makes too — so the cap still shows.
    @Test("before the disk answers, the rows are the estimate")
    func rowsAreTheEstimateUntilTheDiskAnswers() {
        let photos = Self.photos(Self.cap + 1)

        let choices = CommunitySharePhotoChoices(photos: photos, excluding: [], files: .unasked)

        #expect(choices.choice(for: photos[Self.cap]) == .overTheLimit)
        #expect(choices.sharedCount == Self.cap)
    }

    @Test("a tile past the cap says it is over the limit and not shared")
    func theLabelNamesTheLimit() throws {
        let photo = try #require(Self.photos(1).first)

        let label = CommunitySharePhotoStrip.label(for: photo, choice: .overTheLimit, among: Self.cap + 1)

        #expect(label.hasSuffix("over the limit of \(Self.cap), not shared"))
        #expect(
            CommunitySharePhotoStrip.label(for: photo, choice: .shared, among: Self.cap + 1).hasSuffix(", shared"),
            "the tile that goes still says so"
        )

        var sent = photo
        sent.sentToCommunityAt = Date(timeIntervalSince1970: 1_700_001_000)
        let sentLabel = CommunitySharePhotoStrip.label(for: sent, choice: .overTheLimit, among: Self.cap + 1)
        #expect(sentLabel.contains("already sent"))
        #expect(sentLabel.hasSuffix("over the limit of \(Self.cap), not shared again"))
    }

    /// The tick has a shape for each state, so the cap's state is not told
    /// apart from the others by tint alone.
    @Test("each state has a glyph of its own")
    func eachStateHasItsOwnGlyph() {
        let symbols: [CommunitySharePhotoChoices.Choice] = [.shared, .struckOff, .overTheLimit]
        #expect(Set(symbols.map(CommunitySharePhotoStrip.symbol(for:))).count == 3)
    }
}
