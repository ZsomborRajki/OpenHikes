//
//  NavigationStackBodyCostTests.swift
//  OpenHikesTests
//
//  "Navigation stack body cost", split out of
//  SheetPresentationIsolationTests.swift so that a file declares one @Suite.
//  That file's header still holds the context the two share.
//

import Foundation
@testable import OpenHikes
import SwiftData
import SwiftUI
import Testing

/// Builds the stack the way `MapSheet` does, and counts the body passes its
/// enclosing view is charged for — and, so that a count that stays put means
/// something, the passes of the screen the stack pushes.
private struct NavigationStackProbe: View {
    let counter: BodyCounter
    let pushedCounter: BodyCounter
    let presentation: SheetPresentation

    var body: some View {
        counter.record()
        return NavigationStack(path: presentation.pathBinding) {
            Text(verbatim: "root")
                .navigationDestination(for: SheetRoute.self) { _ in
                    PushedProbe(counter: pushedCounter)
                }
        }
    }
}

/// The screen a push puts up, which counts that it was drawn.
private struct PushedProbe: View {
    let counter: BodyCounter

    var body: some View {
        counter.record()
        return Text(verbatim: "pushed")
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

    /// What a push actually costs the view that holds the stack: nothing.
    ///
    /// This expected one pass per push, put down to the stack reading the
    /// binding it was handed while its enclosing body was being evaluated. It
    /// was not the stack. `Binding(get:set:)` calls its getter as it is made,
    /// and ``SheetPresentation/pathBinding`` was first made inside this body,
    /// so that one read of the path made the body a reader of it. Made with
    /// that read untracked, the body reads nothing the stack changes.
    /// Measured against the old binding: a push and a pop cost this body one
    /// pass between them.
    ///
    /// The pushed screen is counted as the precondition rather than as decor:
    /// the path is written from outside the stack, the way a widget tap or a
    /// saved recording writes it, and the screen appearing is the stack
    /// hearing about it through a read of its own. Both directions, so a
    /// reader that lasted past one change is caught as well as one that
    /// does not.
    @Test("a push and a pop cost the view that holds the stack nothing")
    func pushingCostsTheEnclosingBodyNothing() async throws {
        let presentation = SheetPresentation(detent: .large)
        let counter = BodyCounter()
        let pushedCounter = BodyCounter()
        let window = try host(
            NavigationStackProbe(counter: counter, pushedCounter: pushedCounter, presentation: presentation)
        )
        defer { dismiss(window) }
        await settle(window)

        let before = counter.count
        #expect(before > 0, "precondition: the probe rendered at all")

        presentation.path = [.recording]
        await settle(window)
        #expect(pushedCounter.count > 0, "precondition: the stack pushed the screen the path asked for")

        presentation.path = []
        await settle(window)

        #expect(
            counter.count == before,
            "the stack reads the path through the binding in its own update, so neither a push nor a pop is a pass here"
        )
    }
}
