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
    /// The one library import in flight, held so it can be cancelled — see
    /// ``runLibraryImport(_:)``.
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importToken = 0
    /// Whether the sheet still has a screen pushed that a photo could be filed
    /// under. See ``setHostScreenPresent(_:)``.
    @ObservationIgnored private var hasHostScreen = true

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
        refreshAvailability()
        return nextToken
    }

    /// Withdraws the pill, unless another screen has already claimed it.
    func detach(token: Int) {
        guard subject?.token == token else { return }
        subject = nil
        refreshAvailability()
    }

    /// Reports whether the sheet has any screen pushed that could receive a
    /// photo, which withdraws the pill for as long as it has not.
    ///
    /// The claim above cannot do this on its own, because it arrives too late.
    /// SwiftUI runs a pop animation first and calls the leaving screen's
    /// `onDisappear` after it, so a back navigation out of a hike left the pill
    /// standing over the map — fully opaque and answering taps — for the whole
    /// transition. A picker opened from it then had nothing left to file into
    /// by the time the user chose a photo, which reads as a button that does
    /// nothing.
    ///
    /// Written by ``MapSheet`` as a function of its navigation path rather than
    /// as a pop event, so a back-swipe that is abandoned recomputes to the same
    /// answer instead of leaving the pill withdrawn for good.
    func setHostScreenPresent(_ present: Bool) {
        guard hasHostScreen != present else { return }
        hasHostScreen = present
        if !present { cancelLibraryImport() }
        refreshAvailability()
    }

    /// Runs a library import as *the* import, cancelling whichever one was
    /// still working.
    ///
    /// Held here rather than in a view's `@State` for two reasons. Writing a
    /// task handle into `@State` invalidates the declaring view whether or not
    /// its body reads it, and the view that starts this one is the root — the
    /// render cost this whole controller exists to avoid. And this is already
    /// the object that knows when the import's destination has gone away.
    ///
    /// Superseding rather than queueing is the right shape for what the picker
    /// hands over: every asset in one pick is filed under a single anchor
    /// resolved when the picker closed, so a second pick is a newer answer to
    /// the same question rather than more of the same one — and two loops
    /// appending to the same hike interleave their photos.
    func runLibraryImport(_ body: @escaping @MainActor () async -> Void) {
        importTask?.cancel()
        importToken &+= 1
        let token = importToken
        importTask = Task { [weak self] in
            await body()
            guard let self, importToken == token else { return }
            importTask = nil
        }
    }

    /// Stops an import that no longer has anywhere to land.
    ///
    /// Driven by ``setHostScreenPresent(_:)`` and not by ``detach(token:)``,
    /// because a detach is routinely transient: SwiftUI claims the incoming
    /// screen before it releases the outgoing one, and pushing the photo
    /// viewer over a hike releases and re-claims the same walk. `hasHostScreen`
    /// is computed from the sheet's navigation path instead, so it goes false
    /// only when the sheet is genuinely back at a list with no screen to file
    /// a photo into.
    ///
    /// The loop's own `Task.isCancelled` check is what this reaches; without a
    /// handle to cancel, that check could never be true.
    func cancelLibraryImport() {
        importTask?.cancel()
        importTask = nil
    }

    /// Both requests are refused when the pill isn't available, so a tap that
    /// races the withdrawal above cannot open a picker with nothing behind it.
    func requestCamera() {
        guard isAvailable else { return }
        cameraRequest &+= 1
    }

    func requestLibrary() {
        guard isAvailable else { return }
        libraryRequest &+= 1
    }

    private func refreshAvailability() {
        let available = subject != nil && hasHostScreen
        guard isAvailable != available else { return }
        isAvailable = available
    }

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
