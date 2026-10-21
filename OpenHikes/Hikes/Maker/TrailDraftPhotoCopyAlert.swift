//
//  TrailDraftPhotoCopyAlert.swift
//  OpenHikes
//
//  One answer per trail, presented from inside the map sheet's contents.
//  Advancing to another failure, or finishing a refused retry, can happen
//  while the previous alert is still closing. UIKit's dismissal completion
//  orders the next presentation; replacing a SwiftUI alert in that interval
//  swallowed it, with the retry files held behind a notice nobody could see.
//

import Foundation
import SwiftUI
import UIKit

extension View {
    func trailDraftPhotoCopyAlert(_ copy: TrailDraftPhotoCopy) -> some View {
        modifier(TrailDraftPhotoCopyAlert(copy: copy))
    }
}

/// Observable reads stay in this boundary, never in the enclosing screen.
private struct TrailDraftPhotoCopyAlert: ViewModifier {
    let copy: TrailDraftPhotoCopy

    func body(content: Content) -> some View {
        content.background {
            TrailDraftPhotoCopyPresenter(copy: copy, missed: copy.isShowing ? copy.missed : nil)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct TrailDraftPhotoCopyPresenter: UIViewControllerRepresentable {
    let copy: TrailDraftPhotoCopy
    let missed: TrailDraftPhotoCopy.Missed?

    func makeUIViewController(context: Context) -> TrailDraftPhotoAlertController {
        TrailDraftPhotoAlertController()
    }

    func updateUIViewController(_ controller: TrailDraftPhotoAlertController, context: Context) {
        controller.show(copy: copy, missed: missed)
    }

    static func dismantleUIViewController(_ controller: TrailDraftPhotoAlertController, coordinator: ()) {
        controller.clear()
    }
}

private final class TrailDraftPhotoAlertController: UIViewController {
    private var copy: TrailDraftPhotoCopy?
    private var desired: TrailDraftPhotoCopy.Missed?
    private var shown: (id: UUID, controller: UIAlertController)?
    private var isTransitioning = false
    private var afterDismiss: (() -> Void)?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        synchronize()
    }

    func show(copy: TrailDraftPhotoCopy, missed: TrailDraftPhotoCopy.Missed?) {
        self.copy = copy
        if afterDismiss == nil { desired = missed }
        synchronize()
    }

    func clear() {
        desired = nil
        afterDismiss = nil
        shown?.controller.dismiss(animated: false)
        shown = nil
    }

    private func synchronize() {
        guard !isTransitioning, isViewLoaded else { return }
        if let shown {
            guard shown.id != desired?.id else { return }
            close(shown.controller)
        } else if let desired, let copy {
            let presenter = topController
            // Walked first and checked second, for the reason
            // ``LimitedLibraryPresenter/presentingViewController`` gives.
            guard presenter.view.window != nil else { return }
            // The *Name Your Trail* alert a save is answered from is usually
            // still closing when the copy fails.
            if let transition = presenter.transitionCoordinator, wait(for: transition) { return }
            let alert = makeAlert(for: desired, copy: copy)
            shown = (desired.id, alert)
            isTransitioning = true
            presenter.present(alert, animated: true) { [weak self] in
                self?.isTransitioning = false
                self?.synchronize()
            }
            // Refused after all, and it will not call back: left for the next
            // update rather than held behind a flag nothing clears.
            if alert.presentingViewController == nil {
                shown = nil
                isTransitioning = false
            }
        }
    }

    /// The top of whatever this screen already has presented — a picker, a
    /// sheet, another alert. `present` on a controller that is already
    /// presenting, or still opening or closing, writes a line to the console
    /// and never calls back, which left `isTransitioning` set and every later
    /// notice queued behind one nobody could see. The walk
    /// ``LimitedLibraryPresenter`` makes, from this screen's own root.
    private var topController: UIViewController {
        var controller: UIViewController = self
        while let parent = controller.parent { controller = parent }
        while let presented = controller.presentedViewController { controller = presented }
        return controller
    }

    /// Synchronizes again once `transition` has finished. Answers whether it
    /// could be waited on.
    private func wait(for transition: any UIViewControllerTransitionCoordinator) -> Bool {
        isTransitioning = true
        let queued = transition.animate(alongsideTransition: nil) { [weak self] _ in
            self?.isTransitioning = false
            self?.synchronize()
        }
        if !queued { isTransitioning = false }
        return queued
    }

    private func makeAlert(for missed: TrailDraftPhotoCopy.Missed, copy: TrailDraftPhotoCopy) -> UIAlertController {
        let alert = UIAlertController(
            title: String(localized: "Photos Not Added"),
            message: String(localized: """
                \(missed.photos.photos.count) photos couldn’t be added to “\(missed.hikeTitle)”. \
                The trail itself is saved.
                """),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Try Again"), style: .default) { [weak self] _ in
            self?.answer { copy.retry() }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Skip"), style: .cancel) { [weak self] _ in
            self?.answer { copy.skip() }
        })
        return alert
    }

    private func answer(_ action: @escaping () -> Void) {
        afterDismiss = action
        desired = nil
        synchronize()
    }

    private func close(_ alert: UIAlertController) {
        isTransitioning = true
        let finished = { [weak self] in
            guard let self else { return }
            shown = nil
            isTransitioning = false
            let answer = afterDismiss
            afterDismiss = nil
            answer?()
            if let copy { desired = copy.isShowing ? copy.missed : nil }
            synchronize()
        }
        if alert.presentingViewController == nil {
            // Already closed by the time its action ran: nothing to wait on.
            finished()
        } else if alert.isBeingDismissed, let transition = alert.transitionCoordinator {
            if !transition.animate(alongsideTransition: nil, completion: { _ in finished() }) { finished() }
        } else {
            alert.dismiss(animated: true, completion: finished)
        }
    }
}
