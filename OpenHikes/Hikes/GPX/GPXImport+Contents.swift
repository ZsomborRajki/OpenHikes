//
//  GPXImport+Contents.swift
//  OpenHikes
//
//  What ``GPXImport/loadAll(from:limits:)`` hands back, and how many of its
//  places one import of some of its tracks keeps. Split from the parser for
//  length.
//

import Algorithms

nonisolated extension GPXImport {
    /// What a file becomes: its tracks, and how many of its loose waypoints
    /// lay on none of them and were left out — see ``GPXTrackSplit``.
    ///
    /// In a file of several tracks each keeps every place it takes, however
    /// many: they are bounded by what bounds the file, the points and bytes
    /// of ``Limits``, because each is a `<wpt>` the parse counted. The cap on
    /// what an import writes is spent later, by ``placesKept(of:)``, once the
    /// hiker has said which tracks they want.
    struct Contents: Sendable {
        var tracks: [Track]
        var unplacedWaypoints = 0
    }

    /// How many of each track's places one import of `tracks` keeps: the
    /// file's first ``maximumPlaces`` among all of theirs, by
    /// ``Track/placeOffsets``.
    ///
    /// Asked of the tracks chosen, never of the whole file (#1037). A place on
    /// a track the hiker left unticked would otherwise spend a slot, and a
    /// ticked day whose places come later in the file would arrive with none
    /// while the import wrote fewer than the cap.
    ///
    /// Each track's places are in the file's order, so what one keeps is the
    /// start of its own list, and the file's first ``maximumPlaces`` among all
    /// of them are among each track's own first that many. Only those are
    /// candidates, which bounds the work by the cap and the number of tracks
    /// rather than by how many places the file brought. And of them only the
    /// file's first ``maximumPlaces`` and one more are wanted, the last being
    /// where the cut falls, so they are selected rather than all sorted
    /// (#1083): fifty full tracks offer some ten thousand candidates for the
    /// two hundred and one read.
    static func placesKept(of tracks: [Track]) -> [Int] {
        let earliest = tracks.flatMap { $0.placeOffsets.prefix(maximumPlaces + 1) }
            .min(count: maximumPlaces + 1)
        guard earliest.count > maximumPlaces else { return tracks.map(\.placeOffsets.count) }
        // The first place past the cap: it, and every place after it in the
        // file, is cut.
        let firstCut = earliest[maximumPlaces]
        return tracks.map { track in track.placeOffsets.prefix(while: { $0 < firstCut }).count }
    }
}
