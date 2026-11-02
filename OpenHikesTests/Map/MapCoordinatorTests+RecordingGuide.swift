//
//  MapCoordinatorTests+RecordingGuide.swift
//  OpenHikesTests
//
//  What the map does with a trail shown under a recording: draws its line at
//  full strength in an overlay of its own, over the library and under the
//  selected route; leaves its faded copy out of the library; leaves it to the
//  selected route when the two are one hike; stands it down while a trail is
//  being drawn; and takes it off when the recording ends. See
//  `MapRecordingGuide.swift`.
//
//  The trail and the library come from a real store, as the app's do —
//  `RecordingGuideTests` pins the guide itself.
//

import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension MapCoordinatorTests {
    /// A second hike beside the ridge, far enough east to be its own line.
    private static let eastOffset: Double = 0.006

    /// The ridge, moved `east` degrees.
    private static func ridge(east: Double = 0) -> [RouteCoordinate] {
        Fixture.ridgeRoute.map { point in
            RouteCoordinate(latitude: point.latitude, longitude: point.longitude + east)
        }
    }

    /// A library of three hikes side by side followed until all are drawn,
    /// and a guide showing the first of them under a recording, its line
    /// projected.
    private func guidedLibrary(
        draft: RecordingDraftStub
    ) async throws -> (followed: FollowedLibrary, guide: RecordingGuide, trail: Hike) {
        let followed = try FollowedLibrary(
            routes: [Self.ridge(), Self.ridge(east: Self.eastOffset), Self.ridge(east: Self.eastOffset * 2)],
            openRequests: openRequests
        )
        await settle(until: "every hike in the library has its line") { followed.library.lines.count == 3 }
        let hikes = try followed.container.mainContext.fetch(FetchDescriptor<Hike>())
        let trail = try #require(hikes.first { $0.id == followed.hikeIDs[0] })
        draft.id = UUID()
        let guide = RecordingGuide(recordingHikeID: { [draft] in draft.id })
        guide.show(trail)
        await settle(until: "the trail's line has been projected") { guide.line != nil }
        return (followed, guide, trail)
    }

    private func drawnIndex(of overlay: (any MKOverlay)?, in map: MKMapView) -> Int? {
        overlay.flatMap { overlay in map.overlays(in: .aboveLabels).firstIndex { $0 === overlay } }
    }

    @Test("the trail under a recording is drawn at full strength, and its faded copy is left out")
    func theGuideIsDrawnAndTheLibraryLeavesItOut() async throws {
        let draft = RecordingDraftStub()
        let (followed, guide, trail) = try await guidedLibrary(draft: draft)
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let view = mapView(libraryLines: followed.library, recordingGuide: guide)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        let overlay = try #require(coordinator.guideMap.overlay)
        #expect(map.overlays.contains { $0 === overlay })
        #expect(coordinator.guideMap.hikeID == trail.id)
        let renderer = try #require(coordinator.mapView(map, rendererFor: overlay) as? LibraryLinesRenderer)
        #expect(renderer.layerAlpha == MapView.Coordinator.recordingGuideAlpha)
        #expect(renderer.lineWidth == MapView.Coordinator.recordingGuideWidth)
        #expect(renderer !== coordinator.libraryMap.renderer, "an overlay of its own, not the library's")
        #expect(coordinator.libraryMap.drawings.map(\.line.hikeID) == Array(followed.hikeIDs.dropFirst()))
    }

    /// Both ways round: the trail chosen while a selected route is already
    /// drawn goes under it, and a route drawn again later goes over it.
    @Test("the trail under a recording is over the library and under the selected route")
    func theGuideSitsBetween() async throws {
        let draft = RecordingDraftStub()
        let (followed, guide, trail) = try await guidedLibrary(draft: draft)
        defer { followed.stop() }
        guide.stopShowing()
        let coordinator = MapView.Coordinator()
        let view = mapView(
            route: Self.route(followed.hikeIDs[1], coordinates: Self.ridge(east: Self.eastOffset)),
            libraryLines: followed.library,
            recordingGuide: guide
        )
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        #expect(coordinator.guideMap.overlay == nil)

        guide.show(trail)
        await settle(until: "the trail is drawn") { coordinator.guideMap.overlay != nil }
        try expectGuideBetweenLibraryAndRoute(on: map, coordinator)

        mapView(route: nil, libraryLines: followed.library, recordingGuide: guide).update(map, coordinator)
        view.update(map, coordinator)
        try expectGuideBetweenLibraryAndRoute(on: map, coordinator)
    }

    private func expectGuideBetweenLibraryAndRoute(
        on map: MKMapView,
        _ coordinator: MapView.Coordinator,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let index = { (overlay: (any MKOverlay)?) in self.drawnIndex(of: overlay, in: map) }
        let library = try #require(index(coordinator.libraryMap.overlay), sourceLocation: sourceLocation)
        let guide = try #require(index(coordinator.guideMap.overlay), sourceLocation: sourceLocation)
        let route = try #require(index(coordinator.routeOverlay), sourceLocation: sourceLocation)
        #expect(library < guide, sourceLocation: sourceLocation)
        #expect(guide < route, sourceLocation: sourceLocation)
    }

    @Test("the trail is left to the selected route while it is the selected hike")
    func theSelectedRouteDrawsTheGuidesHike() async throws {
        let draft = RecordingDraftStub()
        let (followed, guide, trail) = try await guidedLibrary(draft: draft)
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let view = mapView(
            route: Self.route(trail.id, coordinates: Self.ridge()),
            libraryLines: followed.library,
            recordingGuide: guide
        )
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        #expect(coordinator.guideMap.overlay == nil)

        mapView(route: nil, libraryLines: followed.library, recordingGuide: guide).update(map, coordinator)

        #expect(coordinator.guideMap.overlay != nil)
        #expect(coordinator.libraryMap.drawings.map(\.line.hikeID) == Array(followed.hikeIDs.dropFirst()))
    }

    @Test("the trail goes when the recording ends, and the library draws it again")
    func theGuideEndsWithTheRecording() async throws {
        let draft = RecordingDraftStub()
        let (followed, guide, _) = try await guidedLibrary(draft: draft)
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let view = mapView(libraryLines: followed.library, recordingGuide: guide)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        let overlay = try #require(coordinator.guideMap.overlay)

        draft.id = nil

        await settle(until: "the trail is off the map") { coordinator.guideMap.overlay == nil }
        #expect(!map.overlays.contains { $0 === overlay })
        #expect(coordinator.libraryMap.drawings.map(\.line.hikeID) == followed.hikeIDs)
    }

    @Test("the trail stands down while a trail is being drawn, and comes back after")
    func theGuideStandsDownForTheMaker() async throws {
        let draft = RecordingDraftStub()
        let (followed, guide, _) = try await guidedLibrary(draft: draft)
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let view = mapView(libraryLines: followed.library, recordingGuide: guide)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        coordinator.withdrawCommunityForDrawing(true, on: map)
        #expect(coordinator.guideMap.overlay == nil)

        coordinator.withdrawCommunityForDrawing(false, on: map)
        #expect(coordinator.guideMap.overlay != nil)
    }
}
