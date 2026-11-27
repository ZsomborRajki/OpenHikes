//
//  MapTrailingBarColumn.swift
//  OpenHikes
//
//  Where the pill on the map's trailing edge stands on a closed iPhone Duo:
//  in the column the system keeps down that edge, as the one in Maps does.
//
//  The cover display stands the status bar up in its top trailing corner, and
//  the system keeps that whole edge out of the safe area, for the bars it
//  stands up underneath. The pill was aligned to the safe area, as every
//  control on this map is, so it stopped short of a column with nothing in
//  it: 97 points in from the edge of a screen 466 points wide, where the pill
//  in Maps stands 24 points in. Reported by the owner, 2026-11-27.
//
//  UIKit says where a bar on an edge goes, and that is all this asks: the
//  `bar(onEdge:extent:)` layout region, for a bar as wide as the pill. What it
//  answered for the trailing edge, measured on iOS 27.2, as the insets of the
//  region from the window's trailing edge and from its top:
//
//      window                        safe area   bar region
//                                    trailing    trailing   top
//      closed Duo, upright  466×678    84          26       174
//      closed Duo, turned   678×466     0          26        17
//      open Duo, upright    669×951     0          26        82
//      iPhone 18 Pro        402×874     0           0        62
//      iPhone 18 Pro turned 874×402    62          62        18
//
//  Only the first row has the region beyond the safe area, and that is the
//  whole rule: where a bar on the trailing edge would stand clear of the safe
//  area, the pill stands where the bar would. Everywhere else the region is
//  inside the safe area, the pill is already there, and it keeps the inset it
//  shares with the rest of the map's controls. Nothing here asks which device
//  it is on, so a window Apple gives such a column later is answered the same
//  way.
//
//  The region is centered on the status items above it, and starts under
//  them. The map's own top inset is nothing on that display, so the column's
//  top is what keeps the pill, and the 2D button standing on it, out of the
//  status items — see ``MapView/Coordinator/applySheetTop(on:)``.
//
//  The pill alone moves, with the 2D button, which is constrained to it. The
//  activity capsule across the map stops as far short of the pill as it does
//  on every display.
//
//  `bar(onEdge:extent:)` is iOS 27.1's, behind the gate
//  `HorizontalSheetToolbar.swift` argues for: CI's Xcode 27.0 compiles
//  neither, and only the SDK's SwiftUI version tells the two apart.
//

#if os(iOS)
import MapKit
import UIKit

/// The column the system keeps beyond the safe area, down the trailing edge,
/// for a bar. See this file's header.
///
/// A value, and `nonisolated` as one: only asking a view for it needs the
/// main actor.
nonisolated struct TrailingBarColumn: Equatable, Sendable {
    /// How far in from the trailing edge a bar in the column ends.
    let trailingInset: CGFloat
    /// Where the column starts, under what the system stands at its top.
    let topInset: CGFloat

    /// The column a bar `extent` wide is given, from where the system puts
    /// that bar and where the safe area ends.
    ///
    /// `nil` unless the bar would stand wholly beyond the safe area. A bar
    /// inside it is where the map's controls already are, and one across its
    /// edge is no column at all.
    init?(bar: NSDirectionalEdgeInsets, safeArea: NSDirectionalEdgeInsets, extent: CGFloat) {
        guard extent > 0, bar.trailing >= 0, bar.trailing + extent <= safeArea.trailing else {
            return nil
        }
        trailingInset = bar.trailing
        topInset = max(0, bar.top)
    }

    /// The column `view` has now, for a bar `extent` wide.
    ///
    /// `nil` before iOS 27.1, where the system keeps no such column and has
    /// no way to say where one is.
    ///
    /// The release is asked about here and the regions in a function of
    /// their own, as *The Mac* in `AGENTS.md` asks of any symbol a runtime
    /// may lack: a function can look up the types it uses as it is entered,
    /// and the layout region is a type iOS 18 does not have.
    @MainActor
    static func current(in view: UIView, extent: CGFloat) -> Self? {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return measured(in: view, extent: extent)
        }
        #endif
        return nil
    }

    #if canImport(SwiftUI, _version: 8.0.85)
    @available(iOS 27.1, *)
    @MainActor
    private static func measured(in view: UIView, extent: CGFloat) -> Self? {
        Self(
            bar: view.directionalEdgeInsets(
                for: .bar(onEdge: NSDirectionalRectEdge.trailing, extent: extent)
            ),
            safeArea: view.directionalEdgeInsets(for: .safeArea()),
            extent: extent
        )
    }
    #endif
}

/// The pill's two places across the map, exactly one of them active.
struct TrackingPillPlacement {
    /// Against the safe area, at the inset every control on the map takes.
    private let inSafeArea: NSLayoutConstraint
    /// Against the map's own trailing edge, at the column's inset.
    private let inColumn: NSLayoutConstraint
    /// The column the pill stands in, or `nil` while it is in the safe area.
    private(set) var column: TrailingBarColumn?

    /// Puts `pill` against the safe area, which is where it is until the map
    /// has been asked for a column.
    init(of pill: UIView, on mapView: MKMapView, alignedTo guide: UILayoutGuide) {
        inSafeArea = pill.trailingAnchor.constraint(
            equalTo: guide.trailingAnchor,
            constant: -MapView.controlInset
        )
        inColumn = pill.trailingAnchor.constraint(equalTo: mapView.trailingAnchor)
        inSafeArea.isActive = true
    }

    /// Stands the pill in `column`, or back against the safe area where
    /// there is none.
    ///
    /// Nothing is written unless the column changed, because this is asked
    /// on every pass that measures the map and a constraint write requests
    /// layout.
    mutating func stand(in column: TrailingBarColumn?) {
        guard column != self.column else { return }
        self.column = column
        guard let column else {
            inColumn.isActive = false
            inSafeArea.isActive = true
            return
        }
        inSafeArea.isActive = false
        inColumn.constant = -column.trailingInset
        inColumn.isActive = true
    }
}
#endif
