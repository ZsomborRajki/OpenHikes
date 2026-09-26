//
//  TrailBasemapRenderer.swift
//  OpenHikes
//
//  Rasterizes the selected trail's surroundings into the App Group so the iOS
//  widget can show a real map under the trail line. WidgetKit can't host a
//  live Map/MKMapView at any OS version, so the app rendering images ahead of
//  time is the only way a widget gets a basemap at all — see `TrailBasemap`
//  in OpenHikesShared for the consuming side.
//
//  An actor, because this is the one part of the widget pipeline that's
//  genuinely expensive: four MKMapSnapshotter passes (two shapes × light and
//  dark), each a network round-trip. It keeps the bookkeeping below —
//  `inFlight` and `generation` — consistent across overlapping calls, so a
//  burst of selection changes ends with the *last* selection on disk.
//
//  One set per trail, not one in total. A widget pinned to a trail draws that
//  trail whatever is selected, so the selection's set sits beside the pinned
//  trails' sets rather than replacing them, and every prune spares the
//  pinned ones — see `PinnedHikes`.
//
//  Nothing here runs on the live-fix path. The images depend only on where
//  the trail is, so they're re-rendered when its geometry changes and left
//  alone while a position moves across them — that's what makes shipping
//  images affordable next to a snapshot that updates every 45 seconds.
//

import Foundation
import MapKit
import OpenHikesShared

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

