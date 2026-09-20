//
//  TrailWidgetPlaceholderBasemapTests.swift
//  OpenWidgetTests
//
//  The gallery's map is four JPEGs checked into the asset catalogue, rendered
//  once by `Scripts/placeholder-basemaps.sh` against the route in
//  `TrailWidgetPlaceholder.swift`. Nothing rebuilds them, which makes this the
//  one part of the widget that can rot in silence: move the placeholder route
//  and the images keep loading, keep decoding, and keep framing a valley the
//  trail is no longer in. A reviewer would see a map and a line and have no
//  way to tell they disagree.
//
//  So what is asserted here is the *registration* — that every point of the
//  route the widget draws lands inside every image it might draw it on. That
//  is the property the script exists to produce and the only one a pixel-free
//  test can check.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

@Suite("Placeholder basemaps")
struct TrailWidgetPlaceholderBasemapTests {
    private static let set = TrailWidgetPlaceholderBasemaps.set
    private static let polyline = TrailWidgetProvider.placeholderSnapshot.polyline

    /// The four the renderer produces for a real trail: two shapes, two
    /// appearances. A short set is what `TrailBasemapRenderer.holdsEveryCombination`
    /// refuses to accept as finished, and a checked-in set gets no exemption —
    /// a missing combination here falls back across appearance and draws a
    /// light map under a dark home screen.
    @Test("every shape and appearance is shipped")
    func everyCombinationIsShipped() {
        let combinations = Set(
            Self.set.images.map { "\($0.variant.rawValue)-\($0.appearance.rawValue)" }
        )
        #expect(combinations.count == 4)
        for variant in TrailBasemapVariant.allCases {
            for appearance in TrailBasemapAppearance.allCases {
                #expect(
                    combinations.contains("\(variant.rawValue)-\(appearance.rawValue)"),
                    "\(variant) \(appearance)"
                )
            }
        }
    }

    /// The manifest names data sets, and a name that no longer resolves is a
    /// widget that silently goes back to the line glyph.
    @Test("every image in the manifest is actually in the bundle")
    func everyImageLoads() throws {
        for basemap in Self.set.images {
            let data = try #require(
                TrailWidgetBasemapImages.data(named: basemap.fileName),
                "\(basemap.fileName)"
            )
            #expect(!data.isEmpty, "\(basemap.fileName)")
        }
    }

    /// The assertion the script's header points at. Every point of the
    /// placeholder route must project inside every image's `visibleRect`,
    /// which is what "these images frame this trail" means in the terms
    /// `TrailMapView` actually draws in.
    ///
    /// A margin rather than the bare `0...1` box: the renderer frames a trail
    /// with padding of its own, and a route that had drifted to touch an edge
    /// would be technically inside and visibly wrong.
    @Test("the shipped maps frame the placeholder route")
    func placeholderBasemapsFrameTheTrail() {
        let margin = 0.02
        for basemap in Self.set.images {
            for coordinate in Self.polyline {
                let point = basemap.visibleRect.normalizedPoint(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                #expect(
                    point.x > margin && point.x < 1 - margin,
                    "\(basemap.fileName) x=\(point.x) — re-run Scripts/placeholder-basemaps.sh"
                )
                #expect(
                    point.y > margin && point.y < 1 - margin,
                    "\(basemap.fileName) y=\(point.y) — re-run Scripts/placeholder-basemaps.sh"
                )
            }
        }
    }

    /// Each Home Screen shape has to resolve to the variant it was rendered
    /// for rather than to the fallback chain — a square map aspect-filled into
    /// a medium widget crops the ends off the trail.
    @Test(
        "each family resolves the variant it was rendered for",
        arguments: [
            (WidgetFamily.systemSmall, TrailBasemapVariant.square),
            (.systemMedium, .wide),
            (.systemLarge, .square),
        ]
    )
    func familiesResolveTheirVariant(family: WidgetFamily, variant: TrailBasemapVariant) {
        // The aspect ratios a placed widget actually has, rather than the
        // point sizes, which differ by device.
        let aspectRatio: Double = switch family {
        case .systemMedium: 2.13
        default: 1.0
        }
        for appearance in TrailBasemapAppearance.allCases {
            let resolved = Self.set.image(forAspectRatio: aspectRatio, appearance: appearance)
            #expect(resolved?.variant == variant, "\(family) \(appearance)")
            #expect(resolved?.appearance == appearance, "\(family) \(appearance)")
        }
    }

    /// The gallery is what the images were rendered for, so the entry the
    /// gallery draws has to be carrying them. It reads no store, which is the
    /// point — a hiker choosing the widget has not selected a trail yet.
    @Test("the gallery entry carries the shipped maps")
    func galleryEntryCarriesThem() {
        let entry = TrailWidgetProvider.placeholderEntry()
        #expect(entry.basemaps == Self.set)
        #expect(entry.snapshot?.polyline == Self.polyline)
        let followed = TrailWidgetProvider.followedPlaceholderEntry()
        #expect(followed.basemaps == Self.set)
        #expect(followed.snapshot?.liveFix != nil, "the followed preview draws every element")
    }
}
