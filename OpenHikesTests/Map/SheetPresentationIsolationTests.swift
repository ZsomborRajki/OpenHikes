//
//  SheetPresentationIsolationTests.swift
//  OpenHikesTests
//
//  ``SheetPresentation`` exists because `@State` invalidates the view that
//  declares it whether or not that view's body reads it. The sheet's path and
//  detent were two pieces of `@State` on `OpenHikesView`, so opening a photo
//  from a hike's gallery — three screens into a sheet that covers the map —
//  re-evaluated the root view, the sheet and the list of every hike behind it.
//
//  Moving them into a reference type only helps if the flags published beside
//  them are genuinely coarser than the values they are derived from, which is
//  a claim about Observation rather than about this app: a photo pushed onto a
//  hike changes the path, and must change nothing else. That is what the first
//  suite measures.
//
//  The second one measures the part that is SwiftUI's answer rather than
//  Observation's: whether a `NavigationStack` driven by a binding onto that
//  path makes its *enclosing* body a reader of the path. `MapSheet` is the
//  navigation stack, so the answer decides whether one body pass per push is
//  avoidable or is simply the price of having one.
//

import Foundation
@testable import OpenHikes
import SwiftData
import SwiftUI
import Testing

@MainActor
@Suite("Sheet presentation isolation")
struct SheetPresentationIsolationTests {
    /// The claim the whole type rests on: a push that changes neither where
    /// the sheet rests nor whether something is pushed at all wakes nobody
    /// except the navigation stack.
    @Test("pushing a photo onto a hike wakes the path and none of the flags")
    func pushingAPhotoWakesOnlyThePath() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .large)
        presentation.path = [.hike(hike)]

        let pathCounter = ObservationCounter { _ = presentation.path }
        let flagCounter = ObservationCounter {
            _ = presentation.isCompact
            _ = presentation.isFullHeight
            _ = presentation.isAtMiddleDetent
            _ = presentation.hasPushedScreen
            _ = presentation.isRecordingPresented
        }
        await flagCounter.settle()

        presentation.path.append(.photo(hike, UUID()))
        await pathCounter.settle()

        #expect(pathCounter.count == 1, "precondition: the push really did happen")
        #expect(
            flagCounter.count == 0,
            "a hike and its photo viewer are the same sheet height and the same pushed screen"
        )
    }

    /// And the other half of it: a flag that *should* move still does. A photo
    /// pushed from the middle detent is a real change of height, and the views
    /// reading that flag are meant to hear about it.
    @Test("a photo pushed from the middle detent raises the sheet")
    func pushingAPhotoFromTheMiddleDetentRaisesTheSheet() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.hike(hike)]

        presentation.path.append(.photo(hike, UUID()))

        #expect(presentation.detent == .large)
        #expect(presentation.isFullHeight)
        #expect(presentation.isAtMiddleDetent == false)
    }

    /// Popping the viewer puts the sheet back where the hike was being read,
    /// rather than at a fixed height that throws away the reader's own choice.
    @Test("popping the viewer restores the height the hike was read at")
    func poppingTheViewerRestoresTheHeight() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.hike(hike)]
        presentation.path.append(.photo(hike, UUID()))

        presentation.path.removeLast()

        #expect(presentation.detent == .medium)
        #expect(presentation.hasPushedScreen)
    }

    /// The "show on map" exception: the viewer overrides the remembered height
    /// on its way out, because the user asked to see the very thing the
    /// restored height would cover.
    ///
    /// The middle detent rather than the smallest, which is where this landed
    /// before. The map frames a photograph's pin into the strip above the
    /// middle detent, so a sheet that drops past it leaves the pin in the top
    /// half of a screen whose bottom half is map.
    @Test("show-on-map overrides the remembered height")
    func showOnMapOverridesTheRememberedHeight() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .large)
        presentation.path = [.hike(hike)]
        presentation.path.append(.photo(hike, UUID()))

        presentation.restAtMiddleWhenFullHeightScreenPops()
        presentation.path.removeLast()

        #expect(presentation.detent == .medium)
        #expect(presentation.isCompact == false)
    }

    /// The map draws a live recording differently from a saved hike, and reads
    /// this rather than the path to decide.
    @Test("only the recording screen reports itself as presented")
    func onlyTheRecordingScreenIsRecording() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)

        #expect(presentation.hasPushedScreen == false)
        #expect(presentation.isRecordingPresented == false)

        presentation.path = [.recording]
        #expect(presentation.hasPushedScreen)
        #expect(presentation.isRecordingPresented)

        presentation.path = [.hike(hike)]
        #expect(presentation.isRecordingPresented == false)
    }

    /// The last piece of `OpenHikesView`'s `@State` to move, and the one that
    /// moved the most often.
    ///
    /// The search text was `@State` out there and a `@Binding` in `MapSheet`,
    /// so a keystroke invalidated the root view — the map, the side panel, the
    /// alerts and the `onChange` handlers — for a string none of them draws.
    /// Here the question is Observation's rather than SwiftUI's: a write to
    /// one property of an `@Observable` must reach the readers of *that*
    /// property and nobody else.
    ///
    /// The flags stand in for the root view because they are what it reads of
    /// this object — `layout` through `usesSidePanel`, `isRecordingPresented`
    /// for the map's route selection, `isAtMiddleDetent` in the sheet's
    /// callback. A character typed changes none of them.
    @Test("typing wakes the search field and nothing the root view reads")
    func typingWakesOnlyTheSearchReaders() async {
        let presentation = SheetPresentation(detent: .medium)

        let searchCounter = ObservationCounter { _ = presentation.searchText }
        let rootCounter = ObservationCounter {
            _ = presentation.layout
            _ = presentation.isCompact
            _ = presentation.isFullHeight
            _ = presentation.isAtMiddleDetent
            _ = presentation.hasPushedScreen
            _ = presentation.isRecordingPresented
        }
        await rootCounter.settle()

        presentation.searchText = "Thu"
        await searchCounter.settle()

        #expect(searchCounter.count == 1, "precondition: the keystroke really did land")
        #expect(
            rootCounter.count == 0,
            "the root view draws no character of the query, so it must not be woken by one"
        )
    }

    /// The structural half, and the one that fails if somebody puts it back.
    ///
    /// `@State` invalidates its declaring view whether or not the body reads
    /// it, so *where the property is declared* is the entire fix — a fact
    /// about the type, visible without rendering anything. `MapSheet` reaches
    /// the text through ``SheetPresentation`` now, and stores no binding onto
    /// it; a re-added `@Binding var searchText` would show up here.
    @Test("the sheet stores no binding onto the query")
    func theSheetStoresNoSearchBinding() {
        let sheet = MapSheet(
            selectedHike: .constant(nil),
            presentation: SheetPresentation(detent: .large),
            highlight: RouteHighlight(),
            walkHighlight: WalkHighlight(),
            mapController: MapController(),
            photoCapture: PhotoCaptureController(),
            photoPins: PhotoMapPinController()
        )
        let storesStringBinding = Mirror(reflecting: sheet).children.contains { child in
            String(describing: type(of: child.value)) == "Binding<String>"
        }
        #expect(
            !storesStringBinding,
            "the query lives on the presentation object, not in the view hierarchy above it"
        )
    }
}
