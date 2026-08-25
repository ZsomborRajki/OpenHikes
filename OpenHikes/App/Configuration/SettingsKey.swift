//
//  SettingsKey.swift
//  OpenHikes
//
//  The `UserDefaults` / `@AppStorage` keys the app persists across launches,
//  and the defaults for the ones where "absent" and "false" are different
//  answers. Collected here rather than beside whichever feature happens to
//  read them first: the keys span selection, background tracking, tiles and
//  photos, and several are written by one subsystem and read by another. The
//  string values are a storage contract — changing one silently drops the
//  stored setting on the next launch.
//
//  Nothing here configures networking. What the app puts on the radio is
//  decided from live conditions by ``TileNetworkPolicy``, not from a switch
//  the walker had to find before they set off.
//

import Foundation

/// UserDefaults / `@AppStorage` key shared between the settings UI and the map.
nonisolated enum SettingsKey {
    static let tileProviderID = "settings.tileProviderID"
    /// Whether Background Trail Tracking is on, read by `BackgroundTrailTracker`
    /// at launch to decide whether to re-arm significant-change monitoring.
    static let backgroundTrackingEnabled = "settings.backgroundTrackingEnabled"
    /// The last-selected hike's `id.uuidString`, written by `OpenHikesModel` on
    /// every selection change. Serves two purposes: restoring the selection
    /// on a normal launch, and telling `BackgroundTrailTracker` which hike to
    /// match a fix against on a background relaunch, which has no in-memory
    /// selection to read.
    static let lastSelectedHikeID = "selection.lastHikeID"
    /// How far along the tracked hike the last background fix matched, in
    /// metres. `BackgroundTrailTracker` carries this across process launches so
    /// a relaunched match resumes from the previous position rather than
    /// re-deriving it; absent means "no continuity reference yet", which is why
    /// it is removed rather than zeroed when the selection changes.
    static let lastMatchedDistance = "trailTracking.lastMatchedDistance"
    /// Whether a photo taken in OpenHikes is also written to the system photo
    /// library. Off unless the user turns it on — and the only reason the app
    /// ever asks for photo-library access, which it does on the first save
    /// after the switch is flipped rather than when it is flipped.
    static let savePhotosToLibrary = "settings.savePhotosToLibrary"
}

/// Defaults for keys where "absent" and "false" are different answers, so the
/// settings screen and every non-SwiftUI reader start from the same value.
nonisolated enum SettingsDefault {
    /// Off. A second copy in the user's photo library is a reasonable thing to
    /// want and an unreasonable thing to assume: it costs storage, it mixes
    /// trail pictures into a library the user curates themselves, and it is
    /// the only thing that would make the app ask for photo-library access at
    /// all. The app's own copy is the one the hike depends on either way.
    static let savePhotosToLibrary = false
}
