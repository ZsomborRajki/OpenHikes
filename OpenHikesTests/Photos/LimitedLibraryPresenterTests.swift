//
//  LimitedLibraryPresenterTests.swift
//  OpenHikesTests
//
//  The one place this app hands UIKit a view controller and asks it to present
//  something, and the only part of the limited-access flow whose failure is
//  completely silent.
//
//  `PHPhotoLibrary.presentLimitedLibraryPicker(from:)` asked to present from
//  the wrong controller does not throw, does not return an error and does not
//  put anything on screen — it logs a line and, fatally for the flow above it,
//  never calls its completion handler. Every claim in
//  ``LimitedLibraryPresenter``'s header is therefore a claim about a failure
//  that would look exactly like a button doing nothing: that a controller
//  outside a window cannot present, that a controller already presenting
//  cannot present again, and that the anchor which ends up in the screen's own
//  hierarchy is neither of those.
//
//  Those claims were reasoned from the sheet-presentation rule rather than
//  observed. This file observes them, against a real `UIWindow` built from the
//  host app's own scene — the pattern `RecordingPhotoPinTests` established,
//  and for the reason stated there: `UIWindow(frame:)` is deprecated and a
//  scene-less window never lays out, so a hierarchy hosted in one would report
//  `view.window == nil` and every assertion here would pass vacuously.
//

import Foundation
@testable import OpenHikes
import SwiftUI
import Testing
import UIKit

@Suite("Limited library presenter")
@MainActor
struct LimitedLibraryPresenterTests {
    private static let settleBudget = Duration.seconds(5)

    @Test("a presenter no screen has claimed has nothing to present from")
    func noAnchorMeansNoPresenter() {
        #expect(LimitedLibraryPresenter().presentingViewController == nil)
    }

