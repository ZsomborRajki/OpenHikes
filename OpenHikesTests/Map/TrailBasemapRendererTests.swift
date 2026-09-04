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
//  Three things shape what is asserted below, and they are worth stating
//  rather than discovering.
//
//  `MKMapSnapshotter` remains the production boundary, and no test crosses it.
//  Tests inject the render's *result* at that boundary, so neither an
//  assertion nor a completion time depends on a network service. Two things
//  keep that true rather than merely intended: the suite's `.timeLimit`, which
//  is the real assertion for it — a reintroduced live snapshot does not fail a
//  `#expect`, it costs four framework timeouts per pass and stays green — and
//  ``unusedRenderer(sourceLocation:)``, which is what the tests that must not
//  render at all are handed. A `nil`-returning stub would not do for those:
//  refusing to render leaves the store untouched, which is exactly what they
//  assert, so they would pass while the guard they exist for was broken.
//  `TrailBasemapRendererTests+RenderScale.swift` still goes through the real
//  JPEG path, which is local work and needs no network.
//
//  Ordering is not a promise an actor makes. `TrailBasemapRenderer`
//  serializes, it does not queue: a pass suspends at every snapshot, and
//  another call can enter in that gap. So a burst is asserted through the
//  invariant its bookkeeping exists to preserve — a manifest always has its
//  images, and no image outlives the manifest naming it — never through which
//  caller won. See `overlappingRefreshesLeaveAConsistentStore`; the
//  superseding tests beside it pin what a *single*, scripted interleaving is
//  allowed to do, which is only assertable because the boundary is injected.
//
//  Isolation is asserted at the executor, not at the type. See
//  `rendererDoesNotRunOnTheMainThread`.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Synchronization
import Testing
import UIKit

/// Runs on `renderer`'s own executor rather than the caller's, which is what
/// makes it a measurement of the renderer's isolation instead of a
/// restatement of its declaration.
private func runsOnMainThread(on renderer: isolated TrailBasemapRenderer) -> Bool {
    pthread_main_np() != 0
}

/// The `.timeLimit` is not decoration, and it is not about a slow machine.
/// It is the regression test for the defect this suite was rewritten to fix:
/// a live `MKMapSnapshotter` call makes no assertion here fail, it just waits
/// out four framework timeouts per pass — 570 seconds for a green run, against
/// a 30-minute CI job budget. A minute is several orders of magnitude above
/// what the whole suite costs with the boundary injected, and far below what
/// one reintroduced round-trip costs.
@Suite(
    "Trail basemap rendering",
    .serialized,
    .timeLimit(.minutes(1)),
    .enabled(if: SharedStoreProbe.isAvailable)
)
final class TrailBasemapRendererTests {
    /// The pixel dimensions `renderScale` promises, written out rather than
    /// derived from `pointSize × renderScale` — a derived expectation would
    /// restate the implementation and pass whatever it did.
    nonisolated static let expectedSquarePixels = (width: 640, height: 640)
    nonisolated static let expectedWidePixels = (width: 760, height: 360)

    /// One image the widget can ask for, as the pair that identifies it. A
    /// named type rather than a tuple so a published set can be compared as a
    /// `Set` — which is what makes "every combination, once" assertable
    /// without depending on the order the render loop happens to walk in.
    struct Image: Hashable {
        let variant: TrailBasemapVariant
        let appearance: TrailBasemapAppearance

        /// `nonisolated` because the target defaults to `MainActor` isolation
        /// and ``everyImage`` is built outside it, like every other fixture
        /// here.
        nonisolated init(_ variant: TrailBasemapVariant, _ appearance: TrailBasemapAppearance) {
            self.variant = variant
            self.appearance = appearance
        }
    }

