//
//  MapCoordinatorTests+PlaceSearchRegion.swift
//  OpenHikesTests
//
//  The place pills' half of *Search this area*: the trail maker's, and the one
//  *Places Around Trail* and *Places Nearby* share.
//
//  Both used to be handed the map's whole region, and the finder asked
//  Overpass about the square around it — as wide as the screen is tall, under
//  the sheet and past both sides of the screen. What is pinned here is what
//  the *Community* tab's pill already gets — see
//  `MapCoordinatorTests+AreaSearchRegion.swift`: a settle hands the finders
//  the map above the sheet's middle detent, rectangle and all; a tap hands
//  them the map above the sheet where it is; and a tap whose lowered sheet
//  shows more than the places' ceiling allows asks about the map that enabled
//  the pill, rather than dimming it and asking nothing.
//
//  The places' ceiling is a quarter of the community's, so the zoom that
//  straddles it here is one the community would search either way. A tap held
//  to the community's ceiling would hand the finder a map it refuses, which
//  is the case the ceiling tests exist to catch.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Synchronization
import Testing

/// The two place pills.
nonisolated enum PlaceSearchPill: CaseIterable, Sendable {
    /// The trail maker's.
    case maker
    /// The one *Places Around Trail* and *Places Nearby* share.
    case placesAround
}

extension MapCoordinatorTests {
    /// Answers nothing and remembers every area asked.
    private final class AreaRecordingSource: TrailPointSourcing, Sendable {
        private let asked = Mutex<[CommunitySearchArea]>([])

        var areas: [CommunitySearchArea] { asked.withLock { $0 } }

        func places(near area: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) -> [TrailPlace] {
            asked.withLock { $0.append(area) }
            return []
        }
    }

    /// The span of ``nearThePlaceCeiling``, in degrees: some sixteen
    /// kilometres across, which the map fits to its width.
    private enum PlaceWide {
        static let latitudeSpan = 0.1
        static let longitudeSpan = 0.21
    }

    /// A zoom at which the map above the sheet's middle detent is inside the
    /// places' ceiling and the map with the sheet lowered is outside it — and
    /// inside the community's, so a tap held to that one would be caught.
    private static let nearThePlaceCeiling = MKCoordinateRegion(
        center: searchedRegion.center,
        span: MKCoordinateSpan(latitudeDelta: PlaceWide.latitudeSpan, longitudeDelta: PlaceWide.longitudeSpan)
    )

    /// Where the sheet rests at its middle detent, as a share of the map's
    /// height, and how far up from the bottom it is lowered to — the figures
    /// the community's file uses.
    private static let middleDetentShare: CGFloat = 0.45
    private static let loweredSheetHeight: CGFloat = 100

    #if os(iOS)
    /// One place pill on a map, up and able to search, with the source its
    /// finder asks.
    private struct PlacePillMap {
        let map: MKMapView
        let control: MapAreaSearchView
        let button: UIControl
        let source: AreaRecordingSource
        /// Hands back the screen's claim on the map, for the pill whose
        /// screen holds one.
        let release: () -> Void
    }

    /// `pill`'s map showing `region`: the maker drawing, or *Places Around
    /// Trail* up and asking what its own screen asks with no line to rank
    /// against.
    private func placePillMap(
        _ pill: PlaceSearchPill,
        showing region: MKCoordinateRegion,
        _ coordinator: MapView.Coordinator
    ) throws -> PlacePillMap {
        let source = AreaRecordingSource()
        switch pill {
        case .maker:
            let maker = TrailDraftController(placeSource: source)
            maker.setHostScreenPresent(true)
            maker.setEditing(true)
            let map = searchedMap(mapView(trailMaker: maker), coordinator, showing: region)
            let control = try #require(coordinator.trailPointSearchControl)
            let button = try #require(areaSearchButton(in: control, .trailPoints))
            return PlacePillMap(map: map, control: control, button: button, source: source) { /* no claim */ }
        case .placesAround:
            let around = TrailPlacesAround(finder: TrailPointFinder(source: source))
            let view = mapView(placePins: TrailPlacePinController(around: around))
            let map = searchedMap(view, coordinator, showing: region)
            let token = around.attach(TrailPlacesAround.Handlers(
                select: { _ in /* not asked */ },
                searchArea: { around.finder.search(along: [], avoiding: []) },
                dropPin: { _ in /* not asked */ }
            ))
            let control = try #require(coordinator.placesAroundMap.searchControl)
            let button = try #require(areaSearchButton(in: control, .placesAround))
            return PlacePillMap(map: map, control: control, button: button, source: source) {
                around.detach(token: token)
            }
        }
    }

    /// Settles the map with the sheet at its middle detent, waits for the
    /// pill to be enabled, then lowers the sheet to near the bottom of the
    /// map, as a hiker looking at the whole map would. Answers the two
    /// readings of the map that are then on offer.
    private func enableThenLowerTheSheet(
        _ pillMap: PlacePillMap,
        _ coordinator: MapView.Coordinator
    ) async -> (lowered: MKCoordinateRegion, middle: MKCoordinateRegion) {
        let map = pillMap.map
        settle(sheetMetrics, at: map.bounds.height * Self.middleDetentShare)
        coordinator.mapView(map, regionDidChangeAnimated: false)
        await settle(until: "the pill to be enabled") { pillMap.control.isEnabled }
        sheetMetrics.report(topY: map.bounds.height - Self.loweredSheetHeight, atMiddleDetent: false)
        return (
            coordinator.areaSearchRegion(of: map, sheet: .whereItIs),
            coordinator.areaSearchRegion(of: map, sheet: .atMiddleDetent)
        )
    }
    #endif

