// The menu’s words belong to the app target, which extracts its String Catalog.

import Foundation
import OpenHikesData

nonisolated extension HikeListSort {
    /// What the menu says, phrased as the answer rather than the field: a
    /// hiker picking an order is asking "show me the long ones", not naming a
    /// column.
    var title: String {
        switch self {
        case .newest: String(localized: "Newest First")
        case .alphabetical: String(localized: "Name")
        case .longest: String(localized: "Longest")
        case .mostWalked: String(localized: "Most Hiked")
        case .hilliest: String(localized: "Hilliest")
        }
    }
}
