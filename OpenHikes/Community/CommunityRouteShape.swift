//
//  CommunityRouteShape.swift
//  OpenHikes
//
//  A route's outline, drawn without a map.
//
//  Used by ``CommunityHikeView`` for the one question a preview has to answer
//  before the walker commits to a download and a row in their library: does
//  this route go where I think it does. That question needs the *shape* — an
//  out-and-back, a loop, a ridge traverse — and does not need tiles, a
//  provider, an entitlement check or a network request, all of which a real
//  map would bring with it for a screen that is often backed out of in
//  seconds.
//
//  The aspect ratio is preserved rather than stretched to the frame, which
//  matters more here than it would for a decorative sparkline: a ten-kilometre
//  ridge squashed into a square reads as a loop, and that is precisely the
//  distinction the walker is looking at this for.
//

import CoreLocation
import SwiftUI

struct CommunityRouteShape: Shape {
    let coordinates: [CLLocationCoordinate2D]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard coordinates.count >= 2 else { return path }

        // Longitude is scaled by the cosine of the latitude so a degree east
        // is drawn the same length as a degree north — without it every route
        // is stretched horizontally, increasingly so towards the poles.
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minimumLatitude = latitudes.min(),
              let maximumLatitude = latitudes.max(),
              let minimumLongitude = longitudes.min(),
              let maximumLongitude = longitudes.max()
        else { return path }

        let latitudeScale = cos((minimumLatitude + maximumLatitude) / 2 * .pi / 180)
        let width = (maximumLongitude - minimumLongitude) * latitudeScale
        let height = maximumLatitude - minimumLatitude
        // A route that never moved, or one point repeated: there is no shape
        // to draw and dividing by the span below would be dividing by zero.
        guard width > 0 || height > 0 else { return path }

        let scale = min(
            width > 0 ? rect.width / width : .greatestFiniteMagnitude,
            height > 0 ? rect.height / height : .greatestFiniteMagnitude
        )
        let drawnWidth = width * scale
        let drawnHeight = height * scale
        let originX = rect.minX + (rect.width - drawnWidth) / 2
        let originY = rect.minY + (rect.height - drawnHeight) / 2

        let points = coordinates.map { coordinate in
            CGPoint(
                x: originX + (coordinate.longitude - minimumLongitude) * latitudeScale * scale,
                // Flipped: latitude increases northwards and a view's y
                // increases downwards, so drawing it straight puts every route
                // upside down.
                y: originY + drawnHeight - (coordinate.latitude - minimumLatitude) * scale
            )
        }
        path.addLines(points)
        return path
    }
}
