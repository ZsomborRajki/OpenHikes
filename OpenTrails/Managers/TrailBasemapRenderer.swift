//
//  TrailBasemapRenderer.swift
//  OpenTrails
//
//  Rasterizes the selected trail's surroundings into the App Group so the iOS
//  widget can show a real map under the trail line. WidgetKit can't host a
//  live Map/MKMapView at any OS version, so the app rendering images ahead of
//  time is the only way a widget gets a basemap at all — see `TrailBasemap`
//  in OpenTrailsShared for the consuming side.
//
//  An actor, because this is the one part of the widget pipeline that's
//  genuinely expensive: four MKMapSnapshotter passes (two shapes × light and
//  dark), each a network round-trip. Serializing them here means a burst of
//  selection changes collapses into one render, and the *last* selection is
//  the one that ends up on disk.
//
//  Nothing here runs on the live-fix path. The images depend only on where
//  the trail is, so they're re-rendered when its geometry changes and left
//  alone while a position moves across them — that's what makes shipping
//  images affordable next to a snapshot that updates every 45 seconds.
//

import Foundation
import MapKit
import WidgetKit
import OpenTrailsShared

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

actor TrailBasemapRenderer {
    static let shared = TrailBasemapRenderer()

    /// Rendered at 2× rather than the device's own scale: a 3× image is 2.25×
    /// the bytes and gets decoded inside a widget extension, which has a hard
    /// memory ceiling and no way to recover from crossing it.
    private static let renderScale: CGFloat = 2

    private static let renderQueue = DispatchQueue(label: "com.opentrails.basemap-render", qos: .utility)

    private struct RenderRequest: Equatable {
        let hikeID: UUID
        let coverage: UnitMercatorRect
    }

    /// The render that owns the output directory right now. A pass checks
    /// this back after every suspension and abandons itself if it's no longer
    /// the one — an actor only serializes up to the next `await`, so without
    /// it two trails selected in quick succession would interleave, and the
    /// older pass's prune would delete the newer one's images out from under
    /// its manifest.
    private var inFlight: RenderRequest?

    /// Bumped by ``invalidate()``. A render that started before the bump has
    /// been overtaken by events (the trail was deselected or deleted) and
    /// drops its results instead of resurrecting a trail the user just
    /// cleared.
    private var generation = 0

    /// Whether this pass is still the one whose results are wanted.
    private func stillCurrent(_ request: RenderRequest, since generation: Int) -> Bool {
        inFlight == request && self.generation == generation
    }

    /// Renders `polyline`'s surroundings unless the images on disk already
    /// frame it. Safe and cheap to call on every selection change and every
    /// foreground — the common case is a bounds comparison and no work.
    func refreshIfNeeded(hikeID: UUID, polyline: [SharedTrailSnapshot.CodableCoordinate]) async {
        guard polyline.count > 1, let coverage = UnitMercatorRect(bounding: polyline) else { return }

        let request = RenderRequest(hikeID: hikeID, coverage: coverage)
        // Identical work is already running; anything else supersedes it.
        guard inFlight != request else { return }
        if let existing = SharedStore.loadBasemapSet(for: hikeID),
           existing.coverage.isEquivalent(to: coverage),
           // A manifest whose images have been pruned away is worse than no
           // manifest: without this check it would keep claiming the work is
           // done while the widget quietly fell back to the line glyph.
           SharedStore.hasAllBasemapImages(in: existing) {
            return
        }

        inFlight = request
        let startedAt = generation
        defer { if inFlight == request { inFlight = nil } }

        var images: [TrailBasemap] = []
        for variant in TrailBasemapVariant.allCases {
            let framed = coverage.framed(toAspectRatio: variant.aspectRatio)
            for appearance in TrailBasemapAppearance.allCases {
                guard let rendered = await Self.render(unitRect: framed, size: variant.pointSize, appearance: appearance) else { continue }
                guard stillCurrent(request, since: startedAt) else { return }

                let fileName = Self.fileName(hikeID: hikeID, coverage: coverage, variant: variant, appearance: appearance)
                guard SharedStore.writeBasemapImage(rendered.data, named: fileName) else { continue }
                images.append(
                    TrailBasemap(
                        fileName: fileName,
                        variant: variant,
                        appearance: appearance,
                        pixelWidth: rendered.pixelWidth,
                        pixelHeight: rendered.pixelHeight,
                        visibleRect: rendered.visibleRect
                    )
                )
            }
        }

        // Nothing rendered — offline, or a background launch with no network.
        // Leave whatever was already there: a basemap framing a previous
        // trail is wrong, but the widget only ever pairs a set with the hike
        // it was rendered for, so it simply falls back to the line glyph.
        guard !images.isEmpty, stillCurrent(request, since: startedAt) else { return }

        // Order matters. The images land first, the manifest that points at
        // them second, and only then is anything deleted — so a widget
        // reading mid-render sees either the whole old set or the whole new
        // one, never a manifest pointing at a file that isn't there yet.
        SharedStore.saveBasemapSet(TrailBasemapSet(hikeID: hikeID, coverage: coverage, images: images))
        SharedStore.pruneBasemapImages(keeping: Set(images.map(\.fileName)))
        WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
    }

    /// Drops the rendered basemaps, and makes any render currently in flight
    /// throw its results away rather than write them.
    func invalidate() {
        generation &+= 1
        inFlight = nil
        SharedStore.clearBasemaps()
    }

    // MARK: Naming

    /// Names images after the region they cover, so a re-render writes new
    /// files instead of overwriting the ones a widget may be reading, and the
    /// prune step is what eventually reclaims the old ones.
    private static func fileName(
        hikeID: UUID,
        coverage: UnitMercatorRect,
        variant: TrailBasemapVariant,
        appearance: TrailBasemapAppearance
    ) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in [coverage.originX, coverage.originY, coverage.width, coverage.height] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes in
                for byte in bytes {
                    hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
                }
            }
        }
        return "\(hikeID.uuidString)-\(String(hash, radix: 36))-\(variant.rawValue)-\(appearance.rawValue).jpg"
    }

    // MARK: Rendering

    private struct Rendered: Sendable {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let visibleRect: UnitMercatorRect
    }

    private static func render(
        unitRect: UnitMercatorRect,
        size: CGSize,
        appearance: TrailBasemapAppearance
    ) async -> Rendered? {
        let options = MKMapSnapshotter.Options()
        let world = MKMapSize.world.width
        options.mapRect = MKMapRect(
            x: unitRect.originX * world,
            y: unitRect.originY * world,
            width: unitRect.width * world,
            height: unitRect.height * world
        )
        options.size = size

        // `.muted` is the emphasis style Apple designed for exactly this —
        // a basemap that stays legible with someone else's data drawn over
        // it. POIs come off for the same reason: at 320 points wide, pins
        // compete with the one line that matters.
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration

        #if canImport(UIKit)
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = appearance == .dark ? .dark : .light
            traits.displayScale = renderScale
        }
        #elseif canImport(AppKit)
        // No scale knob here — AppKit renders at the screen's backing scale
        // and `encode` reports whatever pixel size that produced, so the
        // widget's registration doesn't care either way.
        options.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        #endif

        // Two opposite corners of what we asked for, kept as coordinates so
        // the finished snapshot can be measured in its own terms below.
        let northWest = CLLocationCoordinate2D(
            latitude: Mercator.latitude(unitY: unitRect.originY),
            longitude: Mercator.longitude(unitX: unitRect.originX)
        )
        let southEast = CLLocationCoordinate2D(
            latitude: Mercator.latitude(unitY: unitRect.originY + unitRect.height),
            longitude: Mercator.longitude(unitX: unitRect.originX + unitRect.width)
        )

        let snapshotter = MKMapSnapshotter(options: options)
        let rendered = await withCheckedContinuation { continuation in
            snapshotter.start(with: renderQueue) { snapshot, _ in
                continuation.resume(returning: snapshot.flatMap { measure($0, northWest: northWest, southEast: southEast) })
            }
        }
        // Nothing else holds the snapshotter, and it isn't documented to
        // retain itself while working — so keep it alive across the await
        // rather than trusting the optimizer not to release it mid-render.
        withExtendedLifetime(snapshotter) {}
        return rendered
    }

    /// Works out what the snapshot *actually* covers, rather than trusting it
    /// to have rendered the requested rect: the snapshotter is free to adjust
    /// the region to suit the pixel size it was given, and a few points of
    /// unnoticed drift here is the whole difference between a trail that
    /// follows the valley and one that runs alongside it.
    ///
    /// The arithmetic lives in `UnitMercatorRect.init(imageWidth:…)`; what's
    /// here is only the measuring. Deriving the mapping from `point(for:)`
    /// rather than from `MKMapPoint` is the point of the exercise: it
    /// expresses the result in ``Mercator``'s terms, which is what the widget
    /// will project with, and it costs nothing to verify rather than assume.
    private static func measure(
        _ snapshot: MKMapSnapshotter.Snapshot,
        northWest: CLLocationCoordinate2D,
        southEast: CLLocationCoordinate2D
    ) -> Rendered? {
        let pointNW = snapshot.point(for: northWest)
        let pointSE = snapshot.point(for: southEast)
        let imageSize = snapshot.image.size

        guard let visibleRect = UnitMercatorRect(
            imageWidth: Double(imageSize.width),
            imageHeight: Double(imageSize.height),
            .init(latitude: northWest.latitude, longitude: northWest.longitude, x: Double(pointNW.x), y: Double(pointNW.y)),
            .init(latitude: southEast.latitude, longitude: southEast.longitude, x: Double(pointSE.x), y: Double(pointSE.y))
        ) else { return nil }

        guard let encoded = encode(snapshot.image) else { return nil }
        return Rendered(
            data: encoded.data,
            pixelWidth: encoded.pixelWidth,
            pixelHeight: encoded.pixelHeight,
            visibleRect: visibleRect
        )
    }

    private struct Encoded {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// JPEG, not PNG: these are photographic-ish raster maps that a widget
    /// extension has to decode within a hard memory budget, and the trail
    /// line — the part that has to stay crisp — is drawn on top afterwards,
    /// never baked in.
    private static func encode(_ image: PlatformImage) -> Encoded? {
        #if canImport(UIKit)
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return Encoded(
            data: data,
            pixelWidth: Int((image.size.width * image.scale).rounded()),
            pixelHeight: Int((image.size.height * image.scale).rounded())
        )
        #elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return nil }
        return Encoded(data: data, pixelWidth: representation.pixelsWide, pixelHeight: representation.pixelsHigh)
        #else
        return nil
        #endif
    }
}

#if canImport(UIKit)
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
private typealias PlatformImage = NSImage
#endif
