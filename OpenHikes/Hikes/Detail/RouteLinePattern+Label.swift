// The menu’s words belong to the app target, which extracts its String Catalog.

import Foundation
import OpenHikesData

nonisolated extension RouteLinePattern {
    var title: String {
        switch self {
        case .solid: String(localized: "Solid")
        case .directional: String(localized: "Arrows")
        case .dashed: String(localized: "Dashed")
        case .dotted: String(localized: "Dotted")
        case .arrowheads: String(localized: "Arrows only")
        }
    }
}
