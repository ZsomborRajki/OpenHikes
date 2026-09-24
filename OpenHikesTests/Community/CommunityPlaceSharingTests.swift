//
//  CommunityPlaceSharingTests.swift
//  OpenHikesTests
//
//  A shared hike's places: written into the route's asset, read back as a
//  stranger's file, and copied into the library of whoever saves the hike.
//
//  The reading half is the one with teeth. The places arrive in a file any
//  client with an Apple Account can write, and are then drawn on a map,
//  shown to other hikers and — if the hike is saved — written into the saving
//  hiker's private database. So a place off the map is dropped, a list longer
//  than a file import allows is cut, a name is bounded, and a symbol or tag
//  this build does not know costs that field and nothing else. And a
//  malformed list must never cost the walk it came with.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Suite("Community places")
struct CommunityPlaceSharingTests {
    private static let route = [
        RouteCoordinate(latitude: 47.60, longitude: 12.98),
        RouteCoordinate(latitude: 47.62, longitude: 12.98),
    ]

    private static let hut = TrailPlace(
        latitude: 47.61,
        longitude: 12.98,
        name: "Kärlingerhaus",
        symbol: .shelter,
        note: "Open June to October",
        osm: TrailPlaceOSM(
            elementType: "way",
            elementID: 42,
            facts: [TrailPlaceFact(kind: .elevation, value: "1638")]
        )
    )

