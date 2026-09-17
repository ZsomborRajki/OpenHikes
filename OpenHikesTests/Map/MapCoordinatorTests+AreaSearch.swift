//
//  MapCoordinatorTests+AreaSearch.swift
//  OpenHikesTests
//
//  *Search this area* arrives and leaves on a quarter-second fade, and a fade
//  is the one thing about this control that a second application of the same
//  state destroys: the animated branch defers `isHidden` to its completion so
//  the pill has something to fade out, and an unanimated apply running behind
//  it in the same main-actor turn hides the view before the animation has
//  drawn a frame.
//
//  So what is asserted here is the half of the behaviour that outlives the
//  animation: the pill is still in the hierarchy while the fade-out runs, and
//  it is out of the way of the map's hit tests once the fade has landed.
//  Whether the quarter-second actually *looks* like a fade is a device pass.
//
//  What raises and withdraws it is the *Community* tab rather than the offer —
//  see ``MapSheetList`` — so the fade is driven here by leaving the tab, and
//  the offer's own comings and goings are asserted on the one thing they still
//  decide: whether a tap can ask anything.
//
//  The caption under it is asserted here too, and on the same terms: what it
//  says is ``CuratedTrailNotice``'s and is pinned there, so what is pinned
//  here is that what OpenStreetMap answered *reaches* the control and that it
//  leaves the button answering — both for a refusal and for an area with no
//  waymarked routes in it. A rate limit is about one of the list's two
//  sources, and disabling the one control the *Community* tab has because the
//  other source is busy would take the published hikes away with it; an empty
//  area is not a failure at all, and moving the map and tapping again is the
//  whole of what its caption advises.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    private static let metersPerDegree: Double = 111_320
    /// Far enough north of the resting region to clear
    /// ``CommunityQueryPolicy``'s quarter-radius threshold, so a settle there
    /// is an offer rather than the same question again.
    private static let pannedLatitude = 48.03

    private static func areaRegion(
        latitude: Double = 47.63,
        longitude: Double = 12.86,
        spanMeters: Double = 20_000
    ) -> MKCoordinateRegion {
        let degrees = spanMeters / metersPerDegree
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    /// A browser that has opted in and answered once, so the next pan past the
    /// threshold is an offer rather than a question.
    ///
    /// `curatedOutcome` is armed **after** the opt-in has landed, deliberately.
    /// Opening the tab asks OpenStreetMap too — see ``CommunityNearbyScope`` —
    /// so setting it up front would caption the pill before the case had asked
    /// for anything, and the cases here are about what one tap on the pill
    /// puts there.
    private func browsingBrowser(
        curatedOutcome: CuratedTrailOutcome = .trails(1)
    ) async -> CommunityBrowser {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.areaRegion())
        browser.startBrowsing()
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
        transport.curatedOutcome = curatedOutcome
        return browser
    }

    /// Runs the request the pill's own tap makes — the only one that asks
    /// OpenStreetMap anything, and so the only one a rate limit can answer.
    ///
    /// The region is settled again first, and that is not ceremony: attaching
    /// a real `MKMapView` delivers the map's *own* region through
    /// `regionDidChangeAnimated`, which is a continent wide and leaves the
    /// browser at ``CommunityAreaPrompt/zoomIn``. Every test in this file that
    /// asserts about an enabled pill re-settles somewhere askable after the
    /// attach, for the same reason.
    private func searchThisArea(_ browser: CommunityBrowser) async {
        browser.regionDidSettle(Self.areaRegion(latitude: Self.pannedLatitude))
        await settle(until: "the offer to be raised") { browser.areaPrompt == .search }
        browser.searchVisibleArea()
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
    }

    @Test("the pill stays in the hierarchy until its fade-out has landed")
    func areaPillFadesOutRatherThanVanishing() async throws {
        #if os(iOS)
        let browser = await browsingBrowser()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)

        // The tab is up, so the pill is: it belongs to the community list
        // rather than to any one offer.
        await settle(until: "the pill to be raised") { !pill.isHidden }
        #expect(pill.alpha == 1)
        #expect(pill.isUserInteractionEnabled)

        // Leaving the tab withdraws it. Interaction goes at once — the map
        // underneath is being panned — but the view itself belongs to the
        // animation until the animation is done with it.
        browser.stopBrowsing()
        await settle(until: "the fade-out to start") { !pill.isUserInteractionEnabled }
        #expect(
            !pill.isHidden,
            "hiding the pill in the same turn leaves the fade nothing to fade"
        )

        await settle(until: "the fade-out to land") { pill.isHidden }
        #expect(pill.alpha == 0)
        #endif
    }

    /// Taking the offer used to take the button with it, which put the one
    /// control this list has somewhere the hiker had to earn by panning. It
    /// stays, and asking again is a thing they can do.
    @Test("taking the offer leaves the pill where it is")
    func areaPillOutlivesTheOffer() async throws {
        #if os(iOS)
        let browser = await browsingBrowser()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)

        browser.regionDidSettle(Self.areaRegion(latitude: Self.pannedLatitude))
        await settle(until: "the offer to be raised") { browser.areaPrompt == .search }
        browser.searchVisibleArea()
        // On the **pill**, not on the browser. `commit` clears the prompt and
        // starts the request in one turn, so the old wait — the prompt alone —
        // asserted about a control that was still spinning; and waiting on
        // `browser.isSearching` instead only moves the race, because the
        // control catches up an observation hop later. The house rule is to
        // wait on the effect, and the effect here is the pill answering again.
        await settle(until: "the pill to answer again") {
            pill.isEnabled && !pill.isSearching
        }

        #expect(browser.areaPrompt == .settled, "the offer was taken")
        #expect(!pill.isHidden, "an answered area is still an area worth asking about again")
        #expect(pill.isUserInteractionEnabled)
        #endif
    }

    /// The failure the caption exists against: Overpass refusing used to reach
    /// the log and nowhere else, so a hiker whose address had been rate-limited
    /// saw a list with no trails in it and no way to tell that apart from an
    /// area with none. It now reaches the control that spent the request.
    @Test("a rate-limited search captions the pill and leaves it answering")
    func aRateLimitedSearchCaptionsThePill() async throws {
        #if os(iOS)
        let browser = await browsingBrowser(curatedOutcome: .outage(.rateLimited(retryAfter: 60)))
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)
        #expect(pill.notice == nil, "nothing has been refused yet")

        await searchThisArea(browser)

        await settle(until: "the caption to reach the pill") { pill.notice != nil }
        #expect(
            pill.isEnabled,
            "the published half is still askable, so the one control this tab has still works"
        )
        #expect(!pill.isHidden)
        #endif
    }

    /// The other caption, and the one a hiker meets far more often. It is not
    /// a failure, so the button is left exactly as able to answer as it was —
    /// tapping it somewhere else is the advice.
    @Test("an empty area captions the pill and leaves it answering")
    func anEmptyAreaCaptionsThePill() async throws {
        #if os(iOS)
        let browser = await browsingBrowser(curatedOutcome: .trails(0))
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)
        #expect(pill.notice == nil, "nothing has been searched for yet")

        await searchThisArea(browser)

        await settle(until: "the caption to reach the pill") { pill.notice == .noTrailsHere }
        #expect(pill.isEnabled, "somewhere else is the answer, and the pill is how to ask")
        #expect(!pill.isHidden)
        #endif
    }

    /// The spinner is the whole of what the hiker is told while the two
    /// halves are out, so it has to arrive and it has to leave. It is held
    /// open here by a transport that does not answer until the case lets it,
    /// which is the only way to observe a state whose whole job is to be
    /// temporary.
    @Test("the pill spins and stops answering while a search is out")
    func aSearchInFlightSpinsThePill() async throws {
        #if os(iOS)
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([])
        let held = AsyncGate()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.areaRegion())
        browser.startBrowsing()
        while browser.requestsInFlight > 0 { await Task.yield() }
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)
        #expect(!pill.isSearching, "nothing has been asked yet")

        transport.beforeListingsReturn = { await held.wait() }
        browser.regionDidSettle(Self.areaRegion(latitude: Self.pannedLatitude))
        await settle(until: "the offer to be raised") { browser.areaPrompt == .search }
        browser.searchVisibleArea()

        await settle(until: "the pill to start spinning") { pill.isSearching }
        #expect(
            !pill.isEnabled,
            "a second tap cannot answer sooner, only queue another Overpass pass"
        )

        await held.open()
        await settle(until: "the pill to stop spinning") { !pill.isSearching }
        #expect(pill.isEnabled)
        #endif
    }

    /// The caption belongs to the tab that drew it, like the pill itself.
    @Test("leaving the tab takes the caption with the pill")
    func leavingTheTabClearsTheCaption() async throws {
        #if os(iOS)
        let browser = await browsingBrowser(curatedOutcome: .outage(.unavailable))
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)
        await searchThisArea(browser)
        await settle(until: "the caption to reach the pill") { pill.notice != nil }

        browser.stopBrowsing()

        await settle(until: "the caption to be withdrawn") { pill.notice == nil }
        #endif
    }

    /// The one state it cannot answer in. Disabled rather than withdrawn: the
    /// list's footer says why, and a control that vanished at a zoom level
    /// would be reporting policy by absence — the thing this pill exists to
    /// stop.
    @Test("above the ceiling the pill stays up and stops answering")
    func areaPillDimsAboveTheCeiling() async throws {
        #if os(iOS)
        let browser = await browsingBrowser()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)

        browser.regionDidSettle(Self.areaRegion(spanMeters: 2_000_000))
        await settle(until: "the pill to be disabled") { !pill.isEnabled }
        #expect(!pill.isHidden, "the footer explains a dimmed pill, not a missing one")

        browser.regionDidSettle(Self.areaRegion(latitude: 48.03))
        await settle(until: "the pill to answer again") { pill.isEnabled }
        #endif
    }
}
