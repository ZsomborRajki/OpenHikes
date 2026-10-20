//
//  TrailDraftPlanToPhotoTests.swift
//  OpenHikesTests
//
//  *Plan a Trail Here* on a *Community* tab photograph, from the maker's side:
//  where the camera stood becomes the destination of whatever is drawn, the
//  photograph goes onto the maker's map with a file of its own, and the maker
//  is asked to open. See ``TrailDraftController/plan(to:)``.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Trail draft plan to photo")
struct TrailDraftPlanToPhotoTests {
    private static let camera = CLLocationCoordinate2D(latitude: 47.603, longitude: 13.0)

    private final class Root {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrailDraftPlanToPhotoTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// A photograph downloaded into a directory of the *Community* tab's —
    /// one the maker does not own.
    private static func photo(in root: Root) throws -> CommonsPhoto {
        let found = root.url.appending(path: "found")
        try FileManager.default.createDirectory(at: found, withIntermediateDirectories: true)
        let file = found.appendingPathComponent("commons-1.jpeg")
        try PhotoDiscoveryFixture.sampleImageData().write(to: file)
        return CommonsPhoto(
            pin: CommunityPhotoPin(capturedAt: Date(timeIntervalSince1970: 1_600_000_000), coordinate: camera),
            fileURL: file,
            credit: CommonsPhotoCredit(
                author: "Hiker",
                license: HikePhotoLicense(
                    name: "CC0",
                    url: nil,
                    sourceURL: try #require(URL(string: "https://commons.wikimedia.org/wiki/File:1.jpg"))
                )
            )
        )
    }

    private static func maker(_ root: Root) -> TrailDraftController {
        TrailDraftController(photos: TrailDraftPhotos(root: root.url.appending(path: "maker")))
    }

    private static func isCamera(_ waypoint: TrailWaypoint?) -> Bool {
        waypoint?.latitude == camera.latitude && waypoint?.longitude == camera.longitude
    }

    @Test("an empty drawing gets the camera as its destination, with the start left open")
    func emptyDrawing() throws {
        let root = Root()
        let maker = Self.maker(root)

        maker.plan(to: try Self.photo(in: root))

        #expect(maker.draft.waypoints.count == 1)
        #expect(Self.isCamera(maker.draft.waypoints.first))
        #expect(maker.draft.startIsOpen)
        #expect(maker.draft.slots.contains(.open(.start)))
    }

    @Test("a drawing with an end already gets a new one, the old end becoming a stop")
    func drawingWithAnEnd() throws {
        let root = Root()
        let maker = Self.maker(root)
        maker.setEditing(true)
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: 47.59, longitude: 12.99))
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: 47.595, longitude: 12.995))
        maker.setEditing(false)

        maker.plan(to: try Self.photo(in: root))

        #expect(maker.draft.waypoints.count == 3)
        #expect(Self.isCamera(maker.draft.waypoints.last))
    }

    @Test("a drawing with only a start gets the camera in its open destination")
    func drawingWithOnlyAStart() throws {
        let root = Root()
        let maker = Self.maker(root)
        maker.setEditing(true)
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: 47.59, longitude: 12.99))
        maker.setEditing(false)

        maker.plan(to: try Self.photo(in: root))

        #expect(maker.draft.waypoints.count == 2)
        #expect(Self.isCamera(maker.draft.waypoints.last))
        #expect(!maker.draft.startIsOpen)
    }

    @Test("the maker is asked to open")
    func asksToOpen() async throws {
        let root = Root()
        let maker = Self.maker(root)
        let requests = maker.openRequests()

        maker.plan(to: try Self.photo(in: root))

        var iterator = requests.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test("the photograph goes onto the maker's map with a file of its own, once")
    func photographIsAdopted() async throws {
        let root = Root()
        let maker = Self.maker(root)
        let photo = try Self.photo(in: root)

        await maker.photos.adopt(photo).value
        await maker.photos.adopt(photo).value

        let adopted = try #require(maker.photos.photos.first)
        #expect(maker.photos.photos.count == 1)
        #expect(adopted.credit == photo.credit)
        #expect(adopted.fileURL != photo.fileURL)
        #expect(adopted.fileURL.deletingLastPathComponent() == maker.photos.directory)
        #expect(FileManager.default.fileExists(atPath: adopted.fileURL.path))
    }

    @Test("a photograph adopted while the drawing is thrown away is not kept")
    func adoptionAfterDiscard() async throws {
        let root = Root()
        let maker = Self.maker(root)

        let copying = maker.photos.adopt(try Self.photo(in: root))
        maker.photos.clear()
        await copying.value

        #expect(maker.photos.photos.isEmpty)
    }
}
