//
//  MapCoordinatorTests+TrailPoints.swift
//  OpenHikesTests
//
//  The map's half of *Search this area* in the maker: one pill in a strip that
//  already had one, and the provisional pins its answers arrive as.
//
//  **The exclusion is the reason this file exists.** Everywhere else in the
//  maker two controls keep out of each other's way by falling out of their own
//  definitions — the camera pill and the draw pill are offered on opposite
//  answers to *is a screen pushed*, and neither knows the other exists. These
//  two are not like that: selecting the *Community* tab raises the other pill,
//  and a tab selection survives a push. So there is a rule, in
//  ``MapView/Coordinator/withdrawAreaSearchForDrawing(_:)``, and a rule is a
//  thing that can be deleted by somebody who does not know why it is there.
//  What is asserted here is that the two are never both on screen.
//
//  The candidates are asserted on a real `MKMapView` for the reason the
//  maker's own pins are: whether an answer reaches the map at all is not
//  visible from the finder, which will happily publish forty rows to nobody.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    /// A source that answers whatever it was built with, without a network.
    private struct StubPlaceSource: TrailPointSourcing {
        let answers: [TrailPlace]

        func places(near _: CommunitySearchArea) -> [TrailPlace] {
            answers
        }
    }

    /// Where the fixtures sit and what a searchable map of them looks like —
    /// named for the reason `Ridge` is one file over: a coordinate written
    /// inline is a magic number, and these three are read by four cases.
    private enum Fixtures {
        static let latitude: Double = 47.60
        static let longitude: Double = 12.90
        /// Small enough to be under ``TrailPointQuery/maximumRadiusMeters``.
        static let span: Double = 0.05
        /// And wide enough to be over it.
        static let continentalSpan: Double = 2
    }

    private static let searchCentre = CLLocationCoordinate2D(
        latitude: Fixtures.latitude,
        longitude: Fixtures.longitude
    )

    /// A maker whose searches answer, and which is already editing — the state
    /// the pill and the pins are both drawn in.
    private static func drawingMaker(offering places: [TrailPlace] = []) -> TrailDraftController {
        let maker = TrailDraftController(placeSource: StubPlaceSource(answers: places))
        maker.setHostScreenPresent(true)
        maker.setEditing(true)
        return maker
    }

    private static func place(_ latitude: Double, _ longitude: Double) -> TrailPlace {
        TrailPlace(latitude: latitude, longitude: longitude, symbol: .water)
    }

    /// A region small enough for a place search, centred on the fixtures.
    private static func searchableRegion() -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: searchCentre,
            span: MKCoordinateSpan(latitudeDelta: Fixtures.span, longitudeDelta: Fixtures.span)
        )
    }

    // MARK: The pill

    /// The maker is not up when a map is built, so neither is its pill.
    @Test("there is no place-search pill until the maker is up")
    func placeSearchPillHiddenUntilTheMakerIsUp() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailPointSearchControl)

        #expect(pill.isHidden)
        #expect(pill.alpha == 0)
        #expect(!pill.isUserInteractionEnabled, "an invisible control still answers hit tests")
        #endif
    }

    /// A map built while the maker is already open — which a rotation does —
    /// has to draw the pill on its first pass rather than waiting for a
    /// navigation that will not come.
    @Test("a map built while the maker is open offers the pill at once")
    func placeSearchPillVisibleOnFirstBuild() throws {
        #if os(iOS)
        let maker = Self.drawingMaker()

        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailPointSearchControl)

        #expect(!pill.isHidden)
        #expect(pill.alpha == 1)
        #expect(pill.isUserInteractionEnabled)
        #endif
    }

    /// A launch with no source withdraws it rather than offering a button that
    /// would spin and then say *unavailable*: the honest statement is that
    /// this launch cannot ask.
    @Test("a maker with no source is offered no pill")
    func placeSearchPillWithheldWithoutASource() throws {
        #if os(iOS)
        let maker = TrailDraftController()
        maker.setHostScreenPresent(true)
        maker.setEditing(true)

        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailPointSearchControl)

        #expect(pill.isHidden)
        #endif
    }

    /// Above the ceiling a tap would ask nothing, so the pill dims and stays
    /// where it is — the same answer the Community pill gets above its own,
    /// and for the same reason: a control that vanished at a zoom level would
    /// be reporting policy by absence.
    @Test("the pill is dimmed rather than withdrawn above the ceiling")
    func placeSearchPillDimsAboveTheCeiling() async throws {
        #if os(iOS)
        let maker = Self.drawingMaker()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailPointSearchControl)

        maker.finder.regionDidSettle(Self.searchableRegion())
        await settle(until: "the pill to take the offer") { pill.isEnabled }

        maker.finder.regionDidSettle(
            MKCoordinateRegion(
                center: Self.searchCentre,
                span: MKCoordinateSpan(
                    latitudeDelta: Fixtures.continentalSpan,
                    longitudeDelta: Fixtures.continentalSpan
                )
            )
        )
        await settle(until: "the pill to stop answering") { !pill.isEnabled }

        #expect(!pill.isHidden, "it stays where it is and says so by dimming")
        #endif
    }

    /// **The rule.** A hiker can be browsing shared trails and then tap *make
    /// a trail*; without this they had two pills in one strip, one asking
    /// OpenStreetMap for routes and one asking it for places.
    @Test("the community pill is withdrawn while a trail is being drawn")
    func theCommunityPillIsWithdrawnWhileDrawing() async throws {
        #if os(iOS)
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        browser.startBrowsing()
        let maker = Self.drawingMaker()

        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser, trailMaker: maker), coordinator)
        defer { detach(map) }
        let community = try #require(coordinator.areaSearchControl)
        let makerPill = try #require(coordinator.trailPointSearchControl)

        await settle(until: "the maker's pill to take the strip") { !makerPill.isHidden }
        #expect(
            !community.isUserInteractionEnabled,
            "the tab's pill answers nothing while the maker has the strip"
        )

        maker.setEditing(false)
        await settle(until: "the tab's pill to come back") { community.isUserInteractionEnabled }

        #expect(makerPill.alpha == 0, "and the maker's is the one that goes")
        #endif
    }

    // MARK: The candidates

    /// Whether an answer reaches the map at all is not visible from the
    /// finder, which will publish forty rows to nobody just as happily.
    @Test("what a search answers is drawn on the map")
    func aSearchDrawsItsCandidates() async {
        let maker = Self.drawingMaker(offering: [
            Self.place(47.601, 12.901),
            Self.place(47.602, 12.902),
        ])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }

        maker.finder.regionDidSettle(Self.searchableRegion())
        maker.searchNearbyPlaces()
        await settle(until: "the candidates to reach the map") {
            coordinator.trailPointCandidateAnnotations.count == 2
        }

        #expect(
            map.annotations.contains { $0 is TrailPointCandidateAnnotation },
            "and they are on the map rather than only in the coordinator"
        )
    }

    /// **A grey pin is a thing to look at.** A candidate and a place the hiker
    /// marked carry the same title and the same subtitle, and everything that
    /// separates them on screen — the colour, the thinning, the verbs in the
    /// callout — is invisible to a screen reader. Without the sentence below,
    /// a hiker swiping through the map's elements hears forty pins and cannot
    /// tell which three are theirs.
    ///
    /// Asserted here rather than in the accessibility sweep because there is
    /// no launch that can reach one: ``OpenHikesModel/makeTrailPointSource()``
    /// answers `nil` for every test, deliberately, so no candidate pin exists
    /// under automation.
    @Test("a candidate pin says out loud that it is only an offer")
    func aCandidatePinSaysItIsAnOffer() async throws {
        let maker = Self.drawingMaker(offering: [Self.place(47.601, 12.901)])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }

        maker.finder.regionDidSettle(Self.searchableRegion())
        maker.searchNearbyPlaces()
        await settle(until: "the candidate to reach the map") {
            coordinator.trailPointCandidateAnnotations.count == 1
        }
        let annotation = try #require(coordinator.trailPointCandidateAnnotations.first)
        let view = coordinator.trailPointCandidateView(for: annotation, on: map)

        let spoken = try #require(view.accessibilityLabel)
        #expect(spoken.contains("Water"), "it still says what the place is")
        #expect(
            spoken != annotation.title,
            "and it says more than the title a marked place would read with"
        )
        #expect(spoken.contains("not on your trail yet"))
    }

    /// Taking one is the only thing in this phase that writes anything down.
    /// The provisional pin goes because the candidate does, and a marked
    /// place's own pin arrives in its place — two pins on one spot is what
    /// this asserts against.
    @Test("marking a candidate replaces its pin with a place's")
    func markingACandidateReplacesItsPin() async throws {
        let maker = Self.drawingMaker(offering: [Self.place(47.601, 12.901)])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }

        maker.finder.regionDidSettle(Self.searchableRegion())
        maker.searchNearbyPlaces()
        await settle(until: "the candidate to reach the map") {
            coordinator.trailPointCandidateAnnotations.count == 1
        }
        let candidate = try #require(coordinator.trailPointCandidateAnnotations.first)

        coordinator.markTrailPointCandidate(candidate, on: map)
        await settle(until: "the provisional pin to be replaced") {
            coordinator.trailPointCandidateAnnotations.isEmpty
        }

        #expect(maker.draft.places.count == 1)
        #expect(
            maker.draft.places.first?.name == TrailPlaceSymbol.water.label,
            "an unnamed place is named after what it is"
        )
        #expect(coordinator.trailDraftPlaceAnnotations.count == 1, "and its own pin is there")
    }

    /// Nothing on offer is the hiker's, so nothing survives the screen it was
    /// offered on — including on the map.
    @Test("closing the maker takes the candidates off the map")
    func closingTheMakerTakesTheCandidatesOff() async {
        let maker = Self.drawingMaker(offering: [Self.place(47.601, 12.901)])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }

        maker.finder.regionDidSettle(Self.searchableRegion())
        maker.searchNearbyPlaces()
        await settle(until: "the candidate to reach the map") {
            coordinator.trailPointCandidateAnnotations.count == 1
        }

        maker.setEditing(false)
        await settle(until: "the map to be cleared") {
            coordinator.trailPointCandidateAnnotations.isEmpty
        }

        #expect(!map.annotations.contains { $0 is TrailPointCandidateAnnotation })
    }
}
