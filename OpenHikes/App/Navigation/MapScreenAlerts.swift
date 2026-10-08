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
//  What the alerts say is still owned by whoever raises them — the state they
//  read lives on ``OpenHikesView`` or on the app model's ``RecordingEntry``,
//  both of which outlive every rebuild of the sheet, so a rebuild mid-alert
//  loses the box and not the reason for it.
//

import SwiftUI

extension View {
    /// Attaches the map screen's alerts to the view they can actually be
    /// presented from.
    ///
    /// - Parameters:
    ///   - importFailure: A picked file that couldn't become a kept hike.
    ///   - searchFailure: A search that couldn't be answered.
    ///   - startupIssue: Whether this launch is on temporary storage.
    ///   - locationAccess: Whether the map's refused "my location" button has
    ///     been tapped — see ``LocationAccessPrompt``.
    ///   - photoCapture: The camera and library pickers' own failures.
    ///   - walkEndRefused: The record button's End Hike and Record, refused by
    ///     the store — see ``RecordingEntry/walkEndRefused``.
    func mapScreenAlerts(
        importFailure: Binding<HikeImportFailure?>,
        searchFailure: Binding<SearchFailure?>,
        startupIssue: Binding<Bool>,
        locationAccess: Binding<Bool>,
        photoCapture: Binding<PhotoCaptureState>,
        walkEndRefused: Binding<Bool>
    ) -> some View {
        modifier(
            MapScreenAlerts(
                importFailure: importFailure,
                searchFailure: searchFailure,
                startupIssue: startupIssue,
                locationAccess: locationAccess,
                photoCapture: photoCapture,
                walkEndRefused: walkEndRefused
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
    @Binding var walkEndRefused: Bool

    func body(content: Content) -> some View {
        content
            .alert(isPresented: $importFailure.isPresent(), error: importFailure) {
                Button("OK", role: .cancel) { /* dismiss */ }
            }
            // A silent search is indistinguishable from a broken one.
            .alert(isPresented: $searchFailure.isPresent(), error: searchFailure) {
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
            // The detail's End says the same, in the same words — see
            // ``WalkControls``. Nothing recorded: the walk is still under way.
            .alert("Could not end this hike", isPresented: $walkEndRefused) {
                Button("OK", role: .cancel) { /* dismiss */ }
            } message: {
                Text("Its record could not be saved, so the hike is still under way. Try ending it again.")
            }
    }
}
