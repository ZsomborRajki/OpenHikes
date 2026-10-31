//
//  MapCoordinatorTests+LibraryLines.swift
//  OpenHikesTests
//
//  What the map does with every other hike in the library: draws them, in one
//  overlay, faded beneath the selected route and over the shared hikes' lines;
//  leaves the selected hike out; stands them down while a trail is being
//  drawn; and opens the hike under a thumb. See `MapLibraryLines.swift`.
//
//  The lines come from a real store through ``LibraryLines``, as the app's do,
//  read before the map is built or while it is up — `LibraryLinesTests` pins
//  how they are kept true to the store, and `LibraryLinesRendererTests` how
//  they are drawn.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing

extension MapCoordinatorTests {
    /// `Fixture.ridgeRoute` runs due north near Cupertino; these point a
    /// camera at it, and lay a second hike beside it, far enough east to be
    /// told apart by a thumb.
    private enum Valley {
        static let latitude: Double = 37.3350
        static let longitude: Double = -122.0300
        static let span: Double = 0.05
        static let eastOffset: Double = 0.006
        static let wellAwayLongitude: Double = -122.0150
    }

    /// Where the shared hike in `browserWithALine` is, and how it runs.
    private enum Shared {
        static let latitude: Double = 47.63
        static let longitude: Double = 12.86
        static let step: Double = 0.005
        static let points = 5
        static let searchedMeters: Double = 20_000
    }

