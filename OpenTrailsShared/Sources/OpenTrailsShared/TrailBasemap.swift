//
//  TrailBasemap.swift
//  OpenTrailsShared
//
//  Describes the pre-rendered map images the main app ships to the iOS widget
//  through the App Group, and pins each one to the patch of Earth it covers.
//
//  Why images at all: WidgetKit can't host a live Map/MKMapView at any OS
//  version, so the only way to get a real basemap into a widget is for the
//  app to rasterize one ahead of time (MKMapSnapshotter) and hand it over.
//  See `TrailBasemapRenderer` in the app target for the producing side.
//
//  Why this metadata and not just the image: an image alone can't say *where*
//  its pixels are, and the live fix moves between renders — so every image
//  carries the exact geographic rectangle it ended up covering, which lets
//  the widget project the trail line and the current position onto it without
//  the app re-rendering anything.
//
import CoreGraphics
import Foundation

/// A rectangle in unit Web Mercator space (see ``Mercator``): the whole world
/// is `0...1` on both axes, y growing south.
///
/// Unit space rather than `MKMapRect` so this type — and everything that
/// draws with it — stays free of MapKit, which the widget can't use anyway.
public struct UnitMercatorRect: Codable, Sendable, Equatable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    /// Bounding box of `coordinates`, or `nil` if there are none. A single
    /// coordinate yields a zero-sized rect — callers pad it out.
    public init?(bounding coordinates: [SharedTrailSnapshot.CodableCoordinate]) {
        guard let first = coordinates.first else { return nil }
        let start = Mercator.unitPoint(latitude: first.latitude, longitude: first.longitude)
        var minX = start.x, maxX = start.x, minY = start.y, maxY = start.y
        for coordinate in coordinates.dropFirst() {
            let point = Mercator.unitPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        self.init(originX: minX, originY: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A coordinate whose position within a rendered image is known — the
    /// input to ``init(imageWidth:imageHeight:_:_:)``.
    public struct ImageReferencePoint: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        /// Position in the image, in whatever coordinate space the renderer
        /// reported it: the origin corner and y direction are worked out
        /// rather than assumed.
        public var x: Double
        public var y: Double

        public init(latitude: Double, longitude: Double, x: Double, y: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.x = x
            self.y = y
        }
    }

    /// Derives the region an image of `imageWidth` × `imageHeight` covers,
    /// given two coordinates and where they landed in it.
    ///
    /// Web Mercator is linear on both axes, so two points pin the mapping
    /// exactly — which is what lets the app measure a finished map snapshot
    /// instead of trusting it to have rendered the region it was asked for.
    ///
    /// The axis directions are *measured*, not assumed: image coordinates
    /// arrive top-left-origin from UIKit and bottom-left-origin from AppKit.
    /// Whatever comes in, the rect that comes out is top-left-origin with a
    /// positive extent — the one convention drawing code has to know.
    ///
    /// Returns `nil` if the two references are too close together on either
    /// axis to derive a scale from.
    public init?(
        imageWidth: Double,
        imageHeight: Double,
        _ first: ImageReferencePoint,
        _ second: ImageReferencePoint
    ) {
        let spanX = second.x - first.x
        let spanY = second.y - first.y
        guard abs(spanX) > 1, abs(spanY) > 1, imageWidth > 0, imageHeight > 0 else { return nil }

        let unitFirst = Mercator.unitPoint(latitude: first.latitude, longitude: first.longitude)
        let unitSecond = Mercator.unitPoint(latitude: second.latitude, longitude: second.longitude)

        // unit = base + perPoint × imagePoint, independently per axis.
        let perPointX = (unitSecond.x - unitFirst.x) / spanX
        let perPointY = (unitSecond.y - unitFirst.y) / spanY
        let baseX = unitFirst.x - first.x * perPointX
        let baseY = unitFirst.y - first.y * perPointY
        let signedWidth = imageWidth * perPointX
        let signedHeight = imageHeight * perPointY

        self.init(
            originX: signedWidth >= 0 ? baseX : baseX + signedWidth,
            originY: signedHeight >= 0 ? baseY : baseY + signedHeight,
            width: abs(signedWidth),
            height: abs(signedHeight)
        )
    }

    public var midX: Double { originX + width / 2 }
    public var midY: Double { originY + height / 2 }

    /// The latitude at this rect's vertical center — the reference for
    /// anything that has to convert between meters and unit space, since
    /// Mercator's scale factor varies with latitude.
    public var centerLatitude: Double { Mercator.latitude(unitY: midY) }

    /// Where a coordinate falls inside this rect, as a fraction of its size:
    /// `(0, 0)` is the north-west corner, `(1, 1)` the south-east one.
    /// Values outside `0...1` are simply off-image.
    public func normalizedPoint(latitude: Double, longitude: Double) -> CGPoint {
        let unit = Mercator.unitPoint(latitude: latitude, longitude: longitude)
        return CGPoint(
            x: (unit.x - originX) / max(width, .leastNormalMagnitude),
            y: (unit.y - originY) / max(height, .leastNormalMagnitude)
        )
    }

    /// Expands a trail's bounding box into the region a basemap should
    /// actually cover: padded, floored to a sane minimum size, and stretched
    /// to `aspectRatio`.
    ///
    /// - Parameters:
    ///   - padding: breathing room on each side, as a fraction of the trail's
    ///     own size. Doubles as the crop budget — the widget aspect-fills
    ///     whichever rendered shape is closest to its own, and this is what
    ///     that fill eats into instead of the trail. Keep it in step with
    ///     ``TrailBasemapVariant``: the further apart the variants' shapes,
    ///     the more padding the odd sizes between them need.
    ///   - minimumSpanMeters: floor on how small an area gets rendered, so a
    ///     200 m stroll doesn't come out at a zoom that's all driveway and no
    ///     context.
    public func framed(
        toAspectRatio aspectRatio: Double,
        padding: Double = 0.15,
        minimumSpanMeters: Double = 400
    ) -> UnitMercatorRect {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return self }
        let minimumSpan = minimumSpanMeters / max(Mercator.metersPerUnit(atLatitude: centerLatitude), 1)
        let growth = 1 + 2 * padding

        var width = max(self.width, minimumSpan) * growth
        var height = max(self.height, minimumSpan) * growth
        // Grow the deficient axis rather than cropping the other one, so the
        // trail keeps all the padding it was given.
        if width / height < aspectRatio {
            width = height * aspectRatio
        } else {
            height = width / aspectRatio
        }
        width = min(width, 1)
        height = min(height, 1)

        return UnitMercatorRect(
            originX: midX - width / 2,
            // Latitude doesn't wrap: a trail near the top or bottom of the
            // projection gets a shifted window rather than one running off
            // the edge of the world. (Longitude does wrap, and MapKit handles
            // that itself, so x is left alone.)
            originY: min(max(midY - height / 2, 0), 1 - height),
            width: width,
            height: height
        )
    }

    /// Whether `other` is the same rect to within `tolerance`, measured
    /// relative to this rect's own size — the test for whether a trail has
    /// moved or resized enough to be worth re-rendering its basemap.
    public func isEquivalent(to other: UnitMercatorRect, tolerance: Double = 0.02) -> Bool {
        let slack = max(width, height) * tolerance
        guard slack > 0 else { return self == other }
        return abs(originX - other.originX) <= slack
            && abs(originY - other.originY) <= slack
            && abs(width - other.width) <= slack
            && abs(height - other.height) <= slack
    }
}