    /// The refusal the whole flow rests on. A controller that is not in a
    /// window is not a presentation context, and UIKit's answer to being asked
    /// anyway is silence — so this has to be caught here, where it is a `nil`
    /// that can be asserted, rather than upstream where it is an `await` that
    /// never returns.
    ///
    /// This is also the case that a plain "did we remember the anchor" check
    /// would miss: `presenter.anchor` is non-`nil` throughout.
    @Test("an anchor that is not on screen is not a presenter")
    func anAnchorOutsideAWindowIsNotAPresenter() {
        let presenter = LimitedLibraryPresenter()
        let orphan = UIViewController()
        presenter.anchor = orphan

        #expect(orphan.view.window == nil)
        #expect(presenter.anchor === orphan)
        #expect(
            presenter.presentingViewController == nil,
            """
            a controller outside a window silently declines to present, and \
            the picker's completion handler then never arrives
            """
        )
    }

    @Test("an anchor on screen is the controller the picker is raised from")
    func anAnchorInAWindowIsThePresenter() throws {
        let host = try Host()
        defer { host.dismiss() }
        let presenter = LimitedLibraryPresenter()
        presenter.anchor = host.root

        #expect(presenter.presentingViewController === host.root)
    }

    /// The defensive walk in `presentingViewController`. Nothing in the app
    /// presents above the anchor today, which is exactly why this is worth
    /// pinning: if something ever does, the symptom is not a misplaced modal
    /// but a dead button, and no other test in the tree would see it.
    ///
    /// It also pins the order of the two checks inside that property, which is
    /// not the obvious one and was got wrong first: a `.fullScreen`
    /// presentation removes the *presenting* controller's view from the window
    /// once the transition finishes, so an anchor with a full-screen modal
    /// above it reports `view.window == nil` while being entirely presentable
    /// one step up. Checking the window before walking refuses in precisely
    /// the case the walk exists for. This test failed on that and is the
    /// reason the property walks first.
    @Test(
        "a screen already up above the anchor is presented from, not behind",
        arguments: [UIModalPresentationStyle.fullScreen, .pageSheet]
    )
    func presentationWalksPastWhatIsAlreadyUp(style: UIModalPresentationStyle) async throws {
        let host = try Host()
        defer { host.dismiss() }
        let presenter = LimitedLibraryPresenter()
        presenter.anchor = host.root

        let alreadyUp = UIViewController()
        alreadyUp.modalPresentationStyle = style
        await host.present(alreadyUp, from: host.root)

        #expect(host.root.presentedViewController === alreadyUp)
        #expect(
            presenter.presentingViewController === alreadyUp,
            "presenting from a controller that is already presenting does nothing"
        )
    }

    /// The claim the anchor exists to make, observed end to end: a SwiftUI
    /// screen that has been *presented* — which is where this app's photo
    /// screens live, above a sheet that is never dismissed — resolves to a
    /// controller inside that screen rather than to the window's root. The
    /// root is the obvious substitute and is the wrong one; it is two
    /// presentations deep by the time the picker is wanted, and asking it to
    /// present again is the silent failure above.
    @Test("the anchor modifier resolves to the presented screen, not the root")
    func theAnchorResolvesInsideThePresentedScreen() async throws {
        let host = try Host()
        defer { host.dismiss() }
        let presenter = LimitedLibraryPresenter()

        let screen = UIHostingController(
            rootView: Color.clear.limitedLibraryAnchor(presenter)
        )
        screen.modalPresentationStyle = .fullScreen
        await host.present(screen, from: host.root)
        await host.settle(until: "the anchor to reach the presenter") {
            presenter.presentingViewController != nil
        }

        let resolved = try #require(presenter.presentingViewController)
        #expect(resolved.view.window === host.window, "an anchor off screen cannot present")
        #expect(resolved !== host.root, "the root is already presenting and would decline")
        #expect(
            resolved === screen || resolved.isDescendant(of: screen),
            "the picker has to be raised from inside the screen that asked for it"
        )
        #expect(
            resolved.presentedViewController == nil,
            "the resolved controller must be free to present"
        )
    }

    /// The anchor is weak because the controller belongs to SwiftUI's
    /// representable, which takes it down with the view. Holding it strongly
    /// would keep a dismissed screen's controller — and its whole view
    /// hierarchy — alive for as long as whatever owns the presenter, and would
    /// leave `presentingViewController` answering with a controller that is no
    /// longer anywhere.
    @Test("a presenter does not keep a screen that has gone alive")
    func theAnchorIsHeldWeakly() {
        let presenter = LimitedLibraryPresenter()
        autoreleasepool {
            let transient = UIViewController()
            presenter.anchor = transient
            #expect(presenter.anchor === transient)
        }

        #expect(presenter.anchor == nil)
        #expect(presenter.presentingViewController == nil)
    }

    /// A window built from the host app's own scene, because a scene-less
    /// window never lays out and every `view.window` assertion here would then
    /// be vacuously `nil`.
    @MainActor
    private struct Host {
        private static let width: CGFloat = 390
        private static let height: CGFloat = 844

        let window: UIWindow
        let root: UIViewController

        init() throws {
            let scene = try #require(
                UIApplication.shared.connectedScenes
                    .lazy
                    .compactMap { $0 as? UIWindowScene }
                    .first,
                "app-hosted tests run inside the app, which has a scene"
            )
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
            root = UIViewController()
            root.view.backgroundColor = .clear
            window.rootViewController = root
            window.isHidden = false
            window.layoutIfNeeded()
        }

        /// Waits on the presentation itself rather than on a duration:
        /// `present` calls back when the transition has finished, which is the
        /// positive effect the assertions need.
        func present(_ controller: UIViewController, from presenter: UIViewController) async {
            await withCheckedContinuation { continuation in
                presenter.present(controller, animated: false) {
                    continuation.resume()
                }
            }
        }

        /// Pumps SwiftUI until `condition` holds. Both halves are needed:
        /// a yield never makes a hosted hierarchy lay out, and
        /// `layoutIfNeeded()` never lets the main actor run work a body
        /// scheduled. Waiting on a named effect rather than on a pass count is
        /// the argument ``settleDelegateHop(until:)`` makes.
        func settle(
            until description: Comment,
            sourceLocation: SourceLocation = #_sourceLocation,
            condition: @MainActor () -> Bool
        ) async {
            let deadline = ContinuousClock.now + LimitedLibraryPresenterTests.settleBudget
            while ContinuousClock.now < deadline {
                await Task.yield()
                window.rootViewController?.view.setNeedsLayout()
                window.layoutIfNeeded()
                if condition() { return }
                guard await settlePollTick() else { break }
            }
            Issue.record(
                Comment(rawValue: "Timed out waiting for \(description.rawValue)."),
                sourceLocation: sourceLocation
            )
        }

        /// A hosted window left behind keeps a live hierarchy alive across the
        /// rest of the run, and anything it is presenting with it.
        func dismiss() {
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}

private extension UIViewController {
    func isDescendant(of ancestor: UIViewController) -> Bool {
        var current: UIViewController? = parent
        while let candidate = current {
            if candidate === ancestor { return true }
            current = candidate.parent
        }
        return false
    }
}
