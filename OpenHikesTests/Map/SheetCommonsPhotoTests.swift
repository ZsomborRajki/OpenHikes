//
//  SheetCommonsPhotoTests.swift
//  OpenHikesTests
//
//  Opening a Wikimedia Commons photograph the *Community* tab found, or a
//  group of them: each screen is pushed through
//  ``SheetPresentation/showCommonsPhoto(_:)`` or
//  ``SheetPresentation/showCommonsPhotos(_:)`` on the terms a shared hike's
//  preview is — never twice, and a jump rather than a step deeper — and a
//  photograph is the same screen whatever search downloaded it. A photograph
//  opened from a group's grid is the one step deeper, and goes over it; the
//  gallery a photograph's screen opens is one step deeper again, and holds
//  the page it is on for as long as it is pushed. A photograph's screen
//  brings it into view once a push, whichever host draws it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Testing

@MainActor
@Suite("Sheet Commons photo pushes")
struct SheetCommonsPhotoTests {
    private static func photo(_ page: Int, downloadedAs file: String = "a") -> CommonsPhoto {
        CommonsPhoto(
            pin: CommunityPhotoPin(
                capturedAt: Date(timeIntervalSince1970: 1_600_000_000),
                coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: 13.0)
            ),
            fileURL: URL(filePath: "/tmp/community-commons/\(file)/commons-\(page).jpeg"),
            credit: CommonsPhotoCredit(
                author: nil,
                license: HikePhotoLicense(
                    name: "CC0",
                    url: nil,
                    sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(page).jpg")
                        ?? URL(filePath: "/")
                )
            )
        )
    }

    @Test("a photograph is its Commons page, whichever search downloaded it")
    func identityIsThePage() {
        let first = SheetRoute.commonsPhoto(Self.photo(1, downloadedAs: "a"))
        let again = SheetRoute.commonsPhoto(Self.photo(1, downloadedAs: "b"))

        #expect(first == again)
        #expect(first.hashValue == again.hashValue)
        #expect(first != .commonsPhoto(Self.photo(2)))
    }

    @Test("opening a photograph pushes its screen, once")
    func opensOnce() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommonsPhoto(Self.photo(1))
        presentation.showCommonsPhoto(Self.photo(1))

        #expect(presentation.path == [.commonsPhoto(Self.photo(1))])
    }

    @Test("another photograph replaces the first rather than stacking onto it")
    func anotherReplaces() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommonsPhoto(Self.photo(1))
        presentation.showCommonsPhoto(Self.photo(2))

        #expect(presentation.path == [.commonsPhoto(Self.photo(2))])
    }

    @Test("a photograph and a shared hike's preview replace each other")
    func previewsReplacePhotographs() {
        let listing = CommunityListing.stub(id: "pilis")
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommunityHike(listing)
        presentation.showCommonsPhoto(Self.photo(1))
        #expect(presentation.path == [.commonsPhoto(Self.photo(1))])

        presentation.showCommunityHike(listing)
        #expect(presentation.path == [.communityHike(listing)])
    }

    @Test("a photograph's screen and a group's grid are nobody's hike and want no full height")
    func routeFacts() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        for route in [SheetRoute.commonsPhoto(Self.photo(1)), .commonsPhotos([Self.photo(1), Self.photo(2)])] {
            #expect(!route.shows(hikeID: hike.id))
            #expect(!route.prefersFullHeight)
            #expect(!route.revealsMapBeside)
            #expect(route.isCommunityPreview)
        }
    }

    @Test("a group is its photographs' pages, whichever search downloaded them")
    func groupIdentityIsThePages() {
        let first = SheetRoute.commonsPhotos([Self.photo(1, downloadedAs: "a"), Self.photo(2, downloadedAs: "a")])
        let again = SheetRoute.commonsPhotos([Self.photo(1, downloadedAs: "b"), Self.photo(2, downloadedAs: "b")])

        #expect(first == again)
        #expect(first.hashValue == again.hashValue)
        #expect(first != .commonsPhotos([Self.photo(1), Self.photo(3)]))
        #expect(first != .commonsPhoto(Self.photo(1)))
    }

    @Test("a group opens once, and its pin again comes back to its grid from a photograph over it")
    func groupOpensOnce() {
        let group = [Self.photo(1), Self.photo(2)]
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommonsPhotos(group)
        presentation.showCommonsPhotos(group)
        #expect(presentation.path == [.commonsPhotos(group)])

        // What a tile does — see `MapSheet+CommonsPhotos.swift`.
        presentation.path.append(.commonsPhoto(Self.photo(2)))
        presentation.showCommonsPhotos(group)
        #expect(presentation.path == [.commonsPhotos(group)])
    }

    @Test("a group, a photograph and a shared hike's preview replace each other")
    func groupsReplaceAndAreReplaced() {
        let listing = CommunityListing.stub(id: "pilis")
        let group = [Self.photo(1), Self.photo(2)]
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommunityHike(listing)
        presentation.showCommonsPhotos(group)
        #expect(presentation.path == [.commonsPhotos(group)])

        // A pin tapped over a photograph opened from the grid replaces both.
        presentation.path.append(.commonsPhoto(Self.photo(1)))
        presentation.showCommonsPhoto(Self.photo(3))
        #expect(presentation.path == [.commonsPhoto(Self.photo(3))])

        presentation.showCommonsPhotos(group)
        #expect(presentation.path == [.commonsPhotos(group)])

        presentation.showCommunityHike(listing)
        #expect(presentation.path == [.communityHike(listing)])
    }

    @Test("a gallery is the page it opened at, wants the whole sheet and is nobody's hike")
    func galleryRouteFacts() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let gallery = SheetRoute.commonsGallery([Self.photo(1), Self.photo(2)], Self.photo(2))
        let again = SheetRoute.commonsGallery([Self.photo(2, downloadedAs: "b")], Self.photo(2, downloadedAs: "b"))

        #expect(gallery == again)
        #expect(gallery.hashValue == again.hashValue)
        #expect(gallery != .commonsGallery([Self.photo(1), Self.photo(2)], Self.photo(1)))
        #expect(gallery != .commonsPhoto(Self.photo(2)))
        #expect(!gallery.shows(hikeID: hike.id))
        #expect(gallery.prefersFullHeight)
        #expect(!gallery.revealsMapBeside)
        #expect(gallery.isCommunityPreview)
    }

    /// The page is what a rotation comes back to: turning the phone rebuilds
    /// the gallery in the side panel or the sheet, and the selection the
    /// presentation holds for its route is what the new one opens at.
    @Test("a gallery over a photograph takes the whole sheet and keeps its page until it is popped")
    func galleryOverAPhotograph() {
        let photos = [Self.photo(1), Self.photo(2)]
        let gallery = SheetRoute.commonsGallery(photos, Self.photo(1))
        let presentation = SheetPresentation(detent: .medium)
        presentation.showCommonsPhoto(Self.photo(1))

        // What the photograph's header does — see `MapSheet+CommonsPhotos.swift`.
        presentation.path.append(gallery)
        #expect(presentation.detent == .large)
        #expect(presentation.isShowingFullHeightScreen)
        presentation.communityPhotoSelection(for: gallery).currentIndex = 1
        #expect(presentation.communityPhotoSelection(for: gallery).currentIndex == 1)

        presentation.path.removeLast()
        #expect(presentation.path == [.commonsPhoto(Self.photo(1))])
        #expect(presentation.detent == .medium)
        #expect(presentation.communityPhotoSelection(for: gallery).currentIndex == nil)
    }

    @Test("a pin tapped while a gallery is up replaces the gallery and its photograph")
    func pinReplacesGallery() {
        let presentation = SheetPresentation(detent: .medium)
        presentation.showCommonsPhoto(Self.photo(1))
        presentation.path.append(.commonsGallery([Self.photo(1), Self.photo(2)], Self.photo(1)))

        presentation.showCommonsPhoto(Self.photo(3))

        #expect(presentation.path == [.commonsPhoto(Self.photo(3))])
        #expect(presentation.detent == .medium)
    }

    /// A rotation builds the photograph's screen again in the other host, and
    /// a gallery popped back to it there must not take the camera off the
    /// picture its *Show on Map* framed — see ``CommonsPhotoView``.
    @Test("a photograph's screen frames it once a push, however often it is built")
    func framesOncePerPush() {
        let presentation = SheetPresentation(detent: .medium)
        let screen = SheetRoute.commonsPhoto(Self.photo(1))
        presentation.showCommonsPhoto(Self.photo(1))

        #expect(presentation.claimsFirstFraming(of: screen))
        presentation.path.append(.commonsGallery([Self.photo(1), Self.photo(2)], Self.photo(1)))
        presentation.path.removeLast()
        #expect(!presentation.claimsFirstFraming(of: screen))

        // Replaced by another photograph and opened again: a new push.
        presentation.showCommonsPhoto(Self.photo(2))
        presentation.showCommonsPhoto(Self.photo(1))
        #expect(presentation.claimsFirstFraming(of: screen))
    }
}
