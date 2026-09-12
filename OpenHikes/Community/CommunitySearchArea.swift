import CoreLocation
import Foundation
import MapKit

/// A committed search circle. The live map region never changes this value.
nonisolated struct CommunitySearchArea: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init?(region: MKCoordinateRegion) {
        let radius = CommunityQueryPolicy.visibleRadiusMeters(for: region)
        guard CLLocationCoordinate2DIsValid(region.center), radius.isFinite,
              radius >= 0, radius <= CommunityQueryPolicy.maximumRadiusMeters else { return nil }
        latitude = region.center.latitude
        longitude = region.center.longitude
        radiusMeters = max(radius, CommunityQueryPolicy.minimumRadiusMeters)
    }
}

enum CommunityAreaChoice: Equatable {
    case anywhere
    case map
    case nearMe
    case place(String)

    var title: String {
        switch self {
        case .map: String(localized: "This map")
        case .nearMe: String(localized: "Near me")
        case let .place(name): name
        case .anywhere: String(localized: "Anywhere")
        }
    }
}
