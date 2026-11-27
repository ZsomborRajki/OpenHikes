//
//  DownloadedElevationSquares.swift
//  OpenHikes
//
//  The heights a downloaded area brought: what gives a line drawn, found or
//  imported on ground the hiker downloaded its climb with no signal.
//
//  Every download of an area for the OpenHikes map takes a file of the
//  elevation archive's squares besides its map
//  (``OfflineCountryManifest/Role/elevation``): the squares of the area and a
//  few kilometres round it, copied out of the archive the tile server lists,
//  so each is the square a line would have fetched. A square of sea is a tile
//  of the file too, every post at 0 m, which is what lets the file say *sea*
//  as the tile server's 204 does, and lets a square it holds no tile for mean
//  only that the file does not reach it.
//
//  ``ElevationSquareLibrary`` reads these before the squares it keeps from
//  the tile server and before the server itself, square by square: a line
//  inside the download is answered from it alone, and one that reaches past
//  it asks the rest of the way as it always did. A protocol rather than
//  ``OfflineCountryArchives`` itself, so a suite hands the library squares of
//  its own, for the reason ``TrailCellFetching`` is one.
//

import Foundation

/// Squares of ``ElevationSquareGrid`` this device holds as part of a
/// download, and keeps for as long as the download.
nonisolated protocol DownloadedElevationSquares: Sendable {
    /// The bytes of each square of `squares` that a download covers: its
    /// ``ElevationSquareFile``, one at sea level included. A square missing
    /// from the answer is one no download covers.
    func elevationSquares(_ squares: [ElevationSquare]) -> [ElevationSquare: Data]
}

nonisolated extension OfflineCountryArchives: DownloadedElevationSquares {}
