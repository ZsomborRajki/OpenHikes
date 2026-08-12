//
//  StadiaRecordingMatcherTests.swift
//  OpenTrailsTests
//

import CoreLocation
import Foundation
import Testing
@testable import OpenTrails

private actor StadiaRequestProbe {
    private(set) var request: URLRequest?
    let response: RecordingOnlineHTTPResponse

    init(response: RecordingOnlineHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) -> RecordingOnlineHTTPResponse {
        self.request = request
        return response
    }

    func capturedRequest() -> URLRequest? {
        request
    }
}

@Suite("Stadia recording matcher")
struct StadiaRecordingMatcherTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("the opted-in trace is sent after Stop and decoded as polyline6")
    func requestAndDecode() async throws {
        let matched = [
            CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600),
            CLLocationCoordinate2D(latitude: 47.6305, longitude: 12.8605),
            CLLocationCoordinate2D(latitude: 47.6310, longitude: 12.8610)
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "trip": [
                "legs": [
                    ["shape": encodePolyline6(matched)]
                ]
            ]
        ])
        let probe = StadiaRequestProbe(
            response: RecordingOnlineHTTPResponse(
                data: data,
                statusCode: 200
            )
        )
        let matcher = StadiaRecordingMatcher(
            apiKey: "TEST_KEY",
            transport: { request in
                await probe.send(request)
            }
        )
        let points = [
            point(
                matched[0],
                seconds: 0,
                elevation: 600,
                flags: [.nonPedestrian]
            ),
            point(matched[2], seconds: 120, elevation: 620)
        ]

        let route = try await matcher.match(points: points)

        #expect(route.count == 3)
        #expect(abs(route[1].latitude - matched[1].latitude) < 0.000001)
        #expect(abs((route[1].elevation ?? 0) - 610) < 0.1)
        #expect(route.allSatisfy { $0.motion == .nonPedestrian })
        #expect(
            abs(
                try #require(route[1].timestamp).timeIntervalSince(
                    start.addingTimeInterval(60)
                )
            ) < 0.001
        )

        let request = try #require(await probe.capturedRequest())
        #expect(request.httpMethod == "POST")
        #expect(
            URLComponents(
                url: try #require(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.contains {
                $0.name == "api_key" && $0.value == "TEST_KEY"
            } == true
        )
        let body = try #require(request.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["costing"] as? String == "pedestrian")
        #expect(json["shape_match"] as? String == "map_snap")
        #expect((json["shape"] as? [[String: Any]])?.count == 2)
    }

    @Test("a simplified online route keeps an interior motion segment")
    func simplifiedRouteKeepsMotionBoundary() async throws {
        let matched = [
            CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600),
            CLLocationCoordinate2D(latitude: 47.6320, longitude: 12.8620)
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "trip": [
                "legs": [
                    ["shape": encodePolyline6(matched)]
                ]
            ]
        ])
        let matcher = StadiaRecordingMatcher(
            apiKey: "TEST_KEY",
            transport: { _ in
                RecordingOnlineHTTPResponse(
                    data: data,
                    statusCode: 200
                )
            }
        )
        let points = [
            point(matched[0], seconds: 0),
            point(
                CLLocationCoordinate2D(
                    latitude: 47.6310,
                    longitude: 12.8610
                ),
                seconds: 60,
                flags: [.nonPedestrian]
            ),
            point(matched[1], seconds: 120)
        ]

        let route = try await matcher.match(points: points)

        #expect(route.count == 3)
        #expect(route[1].motion == .nonPedestrian)
    }

    @Test("server failures stay explicit so the recorder can fall back")
    func serverFailure() async {
        let matcher = StadiaRecordingMatcher(
            apiKey: "TEST_KEY",
            transport: { _ in
                RecordingOnlineHTTPResponse(
                    data: Data(),
                    statusCode: 429
                )
            }
        )
        let points = [
            point(.init(latitude: 47.63, longitude: 12.86), seconds: 0),
            point(.init(latitude: 47.631, longitude: 12.861), seconds: 60)
        ]

        await #expect(throws: RecordingOnlineMatchError.server(429)) {
            try await matcher.match(points: points)
        }
    }

    private func point(
        _ coordinate: CLLocationCoordinate2D,
        seconds: TimeInterval,
        elevation: Double? = nil,
        flags: RecordingPointFlags = []
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timestamp: start.addingTimeInterval(seconds),
            elevation: elevation,
            horizontalAccuracy: 8,
            course: 45,
            speed: 1,
            flags: flags
        )
    }

    private func encodePolyline6(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> String {
        var previousLatitude = 0
        var previousLongitude = 0
        var bytes: [UInt8] = []

        func append(_ value: Int) {
            var encoded = value < 0 ? ~(value << 1) : value << 1
            while encoded >= 0x20 {
                bytes.append(UInt8((0x20 | (encoded & 0x1F)) + 63))
                encoded >>= 5
            }
            bytes.append(UInt8(encoded + 63))
        }

        for coordinate in coordinates {
            let latitude = Int(
                (coordinate.latitude * 1_000_000).rounded()
            )
            let longitude = Int(
                (coordinate.longitude * 1_000_000).rounded()
            )
            append(latitude - previousLatitude)
            append(longitude - previousLongitude)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
