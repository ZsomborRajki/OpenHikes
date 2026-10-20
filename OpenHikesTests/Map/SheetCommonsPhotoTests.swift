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
//  opened from a group's grid is the one step deeper, and goes over it.
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
}