    /// A small JPEG, drawn here rather than through ``HikePhotoStore/encode(_:)``,
    /// which asserts it is off the main actor these tests run on.
    nonisolated private static func sampleJPEG() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
        #else
        return Data()
        #endif
    }

    private static func encoded(_ document: CommunityRouteDocument) throws -> Data {
        try JSONEncoder().encode(document)
    }

    // MARK: Out and back

    @Test("a place round-trips through the route's asset")
    func placeRoundTrips() throws {
        let data = try Self.encoded(CommunityRouteDocument(route: Self.route, places: [CommunityPlace(Self.hut)]))

        let contents = CommunityRoutePayload.contents(from: data)

        #expect(contents.route.count == 2)
        let place = try #require(contents.places.first)
        #expect(place.id == Self.hut.id)
        #expect(place.name == "Kärlingerhaus")
        #expect(place.symbol == .shelter)
        #expect(place.note == "Open June to October")
        #expect(place.osm?.elementType == "way")
        #expect(place.osm?.elementID == 42)
        #expect(place.osm?.facts == [TrailPlaceFact(kind: .elevation, value: "1638")])
    }

    @Test("a document written before places were published still reads")
    func oldDocumentReads() {
        let data = Data(#"{"route":[{"latitude":47.6,"longitude":12.98},{"latitude":47.62,"longitude":12.98}]}"#.utf8)
        let contents = CommunityRoutePayload.contents(from: data)
        #expect(contents.route.count == 2)
        #expect(contents.places.isEmpty)
    }

    @Test("a malformed place list costs the places, never the walk")
    func malformedPlacesKeepTheRoute() {
        let data = Data(
            #"{"route":[{"latitude":47.6,"longitude":12.98},{"latitude":47.62,"longitude":12.98}],"places":"nonsense"}"#
                .utf8
        )
        let contents = CommunityRoutePayload.contents(from: data)
        #expect(contents.route.count == 2)
        #expect(contents.places.isEmpty)
    }

    // MARK: A stranger's file

    @Test("a place off the map is dropped and the rest are kept")
    func offMapPlaceIsDropped() {
        var bad = CommunityPlace(Self.hut)
        bad.id = UUID()
        bad.latitude = .nan
        let kept = CommunityRoutePayload.places([bad, CommunityPlace(Self.hut)])
        #expect(kept.map(\.id) == [Self.hut.id])
    }

    @Test("two places claiming one id keep the first")
    func duplicateIdsKeepFirst() {
        var second = CommunityPlace(Self.hut)
        second.name = "Impostor"
        let kept = CommunityRoutePayload.places([CommunityPlace(Self.hut), second])
        #expect(kept.map(\.name) == ["Kärlingerhaus"])
    }

    @Test("a symbol or element type this build does not know costs that field only")
    func unknownFieldsAreDropped() throws {
        var place = CommunityPlace(Self.hut)
        place.symbol = "Volcano"
        place.osmElementType = "area"
        let read = try #require(CommunityRoutePayload.places([place]).first)
        #expect(read.symbol == nil)
        #expect(read.osm == nil)
        #expect(read.name == "Kärlingerhaus")
    }

    @Test("names are bounded and the list is capped at a file import's")
    func boundsApply() {
        var long = CommunityPlace(Self.hut)
        long.name = String(repeating: "x", count: 1000)
        let many = (0..<(GPXImport.maximumPlaces + 5)).map { _ in
            var copy = long
            copy.id = UUID()
            return copy
        }
        let read = CommunityRoutePayload.places(many)
        #expect(read.count == GPXImport.maximumPlaces)
        #expect(read.allSatisfy { $0.name.count < 1000 })
    }

    @Test("a tag this build does not show is not kept as a fact")
    func unknownTagsAreIgnored() throws {
        var place = CommunityPlace(Self.hut)
        place.osmTags = ["ele": "1638", "fixme": "check"]
        let read = try #require(CommunityRoutePayload.places([place]).first)
        #expect(read.osm?.facts.map(\.kind) == [.elevation])
    }

    // MARK: Saving a shared hike

    @Test("saving a shared hike copies its places under new ids and files the author's photos under them")
    func importCopiesPlaces() async throws {
        let context = try Fixture.modelContext()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityPlaceSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo-0.jpeg")
        let store = HikePhotoStore(storageRoot: directory.appendingPathComponent("store"))
        try Self.sampleJPEG().write(to: url)

        let detail = CommunityHikeDetail(
            listing: .stub(),
            route: Self.route,
            places: [Self.hut],
            trackDescription: nil,
            photoPins: [CommunityPhotoPin(capturedAt: .now, coordinate: Self.hut.clCoordinate, placeID: Self.hut.id)],
            photoFileURLs: [url],
            photosOnRecord: 1
        )

        let outcome = await CommunityImport.importHike(
            detail,
            into: context,
            store: store,
            libraryWriter: StubPhotoLibraryWriter()
        )

        let hike = try #require(outcome.hike)
        let saved = try #require(hike.places.first)
        #expect(hike.places.count == 1)
        #expect(saved.id != Self.hut.id)
        #expect(saved.name == "Kärlingerhaus")
        #expect(saved.osm?.elementID == 42)
        #expect(hike.photos(ofPlace: saved.id).count == 1)
    }

    // MARK: Sending

    @Test("a photograph names its place only when that place is going too")
    func stagedPinsNameOnlySharedPlaces() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        hike.replacePlaces(with: [Self.hut], in: context)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityPlaceSharingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HikePhotoStore(storageRoot: root.appendingPathComponent("store"))
        _ = await HikePhotoImport.add(
            Self.sampleJPEG(),
            to: hike,
            coordinate: Self.hut.clCoordinate,
            savesToPhotoLibrary: false,
            placeID: Self.hut.id,
            store: store,
            save: { _ in /* in memory */ }
        )

        // Off the main actor, where the publisher stages: the export asserts
        // it is not on the thread drawing the progress view.
        let photos = hike.photos
        let placeID = Self.hut.id
        let shared = await Task.detached {
            CommunityStaging.stagePhotos(
                photos,
                into: root.appendingPathComponent("with"),
                store: store,
                places: [placeID]
            )
        }.value
        let contributed = await Task.detached {
            CommunityStaging.stagePhotos(photos, into: root.appendingPathComponent("without"), store: store)
        }.value

        #expect(shared.pins.first?.placeID == Self.hut.id)
        #expect(contributed.pins.first?.placeID == nil)
    }

    @Test("the share form says the places go, and how many")
    func disclosureNamesPlaces() {
        let none = CommunityShareDisclosure.text(hasNotes: false, photoCount: 0)
        let one = CommunityShareDisclosure.text(hasNotes: false, photoCount: 0, placeCount: 1)
        let several = CommunityShareDisclosure.text(hasNotes: false, photoCount: 0, placeCount: 3)

        #expect(!none.contains("place"))
        #expect(one.contains("The place marked along it goes too"))
        #expect(several.contains("The 3 places marked along it go too"))
    }
}