    /// That `area` is `region` as the finder takes it: its middle, its
    /// rectangle, and half its longer side as the radius.
    private static func expectArea(
        _ area: CommunitySearchArea,
        isOf region: MKCoordinateRegion,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let same = 1e-9
        let figures = [
            (area.latitude, region.center.latitude),
            (area.longitude, region.center.longitude),
            (area.visibleSpan?.latitudeDelta ?? .nan, region.span.latitudeDelta),
            (area.visibleSpan?.longitudeDelta ?? .nan, region.span.longitudeDelta),
            (area.radiusMeters, CommunityQueryPolicy.visibleRadiusMeters(for: region)),
        ]
        for (actual, wanted) in figures {
            #expect(actual.isApproximatelyEqual(to: wanted, absoluteTolerance: same), sourceLocation: sourceLocation)
        }
    }

    /// What the ceiling tests stand on, as in the community's file: the middle
    /// detent's map is one the places take and the lowered sheet's one they
    /// do not, though the community would.
    private static func expectStraddlesThePlaceCeiling(
        lowered: MKCoordinateRegion,
        middle: MKCoordinateRegion,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let loweredRadius = Int(CommunityQueryPolicy.visibleRadiusMeters(for: lowered))
        let middleRadius = Int(CommunityQueryPolicy.visibleRadiusMeters(for: middle))
        #expect(
            TrailPointFinder.isWithinCeiling(middle) && !TrailPointFinder.isWithinCeiling(lowered)
                && CommunityQueryPolicy.isWithinCeiling(lowered),
            "precondition: \(middleRadius) m at the middle detent, \(loweredRadius) m lowered",
            sourceLocation: sourceLocation
        )
    }

    /// The settle the coordinator already makes reaches both finders, measured
    /// as the community's is.
    @Test("a settle hands both place finders the map above the sheet, rectangle and all")
    func theSettledRegionReachesThePlaceFinders() throws {
        #if os(iOS)
        let maker = TrailDraftController(placeSource: AreaRecordingSource())
        let around = TrailPlacesAround(finder: TrailPointFinder(source: AreaRecordingSource()))
        let coordinator = MapView.Coordinator()
        let view = mapView(trailMaker: maker, placePins: TrailPlacePinController(around: around))
        let map = searchedMap(view, coordinator)
        defer { detach(map) }

        coordinator.mapView(map, regionDidChangeAnimated: false)

        let expected = coordinator.areaSearchRegion(of: map, sheet: .atMiddleDetent)
        let middleOfWindow = map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.midY), toCoordinateFrom: map)
        for finder in [maker.finder, around.finder] {
            let area = try #require(finder.searchableArea)
            Self.expectArea(area, isOf: expected)
            #expect(
                area.latitude > middleOfWindow.latitude,
                "the middle of what is visible is north of the middle of the window, which the sheet covers"
            )
        }
        #endif
    }

    /// The pill is at the top of the map in every detent, so a hiker can ask
    /// with the sheet lowered — and then they are looking at nearly all of it.
    @Test(
        "a place pill tapped over a lowered sheet asks about the map it uncovered",
        arguments: PlaceSearchPill.allCases
    )
    func aPlacePillSearchesTheLoweredMap(_ pill: PlaceSearchPill) async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let pillMap = try placePillMap(pill, showing: Self.searchedRegion, coordinator)
        defer {
            pillMap.release()
            detach(pillMap.map)
        }
        let readings = await enableThenLowerTheSheet(pillMap, coordinator)
        #expect(TrailPointFinder.isWithinCeiling(readings.lowered), "precondition: the zoom is far from the ceiling")
        #expect(
            readings.lowered.span.latitudeDelta > readings.middle.span.latitudeDelta,
            "precondition: the lowered sheet shows more"
        )

        pillMap.button.sendActions(for: .primaryActionTriggered)

        await settle(until: "the tap's search to be asked") { !pillMap.source.areas.isEmpty }
        Self.expectArea(try #require(pillMap.source.areas.last), isOf: readings.lowered)
        #endif
    }

    /// The hole the ceiling closes, for the places' own ceiling: lowering the
    /// sheet puts the map it shows past it, and a tap that settled on that
    /// would dim the pill it was pressed on and ask nothing.
    @Test(
        "a place pill whose lowered-sheet map is past the places' ceiling asks about the middle detent's map",
        arguments: PlaceSearchPill.allCases
    )
    func aPlacePillPastTheCeilingSearchesTheMiddleDetent(_ pill: PlaceSearchPill) async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let pillMap = try placePillMap(pill, showing: Self.nearThePlaceCeiling, coordinator)
        defer {
            pillMap.release()
            detach(pillMap.map)
        }
        let readings = await enableThenLowerTheSheet(pillMap, coordinator)
        Self.expectStraddlesThePlaceCeiling(lowered: readings.lowered, middle: readings.middle)

        pillMap.button.sendActions(for: .primaryActionTriggered)

        await settle(until: "the tap's search to be asked") { !pillMap.source.areas.isEmpty }
        Self.expectArea(try #require(pillMap.source.areas.last), isOf: readings.middle)
        await settle(until: "the pill to answer again") {
            pillMap.control.isEnabled && !pillMap.control.isSearching
        }
        #endif
    }
}
