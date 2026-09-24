//
//  MapScreenAlerts.swift
//  OpenHikes
//
//  Every alert the map screen raises, attached in one place — and that place
//  is the sheet's *contents*, not the view that presents the sheet.
//
//  This file exists because the opposite was believed, written down, and
//  wrong. The repository instructions said modals belong inside the sheet's
//  contents "but alerts are the exception and stay on the root view, where
//  they survive the sheet being rebuilt". They do not survive anything there:
//  `OpenHikesView` keeps ``MapSheet`` presented permanently and puts it back
//  whenever it is dismissed, so the root view is already presenting something
//  at the moment any of these fires, and a SwiftUI alert has nowhere to go.
//  Measured, on `--ui-testing` launches against the real screen:
//
//  - An alert raised **while the sheet is settled** — the map's refused "my
//    location" button — opened, *and took the sheet down with it*. The sheet
//    never came back: `showSheet` is still `true`, so the `onChange` that
//    re-presents it never fires, and the app spends the rest of the launch as
//    a bare map with no search field and no way back short of relaunching.
//    That is the hiker's report this file was written for.
//  - An alert raised **while the sheet is going up** — a GPX fixture that
//    could not be read — never appeared at all. No error, no alert, just a
//    file that vanished.
//
//  Two failure modes, one cause, and the second is the reason nobody noticed
//  the first: a swallowed alert leaves nothing behind to report.
//
//  Attaching them here fixes both, and is the same arrangement — for the same
//  reason — as ``weatherDetailSheet(_:weather:)`` and ``MapSheet``'s own
//  `.fileImporter`. "The sheet's contents" rather than "the sheet" is what
//  keeps the answer right in landscape, where ``MapSidePanel`` holds the same
//  contents and there is no sheet to be inside of.
//
//  What the alerts say is still owned by whoever raises them — the state all
//  five read lives on ``OpenHikesView``, which outlives every rebuild of the
//  sheet, so a rebuild mid-alert loses the box and not the reason for it.
//

import OpenHikesData
import SwiftUI

extension View {
    /// Attaches the map screen's five alerts to the view they can actually be
    /// presented from.
    ///
    /// - Parameters:
    ///   - importFailure: A picked file that couldn't become a kept hike.
    ///   - searchFailure: A search that couldn't be answered.
    ///   - startupIssue: Whether this launch is on temporary storage.
    ///   - locationAccess: Whether the map's refused "my location" button has
    ///     been tapped — see ``LocationAccessPrompt``.
    ///   - photoCapture: The camera and library pickers' own failures.
    func mapScreenAlerts(
        importFailure: Binding<HikeImportFailure?>,
        searchFailure: Binding<SearchFailure?>,
        startupIssue: Binding<Bool>,
        locationAccess: Binding<Bool>,
        photoCapture: Binding<PhotoCaptureState>
    ) -> some View {
        modifier(
            MapScreenAlerts(
                importFailure: importFailure,
                searchFailure: searchFailure,
                startupIssue: startupIssue,
                locationAccess: locationAccess,
                photoCapture: photoCapture
            )
        )
    }
}

private struct MapScreenAlerts: ViewModifier {
    @Binding var importFailure: HikeImportFailure?
    @Binding var searchFailure: SearchFailure?
    @Binding var startupIssue: Bool
    @Binding var locationAccess: Bool
    @Binding var photoCapture: PhotoCaptureState

    func body(content: Content) -> some View {
        content
            .alert(isPresented: presence(of: $importFailure), error: importFailure) {
                Button("OK", role: .cancel) { /* dismiss */ }
            }
            // A silent search is indistinguishable from a broken one.
            .alert(isPresented: presence(of: $searchFailure), error: searchFailure) {
                Button("OK", role: .cancel) { /* dismiss */ }
            }
            .alert("Saved Hikes Unavailable", isPresented: $startupIssue) {
                Button("OK", role: .cancel) { /* dismiss */ }
            } message: {
                Text(
                    "OpenHikes couldn't open its saved hikes. " +
                    "This launch is using temporary storage, so changes won't survive a relaunch. " +
                    "Existing data was left untouched."
                )
            }
            .locationAccessAlert(.whileUsing, isPresented: $locationAccess)
            .photoCaptureAlerts($photoCapture)
    }

    /// Presents while `error` holds something, and clears it on dismissal, so
    /// there is never a second flag the two could disagree on.
    private func presence<E>(of error: Binding<E?>) -> Binding<Bool> {
        Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )
    }
}