    /// Every combination a manifest has to carry. Derived from the two
    /// enumerations on purpose, unlike the pixel constants above: this one is
    /// a statement about the widget's needs — it picks by shape and by
    /// appearance — and adding a case to either enumeration is meant to widen
    /// what is asserted rather than leave a combination silently unchecked.
    nonisolated static let everyImage: [Image] = TrailBasemapVariant.allCases.flatMap { variant in
        TrailBasemapAppearance.allCases.map { Image(variant, $0) }
    }

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

    /// What a snapshot would have produced, had one been taken. The bytes name
    /// the image they stand for so a manifest entry can be traced back to the
    /// call that produced it — see ``renderedBytes(for:)``, which is how the
    /// assertions spell the same thing.
    ///
    /// The pixel dimensions come from the renderer's own
    /// `intendedPixelSize(for:)` for one reason only: the short-circuit in
    /// `refreshIfNeeded` consults `isAtIntendedScale`, so a stub returning
    /// anything else would publish a manifest the renderer immediately treats
    /// as stale. What is *asserted* about those dimensions is written out at
    /// ``expectedSquarePixels`` instead, so nothing here decides its own
    /// expectation.
    nonisolated static func rendered(
        for input: TrailBasemapRenderer.RenderInput
    ) -> TrailBasemapRenderer.Rendered {
        let pixels = TrailBasemapRenderer.intendedPixelSize(for: input.variant)
        return TrailBasemapRenderer.Rendered(
            data: renderedBytes(for: input.variant, input.appearance),
            pixelWidth: pixels.width,
            pixelHeight: pixels.height,
            visibleRect: input.unitRect
        )
    }

    /// The bytes ``rendered(for:)`` writes for one image, named rather than
    /// spelled twice — an assertion that built the string itself would agree
    /// with a renderer that had put the wrong file's bytes on disk.
    nonisolated static func renderedBytes(
        for variant: TrailBasemapVariant,
        _ appearance: TrailBasemapAppearance
    ) -> Data {
        Data("\(variant.rawValue)-\(appearance.rawValue)".utf8)
    }

    /// A renderer whose snapshots always fail, for the tests whose subject is
    /// what the *store* looks like afterwards rather than whether a render was
    /// attempted. Offline is a real state, so this is production behaviour and
    /// not only a convenience.
    nonisolated static func failingRenderer() -> TrailBasemapRenderer {
        TrailBasemapRenderer { _ in nil }
    }

