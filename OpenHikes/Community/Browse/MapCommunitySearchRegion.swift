//
//  MapCommunitySearchRegion.swift
//  OpenHikes
//
//  Which part of the map *Search this area* is about.
//
//  The map fills the window and the sheet covers the bottom of it, so the
//  map's region and the map the hiker can see are two different places — and
//  the community search used to be handed the first. Measured on 2026-10-21,
//  the square that turned into at a five-kilometre view was seventeen times
//  the map above a half-height sheet, and the rows nearest its middle — the
//  screen's middle, just under the sheet's top edge — were trails the hiker
//  could not see. ``focusArea(in:)`` answers the same question for the
//  camera; this is its counterpart for a search, measured the same way.
//
//  ## Where the sheet is taken to be
//
//  **At its middle detent, whenever the map settles.** That is where the list
//  is read, and the two requests made from inside the sheet — opening the
//  *Community* tab and *Try Again* — are made with it raised. So a region
//  measured above the middle detent is the map those two describe, even when
//  the map last settled while the sheet was down: measuring the sheet as it
//  stood at the settle would hand them the map behind a sheet that has since
//  come up, which is the very place this exists to stop searching.
//
//  **Where it actually is, at the pill's tap, when that is lower.** The pill
//  stands at the top of the map in every detent, so a hiker can ask from a
//  lowered sheet while looking at nearly the whole map, and a region measured
//  above the middle detent would leave the bottom half of what they see out.
//  The tap hands the browser that region just before it asks — see
//  ``MapView/addAreaSearchControl(to:_:alignedTo:)``. A sheet *above* the
//  middle detent counts as the middle one: the map behind a full-height sheet
//  is not on screen, and the one above the middle detent is what the hiker
//  comes back to.
//
//  **Unless that is past the zoom ceiling.** The settle that enabled the pill
//  measured the middle detent, and a lowered sheet shows a good deal more map
//  than that, so a view the pill accepted can be one the browser refuses. The
//  tap would then settle the browser on a region it will not search, dim the
//  pill and ask nothing, and the dimmed pill would outlast the sheet coming
//  back up, because nothing settles again on a detent change. An enabled pill
//  has to search something, so past the ceiling the tap uses the middle-detent
//  reading that enabled it — see ``communitySearchRegionForTap(of:)``.
//
//  In landscape there is no sheet, and the side panel takes the leading edge
//  instead, through the same ``obstructionInsets(in:)`` the camera uses.
//

import MapKit
import OpenHikesData

extension MapView.Coordinator {
    /// Which reading of the sheet a search region is measured against — see
    /// this file's header.
    enum SheetReading {
        /// The sheet at its middle detent, wherever it is: what a settle uses.
        case atMiddleDetent
        /// The sheet where it is now, when that is lower than its middle
        /// detent: what the pill's tap uses.
        case whereItIs
    }

    /// The part of `mapView` the hiker can see, as a region: what the
    /// community search asks about and sorts its rows outward from.
    ///
    /// The whole map's region when MapKit cannot place a corner of it — a
    /// tilted camera can put the far edge past the horizon — which is what
    /// this handed over before, and never worse than it.
    func communitySearchRegion(of mapView: MKMapView, sheet: SheetReading) -> MKCoordinateRegion {
        Self.region(covering: searchRect(of: mapView, sheet: sheet), on: mapView) ?? mapView.region
    }

