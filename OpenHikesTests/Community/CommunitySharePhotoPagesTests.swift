//
//  CommunitySharePhotoPagesTests.swift
//  OpenHikesTests
//
//  The share gallery's positions and choices, kept while nothing they are
//  made from moves. A page turned is a body pass that reads both again, and
//  must neither search the photographs nor rebuild the choices; a picture
//  struck off, an answer from the disk or a new list of photographs is a
//  rebuild, and the choice it reads is the new one.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Community share photo pages")
struct CommunitySharePhotoPagesTests {
    private static let cap = CommunityPublisher.maximumPhotos

    private static func photos(_ count: Int) -> [HikePhoto] {
        (0..<count).map { index in
            HikePhoto(capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60))
        }
    }

    @Test("turning pages reads positions and choices without working either out again")
    func pageTurnsRebuildNothing() {
        let photos = Self.photos(Self.cap + 3)
        let pages = CommunitySharePhotoPages()

        for (offset, photo) in photos.enumerated() {
            #expect(pages.index(of: photo.id, in: photos) == offset)
            _ = pages.choices(for: photos, excluding: [], files: .unasked)
        }

        #expect(pages.indexBuilds == 1)
        #expect(pages.choiceBuilds == 1)
    }

    @Test("a photograph not among the pages, or none, has no position")
    func unknownHasNoPosition() {
        let photos = Self.photos(3)
        let pages = CommunitySharePhotoPages()

        #expect(pages.index(of: nil, in: photos) == nil)
        #expect(pages.index(of: UUID(), in: photos) == nil)
    }

    /// The toggle writes the form's set; the next pass must read the choice
    /// it made, and the picture it let in past the cap.
    @Test("striking a picture off is a new choice, and lets the next one in")
    func exclusionRebuilds() {
        let photos = Self.photos(Self.cap + 1)
        let pages = CommunitySharePhotoPages()
        let before = pages.choices(for: photos, excluding: [], files: .unasked)
        #expect(before.choice(for: photos[Self.cap]) == .overTheLimit)

        let after = pages.choices(for: photos, excluding: [photos[0].id], files: .unasked)

        #expect(after.choice(for: photos[0]) == .struckOff)
        #expect(after.choice(for: photos[Self.cap]) == .shared)
        #expect(pages.choiceBuilds == 2)
        #expect(pages.indexBuilds == 1)
    }

    /// A picture whose file is elsewhere holds no place under the cap, so the
    /// disk's answer moves which tile is over the limit.
    @Test("the disk's answer is a new choice")
    func filesAnswerRebuilds() {
        let photos = Self.photos(Self.cap + 1)
        let pages = CommunitySharePhotoPages()
        _ = pages.choices(for: photos, excluding: [], files: .unasked)

        let elsewhere = photos[0].id
        let answered = pages.choices(
            for: photos,
            excluding: [],
            files: .answered(Set(photos.map(\.id)).subtracting([elsewhere]))
        )

        #expect(answered.choice(for: photos[Self.cap]) == .shared)
        #expect(answered.sharedCount == Self.cap)
        #expect(pages.choiceBuilds == 2)
    }

    @Test("a new list of photographs is indexed and chosen afresh")
    func newPhotosRebuild() {
        let first = Self.photos(3)
        let second = Array(first.reversed()) + Self.photos(1)
        let pages = CommunitySharePhotoPages()
        _ = pages.choices(for: first, excluding: [], files: .unasked)

        #expect(pages.index(of: first[0].id, in: second) == 2)
        let choices = pages.choices(for: second, excluding: [], files: .unasked)

        #expect(choices.sharedCount == 4)
        #expect(pages.indexBuilds == 2)
        #expect(pages.choiceBuilds == 2)
    }

    /// The form re-derives its list on its own passes, so the viewer can be
    /// handed a new array holding the same photographs. Equal is unchanged.
    @Test("the same photographs in a new array are not a new list")
    func equalCopyIsNotANewList() {
        let photos = Self.photos(4)
        let pages = CommunitySharePhotoPages()
        _ = pages.choices(for: photos, excluding: [], files: .unasked)

        let copy = photos.map(\.self)
        _ = pages.choices(for: copy, excluding: [], files: .unasked)

        #expect(pages.indexBuilds == 1)
        #expect(pages.choiceBuilds == 1)
    }

    /// A tap writes the form's set, and the form's pass hands the viewer its
    /// photographs again in a new array. Kept on the array before it, every
    /// page turned after that tap compared the two photograph by photograph,
    /// once for the position and once for the choices. Held, the next pass
    /// hands in the array held, and the comparison is of storage alone.
    @Test("the same photographs in a new array are held in place of the old")
    func equalCopyIsHeld() {
        let photos = Self.photos(4)
        let pages = CommunitySharePhotoPages()
        _ = pages.choices(for: photos, excluding: [], files: .unasked)
        let copy = photos.map(\.self)
        #expect(!Self.sharesStorage(copy, photos))

        _ = pages.index(of: copy[0].id, in: copy)
        #expect(Self.sharesStorage(pages.photos, copy))

        let another = copy.map(\.self)
        _ = pages.choices(for: another, excluding: [], files: .unasked)
        #expect(Self.sharesStorage(pages.photos, another))
        #expect(pages.indexBuilds == 1)
        #expect(pages.choiceBuilds == 1)
    }

    /// Whether two arrays are one buffer, which is when `==` answers without
    /// comparing a photograph.
    private static func sharesStorage(_ lhs: [HikePhoto], _ rhs: [HikePhoto]) -> Bool {
        lhs.withUnsafeBufferPointer { lhs in
            rhs.withUnsafeBufferPointer { rhs in lhs.baseAddress == rhs.baseAddress }
        }
    }
}
