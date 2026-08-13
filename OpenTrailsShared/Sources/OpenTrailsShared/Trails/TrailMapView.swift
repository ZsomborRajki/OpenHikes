//
//  TrailMapView.swift
//  OpenTrailsShared
//
//  The iOS widget's trail visual: a real basemap, pre-rendered by the app
//  (see `TrailBasemapRenderer`), with the trail line and last-known position
//  drawn on top in exact registration.
//
//  Everything is drawn in one `Canvas` on purpose. The image has to be
//  aspect-filled into a widget whose shape doesn't quite match any rendered
//  variant, and the line has to land on the same pixels the image put that
//  piece of ground on — so image placement and coordinate projection share a
//  single rect computed once, instead of a `.scaledToFill()` image and an
//  overlay each doing their own arithmetic and drifting apart at the edges.
//
//  Falls straight back to ``TrailGlyphView`` whenever there's no usable
//  image: before the first render finishes, if a render failed (they need
//  network), or if the files were pruned. The widget always draws something.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct TrailMapView: View {
    private let polyline: [SharedTrailSnapshot.CodableCoordinate]
    private let liveFix: SharedTrailSnapshot.CodableCoordinate?
    private let basemaps: TrailBasemapSet?
    private let tint: Color
    private let lineWidth: CGFloat
    private let imageData: (String) -> Data?

    @Environment(\.colorScheme)
    private var colorScheme

    /// - Parameter imageData: where the rendered bytes come from. Defaults to
    ///   the App Group, which is the only place they live in the shipping
    ///   app — injectable so this view can also be rendered in a preview or a
    ///   test, neither of which has an App Group container to read from.
    public init(
        polyline: [SharedTrailSnapshot.CodableCoordinate],
        basemaps: TrailBasemapSet?,
        tint: Color,
        liveFix: SharedTrailSnapshot.CodableCoordinate? = nil,
        lineWidth: CGFloat = 3,
        imageData: @escaping (String) -> Data? = SharedStore.basemapImageData(named:)
    ) {
        self.polyline = polyline
        self.liveFix = liveFix
        self.basemaps = basemaps
        self.tint = tint
        self.lineWidth = lineWidth
        self.imageData = imageData
    }

    public var body: some View {
        GeometryReader { proxy in
            if let resolved = resolvedBasemap(for: proxy.size) {
                Canvas { context, size in
                    // The fill rect overflows the view on one axis by design;
                    // without this the overflow would paint outside the
                    // widget's rounded content area.
                    context.clip(to: Path(CGRect(origin: .zero, size: size)))

                    let imageRect = Self.aspectFillRect(aspectRatio: resolved.basemap.aspectRatio, in: size)
                    context.draw(resolved.image.interpolation(.high), in: imageRect)

                    let rect = resolved.basemap.visibleRect
                    func place(_ coordinate: SharedTrailSnapshot.CodableCoordinate) -> CGPoint {
                        let normalized = rect.normalizedPoint(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                        return CGPoint(
                            x: imageRect.minX + normalized.x * imageRect.width,
                            y: imageRect.minY + normalized.y * imageRect.height
                        )
                    }

                    TrailStroke.draw(
                        points: polyline.map(place),
                        liveFixPoint: liveFix.map(place),
                        tint: tint,
                        lineWidth: lineWidth,
                        casing: true,
                        in: &context
                    )
                }
            } else {
                // A rendered basemap frames the trail with padding of its
                // own, which is what keeps the line clear of anything drawn
                // over this view. The fit-to-bounds glyph has no such margin
                // and would otherwise run to the edges — and under the text —
                // now that this fills its whole container.
                TrailGlyphView(polyline: polyline, tint: tint, liveFix: liveFix, lineWidth: lineWidth)
                    .padding(lineWidth * 4)
            }
        }
    }

    private struct ResolvedBasemap {
        let basemap: TrailBasemap
        let image: Image
    }

    /// Picks the image for this size and appearance and loads it. Reading and
    /// decoding synchronously in the render pass is deliberate: a widget's
    /// view tree is rendered to a static snapshot, so there's no later pass
    /// in which an asynchronously-loaded image could appear.
    private func resolvedBasemap(for size: CGSize) -> ResolvedBasemap? {
        guard size.width > 0, size.height > 0, polyline.count > 1 else { return nil }
        guard let basemap = basemaps?.image(
            forAspectRatio: size.width / size.height,
            appearance: colorScheme == .dark ? .dark : .light
        ) else { return nil }
        guard let data = imageData(basemap.fileName),
              let image = Image(basemapData: data)
        else { return nil }
        return ResolvedBasemap(basemap: basemap, image: image)
    }

    /// The rect an image of `aspectRatio` occupies when scaled to cover
    /// `size` and centered — i.e. `.scaledToFill()`, computed rather than
    /// applied so the projection above can use the same numbers.
    static func aspectFillRect(aspectRatio: Double, in size: CGSize) -> CGRect {
        guard aspectRatio.isFinite, aspectRatio > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let viewAspect = size.width / size.height
        let filled = aspectRatio > viewAspect
            ? CGSize(width: size.height * aspectRatio, height: size.height)
            : CGSize(width: size.width, height: size.width / aspectRatio)
        return CGRect(
            x: (size.width - filled.width) / 2,
            y: (size.height - filled.height) / 2,
            width: filled.width,
            height: filled.height
        )
    }
}

extension Image {
    /// Decodes a basemap image. Returns `nil` rather than a placeholder so
    /// the caller falls back to the line-only glyph — a broken-image box in a
    /// widget is worse than no map.
    init?(basemapData data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        return nil
        #endif
    }
}
