//
//  PhotoCalloutMetrics.swift
//  OpenHikes
//
//  The box a photograph is given inside a MapKit callout.
//
//  Two views draw one — ``PhotoCalloutPreview`` for the hiker's own pictures
//  and ``CommunityPhotoCalloutPreview`` for a stranger's — and they had four
//  identical constants each. The second one's comment said as much: "the same
//  4:3 box ``PhotoCalloutPreview`` uses, for the same reason". That sentence
//  is prose doing a constant's job, and it is only true for as long as nobody
//  resizes one of the two.
//
//  The views themselves stay separate. They hold different photographs, keyed
//  differently, with different answers for a picture that will not load — the
//  duplication here was never the views, only the numbers they agreed on.
//
//  What they *build* from these numbers is shared, and that is
//  ``PhotoCalloutPreviewControl``: the hierarchy, the constraints, the tap
//  target, the accessibility traits and the placeholder glyph. Chrome rather
//  than behaviour, and it was written out twice here too.
//

import CoreGraphics

#if os(iOS)
nonisolated enum PhotoCalloutMetrics {
    /// Wide enough to read as a photograph and narrow enough that MapKit's
    /// callout doesn't have to stretch around it, at the 4:3 a phone camera
    /// produces.
    static let previewWidth: CGFloat = 180
    static let previewHeight: CGFloat = 135
    static let cornerRadius: CGFloat = 10
    /// The glyph standing in for a picture that could not be decoded.
    static let placeholderPointSize: CGFloat = 28
}
#endif
