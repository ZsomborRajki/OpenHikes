//
//  TrailDraftPhotoControllerTests.swift
//  OpenHikesTests
//
//  The trail maker's *Photos* chip, from the controller's side: what the pill
//  asks with it on, what turning it off takes away, and the card a photograph
//  opens — *Add Stop* at the camera's own position.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Trail draft photo controller")
struct TrailDraftPhotoControllerTests {
    /// Commons, answering one photograph a few hundred metres north of the
    /// middle of whatever area it is asked about.
    nonisolated private struct OnePhotoSource: CommonsPhotoSourcing {
        @concurrent
        func photos(along route: [RouteCoordinate], downloadingInto directory: URL) async -> [CommonsPhoto] {
            []
        }

        @concurrent
        func photos(
            in area: CommunitySearchArea,
            avoiding shown: Set<URL>,
            downloadingInto directory: URL
        ) async -> [CommonsPhoto] {
            [
                CommonsPhoto(
                    pin: CommunityPhotoPin(
                        capturedAt: Date(timeIntervalSince1970: 1_600_000_000),
                        coordinate: TrailDraftPhotoControllerTests.camera
                    ),
                    fileURL: directory.appendingPathComponent("commons-1.jpeg"),
                    credit: CommonsPhotoCredit(
                        author: "Hiker",
                        licence: HikePhotoLicence(
                            name: "CC0",
                            url: nil,
                            sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:1.jpg")
                                ?? URL(filePath: "/")
                        )
                    )
                ),
            ]
        }
    }

    nonisolated private static let middle = CLLocationCoordinate2D(latitude: 47.6, longitude: 13.0)
    nonisolated private static let camera = CLLocationCoordinate2D(latitude: 47.603, longitude: 13.0)

    private final class Root {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrailDraftPhotoControllerTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// A maker that is up, over a map narrow enough to search, with every
    /// switch where a fresh install has it.
    private static func maker(
        root: Root,
        filter: TrailPlaceFilter = TrailPlaceFilter(defaults: nil)
    ) -> TrailDraftController {
        let maker = TrailDraftController(
            placeFilter: filter,
            photos: TrailDraftPhotos(source: OnePhotoSource(), root: root.url)
        )
        maker.setEditing(true)
        maker.finder.regionDidSettle(
            MKCoordinateRegion(center: middle, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        )
        return maker
    }

    /// Taps the pill and waits for the photographs to land.
    private static func searched(_ maker: TrailDraftController) async throws -> URL {
        maker.searchNearbyPlaces()
        while maker.photos.isSearching {
            await Task.yield()
        }
        return try #require(maker.photos.photos.first?.fileURL)
    }

    // MARK: - The pill

    @Test("the chip starts on, and the pill asks Commons with it")
    func thePillAsksForPhotographs() async throws {
        let root = Root()
        let maker = Self.maker(root: root)

        #expect(maker.finder.filter.photosShown)
        _ = try await Self.searched(maker)

        #expect(maker.photos.photos.count == 1)
    }

    /// Every kind switched off used to disable the pill; with photographs
    /// still wanted there is something left to ask for.
    @Test("with every kind off, the photos chip alone keeps the pill")
    func photosAloneKeepThePill() {
        let root = Root()
        let filter = TrailPlaceFilter(defaults: nil)
        for symbol in TrailPointQuery.searchableSymbols {
            filter.setShows(false, symbol)
        }
        let maker = Self.maker(root: root, filter: filter)

        #expect(maker.canSearchArea)
        maker.setShowsPhotos(false)
        #expect(!maker.canSearchArea)
    }

    @Test("the chip off asks Commons nothing")
    func theChipOffAsksNothing() {
        let root = Root()
        let maker = Self.maker(root: root)
        maker.setShowsPhotos(false)

        maker.searchNearbyPlaces()

        #expect(!maker.photos.isSearching)
    }

    // MARK: - Taking them away

    @Test("turning the chip off takes the photographs away and closes a card about one")
    func theChipOffTakesThemAway() async throws {
        let root = Root()
        let maker = Self.maker(root: root)
        let url = try await Self.searched(maker)
        maker.select(.photo(url))
        #expect(maker.selection == .photo(url))

        maker.setShowsPhotos(false)

        #expect(maker.photos.photos.isEmpty)
        #expect(maker.selection == nil)
    }

    @Test("hiding the places hides the photographs too, and keeps them")
    func thePlacesSwitchHidesThem() async throws {
        let root = Root()
        let maker = Self.maker(root: root)
        let url = try await Self.searched(maker)
        maker.select(.photo(url))

        maker.setPlacesShown(false)

        #expect(maker.selection == nil)
        maker.select(.photo(url))
        #expect(maker.selection == nil, "a hidden pin has nothing on the map to be about")
        #expect(maker.photos.photos.count == 1)
    }

    @Test("throwing the drawing away forgets its photographs")
    func discardForgetsThem() async throws {
        let root = Root()
        let maker = Self.maker(root: root)
        _ = try await Self.searched(maker)

        maker.discard()

        #expect(maker.photos.photos.isEmpty)
    }

    // MARK: - The card

    @Test("a photograph's card offers Add Stop where the camera stood, named like a dropped pin")
    func theCardAddsAStopAtTheCamera() async throws {
        let root = Root()
        let maker = Self.maker(root: root)
        let url = try await Self.searched(maker)

        let card = try #require(
            TrailPlaceCard(.photo(url), in: maker.draft, droppedPin: nil, photos: maker.photos.photos)
        )

        #expect(card.photo?.fileURL == url)
        #expect(card.latitude == Self.camera.latitude)
        #expect(card.longitude == Self.camera.longitude)
        #expect(card.primary == .addStop(name: "", preferredLeg: nil))
        #expect(card.removablePlace == nil)
        #expect(!card.isDroppedPin)
    }

    @Test("a card about a photograph that is no longer found closes")
    func aGonePhotographHasNoCard() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("commons-gone.jpeg")

        #expect(TrailPlaceCard(.photo(gone), in: TrailDraft(), droppedPin: nil, photos: []) == nil)
    }

    @Test("Add Stop from a photograph puts a stop at the camera")
    func addStopFromAPhotograph() async throws {
        let root = Root()
        let maker = Self.maker(root: root)
        _ = try await Self.searched(maker)

        maker.addStop(at: Self.camera)

        let stop = try #require(maker.draft.waypoints.first)
        #expect(stop.latitude == Self.camera.latitude)
        #expect(stop.longitude == Self.camera.longitude)
    }
}
