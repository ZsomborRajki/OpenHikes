//
//  PhotoMapPin.swift
//  OpenHikes
//
//  Which places on the trail have photographs of them, and the one photo each
//  of those places answers with.
//
//  A hike's gallery is a list; the map is not. Two pictures taken from the
//  same bend are one place, and drawing them as two pins stacked on the same
//  coordinate would give the user a target they cannot aim at and a second pin
//  they can never see. So the photos are grouped by the point they were
//  anchored to, and a point speaks for itself with its first photo — first in
//  ``Hike/orderedPhotos``, which is the order the strip and the viewer already
//  page through, so "the first one here" means the same thing on the map as it
//  does in the gallery.
//
//  Grouping is on the stored coordinate exactly. That is not a fuzzy
//  proximity test and is deliberately not one: an anchor is written once, by
//  ``PhotoTrailAnchor``, from a position on the elevation graph, and is never
//  re-derived — so two photos pinned to the same point carry bit-identical
//  coordinates, and two pinned to different points are different places even
//  when they are a stride apart.
//

import CoreLocation
import Foundation
import Observation
import SwiftUI

/// One place on the trail that has photographs of it.
nonisolated struct PhotoMapPin: Hashable, Identifiable, Sendable {
    /// The photo this pin previews, and the one the gallery opens at when the
    /// pin is tapped: the first anchored here in gallery order.
    let photo: HikePhoto
    /// How many photos share this point, counting ``photo``. Only ever used to
    /// say so in the callout — the pin still opens the first one.
    let count: Int
    let latitude: Double
    let longitude: Double

    var id: UUID { photo.id }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Groups a hike's photos into the pins the map draws, in gallery order.
    ///
    /// Unanchored photos are dropped rather than pinned somewhere plausible:
    /// a photo with no place on the trail is still a photo of the walk, and
    /// ``PhotoTrailAnchor`` is where that distinction is argued.
    static func pins(for photos: [HikePhoto]) -> [Self] {
        var order: [CoordinateKey] = []
        var leaders: [CoordinateKey: HikePhoto] = [:]
        var counts: [CoordinateKey: Int] = [:]

        for candidate in photos {
            guard let anchor = candidate.coordinate,
                  CLLocationCoordinate2DIsValid(anchor) else { continue }
            let key = CoordinateKey(
                latitude: anchor.latitude,
                longitude: anchor.longitude
            )
            if let seen = counts[key] {
                counts[key] = seen + 1
            } else {
                counts[key] = 1
                leaders[key] = candidate
                order.append(key)
            }
        }

        return order.compactMap { key in
            guard let leader = leaders[key], let total = counts[key] else { return nil }
            return Self(
                photo: leader,
                count: total,
                latitude: key.latitude,
                longitude: key.longitude
            )
        }
    }

    /// A coordinate that can be a dictionary key. `CLLocationCoordinate2D` is
    /// neither `Hashable` nor `Equatable`, which is the same gap
    /// ``RouteHighlight/move(to:)`` compares around by hand.
    private struct CoordinateKey: Hashable {
        let latitude: Double
        let longitude: Double
    }
}

/// The photo pins currently drawn on the map, and the way back from one of
/// them into the gallery it came from.
///
/// A reference type for the reason ``PhotoCaptureController`` is one: the pins
/// are drawn by MapKit, the photos live on a screen two pushes into the sheet,
/// and the map observes this object directly rather than being handed the list
/// through a SwiftUI body. A screen claims the pins on appear and hands the
/// claim back on disappear, so there is never a set of pins pointing at a hike
/// that is no longer open.
@Observable
final class PhotoMapPinController {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Observed directly by ``MapView/Coordinator``, so adding or removing a
    /// photo redraws MapKit's annotations and no SwiftUI view.
    private(set) var pins: [PhotoMapPin] = []

    /// Where the previews are decoded from. Injectable so a test can point the
    /// pins at its own sandbox rather than at the app's photo directory.
    @ObservationIgnored let store: HikePhotoStore

    @ObservationIgnored private var openPhoto: ((UUID) -> Void)?
    @ObservationIgnored private var activeToken: Int?
    @ObservationIgnored private var nextToken = 0
    /// What the claiming screen last published, kept apart from ``pins`` so a
    /// screen that is being navigated away from can have its pins taken off the
    /// map and put back without re-deriving them.
    @ObservationIgnored private var claimed: [PhotoMapPin] = []
    /// See ``setHostScreenPresent(_:)``.
    @ObservationIgnored private var hasHostScreen = true

