//
//  TrailBasemap.swift
//  OpenHikesShared
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
/// draws with it — stays free of MapKit, which the widget can't draw with
/// anyway.
public struct UnitMercatorRect: Codable, Sendable, Equatable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    /// Takes the four fields as given. The only initializer that does not
    /// check ``isFinite`` — it has no way to refuse — so it is the one place
    /// a non-finite rect can enter. Nothing in the app or the widget calls
    /// it; the two failable initializers below and `Codable` are the real
    /// entry points, and `JSONDecoder` rejects a non-finite `Double` itself.
    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    /// Whether this rect is a real region: every field a number, so it can be
    /// compared, framed and drawn.
    ///
    /// The invariant both failable initializers below enforce, and the reason
    /// they are failable rather than total. A rect carrying `.nan` compares
    /// unequal to **itself**, so `==` and ``isEquivalent(to:)`` answer "no"
    /// forever — which downstream reads as a basemap that is permanently out
    /// of date and a render pass that cannot recognize its own in-flight
    /// work, re-entered on every selection change. Worse, nothing reports it:
    /// `JSONEncoder` refuses a non-finite `Double` by default, so a manifest
    /// built from one would simply never reach disk.
    ///
    /// This is deliberately weaker than ``Mercator/isRepresentable(latitude:longitude:)``.
    /// A latitude past Mercator's limit is a real place and gets clamped;
    /// longitude past the antimeridian is cyclic and is left alone on purpose.
    /// Only `±∞` and `.nan` describe no region at all.
    public var isFinite: Bool {
        originX.isFinite && originY.isFinite && width.isFinite && height.isFinite
    }

    /// Bounding box of `coordinates`, or `nil` if there are none — or if any
    /// one of them is non-finite. A single coordinate yields a zero-sized
    /// rect — callers pad it out.
    ///
    /// The box may run past `x = 1`: x is cyclic, so a route crossing the
    /// antimeridian is bounded the short way round, from a west edge inside
    /// `0..<1` to an east edge beyond it. A plain min/max would answer the
    /// long way instead — two points a kilometre apart either side of ±180°
    /// come out as almost the entire world, which is then what the widget's
    /// basemap gets rendered at.
    ///
    /// Latitude is not cyclic and takes the ordinary min/max.
    ///
    /// One bad coordinate refuses the whole box rather than being skipped.
    /// Skipping is what used to happen, by accident and only sometimes:
    /// `min`/`max` return their first argument when the comparison is false,
    /// so a `.nan` past index 0 lost every comparison and vanished, leaving a
    /// plausible finite box framing a line that still had a hole in it, while
    /// the same value at index 0 seeded the extremes and poisoned the rect.
    /// Two different wrong answers for one bad point. See ``isFinite`` for
    /// why a rect is never allowed to carry the value instead.
    public init?(bounding coordinates: [SharedTrailSnapshot.CodableCoordinate]) {
        guard let first = coordinates.first, first.latitude.isFinite, first.longitude.isFinite else { return nil }
        let start = Mercator.unitPoint(latitude: first.latitude, longitude: first.longitude)
        var minY = start.y, maxY = start.y
        var unitXs: [Double] = []
        unitXs.reserveCapacity(coordinates.count)
        unitXs.append(Mercator.wrappedUnitX(start.x))
        for coordinate in coordinates.dropFirst() {
            // Checked per point rather than in a pass of its own: a route is
            // tens of thousands of points, and this way a bad one at index 3
            // stops there.
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
            let point = Mercator.unitPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
            unitXs.append(Mercator.wrappedUnitX(point.x))
        }
        let span = Self.cyclicSpan(ofUnitX: unitXs)
        self.init(originX: span.origin, originY: minY, width: span.width, height: maxY - minY)
    }

    /// West edge and width of the narrowest arc of the world containing every
    /// one of `unitXs`, each already inside `0..<1`.
    ///
    /// The arc is the complement of the widest gap between neighbouring x
    /// values around the circle — including the gap that runs through `x = 0`,
    /// which is the one an ordinary route falls in and the one a plain
    /// min/max mistakes for the route itself. `TileBoundingBox` finds an
    /// offline download's columns the same way, in degrees.
    ///
    /// Sorting costs an array the length of the route, which a min/max pass
    /// does not. Affordable here and nowhere near the live-fix path: a box is
    /// bounded when a trail's geometry changes, and the four network
    /// round-trips that follow it dwarf the sort.
    private static func cyclicSpan(ofUnitX unitXs: [Double]) -> (origin: Double, width: Double) {
        let sorted = unitXs.sorted()
        guard let west = sorted.first, let east = sorted.last else { return (origin: 0, width: 0) }

        var widestGap = west + 1 - east
        var arcStart = west
        for index in 1..<sorted.count {
            let gap = sorted[index] - sorted[index - 1]
            if gap > widestGap {
                widestGap = gap
                arcStart = sorted[index]
            }
        }
        return (origin: arcStart, width: 1 - widestGap)
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

        /// Every field a number. A non-finite reference point describes no
        /// mapping, so the initializer taking it refuses rather than
        /// propagating the value — see ``UnitMercatorRect/isFinite``.
        public var isFinite: Bool {
            latitude.isFinite && longitude.isFinite && x.isFinite && y.isFinite
        }

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
    /// axis to derive a scale from, or if any input — or the rect they work
    /// out to — is non-finite (see ``isFinite``).
    ///
    /// The result is checked as well as the inputs because finite inputs are
    /// not sufficient here: the scale is a *ratio*, so an image dimension
    /// multiplied by a steep enough per-point factor overflows to `±∞` with
    /// every argument a perfectly ordinary number. Guarding only the way in
    /// would leave the promise ``isFinite`` makes true by inspection rather
    /// than by construction.
    public init?(
        imageWidth: Double,
        imageHeight: Double,
        _ first: ImageReferencePoint,
        _ second: ImageReferencePoint
    ) {
        let spanX = second.x - first.x
        let spanY = second.y - first.y
        guard imageWidth.isFinite, imageHeight.isFinite, first.isFinite, second.isFinite else { return nil }
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

        let candidate = Self(
            originX: signedWidth >= 0 ? baseX : baseX + signedWidth,
            originY: signedHeight >= 0 ? baseY : baseY + signedHeight,
            width: abs(signedWidth),
            height: abs(signedHeight)
        )
        guard candidate.isFinite else { return nil }
        self = candidate
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
    ///
    /// x is measured from the rect's centre the short way round the world, so
    /// a rect that runs past `x = 1` places a point on the far side of the
    /// antimeridian right next to it rather than a whole world to its left.
    /// Nothing changes for a rect that doesn't cross: a point more than half
    /// the world from the centre is off-image either way, and everything
    /// nearer is unaffected.
    public func normalizedPoint(latitude: Double, longitude: Double) -> CGPoint {
        let unit = Mercator.unitPoint(latitude: latitude, longitude: longitude)
        let offsetX = Mercator.unitXOffset(from: midX, to: unit.x) + width / 2
        return CGPoint(
            x: offsetX / max(width, .leastNormalMagnitude),
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
    ) -> Self {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return self }
        let minimumSpan = minimumSpanMeters / max(Mercator.metersPerUnit(atLatitude: centerLatitude), 1)
        let growth = 1 + 2 * padding

        var newWidth = max(width, minimumSpan) * growth
        var newHeight = max(height, minimumSpan) * growth
        // Grow the deficient axis rather than cropping the other one, so the
        // trail keeps all the padding it was given.
        if newWidth / newHeight < aspectRatio {
            newWidth = newHeight * aspectRatio
        } else {
            newHeight = newWidth / aspectRatio
        }
        newWidth = min(newWidth, 1)
        newHeight = min(newHeight, 1)

        return Self(
            // Longitude wraps, so the west edge is brought back inside the
            // world and the width is left to run past it — the shape MapKit
            // reads as a region crossing the antimeridian, rather than one
            // starting a lap short of it.
            originX: Mercator.wrappedUnitX(midX - newWidth / 2),
            // Latitude doesn't wrap: a trail near the top or bottom of the
            // projection gets a shifted window rather than one running off
            // the edge of the world.
            originY: min(max(midY - newHeight / 2, 0), 1 - newHeight),
            width: newWidth,
            height: newHeight
        )
    }

    /// Whether `other` is the same rect to within `tolerance`, measured
    /// relative to this rect's own size — the test for whether a trail has
    /// moved or resized enough to be worth re-rendering its basemap.
    public func isEquivalent(to other: Self, tolerance: Double = 0.02) -> Bool {
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
    case square = "square"
    case wide = "wide"

    private enum PointSize {
        static let squareSide: CGFloat = 320
        static let wideWidth: CGFloat = 380
        static let wideHeight: CGFloat = 180
    }

    /// Render size in points. Kept modest on purpose — a widget extension has
    /// a hard memory ceiling and these get decoded inside it.
    public var pointSize: CGSize {
        switch self {
        case .square: CGSize(width: PointSize.squareSide, height: PointSize.squareSide)
        case .wide: CGSize(width: PointSize.wideWidth, height: PointSize.wideHeight)
        }
    }

    public var aspectRatio: Double { pointSize.width / pointSize.height }

    /// The variant closest to `aspectRatio`, compared logarithmically so
    /// "twice as wide" and "half as wide" count as equally far off.
    public static func best(forAspectRatio aspectRatio: Double) -> Self {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return .square }
        return allCases.min { lhs, rhs in
            abs(log(lhs.aspectRatio / aspectRatio)) < abs(log(rhs.aspectRatio / aspectRatio))
        } ?? .square
    }
}

/// Which system appearance an image was rendered for. WidgetKit renders a
/// single timeline entry in both appearances, so both are shipped and the
/// view picks per render pass.
public enum TrailBasemapAppearance: String, Codable, Sendable, CaseIterable {
    case dark = "dark"
    case light = "light"
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