    private static func valleyRegion() -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: Valley.latitude, longitude: Valley.longitude),
            span: MKCoordinateSpan(latitudeDelta: Valley.span, longitudeDelta: Valley.span)
        )
    }

    /// The ridge, moved `east` degrees.
    private static func ridge(east: Double = 0) -> [RouteCoordinate] {
        Fixture.ridgeRoute.map { point in
            RouteCoordinate(latitude: point.latitude, longitude: point.longitude + east)
        }
    }

    /// A library of one hike per route, newest first, followed until each
    /// has been drawn.
    private func followedLibrary(_ routes: [[RouteCoordinate]]) async throws -> FollowedLibrary {
        let followed = try FollowedLibrary(routes: routes, openRequests: openRequests)
        await settle(until: "every hike in the library has its line") {
            followed.library.lines.count == routes.count
        }
        return followed
    }

    /// The map over the valley, the library's lines on it.
    private func mapOverTheValley(
        _ coordinator: MapView.Coordinator,
        library: LibraryLines,
        route: DisplayedRoute? = nil
    ) -> (view: MapView, map: MKMapView) {
        let view = mapView(route: route, libraryLines: library)
        let map = makeMap(view, coordinator)
        view.update(map, coordinator)
        map.setRegion(Self.valleyRegion(), animated: false)
        return (view, map)
    }

    private func point(atLongitude longitude: Double, in map: MKMapView) -> CGPoint {
        map.convert(CLLocationCoordinate2D(latitude: Valley.latitude, longitude: longitude), toPointTo: map)
    }

    // MARK: - Drawing them

    /// A library is drawn as one overlay, however long it is — see
    /// `LibraryLinesRenderer.swift` for what one each would cost.
    @Test("the library's lines reach the map in one overlay, faded")
    func theLibraryIsOneOverlay() async throws {
        let followed = try await followedLibrary([Self.ridge(), Self.ridge(east: Valley.eastOffset)])
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let (_, map) = mapOverTheValley(coordinator, library: followed.library)
        defer { detach(map) }

        #expect(coordinator.libraryMap.drawings.map(\.line.hikeID) == followed.hikeIDs)
        let overlay = try #require(coordinator.libraryMap.overlay)
        #expect(map.overlays.count { $0 is LibraryLinesOverlay } == 1)
        let renderer = try #require(coordinator.mapView(map, rendererFor: overlay) as? LibraryLinesRenderer)
        #expect(renderer.layerAlpha == MapView.Coordinator.libraryLineAlpha)
        #expect(renderer.borderColor == MapView.Coordinator.defaultBorderColor)
    }

    /// Faded like a shared hike, so the selected route is the one thing at
    /// full strength — and a little less faded, so the hiker's own read apart
    /// from strangers' where both are drawn.
    @Test("a library line is fainter than the selected route and stronger than a shared hike's")
    func theLibrarySitsBetween() {
        #expect(MapView.Coordinator.libraryLineAlpha < 1)
        #expect(MapView.Coordinator.libraryLineAlpha > MapView.Coordinator.communityRouteAlpha)
    }

    /// Lines that land while the map is up reach it with no SwiftUI pass.
    @Test("a line read while the map is up is drawn")
    func aLineReadLaterIsDrawn() async throws {
        let library = LibraryLines(openRequests: openRequests)
        let coordinator = MapView.Coordinator()
        let (_, map) = mapOverTheValley(coordinator, library: library)
        defer { detach(map) }
        #expect(coordinator.libraryMap.overlay == nil, "nothing to draw is no overlay")

        let followed = try FollowedLibrary(routes: [Self.ridge()], openRequests: openRequests, library: library)
        defer { followed.stop() }
        await settle(until: "the line reaches the map") { coordinator.libraryMap.drawings.count == 1 }
        #expect(map.overlays.contains { $0 === coordinator.libraryMap.overlay })
    }

    /// The selected route is drawn properly; a faded copy beneath it would
    /// show through a dashed line and beside it where the outline cut a
    /// corner.
    @Test("the selected hike is left out, and back when it is not selected")
    func theSelectedHikeIsLeftOut() async throws {
        let followed = try await followedLibrary([Self.ridge(), Self.ridge(east: Valley.eastOffset)])
        defer { followed.stop() }
        let selected = followed.hikeIDs[0]
        let coordinator = MapView.Coordinator()
        let (_, map) = mapOverTheValley(
            coordinator,
            library: followed.library,
            route: Self.route(selected, coordinates: Self.ridge())
        )
        defer { detach(map) }
        #expect(coordinator.libraryMap.drawings.map(\.line.hikeID) == [followed.hikeIDs[1]])

        mapView(route: nil, libraryLines: followed.library).update(map, coordinator)
        #expect(coordinator.libraryMap.drawings.map(\.line.hikeID) == followed.hikeIDs)
    }

    /// The hiker's own over a stranger's, and the selected route over both.
    @Test("the library is drawn over the shared hikes' lines and under the selected route")
    func theLibraryIsBetweenTheSharedLinesAndTheRoute() async throws {
        let followed = try await followedLibrary([Self.ridge(east: Valley.eastOffset)])
        defer { followed.stop() }
        let browser = await browserWithALine()
        let coordinator = MapView.Coordinator()
        let view = mapView(
            route: Self.route(coordinates: Self.ridge()),
            community: browser,
            libraryLines: followed.library
        )
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        await settle(until: "the shared hike's line is drawn") { !coordinator.communityRoutes.isEmpty }

        let drawn = map.overlays(in: .aboveLabels)
        let shared = try #require(drawn.firstIndex { $0 === coordinator.communityRoutes.last?.polyline })
        let library = try #require(drawn.firstIndex { $0 === coordinator.libraryMap.overlay })
        let route = try #require(drawn.firstIndex { $0 === coordinator.routeOverlay })
        let ground = try #require(drawn.firstIndex { $0 === coordinator.groundOverlay })
        #expect(ground < shared)
        #expect(shared < library)
        #expect(library < route)
    }

    /// The maker's map is the trail being drawn, for the hiker's own hikes as
    /// for the shared ones.
    @Test("drawing a trail takes the library off the map, and closing the maker brings it back")
    func drawingATrailWithdrawsTheLibrary() async throws {
        let followed = try await followedLibrary([Self.ridge()])
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let (_, map) = mapOverTheValley(coordinator, library: followed.library)
        defer { detach(map) }
        #expect(coordinator.libraryMap.overlay != nil)

        trailMaker.setEditing(true)
        await settle(until: "the maker takes the library off the map") { coordinator.libraryMap.overlay == nil }
        #expect(!map.overlays.contains { $0 is LibraryLinesOverlay })

        trailMaker.setEditing(false)
        await settle(until: "closing the maker brings it back") { coordinator.libraryMap.overlay != nil }
        #expect(coordinator.libraryMap.drawings.count == 1)
    }

    /// A republish of the same lines is the common case — every save of the
    /// hikes' store publishes — and must not rebuild what is drawn.
    @Test("the same lines again keep what is drawn")
    func theSameLinesKeepWhatIsDrawn() async throws {
        let followed = try await followedLibrary([Self.ridge()])
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let (_, map) = mapOverTheValley(coordinator, library: followed.library)
        defer { detach(map) }
        let overlay = try #require(coordinator.libraryMap.overlay)
        let polyline = try #require(coordinator.libraryMap.drawings.first?.rendered.polylines.first)

        coordinator.applyLibraryLines(on: map)
        #expect(coordinator.libraryMap.overlay === overlay)
        #expect(coordinator.libraryMap.drawings.first?.rendered.polylines.first === polyline)
    }

    // MARK: - Tapping one

    @Test("a tap on a library line finds its hike, and a tap away finds nothing")
    func aTapOnALibraryLineFindsItsHike() async throws {
        #if os(iOS)
        let followed = try await followedLibrary([Self.ridge(), Self.ridge(east: Valley.eastOffset)])
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let (_, map) = mapOverTheValley(coordinator, library: followed.library)
        defer { detach(map) }

        let onTheSecond = point(atLongitude: Valley.longitude + Valley.eastOffset, in: map)
        #expect(coordinator.routeTapTarget(at: onTheSecond, in: map) == .libraryHike(followed.hikeIDs[1]))
        let onTheFirst = point(atLongitude: Valley.longitude, in: map)
        #expect(coordinator.routeTapTarget(at: onTheFirst, in: map) == .libraryHike(followed.hikeIDs[0]))
        let wellAway = point(atLongitude: Valley.wellAwayLongitude, in: map)
        #expect(coordinator.routeTapTarget(at: wellAway, in: map) == nil)
        #endif
    }

    /// It is drawn on top, at full strength, in a colour the hiker chose.
    @Test("the selected route wins a tap where it crosses a library line")
    func theSelectedRouteWinsTheTap() async throws {
        #if os(iOS)
        let followed = try await followedLibrary([Self.ridge()])
        defer { followed.stop() }
        let coordinator = MapView.Coordinator()
        let (_, map) = mapOverTheValley(
            coordinator,
            library: followed.library,
            route: Self.route(coordinates: Self.ridge())
        )
        defer { detach(map) }
        #expect(coordinator.libraryMap.drawings.count == 1, "another hike over the same ground")

        let onBoth = point(atLongitude: Valley.longitude, in: map)
        #expect(coordinator.routeTapTarget(at: onBoth, in: map) == .drawnRoute)
        #endif
    }

    // MARK: - Helpers

    /// A browser holding one shared hike's line, with nothing on a network.
    private func browserWithALine() async -> CommunityBrowser {
        let center = CLLocationCoordinate2D(latitude: Shared.latitude, longitude: Shared.longitude)
        let line = (0..<Shared.points).map { index in
            RouteCoordinate(latitude: center.latitude + Double(index) * Shared.step, longitude: center.longitude)
        }
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "ridge")])
        transport.outlinesResult = .success(["ridge": line])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(MKCoordinateRegion(
            center: center,
            latitudinalMeters: Shared.searchedMeters,
            longitudinalMeters: Shared.searchedMeters
        ))
        browser.startBrowsing()
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
        return browser
    }
}

/// A library on an in-memory store, its lines followed until the test stops
/// it.
@MainActor
private final class FollowedLibrary {
    let container: ModelContainer
    let library: LibraryLines
    /// Newest first, the order the lines are drawn in.
    let hikeIDs: [UUID]
    private var task: Task<Void, Never>?

    init(routes: [[RouteCoordinate]], openRequests: HikeOpenRequests, library: LibraryLines? = nil) throws {
        container = try Fixture.modelContainer()
        let main = container.mainContext
        let hikes = routes.enumerated().map { index, route in
            Fixture.hike(in: main, title: "Hike \(index)", route: route) { hike in
                hike.date = .now - TimeInterval(index) * 3600
            }
        }
        try main.save()
        hikeIDs = hikes.map(\.id)
        let followed = library ?? LibraryLines(openRequests: openRequests)
        self.library = followed
        task = Task { [container] in
            await followed.follow(in: container)
        }
    }

    func stop() {
        task?.cancel()
    }
}
