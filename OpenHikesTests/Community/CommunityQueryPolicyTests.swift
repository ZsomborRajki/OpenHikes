//
//  CommunityQueryPolicyTests.swift
//  OpenHikesTests
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// The requests a moving map is allowed to offer to make.
///
/// Every test here is about one that must *not* happen, which is the whole
/// reason the policy is a type rather than an `if` inside the browser: a
/// refused pan and a pan nobody made leave identical state behind, so there is
/// nothing to assert on unless the decision itself is reachable.
@Suite("Community query policy")
struct CommunityQueryPolicyTests {
    /// A region whose longer edge is `spanMeters` across.
    private static func region(
        latitude: Double = 47.63,
        longitude: Double = 12.86,
        spanMeters: Double = 20_000
    ) -> MKCoordinateRegion {
        let degrees = spanMeters / 111_320
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    /// Takes the offer a region raises, the way ``CommunityBrowser`` does.
    @discardableResult private static func commit(
        _ region: MKCoordinateRegion,
        to policy: inout CommunityQueryPolicy
    ) -> CommunitySearchArea? {
        guard case .offer(let area) = policy.action(for: region) else {
            Issue.record("expected this region to be offered")
            return nil
        }
        policy.commit(area)
        return area
    }

    @Test("nothing is offered until the hiker asks")
    func browsingIsOptIn() {
        // `let`, because the decision is now side-effect free: a region that
        // nobody has opted in to changes nothing at all.
        let policy = CommunityQueryPolicy()
        #expect(policy.action(for: Self.region()) == .ignore)
        #expect(policy.issuedQueries == 0)
    }

    @Test("opting in makes wherever the map is a question")
    func firstRegionIsOffered() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        guard case .offer = policy.action(for: Self.region()) else {
            Issue.record("the first region after opting in should be offered")
            return
        }
    }

