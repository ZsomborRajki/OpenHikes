//
//  PhotoCaptureSubject.swift
//  OpenHikes
//
//  How a screen offers itself to the map's camera pill.
//
//  Both screens that can receive a photo — the hike detail view and the
//  recording view — need the same three-line dance: claim on appear, hand the
//  claim back on disappear, and re-claim when the hike underneath them
//  changes. Doing it twice invites the two copies to drift, and the failure it
//  would drift into is a pill that files photos under the previous screen's
//  hike.
//
//  The token, not the hike, is what a release is checked against. SwiftUI
//  presents the incoming screen before it tears the outgoing one down, so an
//  `onDisappear` that simply cleared the subject would cancel the screen that
//  had already replaced it — and the two can legitimately be the same hike,
//  since stopping a recording lands on that recording's detail screen.
//

import CoreLocation
import SwiftUI

extension View {
    /// Offers this screen as the subject of a photo taken from the map.
    ///
    /// - Parameters:
    ///   - controller: `nil` disables the pill entirely, which is what a
    ///     preview or a test that doesn't care about photos passes.
    ///   - hike: `nil` while there is nothing to attach to yet — a recording
    ///     has no draft until it starts.
    ///   - anchor: Evaluated at the shutter, never before. See
    ///     ``PhotoCaptureController`` for why this is a closure.
    ///   - place: The place on the trail this screen is about, which files
    ///     a photo under it — see ``HikePhoto/placeID``.
    func photoCaptureSubject(
        _ controller: PhotoCaptureController?,
        for hike: Hike?,
        place: UUID? = nil,
        anchor: @escaping () -> CLLocationCoordinate2D?
    ) -> some View {
        modifier(
            PhotoCaptureSubject(controller: controller, hike: hike, place: place, anchor: anchor)
        )
    }
}

private struct PhotoCaptureSubject: ViewModifier {
    let controller: PhotoCaptureController?
    let hike: Hike?
    let place: UUID?
    let anchor: () -> CLLocationCoordinate2D?

    @State private var token: Int?

    func body(content: Content) -> some View {
        content
            // `onAppear` rather than a `.task`: coming back from the photo
            // viewer re-appears without re-running a task keyed on the hike,
            // and the pill has to be there again when it does.
            .onAppear { claim() }
            .onDisappear { release() }
            // A place's screen replaced by another place's, on the same hike,
            // files photographs somewhere else from here on.
            .onChange(of: place) { _, _ in
                release()
                claim()
            }
            .onChange(of: hike?.id) { _, _ in
                release()
                claim()
            }
    }

    private func claim() {
        guard let controller, let hike else { return }
        token = controller.attach(to: hike, place: place, anchor: anchor)
    }

    private func release() {
        guard let controller, let token else { return }
        controller.detach(token: token)
        self.token = nil
    }
}
