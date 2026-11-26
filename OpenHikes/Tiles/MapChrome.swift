//
//  MapChrome.swift
//  OpenHikes
//
//  The appearance the controls over the map take, which follows the *map*
//  and not the phone: a control is read against what is drawn under it.
//  `MapView.applyTileSource(to:_:)` has the argument and the measurement
//  that began it, a tracking button's white arrow at 2.25:1 over light tiles
//  in dark mode.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The appearance of the controls drawn over one map.
nonisolated enum MapChrome: Equatable, Sendable {
    /// Dark at every hour, over a map drawn dark at every hour: the
    /// OpenHikes map in its dark colors.
    case dark
    /// Light at every hour, over tiles that draw a light page at every hour:
    /// every raster source, and the OpenHikes map in Carto's colors.
    case light
    /// The phone's, over Apple's maps: the standard map turns over with the
    /// appearance, and the satellite map's chrome follows the phone as Apple
    /// Maps' does.
    case system

    /// The one appearance the controls keep, or `nil` where they follow the
    /// phone. What SwiftUI drawn over the map rather than inside it, the
    /// weather badge and the walk-started pill, sets its color scheme by.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    #if canImport(UIKit)
    /// What the map view overrides its own appearance with, which the UIKit
    /// controls inside it take.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: .unspecified
        }
    }
    #endif
}

extension MapBase {
    /// The appearance of the controls over this base.
    var chrome: MapChrome {
        guard let tileSource else { return .system }
        return TileProvider.vectorPalette(forProviderID: tileSource.providerID).isDark ? .dark : .light
    }
}