    init(store: HikePhotoStore = .shared) {
        self.store = store
    }

    /// Claims the map's photo pins for a screen, returning the token that has
    /// to be handed back to withdraw them.
    ///
    /// Tokened for the reason ``PhotoCaptureController/attach(to:anchor:)`` is:
    /// SwiftUI presents the incoming screen before it tears the outgoing one
    /// down, so a release checked against anything else would cancel the
    /// screen that had already replaced it.
    @discardableResult func attach(
        _ photos: [HikePhoto],
        onOpen: @escaping (UUID) -> Void
    ) -> Int {
        nextToken += 1
        activeToken = nextToken
        openPhoto = onOpen
        apply(PhotoMapPin.pins(for: photos))
        return nextToken
    }

    /// Redraws the pins of a screen that already holds the claim — a photo
    /// taken, imported or deleted while it is up.
    func update(_ photos: [HikePhoto], token: Int) {
        guard activeToken == token else { return }
        apply(PhotoMapPin.pins(for: photos))
    }

    /// Withdraws the pins, unless another screen has already claimed them.
    func detach(token: Int) {
        guard activeToken == token else { return }
        activeToken = nil
        openPhoto = nil
        apply([])
    }

    /// Opens the gallery at the tapped pin's photo, if a screen is still
    /// listening. A tap that arrives after the claim was handed back is
    /// dropped rather than pushed onto whatever is on screen now.
    func open(_ photoID: UUID) {
        guard hasHostScreen else { return }
        openPhoto?(photoID)
    }

    /// Takes the pins off the map for as long as the sheet has no screen
    /// pushed that they could belong to, for the reason
    /// ``PhotoCaptureController/setHostScreenPresent(_:)`` exists: a pop
    /// animation runs before the leaving screen's `onDisappear`, so pins for a
    /// hike the user has navigated out of otherwise stay on the map — and stay
    /// tappable — for the whole of the transition.
    func setHostScreenPresent(_ present: Bool) {
        guard hasHostScreen != present else { return }
        hasHostScreen = present
        publish()
    }

    /// Publishes only a genuine change, so a redraw that produces the same
    /// pins never wakes the map — the same guard, for the same reason, as
    /// ``RouteHighlight/move(to:)``.
    private func apply(_ updated: [PhotoMapPin]) {
        claimed = updated
        publish()
    }

    private func publish() {
        let visible = hasHostScreen ? claimed : []
        guard visible != pins else { return }
        pins = visible
    }
}

extension View {
    /// Draws this screen's photos as pins on the map for as long as it is up,
    /// and opens the gallery when one of them is tapped.
    ///
    /// - Parameters:
    ///   - controller: `nil` draws nothing, which is what a preview or a test
    ///     that doesn't care about the map passes.
    ///   - photos: The screen's photos, in gallery order. Unanchored ones are
    ///     filtered out by ``PhotoMapPin/pins(for:)``.
    ///   - onOpen: Handed the id of the photo a tapped pin speaks for.
    func photoMapPins(
        _ controller: PhotoMapPinController?,
        photos: [HikePhoto],
        onOpen: @escaping (UUID) -> Void
    ) -> some View {
        modifier(
            PhotoMapPinsModifier(controller: controller, photos: photos, onOpen: onOpen)
        )
    }
}

private struct PhotoMapPinsModifier: ViewModifier {
    let controller: PhotoMapPinController?
    let photos: [HikePhoto]
    let onOpen: (UUID) -> Void

    @State private var token: Int?

    func body(content: Content) -> some View {
        content
            // `onAppear`/`onDisappear` rather than a `.task`, and for the same
            // reason ``PhotoCaptureSubject`` uses them: coming back from the
            // photo viewer re-appears without re-running a keyed task, and the
            // pins have to be back on the map when it does.
            .onAppear { claim() }
            .onDisappear { release() }
            .onChange(of: photos) { _, updated in
                guard let controller, let token else {
                    claim()
                    return
                }
                controller.update(updated, token: token)
            }
    }

    private func claim() {
        guard let controller else { return }
        token = controller.attach(photos, onOpen: onOpen)
    }

    private func release() {
        guard let controller, let token else { return }
        controller.detach(token: token)
        self.token = nil
    }
}
