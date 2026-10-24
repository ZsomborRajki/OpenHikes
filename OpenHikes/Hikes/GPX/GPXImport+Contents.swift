//
//  GPXImport+Contents.swift
//  OpenHikes
//
//  What ``GPXImport/loadAll(from:limits:)`` hands back: the tracks, and an
//  account of the loose waypoints none of them took.
//

nonisolated extension GPXImport {
    /// What a file becomes: its tracks, and how many of its loose waypoints
    /// were left out of all of them — see ``GPXTrackSplit``.
    struct Contents: Sendable {
        var tracks: [Track]
        var leftOut = LeftOut()
    }

    /// The loose waypoints of a multi-track file that no track takes, by the
    /// two reasons the confirmation gives for them.
    struct LeftOut: Sendable, Equatable {
        /// Places and photographs that lie on none of the tracks.
        var offTrack = 0
        /// Places that do lie on a track, past ``GPXImport/maximumPlaces``.
        var pastPlaceLimit = 0

        var isEmpty: Bool { offTrack == 0 && pastPlaceLimit == 0 }
    }
}
