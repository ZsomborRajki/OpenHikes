//
//  CommunityQueryPolicyTests.swift
//  OpenHikesTests
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// The requests a moving map is allowed to make.
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

    @Test("nothing is requested until the walker asks")
    func browsingIsOptIn() {
        var policy = CommunityQueryPolicy()
        #expect(policy.action(for: Self.region()) == .ignore)
        #expect(policy.issuedQueries == 0)
    }

    @Test("turning browsing on asks about wherever the map is")
    func firstRegionIsRequested() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        guard case .search = policy.action(for: Self.region()) else {
            Issue.record("the first region after opting in should be requested")
            return
        }
        #expect(policy.issuedQueries == 1)
    }

    /// The one that keeps the feature inside its quota: CloudKit resolves
    /// distance at around ten kilometres, so a small pan asks the same
    /// question and would get the same rows back.
    @Test("a pan smaller than a quarter of the radius asks nothing")
    func smallPanIsRefused() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        _ = policy.action(for: Self.region())
        // 20 km across is a 10 km radius, so the threshold is 2.5 km. This is
        // roughly 1.1 km north.
        let nudged = Self.region(latitude: 47.64)
        #expect(policy.action(for: nudged) == .ignore)
        #expect(policy.issuedQueries == 1)
    }

    @Test("a pan past the threshold is a new question")
    func largePanIsRequested() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        _ = policy.action(for: Self.region())
        // Roughly 44 km north, comfortably past a 2.5 km threshold.
        guard case .search = policy.action(for: Self.region(latitude: 48.03)) else {
            Issue.record("a pan of tens of kilometres is a different question")
            return
        }
        #expect(policy.issuedQueries == 2)
    }

    /// Zooming without moving changes what the walker is asking about even
    /// though the centre is identical, so the centre threshold alone would
    /// refuse it forever.
    @Test("zooming in far enough is a new question without moving")
    func zoomIsRequested() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        _ = policy.action(for: Self.region(spanMeters: 100_000))
        guard case .search = policy.action(for: Self.region(spanMeters: 20_000)) else {
            Issue.record("a fivefold zoom is a different question")
            return
        }
    }

    @Test("zoomed out past the ceiling, nothing is asked")
    func continentalZoomIsRefused() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        #expect(policy.action(for: Self.region(spanMeters: 2_000_000)) == .ignore)
        #expect(policy.issuedQueries == 0)
    }

    /// Zooming out to the whole country and back must leave the valley's
    /// results standing, so the refusal above must not also forget the last
    /// query — otherwise coming back would re-fetch what is already on screen.
    @Test("a refused zoom-out does not forget where the map was")
    func ceilingDoesNotForget() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        _ = policy.action(for: Self.region())
        _ = policy.action(for: Self.region(spanMeters: 2_000_000))
        #expect(policy.action(for: Self.region()) == .ignore)
        #expect(policy.issuedQueries == 1)
    }

    /// A failed request has to leave the region askable again, or the walker's
    /// only recourse is to pan away and back.
    @Test("forgetting the last query makes the same region a new question")
    func forgettingReopensTheRegion() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        _ = policy.action(for: Self.region())
        #expect(policy.action(for: Self.region()) == .ignore)
        policy.forgetLastQuery()
        guard case .search = policy.action(for: Self.region()) else {
            Issue.record("a forgotten query should make the region askable again")
            return
        }
    }

    /// Turning the chip off and on again must not show a list from wherever
    /// the map used to be.
    @Test("switching browsing off forgets the last query")
    func stoppingForgets() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()
        _ = policy.action(for: Self.region())
        policy.stopBrowsing()
        #expect(!policy.isBrowsing)
        policy.startBrowsing()
        guard case .search = policy.action(for: Self.region()) else {
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
        guard case .search(_, let radius) = policy.action(for: Self.region(spanMeters: 200)) else {
            Issue.record("a close-in region is still a question")
            return
        }
        #expect(radius == CommunityQueryPolicy.minimumRadiusMeters)
    }
}
