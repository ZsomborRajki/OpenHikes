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

    @Test("nothing is offered until the walker asks")
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

    /// The half that separates deciding from asking: a walker who ignores the
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

    /// The one that keeps the feature inside its quota: CloudKit resolves
    /// distance at around ten kilometres, so a small pan asks the same
    /// question and would get the same rows back — a button offering to re-ask
    /// it would change nothing.
    @Test("a pan smaller than a quarter of the radius offers nothing")
    func smallPanIsRefused() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        // 20 km across is a 10 km radius, so the threshold is 2.5 km. This is
        // roughly 1.1 km north.
        #expect(policy.action(for: Self.region(latitude: 47.64)) == .ignore)
    }

    @Test("a pan past the threshold is a new question")
    func largePanIsOffered() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(), to: &policy)
        // Roughly 44 km north, comfortably past a 2.5 km threshold.
        guard case .offer = policy.action(for: Self.region(latitude: 48.03)) else {
            Issue.record("a pan of tens of kilometres is a different question")
            return
        }
    }

    /// Zooming without moving changes what the walker is asking about even
    /// though the centre is identical, so the centre threshold alone would
    /// refuse it forever.
    @Test("zooming in far enough is a new question without moving")
    func zoomIsOffered() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        Self.commit(Self.region(spanMeters: 100_000), to: &policy)
        guard case .offer = policy.action(for: Self.region(spanMeters: 20_000)) else {
            Issue.record("a fivefold zoom is a different question")
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

    /// A failed request has to leave the region askable again, or the walker's
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
