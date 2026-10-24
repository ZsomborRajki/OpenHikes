//
//  WikimediaCommonsAreaTests.swift
//  OpenHikesTests
//
//  The trail maker's question to Commons — the photographs taken in the area
//  on screen — driven through ``WikimediaCommonsSource/Transport`` rather than
//  the network. The route's question has its own suite,
//  ``WikimediaCommonsSourceTests``; what is different here is that there is
//  one circle, no line to snap onto, and photographs already on the map to
//  leave out.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Synchronization
import Testing

@Suite("Wikimedia Commons area search")
struct WikimediaCommonsAreaTests {
    nonisolated private enum Answers {
        typealias Camera = (id: Int, latitude: Double, longitude: Double)

        static let middle = (latitude: 47.6, longitude: 13.0)
        /// Three cameras a few hundred metres from the middle, none of them on
        /// any line.
        static let cameras: [Camera] = [
            (id: 1, latitude: 47.602, longitude: 13.001),
            (id: 2, latitude: 47.598, longitude: 13.003),
            (id: 3, latitude: 47.601, longitude: 12.996),
        ]
        /// For ``WikimediaCommonsAreaTests/tallMap``: one camera near its
        /// middle, one in its north-east corner, past the circle a pill hands
        /// over, and one off its east side, inside that circle.
        static let tallMapCameras: [Camera] = [
            (id: 1, latitude: 47.601, longitude: 13.001),
            (id: 2, latitude: 47.6125, longitude: 13.009),
            (id: 3, latitude: 47.6, longitude: 13.016),
        ]

        static func page(_ id: Int) -> String {
            "https://commons.wikimedia.org/wiki/File:\(id).jpg"
        }

        static func geosearch(_ cameras: [Camera]) -> Data {
            let hits = cameras.map { camera in
                """
                {"pageid":\(camera.id),"ns":6,"title":"File:\(camera.id).jpg",\
                "lat":\(camera.latitude),"lon":\(camera.longitude),"dist":1,"primary":true}
                """
            }
            return Data(#"{"batchcomplete":true,"query":{"geosearch":[\#(hits.joined(separator: ","))]}}"#.utf8)
        }

        static func imageInfo(_ cameras: [Camera]) -> Data {
            let pages = cameras.map { camera in
                """
                {"pageid":\(camera.id),"ns":6,"title":"File:\(camera.id).jpg","imageinfo":[{\
                "timestamp":"2020-06-0\(camera.id)T10:00:00Z","width":3000,"mime":"image/jpeg",\
                "thumburl":"https://upload.wikimedia.org/thumb/\(camera.id)/960px-\(camera.id).jpg",\
                "descriptionurl":"\(page(camera.id))",\
                "extmetadata":{"Artist":{"value":"Hiker \(camera.id)"},"LicenseShortName":{"value":"CC BY 4.0"}}}]}
                """
            }
            return Data(#"{"batchcomplete":true,"query":{"pages":[\#(pages.joined(separator: ","))]}}"#.utf8)
        }
    }

    /// Commons, answering from memory and writing down what it was asked.
    nonisolated private final class StubCommons: Sendable {
        private let asked = Mutex<[URL]>([])
        private let cameras: [Answers.Camera]

        init(cameras: [Answers.Camera] = Answers.cameras) {
            self.cameras = cameras
        }

        var requests: [URL] { asked.withLock { $0 } }

        var transport: WikimediaCommonsSource.Transport {
            { [self] request in
                let url = request.url ?? URL(filePath: "/")
                asked.withLock { $0.append(url) }
                let text = url.absoluteString
                if text.contains("list=geosearch") { return (Answers.geosearch(cameras), 200) }
                if text.contains("prop=imageinfo") { return (Answers.imageInfo(cameras), 200) }
                return (PhotoDiscoveryFixture.sampleImageData(), 200)
            }
        }
    }

    private final class Downloads {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikimediaCommonsAreaTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private static let area = CommunitySearchArea(
        coordinate: CLLocationCoordinate2D(latitude: Answers.middle.latitude, longitude: Answers.middle.longitude),
        radiusMeters: 1500
    )

    /// The map above a lowered sheet, as a pill hands it over: a kilometre
    /// and a half across and three from top to bottom, with a circle half its
    /// longer side.
    private static let tallMap = CommunitySearchArea(
        coordinate: area.coordinate,
        radiusMeters: 1500,
        visibleSpan: CommunitySearchArea.Span(latitudeDelta: 0.027, longitudeDelta: 0.02)
    )

    private static func source(_ commons: StubCommons) -> WikimediaCommonsSource {
        WikimediaCommonsSource(transport: commons.transport, pause: { _ in /* never busy */ })
    }

    @Test("an area is one geosearch over the circle on screen")
    func oneGeosearch() async throws {
        let commons = StubCommons()
        let downloads = Downloads()

        _ = try await Self.source(commons).photos(in: Self.area, avoiding: [], downloadingInto: downloads.directory)

        let searches = commons.requests.filter { $0.absoluteString.contains("list=geosearch") }
        #expect(searches.count == 1)
        let search = try #require(searches.first)
        let items = try #require(URLComponents(url: search, resolvingAgainstBaseURL: false)).queryItems ?? []
        #expect(items.first { $0.name == "gscoord" }?.value == "47.6|13.0")
        #expect(items.first { $0.name == "gsradius" }?.value == "1500")
    }

    /// The circle a pill hands over is half the map's longer side. Asked as
    /// it was, the geosearch missed the corners of the screen, and what came
    /// back off its sides took the photographs' places.
    @Test("a map on screen is asked about through its corners, and answered with what is on it")
    func theMapOnScreenIsAsked() async throws {
        let commons = StubCommons(cameras: Answers.tallMapCameras)
        let downloads = Downloads()

        let photos = try await Self.source(commons)
            .photos(in: Self.tallMap, avoiding: [], downloadingInto: downloads.directory)

        let search = try #require(commons.requests.first { $0.absoluteString.contains("list=geosearch") })
        let items = try #require(URLComponents(url: search, resolvingAgainstBaseURL: false)).queryItems ?? []
        #expect(items.first { $0.name == "gscoord" }?.value == "47.6|13.0")
        let radius = try #require(items.first { $0.name == "gsradius" }?.value.flatMap { Double($0) })
        let northEast = CLLocationCoordinate2D(
            latitude: Answers.middle.latitude + 0.0135,
            longitude: Answers.middle.longitude + 0.01
        )
        let toTheCorner = RouteGeometry.distanceMeters(from: Self.tallMap.coordinate, to: northEast)
        #expect(radius.isApproximatelyEqual(to: toTheCorner, absoluteTolerance: 2))
        #expect(Set(photos.map(\.credit.author)) == ["Hiker 1", "Hiker 2"])
    }

    /// No line to snap onto, and the spot is what *Add Stop* is offered on.
    @Test("each photograph stands where its camera stood, credited")
    func pinnedWhereTheCameraStood() async throws {
        let commons = StubCommons()
        let downloads = Downloads()

        let photos = try await Self.source(commons)
            .photos(in: Self.area, avoiding: [], downloadingInto: downloads.directory)

        #expect(Set(photos.map(\.credit.author)) == ["Hiker 1", "Hiker 2", "Hiker 3"])
        for camera in Answers.cameras {
            let photo = try #require(photos.first { $0.credit.author == "Hiker \(camera.id)" })
            #expect(photo.pin.coordinate?.latitude == camera.latitude)
            #expect(photo.pin.coordinate?.longitude == camera.longitude)
        }
    }

    /// A second tap over the same valley offers the next ones along.
    @Test("a photograph already on the map is left out")
    func shownPhotographsAreLeftOut() async throws {
        let commons = StubCommons()
        let downloads = Downloads()
        let shown = try #require(URL(string: Answers.page(2)))

        let photos = try await Self.source(commons)
            .photos(in: Self.area, avoiding: [shown], downloadingInto: downloads.directory)

        #expect(Set(photos.map(\.credit.license.sourceURL)).isDisjoint(with: [shown]))
        #expect(photos.count == 2)
        #expect(
            !commons.requests.contains { $0.absoluteString.contains("/thumb/2/") },
            "nothing is downloaded for a photograph already on the map"
        )
    }

    @Test("the dormant source answers an area with nothing")
    func dormantAnswersNothing() async {
        let photos = await DormantCommonsPhotoSource()
            .photos(in: Self.area, avoiding: [], downloadingInto: FileManager.default.temporaryDirectory)

        #expect(photos.isEmpty)
    }
}