    /// The half that separates deciding from asking: a hiker who ignores the
    /// offer keeps it, and one who takes it spends the request.
    @Test("an offer costs nothing until it is committed")
    func offersAreFree() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        _ = policy.action(for: Self.region())
        _ = policy.action(for: Self.region())
        #expect(policy.issuedQueries == 0)
        Self.commit(Self.region(), to: &policy)
        #expect(policy.issuedQueries == 1)
    }

    /// The reason ``CommunityQueryPolicy/action(for:)`` has no side effects. A
    /// pan is a run of settles, and the second one must not withdraw the offer
    /// the first one raised.
    @Test("a repeated settle keeps offering the same region")
    func repeatedSettlesKeepTheOffer() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        let moved = Self.region(latitude: 48.03)
        guard case .offer(let first) = policy.action(for: moved),
              case .offer(let second) = policy.action(for: moved) else {
            Issue.record("an untaken offer should survive the next settle")
            return
        }
        #expect(first == second)
    }

    /// The one that keeps the feature inside its quota. It used to be a
    /// quarter of the radius, which is where *CloudKit's* answer starts to
    /// differ; it is half now, because taking an offer also spends an Overpass
    /// listing pass against a volunteer-run API — see
    /// ``CommunityQueryPolicy/recentreFraction``. The hiker loses nothing by
    /// it: the pill is permanent, and a tap with no offer standing re-asks.
    @Test("a pan smaller than half the radius offers nothing")
    func smallPanIsRefused() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        // 20 km across is a 10 km radius, so the threshold is 5 km. This is
        // roughly 1.1 km north.
        #expect(policy.action(for: Self.region(latitude: 47.64)) == .ignore)
    }

    /// The figure that moved, pinned from the other side: a pan that clears a
    /// quarter of the radius and not half of it is refused now, where it used
    /// to be offered. Without this the threshold could be lowered back to a
    /// quarter and every other case in this file would still pass.
    @Test("a pan of a third of the radius is not enough any more")
    func aQuarterPanIsRefused() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        // 10 km radius, so roughly 3.3 km north: past the old 2.5 km
        // threshold and short of the new 5 km one.
        #expect(policy.action(for: Self.region(latitude: 47.66)) == .ignore)
    }

    @Test("a pan past the threshold is a new question")
    func largePanIsOffered() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        // Roughly 44 km north, comfortably past a 5 km threshold.
        guard case .offer = policy.action(for: Self.region(latitude: 48.03)) else {
            Issue.record("a pan of tens of kilometres is a different question")
            return
        }
    }

    /// Zooming without moving changes what the hiker is asking about even
    /// though the centre is identical, so the centre threshold alone would
    /// refuse it forever.
    @Test("zooming in far enough is a new question without moving")
    func zoomIsOffered() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        // Both spans are inside the ceiling, which is 40 km of *radius* — an
        // 80 km one. The wider of the two used to be 100 km across and is not
        // a question this policy takes any more; see
        // ``CommunityQueryPolicy/maximumRadiusMeters``.
        Self.commit(Self.region(spanMeters: 60_000), to: &policy)
        guard case .offer = policy.action(for: Self.region(spanMeters: 20_000)) else {
            Issue.record("a threefold zoom is a different question")
            return
        }
    }

    /// The band that used to sit between the two ceilings, asserted from the
    /// inside. A 50 km radius was offered, spent a CloudKit query, and came
    /// back with no curated trails and nothing on screen saying why.
    @Test("a radius past the curated ceiling is too far out")
    func theCuratedCeilingIsThePolicysCeiling() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        let pastIt = CuratedTrailQuery.maximumRadiusMeters * 2 + 1

        #expect(policy.action(for: Self.region(spanMeters: pastIt)) == .tooFarOut)
        guard case .offer = policy.action(
            for: Self.region(spanMeters: CuratedTrailQuery.maximumRadiusMeters * 2)
        ) else {
            Issue.record("the ceiling itself is still a question worth asking")
            return
        }
    }

    /// Past the ceiling there is nothing worth asking and something worth
    /// saying, which is why this is its own answer rather than `.ignore` —
    /// the sheet says it, since a button that cannot answer well is worse
    /// than no button.
    @Test("zoomed out past the ceiling, the answer is to zoom in")
    func continentalZoomIsRefused() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        #expect(policy.action(for: Self.region(spanMeters: 2_000_000)) == .tooFarOut)
        #expect(policy.issuedQueries == 0)
    }

    /// Zooming out to the whole country and back must leave the valley's
    /// results standing, so the refusal above must not also forget the last
    /// query — otherwise coming back would offer to re-fetch what is already
    /// on screen.
    @Test("a refused zoom-out does not forget where the map was")
    func ceilingDoesNotForget() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        #expect(policy.action(for: Self.region(spanMeters: 2_000_000)) == .tooFarOut)
        #expect(policy.action(for: Self.region()) == .ignore)
        #expect(policy.issuedQueries == 1)
    }

    /// A failed request has to leave the region askable again, or the hiker's
    /// only recourse is to pan away and back.
    @Test("forgetting the last query makes the same region a new question")
    func forgettingReopensTheRegion() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        #expect(policy.action(for: Self.region()) == .ignore)
        policy.forgetLastQuery()
        guard case .offer = policy.action(for: Self.region()) else {
            Issue.record("a forgotten query should make the region askable again")
            return
        }
    }

    /// Hiding the section and asking for it again must not show a list from
    /// wherever the map used to be.
    @Test("switching browsing off forgets the last query")
    func stoppingForgets() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        policy.stopBrowsing()
        #expect(!policy.isBrowsing)
        policy.startBrowsing()
        guard case .offer = policy.action(for: Self.region()) else {
            Issue.record("re-opting in should ask again")
            return
        }
    }

    /// A zoomed-right-in map still asks about a usable area rather than the
    /// hundred metres on screen, because the server cannot answer finer.
    @Test("the radius never drops below what the server can resolve")
    func radiusHasAFloor() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        guard case .offer(let area) = policy.action(for: Self.region(spanMeters: 200)) else {
            Issue.record("a close-in region is still a question")
            return
        }
        #expect(area.radiusMeters == CommunityQueryPolicy.minimumRadiusMeters)
    }
}
