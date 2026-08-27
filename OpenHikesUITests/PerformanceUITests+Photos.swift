//
//  PerformanceUITests+Photos.swift
//  OpenHikesUITests
//
//  The gallery scenario, in its own file because it is the one scenario that
//  needs the app's help to exist.
//
//  Every other scenario here drives something a user could drive: a pan, a
//  drag, a walk. A photo cannot be taken that way — the Simulator has no
//  camera and the library picker is a system process automation is not allowed
//  to touch — so the hike arrives with photos already on it, seeded by
//  `--ui-test-seed-photos=N` (see `SeededPhotoFixture`). Only the pixels are
//  invented; the files, the store and the ImageIO decode path underneath are
//  the shipping ones.
//
//  That asymmetry is why this is split out rather than filed with the rest:
//  a scenario that depends on a debug-only launch argument should be obvious
//  about it, not buried among the ones that don't.
//

import XCTest

extension PerformanceUITests {
    /// Enough photos to fill the strip and make it scroll. Every one is a
    /// 12 MP JPEG written to disk by the real store, so this is also what the
    /// scenario spends its first few seconds doing before it can measure
    /// anything.
    private static let seededPhotos = 8
    /// Seeding eight 12 MP JPEGs is slower than anything else in the suite
    /// waits for, so this is the launch timeout rather than the shorter one
    /// the functional tests use.
    private static let photoTimeout: TimeInterval = UITestTimeout.launch

    // MARK: - Gallery

    /// The newest expensive thing in the app, and until this scenario existed
    /// the only feature with no performance number at all.
    ///
    /// A gallery is a render-isolation problem wearing a different hat. Each
    /// tile decodes a 12 MP JPEG on the concurrent executor and then hands an
    /// image back to the main actor, so eight tiles are eight arrivals — and
    /// if any of them lands on a `@State` above the strip, one screen of
    /// photos re-renders the elevation chart, the stats grid and the action
    /// bar eight times over.
    ///
    /// The energy claim underneath it is simpler: a decode is priced per
    /// pixel, and a decode that happens on the main thread is priced twice,
    /// because everything else waits. `assertNoStall` is the assertion that
    /// actually matters here.
    @MainActor
    func testPhotoGalleryStaysInsideTheStrip() {
        let app = launch(
            scenario: "photo-gallery",
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=\(Self.seededPhotos)",
            ]
        )
        awaitImportedHike(in: app)
        openHikeDetail(in: app)

        // Seeding writes eight 12 MP files through the real store, which is
        // slower than an import and finishes after the row appears. Each
        // attachment re-renders the strip, so waiting for the app to go quiet
        // is waiting for the seeding — and it keeps that work out of the
        // measured phases without guessing at a duration.
        settle(in: app)

        // Warmed on the chart rather than on the gallery, and that is not
        // arbitrary: the cost being paid off here is the first hit-test
        // against a newly presented *screen*, which any interaction on it
        // settles. The gallery cannot be the one to do it, because every
        // pixel of it is a button that opens the viewer — warming there would
        // navigate away from the thing about to be measured.
        warmAccessibilityTree(around: element("elevation-chart", in: app), in: app)

        // The gallery sits below the numbers on a screen taller than the
        // sheet, so it has to be brought on screen before there is anything to
        // measure.
        let strip = element("hike-photo-strip", in: app)
        XCTAssertTrue(
            scrollIntoView(strip, in: app),
            "the seeded photos never reached the gallery"
        )
        settle(in: app)

        let scrolling = measurePhase(named: "photo-strip", in: app, seconds: 1) {
            strip.swipeLeft()
            strip.swipeRight()
        }

        // Scrolling the strip decodes thumbnails. What it must not do is
        // anything above the strip: the detail screen's chart and stats have
        // not changed, and the map behind the sheet has not moved.
        assertNoMoreThan(0, of: "OpenHikesViewBody", in: scrolling, phase: "photo-strip")
        assertNoMoreThan(0, of: "MapSheetBody", in: scrolling, phase: "photo-strip")
        assertNoMoreThan(0, of: "MapRouteRebuilt", in: scrolling, phase: "photo-strip")
        assertNoMoreThan(0, of: "HikeDetailPrepared", in: scrolling, phase: "photo-strip")
        // A tile that arrives must redraw its own tile, not the strip around
        // it. One body per scroll is the recycling `ScrollView` asking for
        // tiles it had released; one per *decode* would mean eight.
        assertNoMoreThan(2, of: "HikePhotoSectionBody", in: scrolling, phase: "photo-strip")
        // And none of it on the main thread. This is the whole claim.
        assertNoStall(in: scrolling, phase: "photo-strip")

