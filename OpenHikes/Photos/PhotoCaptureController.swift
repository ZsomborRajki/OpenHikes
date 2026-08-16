//
//  PhotoCaptureController.swift
//  OpenHikes
//
//  What a photo taken right now would be attached to, and the two requests the
//  map's camera pill raises.
//
//  A reference type for the reason every other controller in this app is one:
//  the pill lives on the map, the hike it photographs lives in the sheet's
//  navigation stack, and the elevation-graph position it anchors to lives
//  inside ``HikeDetailView``'s own state. Passing any of that up through the
//  view hierarchy would make the root view a dependency of a screen two pushes
//  down; the screens attach themselves here instead, and the map observes only
//  the one property it draws — ``isAvailable``.
//
//  The anchor is a closure rather than a value because it is read exactly once,
//  at the moment the shutter fires. Publishing the elevation graph's position
//  as it moved would put a scrub — and, during a walk, every accepted fix —
//  through this object and into whatever observes it, which is the cost the
//  whole arrangement exists to avoid.
//

import CoreLocation
import Foundation
import Observation

@Observable
final class PhotoCaptureController {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The screen a photo taken now would be filed under, and where on the
    /// trail it would be pinned.
    struct Subject {
        /// Identifies the attachment, so a screen that goes away after its
        /// replacement has already arrived doesn't detach the replacement.
        let token: Int
        let hike: Hike
        /// Resolved at capture time — see the note above. `nil` means the
        /// photo joins the gallery without a place on the map.
        let anchor: () -> CLLocationCoordinate2D?
    }

    /// Whether the camera pill belongs on the map. Observed directly by
    /// ``MapView/Coordinator``, so showing or hiding it never re-renders a
    /// SwiftUI view.
    private(set) var isAvailable = false

    /// One-shot requests, in the same shape ``MapController``'s commands take:
    /// a token whose *change* is the message.
    private(set) var cameraRequest = 0
    private(set) var libraryRequest = 0

    @ObservationIgnored private(set) var subject: Subject?
    @ObservationIgnored private var nextToken = 0

    /// Offers the camera pill for `hike`, and returns the token that has to be
    /// handed back to withdraw it.
    ///
    /// Called from a screen's `onAppear`. SwiftUI presents the incoming screen
    /// before it tears the outgoing one down, so the token — rather than the
    /// hike's identity — is what keeps a push from being cancelled by the
    /// `onDisappear` of the screen it replaced. The two can be the same hike:
    /// stopping a recording lands on that recording's detail screen.
    @discardableResult func attach(
        to hike: Hike,
        anchor: @escaping () -> CLLocationCoordinate2D?
    ) -> Int {
        nextToken += 1
        subject = Subject(token: nextToken, hike: hike, anchor: anchor)
        isAvailable = true
        return nextToken
    }

    /// Withdraws the pill, unless another screen has already claimed it.
    func detach(token: Int) {
        guard subject?.token == token else { return }
        subject = nil
        isAvailable = false
    }

    func requestCamera() { cameraRequest &+= 1 }
    func requestLibrary() { libraryRequest &+= 1 }

    /// The hike a photo taken now belongs to, and where to pin it.
    ///
    /// Resolved together so the two can't come from different moments — the
    /// walker moves between the tap and the shutter, and a coordinate taken
    /// after the subject changed would pin a photo to a trail it isn't of.
    func currentSubject() -> (hike: Hike, coordinate: CLLocationCoordinate2D?)? {
        guard let subject else { return nil }
        return (subject.hike, subject.anchor())
    }
}
