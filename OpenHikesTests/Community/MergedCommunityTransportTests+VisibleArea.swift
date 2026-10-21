//
//  MergedCommunityTransportTests+VisibleArea.swift
//  OpenHikesTests
//
//  The area reaches both halves whole.
//
//  The transport used to take a coordinate and a radius and build the curated
//  half's area itself, which was harmless while an area was nothing more than
//  that. It now carries the rectangle the map handed over, and a composite that
//  rebuilt it from the two numbers would ask Overpass about the twenty-kilometre
//  square again while every row still came back looking right — so what is
//  pinned is the question each half received, not the answer.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

extension MergedCommunityTransportTests {
    @Test("both halves are asked about the whole area, the rectangle on screen included")
    func bothHalvesGetTheWholeArea() async throws {
        let merged = Self.merged()
        let area = CommunitySearchArea(
            coordinate: Self.area.coordinate,
            radiusMeters: Self.area.radiusMeters,
            visibleSpan: CommunitySearchArea.Span(latitudeDelta: 0.044, longitudeDelta: 0.0665)
        )

        _ = try await Self.answer(merged, area: area)

        let curated = try #require(merged.overpass.recording.areaRequests.first)
        #expect(curated.area == area, "the curated half must be handed the rectangle, not a circle rebuilt from it")
        #expect(merged.cloudKit.recording.nearbyRequests == [area])
    }
}
