import Foundation

/// A property of this draft, independent of the freehand switch and undo history.
nonisolated enum TrailTravelMode: String, CaseIterable, Codable, Sendable {
    case cycling = "cycling"
    case driving = "driving"
    case hiking = "hiking"
    case walking = "walking"

    static let allCases: [Self] = [.walking, .hiking, .cycling, .driving]

    var label: String {
        switch self {
        case .walking: String(localized: "Walking")
        case .hiking: String(localized: "Hiking")
        case .cycling: String(localized: "Cycling")
        case .driving: String(localized: "Driving")
        }
    }

    var symbolName: String {
        switch self {
        case .walking: "figure.walk"
        case .hiking: "figure.hiking"
        case .cycling: "bicycle"
        case .driving: "car.fill"
        }
    }

    /// The pace a leg is timed at when no router said how long it takes: every
    /// hiking leg, since the trail graph knows distances and nothing else, and
    /// any leg drawn freehand. Apple Maps' own estimate replaces it whenever a
    /// directions answer carries one.
    ///
    /// Hiking is 4 km/h rather than walking's 5 because a path is not a
    /// pavement; neither counts the climb, which no single leg is measured for.
    var paceMetersPerSecond: Double {
        let pace = switch self {
        case .walking: Self.walkingPace
        case .hiking: Self.hikingPace
        case .cycling: Self.cyclingPace
        case .driving: Self.drivingPace
        }
        return pace.converted(to: .metersPerSecond).value
    }

    private static let walkingPace = Measurement(value: 5, unit: UnitSpeed.kilometersPerHour)
    private static let hikingPace = Measurement(value: 4, unit: UnitSpeed.kilometersPerHour)
    private static let cyclingPace = Measurement(value: 15, unit: UnitSpeed.kilometersPerHour)
    private static let drivingPace = Measurement(value: 50, unit: UnitSpeed.kilometersPerHour)
}
