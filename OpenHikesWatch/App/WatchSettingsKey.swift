//
//  WatchSettingsKey.swift
//  OpenHikesWatch
//
//  The watch's own preferences, which are its own on purpose.
//
//  Nothing here syncs. A basemap choice is a statement about the screen it is
//  read on — a 44 mm watch above the treeline is not an iPhone in a pocket —
//  and the phone has a tile provider of its own that means something else
//  entirely. Mirrors `SettingsKey` on the phone, including the dotted
//  namespacing, so a key read in a log says which app wrote it.
//

import Foundation

nonisolated enum WatchSettingsKey {
    /// Which basemap a trail is drawn on — see ``WatchMapStyle``.
    static let mapStyle = "watch.mapStyle"
}