    /// What the pill's tap hands the browser: the map above the sheet where it
    /// is now, unless that is past the zoom ceiling.
    ///
    /// The pill is enabled by the region the last settle measured above the
    /// middle detent, and a sheet lowered since is looking at more map than
    /// that — enough more that a view the pill accepted can come out past the
    /// ceiling. Settling the browser on it anyway refuses the question the
    /// hiker has just been invited to ask: the browser dims the pill, asks
    /// nothing, and keeps the refused region as the one a return to the tab
    /// reads, so the pill stays dimmed after the sheet has come back up until
    /// the map is moved. So the reading that enabled it is searched instead,
    /// which is also the map that stays on screen when the sheet rises to show
    /// the list.
    ///
    /// With both readings past the ceiling, a tap that lands in the middle of
    /// a zoom, nothing is searched, which is right: the gesture's own settle
    /// says where the map ended up.
    func communitySearchRegionForTap(of mapView: MKMapView) -> MKCoordinateRegion {
        let whereItIs = communitySearchRegion(of: mapView, sheet: .whereItIs)
        if CommunityQueryPolicy.isWithinCeiling(whereItIs) { return whereItIs }
        return communitySearchRegion(of: mapView, sheet: .atMiddleDetent)
    }
}

private extension MapView.Coordinator {
    /// The map nothing is drawn over, in its own points.
    ///
    /// From the map's top edge rather than from the safe area, unlike
    /// ``focusArea(in:)``: a camera move is aiming at somewhere to put a
    /// route, and keeps it out of the status bar, while a search is listing
    /// what is visible, and the map under the status bar is.
    func searchRect(of mapView: MKMapView, sheet: SheetReading) -> CGRect {
        var insets = obstructionInsets(in: mapView)
        if sheet == .whereItIs, let top = currentSheetTop(in: mapView) {
            insets.bottom = min(insets.bottom, mapView.bounds.height - top)
        }
        let bounds = mapView.bounds
        return CGRect(
            x: bounds.minX + insets.left,
            y: bounds.minY + insets.top,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom)
        )
    }

    /// Where the sheet's top edge is now, in the map's own points, or `nil`
    /// when there is no sheet over the map or no reading of it to trust.
    ///
    /// ``SheetMetrics`` reports a global Y and the map fills the window, so
    /// the two already agree; a reading off the map is refused for the reason
    /// the "my location" button refuses one — see
    /// `MapCoordinator+TrackingButton.swift`.
    func currentSheetTop(in mapView: MKMapView) -> CGFloat? {
        guard sidePanelInset == 0,
              let top = sheetMetrics?.topY,
              top > 0, top <= mapView.bounds.height
        else { return nil }
        return top
    }

    /// The smallest region holding every corner of `rect`, or `nil` when one
    /// of them is not a place.
    ///
    /// Read off the corners rather than by scaling `MKMapView.region`, because
    /// MapKit measures that inside the map's layout margins — twelve points
    /// short of the view on each side here, see ``MapView/controlInset`` — so
    /// a share of it is a share of slightly less than the screen. Every corner
    /// rather than two, so a map the hiker has turned is answered with the
    /// region around what they see rather than a sliver of it. Longitudes are
    /// measured from the middle of `rect` the short way round, so a view
    /// across the date line is a narrow region rather than one around the
    /// world.
    static func region(covering rect: CGRect, on mapView: MKMapView) -> MKCoordinateRegion? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let middle = mapView.convert(CGPoint(x: rect.midX, y: rect.midY), toCoordinateFrom: mapView)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ].map { mapView.convert($0, toCoordinateFrom: mapView) }
        guard CLLocationCoordinate2DIsValid(middle), corners.allSatisfy(CLLocationCoordinate2DIsValid) else {
            return nil
        }
        let latitudes = corners.map(\.latitude)
        let longitudeOffsets = corners.map { corner in
            RouteGeometry.normalizedLongitudeDelta(corner.longitude - middle.longitude)
        }
        guard let south = latitudes.min(), let north = latitudes.max(),
              let west = longitudeOffsets.min(), let east = longitudeOffsets.max(),
              north > south, east > west
        else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (south + north) / 2,
                longitude: RouteGeometry.normalizedLongitude(middle.longitude + (west + east) / 2)
            ),
            span: MKCoordinateSpan(latitudeDelta: north - south, longitudeDelta: east - west)
        )
    }
}