        let viewing = measurePhase(named: "photo-viewer", in: app, seconds: 1) {
            app.descendants(matching: .button)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "hike-photo-"))
                .firstMatch
                .tap()
        }

        // Opening a photo decodes the full-size image — the single most
        // expensive decode in the app — and it, too, has to stay off the main
        // thread.
        assertAtLeast(1, of: "PhotoImageDecoded", in: viewing, phase: "photo-viewer")
        assertNoStall(in: viewing, phase: "photo-viewer")
        assertNoMoreThan(0, of: "MapRouteRebuilt", in: viewing, phase: "photo-viewer")
        // Pushing the viewer covers the map screen entirely, so nothing out
        // there has anything to redraw. Both of these used to be 1 and 2: the
        // sheet's navigation path was `@State` on the root, and `@State`
        // invalidates its declaring view on every write whether or not the body
        // reads it, which re-ran the sheet's content closure and rebuilt the
        // hike list with it. The path lives on `SheetPresentation` now and the
        // root reads only the coarse flags it actually draws from.
        assertNoMoreThan(0, of: "OpenHikesViewBody", in: viewing, phase: "photo-viewer")
        assertNoMoreThan(0, of: "MapSheetHikesBody", in: viewing, phase: "photo-viewer")
        // One, not zero. `NavigationStack(path:)` reads its binding while the
        // body that contains the stack is being evaluated, so whichever view
        // owns the stack is a reader of the path no matter where the path is
        // stored — moving the stack into a child would relocate this pass, not
        // remove it. `NavigationStackBodyCostTests` pins that floor directly;
        // if SwiftUI ever stops charging for it, lower this rather than
        // restoring the pass.
        assertNoMoreThan(1, of: "MapSheetBody", in: viewing, phase: "photo-viewer")

        let viewer = element("photo-viewer", in: app)
        XCTAssertTrue(viewer.waitForExistence(timeout: Self.photoTimeout))
        let paging = measurePhase(named: "photo-paging", in: app, seconds: 1) {
            viewer.swipeLeft()
        }

        // A page turn is where a gallery's energy cost is actually decided. The
        // pages are a `LazyHStack`, so each turn realises whatever SwiftUI
        // decides is nearby, and every realisation is a 12 MP decode. Budgeted
        // at two — the photo arrived at plus one neighbour prefetched, which is
        // what makes the *next* swipe instant — because three would mean both
        // neighbours are being decoded on every turn, and paging an eight-photo
        // gallery would cost three times what looking at it does.
        assertNoMoreThan(2, of: "PhotoImageDecoded", in: paging, phase: "photo-paging")
        assertNoStall(in: paging, phase: "photo-paging")
        // Paging photos is not a navigation event. The root, the sheet and the
        // hike list are all still behind the viewer and none of them changed.
        assertNoMoreThan(0, of: "OpenHikesViewBody", in: paging, phase: "photo-paging")
        assertNoMoreThan(0, of: "MapSheetHikesBody", in: paging, phase: "photo-paging")
        // What a page turn *does* legitimately cost is the viewer's own body:
        // the title, the caption and the current-photo controls all name the
        // photo being looked at.
        //
        // The ratio below it is the one worth watching. `hike.orderedPhotos`
        // is a full sort behind a computed property, and the viewer reads it
        // through six separate accessors — `photos.isEmpty`, `currentIndex`,
        // `current`, `pages`, the title and an `onChange` — none of which look
        // like work at the call site. A sort per read rather than per pass is
        // invisible at eight photos and is O(n log n) string comparisons per
        // swipe at two hundred, so the budget is stated against the body count
        // rather than as a constant.
        assertNoMoreThan(3, of: "PhotoViewerBody", in: paging, phase: "photo-paging")
        assertRatio(
            atMost: 2,
            of: "PhotoOrderComputed",
            per: paging.count(of: "PhotoViewerBody"),
            in: paging
        )
        finish()
    }

}
