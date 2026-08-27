//
//  TrailBasemapRendererTests.swift
//  OpenHikesTests
//
//  What the widget draws under the trail line is a JPEG this renderer wrote
//  into the App Group. Nothing downstream can repair a bad one: the widget
//  extension has no map, no network budget and no way to tell a wrong region
//  from a right one — it draws whatever the manifest points at. So the
//  contract worth pinning here is not "the picture is pretty", it is that the
//  *store* is never left in a shape the widget cannot survive.
//
//  Three limits shape what is asserted below, and they are worth stating
//  rather than discovering.
//
//  `MKMapSnapshotter` has no injectable seam. The renderer builds one
//  directly, so a render is a live network round-trip and its result is not
//  the test's to decide. Everything here is therefore written to hold
//  identically whether or not a snapshot lands — the repository's rule that
//  no test depends on a real connection is what rules out asserting on
//  rendered output. So the render pass's interior is uncovered, not covered
//  quietly: the framed region, the measured `visibleRect`, the JPEG bytes and
//  the pixel dimensions recorded in the manifest are all asserted by nothing.
//  Reaching them needs a snapshotter the caller supplies, which is a change to
//  the renderer rather than to this file.
//
//  Ordering is not a promise an actor makes. `TrailBasemapRenderer`
//  serializes, it does not queue: a pass suspends at every snapshot, and
//  another call can enter in that gap. So a burst is asserted through the
//  invariant its bookkeeping exists to preserve — a manifest always has its
//  images, and no image outlives the manifest naming it — never through which
//  caller won.
//
//  Isolation is asserted at the executor, not at the type. See
//  `rendererDoesNotRunOnTheMainThread`.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing
import UIKit

/// Runs on `renderer`'s own executor rather than the caller's, which is what
/// makes it a measurement of the renderer's isolation instead of a
/// restatement of its declaration.
private func runsOnMainThread(on renderer: isolated TrailBasemapRenderer) -> Bool {
    pthread_main_np() != 0
}

@Suite("Trail basemap rendering", .serialized, .enabled(if: SharedStoreProbe.isAvailable))
final class TrailBasemapRendererTests {
    /// The pixel dimensions `renderScale` promises, written out rather than
    /// derived from `pointSize × renderScale` — a derived expectation would
    /// restate the implementation and pass whatever it did.
    nonisolated static let expectedSquarePixels = (width: 640, height: 640)
    nonisolated static let expectedWidePixels = (width: 760, height: 360)