/// The shapes a basemap gets rendered in.
///
/// Two is enough: widget families cluster into roughly-square (small, large)
/// and roughly-2:1 (medium, extra large). The view picks whichever is closer
/// and aspect-*fills* it, so the leftover mismatch crops into the padding the
/// renderer leaves around the trail rather than into the trail itself.
public enum TrailBasemapVariant: String, Codable, Sendable, CaseIterable {
    case square
    case wide

    /// Render size in points. Kept modest on purpose — a widget extension has
    /// a hard memory ceiling and these get decoded inside it.
    public var pointSize: CGSize {
        switch self {
        case .square: CGSize(width: 320, height: 320)
        case .wide: CGSize(width: 380, height: 180)
        }
    }

    public var aspectRatio: Double { pointSize.width / pointSize.height }

    /// The variant closest to `aspectRatio`, compared logarithmically so
    /// "twice as wide" and "half as wide" count as equally far off.
    public static func best(forAspectRatio aspectRatio: Double) -> TrailBasemapVariant {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return .square }
        return allCases.min {
            abs(log($0.aspectRatio / aspectRatio)) < abs(log($1.aspectRatio / aspectRatio))
        } ?? .square
    }
}

/// Which system appearance an image was rendered for. WidgetKit renders a
/// single timeline entry in both appearances, so both are shipped and the
/// view picks per render pass.
public enum TrailBasemapAppearance: String, Codable, Sendable, CaseIterable {
    case light
    case dark
}

/// One rendered basemap image: what shape it is, and where on Earth it is.
public struct TrailBasemap: Codable, Sendable, Equatable {
    /// File name within the App Group's basemap directory — see
    /// ``SharedStore/basemapImageData(named:)``.
    public var fileName: String
    public var variant: TrailBasemapVariant
    public var appearance: TrailBasemapAppearance
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The area the image actually covers — measured from the finished
    /// snapshot rather than taken from the region requested of it, because
    /// the snapshotter may adjust what it renders to fit the pixel size it
    /// was asked for.
    public var visibleRect: UnitMercatorRect

    public init(
        fileName: String,
        variant: TrailBasemapVariant,
        appearance: TrailBasemapAppearance,
        pixelWidth: Int,
        pixelHeight: Int,
        visibleRect: UnitMercatorRect
    ) {
        self.fileName = fileName
        self.variant = variant
        self.appearance = appearance
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.visibleRect = visibleRect
    }

    public var aspectRatio: Double {
        guard pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// Every basemap currently on disk, and what it was rendered for.
///
/// Stored beside the trail snapshot rather than inside it, on purpose: the
/// snapshot is rewritten whenever a live fix lands (as often as every 45
/// seconds), whereas this changes only when the selected trail's geometry does.
public struct TrailBasemapSet: Codable, Sendable, Equatable {
    public var hikeID: UUID
    /// The trail's own bounding box at render time — the staleness key. Once
    /// the current trail's box no longer matches, these images are framing
    /// the wrong piece of the world and get re-rendered.
    public var coverage: UnitMercatorRect
    public var images: [TrailBasemap]
    public var generatedAt: Date

    public init(hikeID: UUID, coverage: UnitMercatorRect, images: [TrailBasemap], generatedAt: Date = .now) {
        self.hikeID = hikeID
        self.coverage = coverage
        self.images = images
        self.generatedAt = generatedAt
    }

    /// The best image for a view of `aspectRatio` in `appearance`, falling
    /// back first across appearance (a light map under a dark widget still
    /// beats no map) and then across variant, so a half-rendered set still
    /// draws something sensible.
    public func image(forAspectRatio aspectRatio: Double, appearance: TrailBasemapAppearance) -> TrailBasemap? {
        let variant = TrailBasemapVariant.best(forAspectRatio: aspectRatio)
        return images.first { $0.variant == variant && $0.appearance == appearance }
            ?? images.first { $0.variant == variant }
            ?? images.first { $0.appearance == appearance }
            ?? images.first
    }
}