    /// A renderer that must never be asked for anything, for the tests that
    /// exist to prove a guard runs *before* the render loop.
    ///
    /// ``failingRenderer()`` cannot serve that purpose. Refusing to render
    /// also leaves the store untouched, which is precisely what those tests
    /// assert, so they would stay green while the guard was gone. This fails
    /// on the attempt, so the assertion is "nothing was rendered" rather than
    /// "nothing survived being rendered".
    ///
    /// It also closes the last routes to a live snapshot. With these two call
    /// sites converted, no test reaches `refreshIfNeeded(hikeID:polyline:)`
    /// through the default initialiser: the remaining `TrailBasemapRenderer()`
    /// calls are `invalidate()` and the executor probe, and neither enters the
    /// render loop. The production initialiser stays exercised, which is the
    /// point of leaving them alone.
    nonisolated static func unusedRenderer(
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> TrailBasemapRenderer {
        TrailBasemapRenderer { input in
            Issue.record(
                "a render reached the snapshot boundary: \(input.variant.rawValue)/\(input.appearance.rawValue)",
                sourceLocation: sourceLocation
            )
            return nil
        }
    }

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
    ///
    /// Internal rather than private only because the overlap tests live in
    /// `TrailBasemapRendererTests+Overlap.swift`; nothing outside this suite
    /// should reach for it.
    enum Container {
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

    private static func basemap(named fileName: String, _ image: Image) -> TrailBasemap {
        let pixels = TrailBasemapRenderer.intendedPixelSize(for: image.variant)
        return TrailBasemap(
            fileName: fileName,
            variant: image.variant,
            appearance: image.appearance,
            pixelWidth: pixels.width,
            pixelHeight: pixels.height,
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
    ///
    /// Every combination by default, because that is what "already done" means
    /// to `refreshIfNeeded`: a manifest short of one is *not* entitled to that
    /// trust, and `partialManifestIsRenderedAgain` seeds one deliberately to
    /// say so.
    @discardableResult private static func seedPublishedSet(
        hikeID: UUID,
        coverage: UnitMercatorRect,
        holding combinations: [Image] = everyImage,
        generatedAt: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> TrailBasemapSet {
        let images = combinations.map { image in
            basemap(
                named: "\(hikeID.uuidString)-seed-\(image.variant.rawValue)-\(image.appearance.rawValue).jpg",
                image
            )
        }
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
    static func expectConsistentStore(
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
    ///
    /// Through ``unusedRenderer(sourceLocation:)`` so that "renders nothing"
    /// is what is asserted. The store assertions below hold whether the guard
    /// ran or a render simply failed, and only one of those is the contract.
    @Test("a polyline of fewer than two points renders nothing", arguments: [0, 1])
    func tooFewPointsRenderNothing(pointCount: Int) async throws {
        let hikeID = UUID()
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        let seeded = Self.seedPublishedSet(hikeID: hikeID, coverage: coverage)

        await Self.unusedRenderer().refreshIfNeeded(
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
    ///
    /// ``unusedRenderer(sourceLocation:)`` rather than a default renderer, for
    /// two reasons that point the same way. The store assertions below cannot
    /// tell a short-circuit from a render that was taken and then found to
    /// change nothing, so without it this test passes on a broken
    /// short-circuit. And a default renderer would *take* those four
    /// snapshots the moment the short-circuit regressed, which is this suite's
    /// old failure mode: the one test whose subject is the cost of a redundant
    /// render, paying it.
    @Test("a trail the stored manifest already frames is left exactly as it is")
    func coveredTrailIsLeftExactlyAsItIs() async throws {
        let hikeID = UUID()
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        let seeded = Self.seedPublishedSet(hikeID: hikeID, coverage: coverage)

        await Self.unusedRenderer().refreshIfNeeded(hikeID: hikeID, polyline: Self.trail)

        #expect(SharedStore.loadBasemapSet(for: hikeID) == seeded)
        #expect(Self.Container.fileNames == Set(seeded.images.map(\.fileName)))
        #expect(SharedStore.basemapImageData(named: seeded.images[0].fileName) == Self.imageBytes)
    }

    /// The other three questions the short-circuit asks — same coverage, files
    /// on disk, intended scale — are all asked of the manifest's *own* images,
    /// so a manifest holding three of four answers yes to every one of them.
    /// Without a fourth question, re-selecting the same trail returns before
    /// rendering anything and the missing combination draws the line glyph
    /// until the trail's geometry changes or `invalidate()` runs.
    @Test("a manifest missing a combination is rendered again rather than trusted")
    func partialManifestIsRenderedAgain() async throws {
        let hikeID = UUID()
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        Self.seedPublishedSet(
            hikeID: hikeID,
            coverage: coverage,
            holding: Self.everyImage.filter { $0.appearance == .light }
        )
        let renderer = TrailBasemapRenderer { Self.rendered(for: $0) }

        await renderer.refreshIfNeeded(hikeID: hikeID, polyline: Self.trail)

        let published = try #require(SharedStore.loadBasemapSet(for: hikeID))
        #expect(
            Set(published.images.map { Self.Image($0.variant, $0.appearance) })
                == Set(Self.everyImage)
        )
        Self.expectConsistentStore(for: [hikeID], "after re-rendering a partial manifest")
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

// MARK: - Deterministic render outcomes

extension TrailBasemapRendererTests {
    /// The interior of a successful pass, which nothing asserted for as long
    /// as a render meant a live snapshot: that every image the widget can ask
    /// for is written, that each one's bytes reach the file its manifest entry
    /// names, and that the region and pixel dimensions recorded are the ones
    /// the render reported rather than the ones the renderer assumed.
    ///
    /// The pixel expectations are ``expectedSquarePixels`` and
    /// ``expectedWidePixels`` rather than `intendedPixelSize(for:)`, which is
    /// what the stub was built from: comparing the two would restate the
    /// implementation on both sides and agree with whatever it did.
    @Test("a successful render publishes every variant with controlled metadata")
    func successfulRenderPublishesControlledMetadata() async throws {
        let hikeID = UUID()
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        let renderer = TrailBasemapRenderer { input in Self.rendered(for: input) }

        await renderer.refreshIfNeeded(hikeID: hikeID, polyline: Self.trail)

        let published = try #require(SharedStore.loadBasemapSet(for: hikeID))
        #expect(published.coverage == coverage)
        // Every shape the widget can be laid out at, in both appearances: the
        // set the widget picks from, so a missing combination is a fallback to
        // the line glyph on some device.
        #expect(published.images.count == Self.everyImage.count)
        #expect(Set(published.images.map { Self.Image($0.variant, $0.appearance) }) == Set(Self.everyImage))
        for image in published.images {
            let expectedPixels = image.variant == .square ? Self.expectedSquarePixels : Self.expectedWidePixels
            let label = "\(image.variant.rawValue)/\(image.appearance.rawValue)"
            #expect(
                image.visibleRect == coverage.framed(toAspectRatio: image.variant.aspectRatio),
                "\(label) recorded a region the render did not report"
            )
            #expect(image.pixelWidth == expectedPixels.width, "\(label) recorded the wrong width")
            #expect(image.pixelHeight == expectedPixels.height, "\(label) recorded the wrong height")
            #expect(
                SharedStore.basemapImageData(named: image.fileName)
                    == Self.renderedBytes(for: image.variant, image.appearance),
                "\(label) points at another image's bytes"
            )
        }
        Self.expectConsistentStore(for: [hikeID], "after a successful render")
    }

    /// The widget is told to redraw *through the recording gate*, not by
    /// reaching for `WidgetCenter` directly.
    ///
    /// That distinction is the whole of `TrailWidgetReload`: a live recording
    /// owns the widget, so the images this pass just published are not what it
    /// is drawing, and the redraw waits for the walk to end. `WidgetCenter`
    /// neither reports a reload nor replays one, so the injected sink is the
    /// only way to tell the two apart — a pass that went back to calling
    /// `WidgetCenter` itself would publish exactly the same manifest and leave
    /// every other test here green.
    ///
    /// The refusal half is asserted where the recording payload can be written
    /// without racing this suite's own App Group files — see
    /// `WidgetFeedBudgetTests`, which drives the tracker's two call sites.
    @Test("a published render asks for the redraw through the recording gate")
    func publishedRenderAsksThroughTheGate() async {
        let reloads = WidgetReloadSpy()
        let renderer = TrailBasemapRenderer(
            render: { input in Self.rendered(for: input) },
            widgetReload: reloads.reload
        )

        await renderer.refreshIfNeeded(hikeID: UUID(), polyline: Self.trail)

        #expect(reloads.count == 1, "a pass that published has to ask for the widget to be redrawn")
    }

    /// Offline, or a background launch with no network — the state the whole
    /// suite used to run in by accident, and the one the renderer's own
    /// comment says must leave the previous trail's pictures alone. A widget
    /// only ever pairs a set with the hike it was rendered for, so a stale set
    /// is harmless where a cleared one is a blank map.
    ///
    /// This is also the timing regression from the issue, and the assertion
    /// for that half is the suite's `.timeLimit` rather than anything here: a
    /// forced failure has to *return*, not wait out `MKMapSnapshotter`.
    @Test("forced snapshot failures return without replacing the previous set")
    func failedRenderLeavesThePreviousSetIntact() async throws {
        let previousHike = UUID()
        let seeded = Self.seedPublishedSet(
            hikeID: previousHike,
            coverage: try #require(UnitMercatorRect(bounding: Self.trail))
        )
        let subject = UUID()

        await Self.failingRenderer().refreshIfNeeded(hikeID: subject, polyline: Self.trail)

        #expect(SharedStore.loadBasemapSet(for: previousHike) == seeded)
        #expect(SharedStore.loadBasemapSet(for: subject) == nil)
        #expect(Self.Container.fileNames == Set(seeded.images.map(\.fileName)))
    }

    /// A pass where some snapshots land and others don't — one appearance
    /// failing while the other succeeds is the shape a flaky connection
    /// actually takes, since the four renders are four separate requests.
    ///
    /// The policy is publish-what-landed, and it is a real decision rather
    /// than an oversight in the loop: the alternative is to discard four
    /// snapshots because one of them failed, and a widget that has the light
    /// image it is currently being asked for draws a map, while one holding
    /// nothing draws the line glyph. The cost is that the *other* appearance
    /// falls back until the next selection change re-renders — which is the
    /// same fallback an all-or-nothing policy would have given both.
    ///
    /// So an incomplete set reaching disk is correct here. What must still
    /// hold is that it is an *honest* incomplete set: every entry it
    /// advertises has its bytes, and the trail it superseded took its own
    /// images with it.
    @Test("a partly failed render publishes the images that did land")
    func partialSuccessPublishesTheImagesThatLanded() async throws {
        let previousHike = UUID()
        Self.seedPublishedSet(
            hikeID: previousHike,
            coverage: try #require(UnitMercatorRect(bounding: Self.trail))
        )
        let subject = UUID()
        let renderer = TrailBasemapRenderer { input in
            input.appearance == .light ? Self.rendered(for: input) : nil
        }

        await renderer.refreshIfNeeded(hikeID: subject, polyline: Self.trail)

        let published = try #require(SharedStore.loadBasemapSet(for: subject))
        #expect(
            Set(published.images.map { Self.Image($0.variant, $0.appearance) })
                == Set(Self.everyImage.filter { $0.appearance == .light })
        )
        #expect(SharedStore.loadBasemapSet(for: previousHike) == nil)
        Self.expectConsistentStore(for: [previousHike, subject], "after partial success")
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
        await Self.failingRenderer().refreshIfNeeded(hikeID: hikeID, polyline: shape.polyline)

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

        await Self.failingRenderer().refreshIfNeeded(hikeID: subject, polyline: shape.polyline)

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

    /// The antimeridian shape survives the pass, above — this is the other
    /// half of it: that what the pass would render is the trail rather than
    /// the ocean it sits in.
    ///
    /// Asserted on the region because this is the bounding and framing
    /// contract rather than MapKit's raster output. Getting it wrong asks
    /// `MKMapSnapshotter` for nearly the entire world and leaves the widget
    /// drawing a 1 km walk across two pixels of the Pacific.
    @Test("a trail across the antimeridian is framed at walking scale")
    func antimeridianCoverageStaysTight() throws {
        let coverage = try #require(UnitMercatorRect(bounding: Self.antimeridian))
        let metersPerUnit = Mercator.metersPerUnit(atLatitude: coverage.centerLatitude)
        // The trail is ~1.5 km of longitude. Anything approaching a world
        // (40,000 km) is the bug this guards.
        #expect(coverage.width * metersPerUnit < 10_000, "the box came out \(coverage.width) of the world wide")

        for variant in TrailBasemapVariant.allCases {
            let framed = coverage.framed(toAspectRatio: variant.aspectRatio)
            #expect(
                framed.width * metersPerUnit < 10_000,
                "\(variant.rawValue) was framed \(framed.width) of the world wide"
            )
            for point in Self.antimeridian {
                let normalized = framed.normalizedPoint(latitude: point.latitude, longitude: point.longitude)
                #expect((0...1).contains(normalized.x), "\(variant.rawValue) framed \(point.longitude)° out")
                #expect((0...1).contains(normalized.y), "\(variant.rawValue) framed \(point.latitude)° out")
            }
        }
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