    /// A ~1 km trail with bends in both axes, in the Chiemgau Alps.
    nonisolated static let trail: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: 47.6501, longitude: 12.8602),
        .init(latitude: 47.6518, longitude: 12.8631),
        .init(latitude: 47.6529, longitude: 12.8677),
        .init(latitude: 47.6544, longitude: 12.8702),
    ]

    /// Not an image — the renderer never reads these bytes back, and the
    /// suite only needs a file of a known length to notice it surviving or
    /// disappearing.
    nonisolated static let imageBytes = Data("not-a-jpeg".utf8)

    /// One name per shape rather than coordinates written inline in
    /// ``degenerateShapes``: a literal nested inside a tuple is no longer part
    /// of a variable declaration as far as the magic-number rule is
    /// concerned, and the table reads better for it anyway.
    nonisolated static let identicalPoints = Array(repeating: trail[0], count: 5)
    nonisolated static let meridian: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: 47.6001, longitude: 12.8602),
        .init(latitude: 47.7001, longitude: 12.8602),
    ]
    nonisolated static let parallel: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: 47.6501, longitude: 12.8002),
        .init(latitude: 47.6501, longitude: 12.9002),
    ]
    nonisolated static let poleToPole: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: -90, longitude: 0),
        .init(latitude: 90, longitude: 0),
    ]
    nonisolated static let antimeridian: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: 47.6501, longitude: 179.99),
        .init(latitude: 47.6601, longitude: -179.99),
    ]
    nonisolated static let notANumber: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: .nan, longitude: .nan),
        .init(latitude: 47.6501, longitude: 12.8602),
    ]

    /// Shapes a real route can take once a receiver, an importer or a
    /// decimator has had its way with it. None of them are drawings anyone
    /// wants; all of them have to leave a store the widget can read.
    nonisolated static let degenerateShapes: [(name: String, polyline: [SharedTrailSnapshot.CodableCoordinate])] = [
        ("all points identical", identicalPoints),
        ("a pure meridian", meridian),
        ("a pure parallel", parallel),
        ("pole to pole", poleToPole),
        ("across the antimeridian", antimeridian),
        ("a coordinate that is not a number", notANumber),
    ]

    init() {
        SharedStore.clearBasemaps()
    }

    /// Narrower than `SharedStore.clear()` deliberately: the widget's trail
    /// snapshot belongs to the feed suites, and a teardown that reached for
    /// the bigger hammer would make this suite's own
    /// `invalidateLeavesTheWidgetSnapshotAlone` unable to distinguish the two.
    deinit {
        SharedStore.clearBasemaps()
    }

    // MARK: Store fixtures

    /// `SharedStore` keeps the basemap directory's name private, so the suite
    /// names it a second time here. `seededImagesLandWhereTheSuiteLooks` is
    /// what keeps that copy honest — without it, a renamed directory would
    /// turn every orphan check below silently vacuous rather than red.
    private enum Container {
        static let directoryName = "basemaps"

        static var url: URL? {
            FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)?
                .appendingPathComponent(directoryName, isDirectory: true)
        }

        static var fileNames: Set<String> {
            guard let url, let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ) else { return [] }
            return Set(contents.map(\.lastPathComponent))
        }
    }

    private static func basemap(named fileName: String) -> TrailBasemap {
        TrailBasemap(
            fileName: fileName,
            variant: .square,
            appearance: .light,
            pixelWidth: 640,
            pixelHeight: 640,
            visibleRect: UnitMercatorRect(bounding: trail) ?? UnitMercatorRect(
                originX: 0,
                originY: 0,
                width: 1,
                height: 1
            )
        )
    }

    /// Publishes a manifest for `hikeID` covering `coverage`, with every image
    /// it advertises actually on disk — the state the renderer's own
    /// short-circuit is entitled to trust.
    @discardableResult private static func seedPublishedSet(
        hikeID: UUID,
        coverage: UnitMercatorRect,
        generatedAt: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> TrailBasemapSet {
        let images = [basemap(named: "\(hikeID.uuidString)-seed-square-light.jpg")]
        for image in images {
            SharedStore.writeBasemapImage(imageBytes, named: image.fileName)
        }
        let set = TrailBasemapSet(
            hikeID: hikeID,
            coverage: coverage,
            images: images,
            generatedAt: generatedAt
        )
        SharedStore.saveBasemapSet(set)
        return set
    }

    /// The one thing the store must never do, whatever a render decided:
    /// advertise an image it does not have, or keep an image nothing
    /// advertises. Both are silent in production — the first makes the widget
    /// fall back to the line glyph forever, the second leaks bytes into a
    /// container nothing else sweeps.
    private static func expectConsistentStore(
        for hikeIDs: [UUID],
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let manifests = hikeIDs.compactMap { SharedStore.loadBasemapSet(for: $0) }
        for manifest in manifests {
            #expect(
                SharedStore.hasAllBasemapImages(in: manifest),
                "\(comment): a published manifest is missing its images",
                sourceLocation: sourceLocation
            )
        }
        let advertised = Set(manifests.flatMap { $0.images.map(\.fileName) })
        let orphans = Container.fileNames.subtracting(advertised)
        #expect(
            orphans.isEmpty,
            "\(comment): basemap images nothing points at: \(orphans.sorted())",
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - The suite's own footing

extension TrailBasemapRendererTests {
    /// Fails if `SharedStore` ever moves its basemap directory, which is the
    /// only thing standing between the orphan assertions above and a
    /// permanently empty set that agrees with everything.
    @Test("a seeded image lands where this suite looks for it")
    func seededImagesLandWhereTheSuiteLooks() throws {
        let name = "footing-probe-square-light.jpg"
        #expect(SharedStore.writeBasemapImage(Self.imageBytes, named: name))

        #expect(Self.Container.fileNames.contains(name))
        #expect(SharedStore.basemapImageData(named: name) == Self.imageBytes)

        let url = try #require(Self.Container.url).appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Invalidation

extension TrailBasemapRendererTests {
    /// A deselected or deleted trail has to take its pictures with it. The
    /// manifest alone is not enough: `loadBasemapSet(for:)` filters by hike,
    /// so images left behind would be invisible to every reader and reclaimed
    /// by nothing until some future render's prune.
    @Test("invalidating drops the manifest and the image bytes together")
    func invalidateRemovesTheManifestAndTheImages() async throws {
        let hikeID = UUID()
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        let seeded = Self.seedPublishedSet(hikeID: hikeID, coverage: coverage)
        let fileName = try #require(seeded.images.first?.fileName)

        try #require(SharedStore.loadBasemapSet(for: hikeID) != nil)
        try #require(SharedStore.basemapImageData(named: fileName) != nil)

        await TrailBasemapRenderer().invalidate()

        #expect(SharedStore.loadBasemapSet(for: hikeID) == nil)
        #expect(SharedStore.basemapImageData(named: fileName) == nil)
        #expect(Self.Container.fileNames.isEmpty)
    }

    /// `invalidate()` clears basemaps, not the widget's payload. Reaching for
    /// `SharedStore.clear()` here would look tidier and would blank the widget
    /// on every trail edit that only moved the geometry.
    @Test("invalidating leaves the widget's trail snapshot alone")
    func invalidateLeavesTheWidgetSnapshotAlone() async throws {
        let hikeID = UUID()
        SharedStore.save(
            SharedTrailSnapshot(
                hikeID: hikeID,
                title: "Ridge",
                tintHex: "#FF8800",
                totalDistanceMeters: 1000,
                polyline: Self.trail
            )
        )
        Self.seedPublishedSet(
            hikeID: hikeID,
            coverage: try #require(UnitMercatorRect(bounding: Self.trail))
        )
        try #require(SharedStore.load() != nil)

        await TrailBasemapRenderer().invalidate()

        #expect(SharedStore.loadBasemapSet(for: hikeID) == nil)
        #expect(SharedStore.load()?.hikeID == hikeID, "the widget still has a trail to draw")

        SharedStore.clear()
    }

    /// Called on every deselection, including the ones where nothing was ever
    /// rendered — a background relaunch that resolves to no trail reaches
    /// this before any snapshot has been taken.
    @Test("invalidating an empty store is a no-op, not a failure")
    func invalidateOnAnEmptyStoreIsHarmless() async {
        let renderer = TrailBasemapRenderer()
        await renderer.invalidate()
        await renderer.invalidate()

        #expect(Self.Container.fileNames.isEmpty)
        #expect(SharedStore.loadBasemapSet(for: UUID()) == nil)
    }
}

// MARK: - What is refused before any network is touched

extension TrailBasemapRendererTests {
    /// A trail the widget can't draw a line for isn't worth a region either,
    /// and the guard runs before the store is consulted — so an existing
    /// manifest for the same hike survives untouched rather than being
    /// replaced by a render of a single point's neighbourhood.
    @Test("a polyline of fewer than two points renders nothing", arguments: [0, 1])
    func tooFewPointsRenderNothing(pointCount: Int) async throws {
        let hikeID = UUID()
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        let seeded = Self.seedPublishedSet(hikeID: hikeID, coverage: coverage)

        await TrailBasemapRenderer().refreshIfNeeded(
            hikeID: hikeID,
            polyline: Array(Self.trail.prefix(pointCount))
        )

        #expect(SharedStore.loadBasemapSet(for: hikeID) == seeded)
        #expect(Self.Container.fileNames == Set(seeded.images.map(\.fileName)))
    }

    /// The common case by a wide margin: every foreground and every selection
    /// change asks, and almost every ask is already answered. A manifest whose
    /// coverage still frames the trail and whose images are all present has to
    /// come back untouched — `generatedAt` included, since a re-render that
    /// produced identical pixels would still cost four network round-trips and
    /// a widget reload.
    @Test("a trail the stored manifest already frames is left exactly as it is")
    func coveredTrailIsLeftExactlyAsItIs() async throws {
        let hikeID = UUID()
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        let seeded = Self.seedPublishedSet(hikeID: hikeID, coverage: coverage)

        await TrailBasemapRenderer().refreshIfNeeded(hikeID: hikeID, polyline: Self.trail)

        #expect(SharedStore.loadBasemapSet(for: hikeID) == seeded)
        #expect(Self.Container.fileNames == Set(seeded.images.map(\.fileName)))
        #expect(SharedStore.basemapImageData(named: seeded.images[0].fileName) == Self.imageBytes)
    }

    /// The manifest is keyed by hike, so another trail's images can never be
    /// mistaken for this one's — and asking about a hike that was never
    /// rendered must not hand back the one that was.
    @Test("a manifest is never served to a hike it wasn't rendered for")
    func aManifestIsNeverServedToAnotherHike() throws {
        let rendered = UUID()
        let seeded = Self.seedPublishedSet(
            hikeID: rendered,
            coverage: try #require(UnitMercatorRect(bounding: Self.trail))
        )

        #expect(SharedStore.loadBasemapSet(for: rendered) == seeded)
        #expect(SharedStore.loadBasemapSet(for: UUID()) == nil)
    }
}

// MARK: - Geometry that has no business being a map

extension TrailBasemapRendererTests {
    /// Degenerate geometry is allowed to produce a useless picture or no
    /// picture at all. What it is not allowed to do is leave the container in
    /// a state the widget reads as a lie.
    ///
    /// The NaN case reaches the least far of the lot — `UnitMercatorRect`
    /// refuses to bound a non-finite coordinate, so the pass stops at its
    /// first guard — but it stays in the table deliberately: what is asserted
    /// here is the container, and the container has to survive the refusal
    /// landing anywhere in the pass, not only where it lands today.
    @Test("degenerate geometry leaves a store the widget can read", arguments: degenerateShapes)
    func degenerateGeometryLeavesAConsistentStore(
        shape: (name: String, polyline: [SharedTrailSnapshot.CodableCoordinate])
    ) async {
        let hikeID = UUID()
        await TrailBasemapRenderer().refreshIfNeeded(hikeID: hikeID, polyline: shape.polyline)

        Self.expectConsistentStore(for: [hikeID], Comment(rawValue: shape.name))
    }

    /// The same shapes, against a store that already holds a published set
    /// for a different trail — the realistic case, and the only one where the
    /// prune step has anything to do.
    ///
    /// Superseding the previous trail is correct: the container holds one
    /// trail's basemaps at a time, and `pruneBasemapImages(keeping:)` exists
    /// to make sure the one it holds is the current one. What is asserted is
    /// that the handover is all or nothing — a manifest that survived keeps
    /// its images, and one that was replaced takes its images with it.
    @Test(
        "degenerate geometry hands over from another trail cleanly",
        arguments: degenerateShapes
    )
    func degenerateGeometryHandsOverCleanly(
        shape: (name: String, polyline: [SharedTrailSnapshot.CodableCoordinate])
    ) async throws {
        let neighbour = UUID()
        let seeded = Self.seedPublishedSet(
            hikeID: neighbour,
            coverage: try #require(UnitMercatorRect(bounding: Self.trail))
        )
        let subject = UUID()

        await TrailBasemapRenderer().refreshIfNeeded(hikeID: subject, polyline: shape.polyline)

        Self.expectConsistentStore(for: [neighbour, subject], Comment(rawValue: shape.name))

        let neighbourImage = SharedStore.basemapImageData(named: seeded.images[0].fileName)
        if SharedStore.loadBasemapSet(for: neighbour) == nil {
            #expect(
                neighbourImage == nil,
                "\(shape.name) replaced the manifest but left the superseded image on disk"
            )
        } else {
            #expect(
                neighbourImage == Self.imageBytes,
                "\(shape.name) kept the manifest but deleted the image it points at"
            )
        }
    }
}

// MARK: - Overlap

extension TrailBasemapRendererTests {
    /// A user flicking through a list changes the selection faster than four
    /// network snapshots complete, so passes overlap by design. The renderer
    /// promises the store survives that, not that a particular pass wins:
    /// each one suspends at every snapshot, and an actor gives mutual
    /// exclusion but no ordering across those suspensions. Asserting a winner
    /// here would be asserting a scheduling accident.
    @Test("overlapping refreshes never leave the store half-written")
    func overlappingRefreshesLeaveAConsistentStore() async {
        let renderer = TrailBasemapRenderer()
        let hikeIDs = (0..<4).map { _ in UUID() }

        await withTaskGroup(of: Void.self) { group in
            for (offset, hikeID) in hikeIDs.enumerated() {
                group.addTask {
                    await renderer.refreshIfNeeded(
                        hikeID: hikeID,
                        polyline: Self.trail.map { point in
                            .init(
                                latitude: point.latitude + Double(offset) / 100,
                                longitude: point.longitude
                            )
                        }
                    )
                }
            }
            group.addTask { await renderer.invalidate() }
        }

        Self.expectConsistentStore(for: hikeIDs, "after an interrupted burst")
    }

    /// The deselect path in `BackgroundTrailTracker`: a render finishes, and
    /// the trail it was for is cleared straight afterwards. Awaiting the
    /// render first is what makes this the sequential case rather than the
    /// racing one above — here the store really must end up empty.
    @Test("a completed render is still dropped by a later invalidate")
    func aCompletedRenderIsStillDroppedByInvalidate() async {
        let renderer = TrailBasemapRenderer()
        let hikeID = UUID()

        await renderer.refreshIfNeeded(hikeID: hikeID, polyline: Self.trail)
        await renderer.invalidate()

        #expect(SharedStore.loadBasemapSet(for: hikeID) == nil)
        #expect(Self.Container.fileNames.isEmpty)
    }
}

// MARK: - Isolation

extension TrailBasemapRendererTests {
    /// Four snapshots, four JPEG encodes and a handful of container writes,
    /// none of which may happen on the main thread — the renderer is called
    /// from `BackgroundTrailTracker`, which is main-actor isolated, so the
    /// only thing keeping this work off the UI thread is the renderer having
    /// an executor of its own.
    ///
    /// Asserting that the declaration says `actor` would prove nothing a
    /// reader can't see; this runs a body *on the renderer's executor* and
    /// asks the thread where it landed. A custom `unownedExecutor` pinning it
    /// to `MainActor.sharedUnownedExecutor` — the shape a "fix" for a
    /// main-actor warning takes — compiles fine and turns this red.
    @Test("the renderer's own executor is not the main thread")
    func rendererDoesNotRunOnTheMainThread() async {
        #expect(pthread_main_np() != 0, "the test itself is main-actor isolated")

        let onMain = await runsOnMainThread(on: TrailBasemapRenderer())

        #expect(!onMain)
    }
}

// MARK: - Render scale

/// `renderScale` was a claim rather than a behaviour for as long as it
/// existed: `MKMapSnapshotter` ignores every scale knob it offers and returns
/// the device's own, so the images that reached the App Group were 960×960 and
/// 1140×540 on a 3× phone while the constant asked for 640×640 and 760×360 —
/// 2.25× the bytes to decode, inside the one process the renderer's header
/// says cannot recover from running out.
///
/// `encode` resamples now, and these are what stop the next OS release quietly
/// undoing it. They avoid the network entirely by going at `encode` directly
/// with an image built at a chosen scale, which is also the only way anything
/// asserts the pixel dimensions a manifest records.
extension TrailBasemapRendererTests {
    /// An opaque image of `size` points at `scale`, standing in for what the
    /// snapshotter returns. Two tones rather than one so the JPEG encoder has
    /// something to do.
    @MainActor
    static func deviceScaleImage(size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
    }

    /// Pixel dimensions read out of encoded bytes, so what is asserted is what
    /// a decoder will find in the file rather than what the struct claims.
    static func pixelSize(ofJPEG data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width: width, height: height)
    }

    nonisolated static let deviceScales: [CGFloat] = [2, 3]

    @Test("the intended pixel size is the point size at the renderer's scale")
    func intendedPixelSizeMatchesTheVariant() {
        #expect(TrailBasemapRenderer.intendedPixelSize(for: .square) == Self.expectedSquarePixels)
        #expect(TrailBasemapRenderer.intendedPixelSize(for: .wide) == Self.expectedWidePixels)
    }

    /// The fix itself, at both the scale that needed it and the scale that
    /// didn't. A 2× device already produced the intended size and must come
    /// through untouched; a 3× device is the case that was silently oversized.
    @Test(
        "an image at the device's own scale is written at the renderer's scale",
        arguments: TrailBasemapVariant.allCases, deviceScales
    )
    @MainActor
    func encodeResamplesToTheIntendedScale(variant: TrailBasemapVariant, deviceScale: CGFloat) throws {
        let source = Self.deviceScaleImage(size: variant.pointSize, scale: deviceScale)
        let intended = TrailBasemapRenderer.intendedPixelSize(for: variant)
        let label = "\(variant.rawValue) at \(deviceScale)×"

        let encoded = try #require(TrailBasemapRenderer.encode(source), Comment(rawValue: label))

        #expect(encoded.pixelWidth == intended.width, "\(label) recorded the wrong width")
        #expect(encoded.pixelHeight == intended.height, "\(label) recorded the wrong height")

        let onDisk = try #require(Self.pixelSize(ofJPEG: encoded.data), Comment(rawValue: label))
        #expect(onDisk.width == intended.width, "\(label) encoded the wrong width")
        #expect(onDisk.height == intended.height, "\(label) encoded the wrong height")
    }

    /// The saving is the point, so it is measured rather than inferred from
    /// the dimensions. Bounded loosely on purpose: what a JPEG encoder does
    /// with a given picture is not this suite's business, and a tight bound
    /// here would fail on a future encoder without anything being wrong.
    @Test("resampling actually shrinks what reaches the App Group")
    @MainActor
    func resamplingShrinksTheEncodedImage() throws {
        let variant = TrailBasemapVariant.square
        let native = try #require(
            Self.deviceScaleImage(size: variant.pointSize, scale: 3).jpegData(compressionQuality: 0.9)
        )
        let resampled = try #require(
            TrailBasemapRenderer.encode(Self.deviceScaleImage(size: variant.pointSize, scale: 3))
        )

        #expect(resampled.data.count < native.count)
    }

    /// The resample is UIKit drawing on a pipeline that must not touch the
    /// main thread — `encode` is reached from inside
    /// `withTaskExecutorPreference`, so this is where it really runs. A UIKit
    /// call that needed the main thread would fail here rather than in the
    /// field.
    @Test("encoding, and so the resample, works off the main thread")
    func encodeWorksOffTheMainThread() async throws {
        let variant = TrailBasemapVariant.square
        let source = Self.deviceScaleImage(size: variant.pointSize, scale: 3)

        let outcome = await Task.detached {
            (wasMain: pthread_main_np() != 0, encoded: TrailBasemapRenderer.encode(source))
        }.value

        #expect(!outcome.wasMain, "the probe itself ran on the main thread and proves nothing")
        let encoded = try #require(outcome.encoded)
        let intended = TrailBasemapRenderer.intendedPixelSize(for: variant)
        #expect(encoded.pixelWidth == intended.width)
        #expect(encoded.pixelHeight == intended.height)
    }

    /// A manifest written before the resample existed records the device's own
    /// scale. The short-circuit has to treat that as work still to do, or a
    /// walker who keeps one trail selected keeps the oversized images for as
    /// long as they keep it selected.
    @Test("a manifest recorded at the device's scale is not accepted as done")
    func anOversizedManifestIsNotAtIntendedScale() throws {
        let atIntended = try Self.basemapSet(scale: 2)
        let oversized = try Self.basemapSet(scale: 3)

        #expect(TrailBasemapRenderer.isAtIntendedScale(atIntended))
        #expect(!TrailBasemapRenderer.isAtIntendedScale(oversized))
    }

    /// One oversized image among correct ones still has to re-render: the
    /// widget picks per appearance and shape, so the one it lands on is not
    /// this renderer's to predict.
    @Test("one oversized image is enough to make the whole manifest stale")
    func oneOversizedImageMakesTheSetStale() throws {
        var mixed = try Self.basemapSet(scale: 2)
        mixed.images[0].pixelWidth *= 2
        mixed.images[0].pixelHeight *= 2

        #expect(!TrailBasemapRenderer.isAtIntendedScale(mixed))
    }

    /// A manifest as the renderer would have written it on a device of the
    /// given scale — every variant and appearance, since the widget picks
    /// among them and one wrong entry is one wrong widget.
    static func basemapSet(scale: CGFloat) throws -> TrailBasemapSet {
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        return TrailBasemapSet(
            hikeID: UUID(),
            coverage: coverage,
            images: TrailBasemapVariant.allCases.flatMap { variant in
                TrailBasemapAppearance.allCases.map { appearance in
                    TrailBasemap(
                        fileName: "\(variant.rawValue)-\(appearance.rawValue).jpg",
                        variant: variant,
                        appearance: appearance,
                        pixelWidth: Int(variant.pointSize.width * scale),
                        pixelHeight: Int(variant.pointSize.height * scale),
                        visibleRect: coverage
                    )
                }
            }
        )
    }
}