actor TrailBasemapRenderer {
    static let shared = TrailBasemapRenderer(
        pinnedHikeIDs: SharedHikeCataloguePublisher.pinnedTrails
    )
    private static let jpegCompressionQuality: CGFloat = 0.9

    /// Rendered at 2× rather than the device's own scale: a 3× image decodes
    /// to 2.25× the bytes inside a widget extension, which has a hard memory
    /// ceiling and no way to recover from crossing it. Measured on the two
    /// variants: 3.5 MB → 1.6 MB and 2.3 MB → 1.0 MB of decoded bitmap.
    ///
    /// `MKMapSnapshotter` does not honour this. It ignores
    /// `options.traitCollection.displayScale` and the deprecated
    /// `options.scale` alike and returns the device's own scale regardless,
    /// so for a long time this constant expressed an intent that never
    /// happened — manifests recorded 960×960 where they meant 640×640.
    /// ``resampled(_:)`` is what applies it now; the request in
    /// ``snapshotTraits(for:)`` is left in place so the resample becomes a
    /// no-op if a later OS starts honouring it.
    private static let renderScale: CGFloat = 2

    private static let renderExecutor = DispatchQueue(
        label: "com.openhikes.basemap-render",
        qos: .utility
    )

    /// What one snapshot is asked for: a framed region, the shape it is being
    /// rendered at, and which appearance. Internal rather than private
    /// because ``Render`` names it — see there for why that seam exists.
    struct RenderInput: Sendable {
        let unitRect: UnitMercatorRect
        let variant: TrailBasemapVariant
        let appearance: TrailBasemapAppearance
    }

    /// What one snapshot produced: encoded bytes, the pixel dimensions they
    /// decode to, and the region the snapshotter *actually* covered, which is
    /// not always the region it was asked for — see ``measure(_:northWest:southEast:)``.
    struct Rendered: Sendable {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let visibleRect: UnitMercatorRect
    }

    /// The snapshot boundary, as a function, so a suite can decide what a
    /// render returns instead of a Maps server deciding it.
    ///
    /// A deliberate test seam rather than production indirection: the only
    /// caller that supplies one is `TrailBasemapRendererTests`, and
    /// ``shared`` — the single instance the app builds — takes the default.
    /// It exists because everything worth asserting about this actor is what
    /// it does with a result, and reaching any of it used to mean four live
    /// round-trips per pass. Unreachable ones cost the suite 570 seconds of
    /// `maps.snapshot.timeout` against a 30-minute CI budget, and failed
    /// nothing while doing it.
    ///
    /// `nil` means this snapshot did not land. It is an ordinary outcome —
    /// offline, or a background launch with no network — and the pass
    /// publishes whatever else did.
    typealias Render = @Sendable (RenderInput) async -> Rendered?

    private let render: Render

    /// Which trails a placed widget is pinned to, or that WidgetKit cannot
    /// say.
    ///
    /// The container holds a set per trail, and this is what decides which
    /// ones outlive a change of selection: a widget pinned to a trail draws
    /// that trail's map whatever the app has selected, so pruning to the
    /// selection alone took the map out from under it and left the pinned
    /// trail's line on a grey fill. ``PinnedTrails/unknown`` prunes nothing
    /// but the selection's own superseded frames — a set nothing draws is bytes, and a pinned one
    /// deleted on a guess is a grey widget.
    ///
    /// A seam for the reason ``Render`` is one, and the default is the
    /// suites': nothing is pinned. ``shared`` asks WidgetKit.
    typealias PinnedHikes = @Sendable () async -> PinnedTrails

    private let pinnedHikeIDs: PinnedHikes

    private struct RenderRequest: Equatable {
        let hikeID: UUID
        let coverage: UnitMercatorRect
    }

    /// Which bookkeeping a pass answers to — see ``inFlight`` and
    /// ``pinnedInFlight``.
    private enum Lane {
        /// The selected trail, which a newer selection or a deselection
        /// overtakes. Carries the ``generation`` the pass started at.
        case selection(generation: Int)
        /// A trail a widget is pinned to, which nothing but a re-render of
        /// the same trail overtakes.
        case pinned
    }

    /// The selection's render right now. A pass checks this back after every
    /// suspension and abandons itself if it's no longer the one — an actor
    /// only serializes up to the next `await`, so without it two trails
    /// selected in quick succession would interleave, and the older pass
    /// would publish a set for a trail nobody is looking at.
    private var inFlight: RenderRequest?

    /// The pinned trails' renders, one per trail. Kept apart from
    /// ``inFlight`` because a selection change is not a reason to stop one: a
    /// pinned trail is on a Home Screen whatever is selected.
    private var pinnedInFlight: [UUID: RenderRequest] = [:]

    /// Bumped by ``invalidate()``. A render that started before the bump has
    /// been overtaken by events (the trail was deselected or deleted) and
    /// drops its results instead of resurrecting a trail the user just
    /// cleared.
    private var generation = 0

    /// The redraw seam, for the same reason ``Render`` is one: `WidgetCenter`
    /// neither reports a reload nor replays it, so a suite can only tell that
    /// this pass went through the recording gate if it is handed the sink.
    private let widgetReload: TrailWidgetReload

    /// - Parameters:
    ///   - render: the snapshot boundary, defaulting to the real
    ///     `MKMapSnapshotter` pass. Supplied only by tests; see ``Render``.
    ///   - widgetReload: where a finished pass asks for the widget to be
    ///     redrawn. Supplied only by tests; see ``TrailWidgetReload``.
    ///   - pinnedHikeIDs: which trails' sets outlive a change of selection;
    ///     see ``PinnedHikes``.
    init(
        render: Render? = nil,
        widgetReload: TrailWidgetReload = .system,
        pinnedHikeIDs: @escaping PinnedHikes = { .known([]) }
    ) {
        self.render = render ?? TrailBasemapRenderer.renderWithMapKit
        self.widgetReload = widgetReload
        self.pinnedHikeIDs = pinnedHikeIDs
    }

    /// Whether this pass is still the one whose results are wanted.
    private func stillCurrent(_ request: RenderRequest, in lane: Lane) -> Bool {
        switch lane {
        case .selection(let startedAt):
            inFlight == request && generation == startedAt
        case .pinned:
            pinnedInFlight[request.hikeID] == request
        }
    }

    /// Every trail a pass is writing images for right now, which no prune may
    /// take: the images land before the manifest naming them does.
    private var renderingHikeIDs: Set<UUID> {
        Set(pinnedInFlight.keys).union(inFlight.map { [$0.hikeID] } ?? [])
    }

    /// Renders the selected trail's surroundings unless the images on disk
    /// already frame it. Safe to call on every selection change and every
    /// foreground — the common case is a manifest load, a bounds comparison,
    /// and no render.
    func refreshIfNeeded(hikeID: UUID, polyline: [SharedTrailSnapshot.CodableCoordinate]) async {
        // Identical work is already running; anything else supersedes it.
        guard let request = Self.request(hikeID: hikeID, polyline: polyline),
              inFlight != request,
              !Self.isPublished(request)
        else { return }

        inFlight = request
        defer { if inFlight == request { inFlight = nil } }
        await renderAndPublish(request, in: .selection(generation: generation))
    }

    /// Renders a pinned trail's surroundings unless the images on disk already
    /// frame it — the map a widget pinned to a trail that is not selected has
    /// no other way to get. Called from the pinned-trail sweep in
    /// `SharedHikeCataloguePublisher`.
    ///
    /// Beside the selection's render rather than through it: the two would
    /// otherwise overtake each other, and a launch runs both at once.
    func refreshPinned(hikeID: UUID, polyline: [SharedTrailSnapshot.CodableCoordinate]) async {
        guard let request = Self.request(hikeID: hikeID, polyline: polyline),
              pinnedInFlight[hikeID] != request,
              // The selection is already rendering exactly this; its set is
              // the one this pass would publish.
              inFlight != request,
              !Self.isPublished(request)
        else { return }

        pinnedInFlight[hikeID] = request
        defer { if pinnedInFlight[hikeID] == request { pinnedInFlight[hikeID] = nil } }
        await renderAndPublish(request, in: .pinned)
    }

    /// Deletes every set but those for `hikeIDs` and whatever is rendering —
    /// the sweep's half of keeping the container bounded by what is on a
    /// screen. Through the actor so it cannot take a pass's images between
    /// their landing and the manifest that names them.
    func prune(keeping hikeIDs: Set<UUID>) {
        SharedStore.pruneBasemaps(keeping: hikeIDs.union(renderingHikeIDs))
    }

    private static func request(
        hikeID: UUID,
        polyline: [SharedTrailSnapshot.CodableCoordinate]
    ) -> RenderRequest? {
        guard polyline.count > 1, let coverage = UnitMercatorRect(bounding: polyline) else { return nil }
        return RenderRequest(hikeID: hikeID, coverage: coverage)
    }

    /// Whether the stored set already frames `request`, whole.
    private static func isPublished(_ request: RenderRequest) -> Bool {
        guard let existing = SharedStore.loadBasemapSet(for: request.hikeID) else { return false }
        return existing.coverage.isEquivalent(to: request.coverage)
            // A manifest whose images have been pruned away is worse than no
            // manifest: without this check it would keep claiming the work is
            // done while the widget quietly fell back to the line glyph.
            && SharedStore.hasAllBasemapImages(in: existing)
            && holdsEveryCombination(existing)
            && isAtIntendedScale(existing)
    }

    /// Whether another pass could have written files under the same names as
    /// this one — the same trail and the same coverage in the other lane, or
    /// an identical selection render started after a deselection overtook
    /// this one. Names are derived from exactly those two, so deleting ours
    /// would delete theirs.
    private func anotherPassSharesNames(with request: RenderRequest, in lane: Lane) -> Bool {
        switch lane {
        case .selection(let startedAt):
            pinnedInFlight[request.hikeID] == request
                || (inFlight == request && generation != startedAt)
        case .pinned:
            inFlight == request
        }
    }

    private func renderAndPublish(_ request: RenderRequest, in lane: Lane) async {
        let hikeID = request.hikeID
        let coverage = request.coverage

        // Every early return below leaves behind whatever this pass had already
        // written — files with no manifest pointing at them, reclaimed only by
        // the *next* successful render's prune, which may never come if the
        // user doesn't select another trail. So the pass cleans up after
        // itself, naming its own files rather than pruning to a keep-set,
        // which is what makes this safe to do while another pass is writing.
        var written: Set<String> = []
        var published = false
        defer {
            if !published, !written.isEmpty, !anotherPassSharesNames(with: request, in: lane) {
                SharedStore.removeBasemapImages(named: written)
            }
        }

        var images: [TrailBasemap] = []
        for variant in TrailBasemapVariant.allCases {
            let framed = coverage.framed(toAspectRatio: variant.aspectRatio)
            for appearance in TrailBasemapAppearance.allCases {
                let input = RenderInput(unitRect: framed, variant: variant, appearance: appearance)
                guard let rendered = await render(input) else { continue }
                guard stillCurrent(request, in: lane) else { return }

                let fileName = Self.fileName(
                    hikeID: hikeID,
                    coverage: coverage,
                    variant: variant,
                    appearance: appearance
                )
                // A `continue` rather than an abort, here and at the render
                // above: the four snapshots are four separate requests, so
                // one failing while the others land is what a flaky
                // connection looks like. The widget picks one image by shape
                // and appearance, and a set holding the one it is being asked
                // for draws a map where an all-or-nothing set draws the line
                // glyph. The combinations that failed fall back until the
                // next pass — which is what discarding the whole pass would
                // have given all four — and a short set is what
                // ``holdsEveryCombination(_:)`` refuses to accept as done, so
                // the next pass is the next refresh rather than the next
                // change of coverage.
                guard SharedStore.writeBasemapImage(rendered.data, named: fileName) else { continue }
                written.insert(fileName)
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
        guard !images.isEmpty else { return }

        // Asked before the manifest lands rather than after, so nothing
        // between the save and the prune below can suspend. Only the
        // selection's pass prunes other trails: it is the one that leaves a
        // set behind every time the hiker looks at another trail.
        let pinned: PinnedTrails = switch lane {
        case .selection: await pinnedHikeIDs()
        case .pinned: .unknown
        }
        guard stillCurrent(request, in: lane) else { return }

        // Order matters. The images land first, the manifest that points at
        // them second, and only then is anything deleted — so a widget
        // reading mid-render sees either the whole old set or the whole new
        // one, never a manifest pointing at a file that isn't there yet.
        let set = TrailBasemapSet(hikeID: hikeID, coverage: coverage, images: images)
        SharedStore.saveBasemapSet(set)
        published = true
        SharedStore.pruneBasemapImages(supersededBy: set)
        if case .known(let pinned) = pinned {
            SharedStore.pruneBasemaps(keeping: pinned.union(renderingHikeIDs).union([hikeID]))
        }
        // Unless a live recording owns the widget, in which case these images
        // are not what it is drawing and the redraw waits for the recording to
        // release it — see ``TrailWidgetReload``. An actor rather than the
        // main actor, so the App Group read that decision costs is already off
        // the main thread.
        widgetReload.requestUnlessRecording()
    }

    /// Drops the rendered basemaps of every trail no widget is pinned to, and
    /// makes the selection's render currently in flight throw its results
    /// away rather than write them.
    ///
    /// A pinned trail's set stays, and so does a pinned trail's render: this
    /// is deselection, and a pinned widget is not following the selection.
    /// When WidgetKit cannot say what is pinned nothing is dropped — see
    /// ``PinnedHikes`` — and the next prune that can tell does it instead.
    func invalidate() async {
        generation &+= 1
        inFlight = nil
        guard case .known(let pinned) = await pinnedHikeIDs() else { return }
        // Read after the `await`: a selection made meanwhile is rendering, and
        // its images are on disk ahead of their manifest.
        SharedStore.pruneBasemaps(keeping: pinned.union(renderingHikeIDs))
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
        var hasher = StableHasher()
        for value in [coverage.originX, coverage.originY, coverage.width, coverage.height] {
            hasher.combine(value)
        }
        return "\(hikeID.uuidString)-\(String(hasher.value, radix: 36))-\(variant.rawValue)-\(appearance.rawValue).jpg"
    }
}

/// The MapKit half, in an extension in this same file because the actor's
/// body reached the length SwiftLint enforces once it kept a set per trail.
/// Nothing here touches the bookkeeping above.
extension TrailBasemapRenderer {
    // MARK: Rendering

    /// One corner of the region asked for, in both of the spellings the
    /// measuring step needs.
    ///
    /// A region crossing the antimeridian runs past `x = 1`, and its two
    /// spellings part company there: the corner has to be *asked about* at a
    /// longitude inside ±180°, because that is the only kind `point(for:)`
    /// takes, and *measured* at the longitude the region names it by, so the
    /// east corner stays east of the west one instead of reappearing a world
    /// to its left and turning a valley into a hemisphere.
    private struct Corner {
        let latitude: Double
        /// As the region names it — may run past ±180°.
        let longitude: Double
        /// The same place, inside ±180°.
        let coordinate: CLLocationCoordinate2D

        init(latitude: Double, unitX: Double) {
            self.latitude = latitude
            longitude = Mercator.longitude(unitX: unitX)
            coordinate = CLLocationCoordinate2D(
                latitude: latitude,
                longitude: Mercator.longitude(unitX: Mercator.wrappedUnitX(unitX))
            )
        }
    }

    private static func renderWithMapKit(_ input: RenderInput) async -> Rendered? {
        let options = MKMapSnapshotter.Options()
        let world = MKMapSize.world.width
        options.mapRect = MKMapRect(
            x: input.unitRect.originX * world,
            y: input.unitRect.originY * world,
            width: input.unitRect.width * world,
            height: input.unitRect.height * world
        )
        options.size = input.variant.pointSize

        // `.muted` is the emphasis style Apple designed for exactly this —
        // a basemap that stays legible with someone else's data drawn over
        // it. POIs come off for the same reason: at 320 points wide, pins
        // compete with the one line that matters.
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration

        #if canImport(UIKit)
        options.traitCollection = await snapshotTraits(for: input.appearance)
        #elseif canImport(AppKit)
        // No scale knob here — AppKit renders at the screen's backing scale
        // and `encode` reports whatever pixel size that produced, so the
        // widget's registration doesn't care either way.
        options.appearance = NSAppearance(named: input.appearance == .dark ? .darkAqua : .aqua)
        #endif

        // Two opposite corners of what we asked for, kept as coordinates so
        // the finished snapshot can be measured in its own terms below. Each
        // carries two longitudes; see ``Corner`` for which is for what.
        let northWest = Corner(
            latitude: Mercator.latitude(unitY: input.unitRect.originY),
            unitX: input.unitRect.originX
        )
        let southEast = Corner(
            latitude: Mercator.latitude(unitY: input.unitRect.originY + input.unitRect.height),
            unitX: input.unitRect.originX + input.unitRect.width
        )

        let snapshotter = MKMapSnapshotter(options: options)
        return await withTaskExecutorPreference(renderExecutor) {
            guard let snapshot = try? await snapshotter.start() else { return nil }
            return measure(
                snapshot,
                northWest: northWest,
                southEast: southEast
            )
        }
    }

    /// Built on the main actor because UIKit's mutable traits are main-actor
    /// isolated, while this renderer is an actor of its own — the trait
    /// collection itself is `Sendable`, so one hop per snapshot buys the
    /// whole render pass its appearance without the pass leaving its actor.
    ///
    /// `displayScale` here is a request the snapshotter does not honour; it
    /// returns the device's own scale whatever this says. Kept anyway, as the
    /// statement of intent that ``resampled(_:)`` currently has to enforce by
    /// hand, and so the resample turns itself off if that ever changes.
    #if canImport(UIKit)
    @MainActor
    private static func snapshotTraits(
        for appearance: TrailBasemapAppearance
    ) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = appearance == .dark ? .dark : .light
            traits.displayScale = renderScale
        }
    }
    #endif

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
        northWest: Corner,
        southEast: Corner
    ) -> Rendered? {
        let pointNW = snapshot.point(for: northWest.coordinate)
        let pointSE = snapshot.point(for: southEast.coordinate)
        let imageSize = snapshot.image.size

        guard let visibleRect = UnitMercatorRect(
            imageWidth: Double(imageSize.width),
            imageHeight: Double(imageSize.height),
            .init(
                latitude: northWest.latitude,
                longitude: northWest.longitude,
                x: Double(pointNW.x),
                y: Double(pointNW.y)
            ),
            .init(
                latitude: southEast.latitude,
                longitude: southEast.longitude,
                x: Double(pointSE.x),
                y: Double(pointSE.y)
            )
        ) else { return nil }

        guard let encoded = encode(snapshot.image) else { return nil }
        return Rendered(
            data: encoded.data,
            pixelWidth: encoded.pixelWidth,
            pixelHeight: encoded.pixelHeight,
            visibleRect: visibleRect
        )
    }

    /// Internal rather than private so the suite can hand ``encode(_:)`` an
    /// image at a chosen device scale and read back what reaches disk. The
    /// injected render boundary covers manifest bookkeeping; this seam keeps
    /// the production JPEG conversion covered too.
    struct Encoded {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// JPEG, not PNG: these are photographic-ish raster maps that a widget
    /// extension has to decode within a hard memory budget, and the trail
    /// line — the part that has to stay crisp — is drawn on top afterwards,
    /// never baked in.
    ///
    /// Resamples to ``renderScale`` first, because the snapshotter won't.
    static func encode(_ image: PlatformImage) -> Encoded? {
        let scaled = resampled(image)
        #if canImport(UIKit)
        guard let data = scaled.jpegData(compressionQuality: jpegCompressionQuality) else { return nil }
        return Encoded(
            data: data,
            pixelWidth: Int((scaled.size.width * scaled.scale).rounded()),
            pixelHeight: Int((scaled.size.height * scaled.scale).rounded())
        )
        #elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: jpegCompressionQuality]
              )
        else { return nil }
        return Encoded(data: data, pixelWidth: representation.pixelsWide, pixelHeight: representation.pixelsHigh)
        #else
        return nil
        #endif
    }

    /// Redraws `image` at ``renderScale`` so the bytes that reach the App
    /// Group are the size that constant names.
    ///
    /// This is the only lever left. The snapshotter ignores every scale knob
    /// it offers — five spellings were tried, including the deprecated
    /// `options.scale` reached by KVC, and all returned the device's own
    /// scale — so asking harder is not an option and asking differently is
    /// not either.
    ///
    /// The trade is deliberate and one-directional. It costs the *app*
    /// roughly 2 ms of CPU per image (four per pass, off the main thread,
    /// against four network round-trips) and a transient buffer the size of
    /// the output. It saves the *widget extension* 2.25× on every decode, and
    /// the extension is the process the header calls out as unable to recover
    /// from crossing its ceiling. The file on disk shrinks too, by a measured
    /// 1.9× rather than 2.25× — downsampling concentrates detail, so JPEG
    /// spends slightly more per remaining pixel. Decode memory is the figure
    /// that matters here, and that one is exactly 2.25×.
    ///
    /// A device already at or below `renderScale` is returned untouched, so
    /// this costs nothing on a 2× phone and would cost nothing at all if a
    /// later OS honoured the request in ``snapshotTraits(for:)``.
    private static func resampled(_ image: PlatformImage) -> PlatformImage {
        #if canImport(UIKit)
        guard image.scale > renderScale else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        // A basemap has nothing to see through, and an opaque context drops
        // the alpha channel from both the resample and the JPEG.
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        #else
        // AppKit renders at the screen's backing scale and `encode` reports
        // whatever pixel size that produced. Unbuilt — see the platform note
        // in the repository conventions — and left as-is rather than guessed at.
        return image
        #endif
    }

    /// The pixel size an image of `variant` is meant to reach disk at.
    static func intendedPixelSize(for variant: TrailBasemapVariant) -> (width: Int, height: Int) {
        (
            width: Int((variant.pointSize.width * renderScale).rounded()),
            height: Int((variant.pointSize.height * renderScale).rounded())
        )
    }

    /// Whether every image `set` names was written at the scale
    /// ``renderScale`` asks for.
    ///
    /// A manifest written before the resample existed records the device's
    /// own scale, and the short-circuit in ``refreshIfNeeded(hikeID:polyline:)``
    /// would otherwise serve it for as long as the trail stays selected —
    /// which for someone with one favourite trail is forever. Treating it as
    /// stale costs one render pass, once.
    ///
    /// This cannot re-render in a loop: ``encode(_:)`` reports the dimensions
    /// of a context it *constructed* at that scale rather than ones it
    /// measured, so a pass that publishes anything publishes something this
    /// accepts.
    /// Whether every shape-and-appearance combination the widget can ask for
    /// is in this manifest.
    ///
    /// Without it the early-out above accepts a short set forever: its other
    /// two questions — the coverage, and whether the files are on disk — are
    /// asked of the manifest's *own* images, so a manifest holding three of
    /// four answers yes to both. Re-selecting the same trail would return
    /// before rendering anything, and the combination that failed would draw
    /// the line glyph until the trail's geometry changed or ``invalidate()``
    /// ran. Refusing a short set makes the fallback last until the next
    /// refresh instead, which is the whole reason a partial pass publishes.
    static func holdsEveryCombination(_ set: TrailBasemapSet) -> Bool {
        for variant in TrailBasemapVariant.allCases {
            for appearance in TrailBasemapAppearance.allCases
            where !set.images.contains(
                where: { $0.variant == variant && $0.appearance == appearance }
            ) {
                return false
            }
        }
        return true
    }

    static func isAtIntendedScale(_ set: TrailBasemapSet) -> Bool {
        set.images.allSatisfy { image in
            let intended = intendedPixelSize(for: image.variant)
            return image.pixelWidth == intended.width && image.pixelHeight == intended.height
        }
    }
}

/// Internal rather than private only because ``TrailBasemapRenderer/encode(_:)``
/// is a test seam and Swift will not let an internal signature name a private
/// type. Nothing else in the app declares this name.
#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif
