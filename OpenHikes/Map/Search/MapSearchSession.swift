import Foundation
import Observation

enum MapSearchScope: String, CaseIterable, Identifiable {
    case all = "all"
    case community = "community"
    case places = "places"
    case yourHikes = "yourHikes"

    static var displayOrder: [Self] { [.all, .yourHikes, .community, .places] }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .yourHikes: String(localized: "Your Hikes")
        case .community: String(localized: "Community")
        case .places: String(localized: "Places")
        }
    }

    var includesHikes: Bool { self == .all || self == .yourHikes }
    var includesCommunity: Bool { self == .all || self == .community }
    var includesPlaces: Bool { self == .all || self == .places }
}

/// Search survives keyboard dismissal, previews and replacement of the sheet on rotation.
@Observable
final class MapSearchSession {
    var scope: MapSearchScope = .all
    var showsResults = false
    @ObservationIgnored var programmaticQuery: String?

    func consumesProgrammaticChange(_ value: String) -> Bool {
        let matches = programmaticQuery == value
        programmaticQuery = nil
        return matches
    }
}
