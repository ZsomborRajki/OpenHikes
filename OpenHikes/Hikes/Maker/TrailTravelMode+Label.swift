//
//  TrailTravelMode+Label.swift
//  OpenHikes
//
//  What a travel mode is called on screen. The mode itself is in
//  `OpenHikesData`; its words stay in the app, because only the app target's
//  build extracts strings into `Localizable.xcstrings` — a `String(localized:)`
//  in a package is looked up in the app's catalog but never added to it.
//

import Foundation
import OpenHikesData

nonisolated extension TrailTravelMode {
    var label: String {
        switch self {
        case .walking: String(localized: "Walking")
        case .hiking: String(localized: "Hiking")
        case .cycling: String(localized: "Cycling")
        case .driving: String(localized: "Driving")
        }
    }
}
