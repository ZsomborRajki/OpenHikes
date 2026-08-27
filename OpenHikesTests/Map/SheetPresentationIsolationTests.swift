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

    /// The "show on map" exception: the viewer collapses the sheet on its way
    /// out, because the user asked to see the very thing the restored height
    /// would cover.
    @Test("show-on-map overrides the remembered height")
    func showOnMapOverridesTheRememberedHeight() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .large)
        presentation.path = [.hike(hike)]
        presentation.path.append(.photo(hike, UUID()))

        presentation.collapseWhenFullHeightScreenPops()
        presentation.path.removeLast()

        #expect(presentation.detent == SheetPresentation.compactDetent)
        #expect(presentation.isCompact)
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
}

/// Builds the stack the way `MapSheet` does, and counts the body passes its
/// enclosing view is charged for.
private struct NavigationStackProbe: View {
    let counter: BodyCounter
    let presentation: SheetPresentation

    var body: some View {
        counter.record()
        return NavigationStack(path: presentation.pathBinding) {
            Text(verbatim: "root")
                .navigationDestination(for: SheetRoute.self) { _ in
                    Text(verbatim: "pushed")
                }
        }
    }
}

@MainActor
@Suite("Navigation stack body cost")
struct NavigationStackBodyCostTests {
    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func settle(_ window: UIWindow) async {
        for _ in 0..<10 {
            await Task.yield()
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
        }
    }

    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// What a push actually costs the view that holds the stack.
    ///
    /// Recorded rather than asserted in one direction, because the number is
    /// SwiftUI's to decide and the app has no way to argue with it: a
    /// `NavigationStack` reads the binding it was given while its enclosing
    /// body is being evaluated, so that body is a reader of the path no matter
    /// where the path is stored. One pass per push is therefore the floor for
    /// `MapSheet`, and the point of ``SheetPresentation`` is everything *above*
    /// it — the root view and the hikes list — which this suite's sibling
    /// covers.
    ///
    /// If a future SwiftUI stops reading the binding eagerly this fails, and
    /// the right response is to delete the expectation rather than to restore
    /// the pass.
    @Test("a push costs the view that holds the stack exactly one body pass")
    func pushingCostsTheEnclosingBodyOnePass() async throws {
        let presentation = SheetPresentation(detent: .large)
        let counter = BodyCounter()
        let window = try host(NavigationStackProbe(counter: counter, presentation: presentation))
        defer { dismiss(window) }
        await settle(window)

        let before = counter.count
        #expect(before > 0, "precondition: the probe rendered at all")

        presentation.path = [.recording]
        await settle(window)

        #expect(
            counter.count == before + 1,
            "the stack reads its binding inside this body, so a push is one pass and never more"
        )
    }
}
