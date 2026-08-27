//
//  LimitedLibraryPresenter.swift
//  OpenHikes
//
//  The one modal in this app UIKit has to put on screen itself, and the view
//  controller it is raised from.
//
//  `PHPhotoLibrary.presentLimitedLibraryPicker(from:)` takes a
//  `UIViewController`, and SwiftUI hands none out. The obvious substitute —
//  the window's `rootViewController` — is the wrong one, and wrong in exactly
//  the way this app has already been bitten by. OpenHikes keeps its bottom
//  sheet up permanently and presents the photo screens from inside it, so by
//  the time this picker is wanted the root controller is two presentations
//  deep. Asking a controller that is already presenting to present again does
//  nothing but write a line to the console — and since the picker's completion
//  handler is then never called, the `await` waiting on it never returns. A
//  button that does nothing, and a screen stuck behind it.
//
//  So the presenter is resolved from inside the screen that asked, through an
//  invisible view controller placed in that screen's own hierarchy by
//  ``SwiftUICore/View/limitedLibraryAnchor(_:)``. Nothing is presented above
//  that one, and UIKit draws the picker over everything regardless of how deep
//  in the stack it was raised from.
//
//  The same shape would serve any other UIKit presentation this app grows.
//  It is deliberately not general yet: one caller is not a pattern, and the
//  thing worth stating here is *which* controller is correct rather than how
//  to reuse it.
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Where a UIKit modal raised from inside a SwiftUI sheet is presented from.
///
/// Handed to ``PhotoLibraryReading/presentLimitedLibraryPicker(from:)`` rather
/// than resolved inside it, so the flow can be driven from a test that has no
/// screen at all: a presenter with no anchor presents nothing and says so.
@MainActor
final class LimitedLibraryPresenter {
    #if os(iOS)
    /// Set by the anchor while it is on screen.
    ///
    /// Weak because the controller belongs to SwiftUI's representable, which
    /// takes it down with the view. A strong reference would keep a dismissed
    /// screen's controller alive for as long as whatever holds this presenter.
    weak var anchor: UIViewController?

    /// The controller a modal can actually be presented from, or `nil` when
    /// there is no screen to present over.
    ///
    /// Walks past anything already presented above the anchor. That cannot
    /// happen today — the anchor sits in the topmost sheet — but the cost of
    /// being wrong is silent: `present` on a controller that is already
    /// presenting logs and returns, and PhotoKit's completion handler never
    /// arrives.
    ///
    /// The walk comes first and the window check second, which is the opposite
    /// of the obvious order and is load-bearing. A `.fullScreen` presentation
    /// takes the presenting controller's view *out* of the window once the
    /// transition finishes, so an anchor with a full-screen modal above it
    /// reports `view.window == nil` while being perfectly presentable one step
    /// up. Checking the window before walking would refuse in exactly the case
    /// the walk exists for. Checking it after still refuses the case that
    /// matters — an anchor belonging to a screen that has gone away, which is
    /// in no window at any depth.
    var presentingViewController: UIViewController? {
        guard var controller = anchor else { return nil }
        while let presented = controller.presentedViewController {
            controller = presented
        }
        guard controller.view.window != nil else { return nil }
        return controller
    }
    #endif
}

#if os(iOS)
/// An invisible, untouchable view controller, kept only so that something in
/// this screen's own hierarchy can present.
private struct LimitedLibraryAnchor: UIViewControllerRepresentable {
    let presenter: LimitedLibraryPresenter

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(
        _ controller: UIViewController,
        context: Context
    ) {
        // Re-pointed on every update rather than only at creation: SwiftUI is
        // free to make a new controller for the same representable, and a
        // presenter still holding the previous one would resolve to a
        // controller whose view has left the window — which reads as "no
        // screen to present over" and silently does nothing.
        presenter.anchor = controller
    }
}
#endif

extension View {
    /// Puts an invisible view controller in this view's hierarchy, so
    /// `presenter` has something inside the current screen to present from.
    ///
    /// A `.background` rather than an overlay or a zero-size sibling: it
    /// inherits this view's size, which is what keeps its own view in the
    /// window — a detached controller cannot present — while drawing nothing
    /// and taking no touches.
    func limitedLibraryAnchor(
        _ presenter: LimitedLibraryPresenter
    ) -> some View {
        #if os(iOS)
        background {
            LimitedLibraryAnchor(presenter: presenter)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}
