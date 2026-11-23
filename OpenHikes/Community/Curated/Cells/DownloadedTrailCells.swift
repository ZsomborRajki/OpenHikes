//
//  DownloadedTrailCells.swift
//  OpenHikes
//
//  The day hikes' squares a downloaded area brought: what lets the Community
//  tab search with no signal where the hiker has downloaded the map.
//
//  Every download of an area for the OpenHikes map takes a file of the
//  trails archive's squares besides its map (``OfflineCountryManifest/Role/trails``):
//  the squares that reach the area and a wide margin round it, copied out of
//  the archive the tile server lists, so each is the square a search would
//  have fetched. A square of that ground with no routes in it is a tile of
//  the file too, holding none, which is what lets the file say *nothing
//  here* as the tile server's 204 does, and lets a square it holds no tile
//  for mean only that the file does not reach it.
//
//  ``TrailCellLibrary`` reads these before the squares it keeps from the tile
//  server and before the server itself, square by square: a search inside
//  the margin is answered from the download alone, and one that reaches past
//  it asks the rest of the way as it always did. A protocol rather than
//  ``OfflineCountryArchives`` itself, so a suite hands the library squares of
//  its own, for the reason ``TrailCellFetching`` is one.
//

import Foundation

/// Squares of ``TrailCellGrid`` this device holds as part of a download, and
/// keeps for as long as the download.
nonisolated protocol DownloadedTrailCells: Sendable {
    /// The bytes of each square of `names` that a download covers, by name:
    /// its ``TrailCellFile``, an empty one included. A name missing from the
    /// answer is a square no download covers.
    func trailCells(named names: [String]) -> [String: Data]
}

nonisolated extension OfflineCountryArchives: DownloadedTrailCells {}
