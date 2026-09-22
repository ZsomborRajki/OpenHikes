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
}
