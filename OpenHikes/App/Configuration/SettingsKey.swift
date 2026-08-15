//
//  SettingsKey.swift
//  OpenHikes
//
//  The `UserDefaults` / `@AppStorage` keys the app persists across launches,
//  and the defaults for the ones where "absent" and "false" are different
//  answers. Collected here rather than beside whichever feature happens to
//  read them first: the keys span selection, background tracking, tiles and
//  network policy, and several are written by one subsystem and read by
//  another. The string values are a storage contract — changing one silently
//  drops the stored setting on the next launch.
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
    /// Whether map tiles may be fetched over a cellular connection. Read by
    /// ``TileCache`` at launch and pushed at it by the settings screen when it
    /// changes — a `@AppStorage` binding alone would leave the cache, which is
    /// nonisolated and reads this per tile miss, looking at a stale value.
    static let cellularTileDownloads = "settings.cellularTileDownloads"
    /// How far along the tracked hike the last background fix matched, in
    /// metres. `BackgroundTrailTracker` carries this across process launches so
    /// a relaunched match resumes from the previous position rather than
    /// re-deriving it; absent means "no continuity reference yet", which is why
    /// it is removed rather than zeroed when the selection changes.
    static let lastMatchedDistance = "trailTracking.lastMatchedDistance"
}

/// Defaults for keys where "absent" and "false" are different answers, so the
/// settings screen and every non-SwiftUI reader start from the same value.
nonisolated enum SettingsDefault {
    /// On, matching what the app did before there was a setting. Turning it
    /// off is a deliberate choice a hiker makes for a walk on cellular; making
    /// it the default would mean a blank map for anyone who never opens
    /// Settings, which is a bug report rather than a battery saving.
    static let cellularTileDownloads = true
}
