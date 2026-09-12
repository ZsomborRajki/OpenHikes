#if DEBUG
import CoreLocation
import Foundation
import MapKit

/// Read-only, deterministic data for UI automation. Never constructs CloudKit.
nonisolated struct CommunitySearchFixture: CommunityTransporting {
    private static let latitude = 47.72
    private static let longitude = 18.9
    static let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    private static let diameter: Double = 20_000
    private static let routeOffset = 0.02
    private static let hikeDistance: Double = 8000
    private static let dateInterval: TimeInterval = 1_750_000_000
    private static let date = Date(timeIntervalSince1970: dateInterval)

    static var region: MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: diameter, longitudinalMeters: diameter)
    }

    private static let rows = ["Pilis Ridge", "Forest Loop", "Valley Walk"].enumerated().map { index, title in
        CommunityListing(
            id: "fixture-\(index)",
            submissionID: "fixture-submission-\(index)",
            title: title,
            authorName: "Anna",
            authorID: "fixture-author",
            hikeDate: date,
            distanceMeters: hikeDistance,
            photoCount: 0,
            latitude: center.latitude,
            longitude: center.longitude,
            publishedAt: date
        )
    }

    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String {
        throw CommunityFailure.unavailable("UI fixtures cannot submit hikes")
    }

    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>
    ) async -> [CommunityListing] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let fixtureLocation = CLLocation(latitude: Self.center.latitude, longitude: Self.center.longitude)
        guard origin.distance(from: fixtureLocation) < radiusMeters else { return [] }
        return Array(Self.rows.filter { !excluding.contains($0.authorID) }.prefix(limit))
    }

    @concurrent
    func listings(
        matching query: String,
        area: CommunitySearchArea?,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing] {
        if query == "Offline" { throw CommunityFailure.unreachable }
        // Both predicates before the budget, as ``CommunityTransporting``
        // specifies and ``CloudKitCommunityTransport`` implements with a
        // compound predicate. Spending `limit` on the area first would let a
        // matching title drop out because non-matching rows ahead of it used
        // the budget up — a fixture that models the transport wrongly is a
        // test that agrees with the regression.
        let candidates: [CommunityListing]
        if let area {
            candidates = await listings(
                near: area.coordinate,
                radiusMeters: area.radiusMeters,
                limit: Self.rows.count,
                excluding: excluding
            )
        } else {
            candidates = Self.rows.filter { !excluding.contains($0.authorID) }
        }
        return Array(candidates.filter { $0.title.localizedCaseInsensitiveContains(query) }.prefix(limit))
    }

    @concurrent
    func detail(
        for listing: CommunityListing,
        downloadingInto directory: URL
    ) async -> CommunityHikeDetail {
        let route = [
            RouteCoordinate(Self.center),
            RouteCoordinate(latitude: Self.center.latitude + Self.routeOffset, longitude: Self.center.longitude),
            RouteCoordinate(Self.center),
        ]
        return CommunityHikeDetail(
            listing: listing,
            route: route,
            trackDescription: "A published hike for UI testing.",
            photoPins: [],
            photoFileURLs: []
        )
    }
}
#endif
