//
//  TrailWidgetBasemapImages.swift
//  OpenWidget
//
//  Where the widget's basemap bytes come from.
//
//  There are two sources and one caller. A real trail's images are rendered by
//  the app into the App Group, named after the region they cover
//  (`<uuid>-<hash>-<variant>-<appearance>.jpg`); the placeholder's four are
//  rendered ahead of time by `Scripts/placeholder-basemaps.sh` and compiled
//  into this extension's asset catalogue, because the gallery is where a
//  hiker decides whether to place the widget at all and a trail-shaped
//  squiggle on a blank fill is not what they would be getting.
//
//  **Asked in that order, and the names are what keep it unambiguous.** A
//  rendered file name carries a `.jpg` extension and a UUID, so it is never a
//  data-set name and `NSDataAsset` misses it on a compiled hash lookup before
//  any file is touched. There is deliberately no prefix convention and no flag
//  on the entry saying which kind of set it is holding: the manifest shape is
//  identical for both, which is the property that lets `TrailMapView` draw
//  either one without knowing.
//

import Foundation
import OpenHikesShared
import UIKit

enum TrailWidgetBasemapImages {
    /// The bytes for `fileName`, from the asset catalogue or the App Group.
    ///
    /// `nil` for either miss, which is what `TrailMapView` turns into the
    /// line-only fallback — a broken-image box in a widget is worse than no
    /// map, and that decision stays in one place.
    static func data(named fileName: String) -> Data? {
        NSDataAsset(name: fileName, bundle: bundle)?.data
            ?? SharedStore.basemapImageData(named: fileName)
    }

    /// The bundle holding this file's compiled code, which is *not*
    /// `Bundle.main`. In the shipping app that is the widget extension, whose
    /// main bundle is the host app; under test it is the `OpenWidgetTests`
    /// bundle, which compiles the whole `OpenWidget` folder — assets included —
    /// and is hosted by the app as well. `Bundle.main` is the app in both
    /// cases, and the app does not carry these images.
    private static let bundle = Bundle(for: BundleMarker.self)

    /// Exists only to name the bundle above. A class rather than anything
    /// tidier because `Bundle(for:)` takes an `AnyClass` and there is no
    /// equivalent for a struct or an enum.
    private final class BundleMarker {}
}
