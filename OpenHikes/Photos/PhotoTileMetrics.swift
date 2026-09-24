//
//  PhotoTileMetrics.swift
//  OpenHikes
//
//  How big a photograph is drawn when it is one of several.
//
//  Three screens lay out the same thumbnails: the hike's own gallery strip,
//  the strip on the share form that decides which of them go, and the grid the
//  discovery sheet offers. They agreed about the corner radius and the gap by
//  hand, and about the tile size in a comment — ``CommunitySharePhotoStrip``
//  said it was drawing "the same 76-point tile the hike's own gallery draws",
//  which was true and was not checkable.
//
//  It matters most between the two strips, and for the reason that comment
//  gave: they are the same row of the same photographs, one of them with
//  checkmarks on it, so two sizes would be two answers to one question — a
//  hiker moving between them would see the pictures change size for no reason
//  they did anything about.
//
//  The grid is deliberately not the same size, which is why it says so here
//  rather than by holding a different number somewhere else. A sheet whose
//  whole job is choosing photographs can afford a bigger cell than a row
//  inside a form.
//

import CoreGraphics
import OpenHikesData

/// The figures the photo strips and the discovery grid share.
enum PhotoTileMetrics {
    /// One thumbnail in a horizontal strip.
    static let stripTileSize: CGFloat = 76
    /// One cell in the discovery sheet's grid, which is larger on purpose —
    /// see this file's header.
    static let gridCellSize: CGFloat = 104
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 12
}
