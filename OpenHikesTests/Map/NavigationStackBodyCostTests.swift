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
