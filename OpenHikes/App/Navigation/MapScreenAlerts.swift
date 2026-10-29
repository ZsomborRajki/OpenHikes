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
//  loses the box and not the reason for it. That includes the hikes list's own
//  refused *Delete*: the list is inside the sheet, and so is rebuilt with it.
//
//  One more is attached beside these rather than through them, for the same
//  reason and on the same contents: the trail maker's missed photographs —
//  see ``TrailDraftPhotoCopy``, whose state lives on the app model's maker.
//  Beside, because it carries an object rather than a binding, and a seventh
//  argument is past what the linter allows here.
//

import SwiftUI

extension View {
    /// Attaches the map screen's alerts to the view they can actually be
    /// presented from.
    ///
    /// - Parameters:
    ///   - importReport: A picked file that couldn't become a kept hike, or
    ///     became one without every place — see ``HikeImportReport``.
    ///   - searchFailure: A search that couldn't be answered.
    ///   - startupIssue: Whether this launch is on temporary storage.
    ///   - locationAccess: Whether the map's refused "my location" button has
    ///     been tapped — see ``LocationAccessPrompt``.
    ///   - photoCapture: The camera and library pickers' own failures.
    ///   - refusals: What the store turned down — see ``MapScreenRefusals``.
    func mapScreenAlerts(
        importReport: Binding<HikeImportReport>,
        searchFailure: Binding<SearchFailure?>,
        startupIssue: Binding<Bool>,
        locationAccess: Binding<Bool>,
        photoCapture: Binding<PhotoCaptureState>,
        refusals: MapScreenRefusals
    ) -> some View {
        modifier(
            MapScreenAlerts(
                importReport: importReport,
                searchFailure: searchFailure,
                startupIssue: startupIssue,
                locationAccess: locationAccess,
                photoCapture: photoCapture,
                walkEndRefused: refusals.walkEnd,
                hikeDeletionRefused: refusals.hikeDeletion
            )
        )
    }
}

/// Something the hiker asked for on the map screen that the store refused
/// and put back, so that nothing changed: one alert each, and each says so.
///
/// One argument for the two rather than one each, because they are one
/// subject — and ``View/mapScreenAlerts(importReport:searchFailure:startupIssue:locationAccess:photoCapture:refusals:)``
/// is at the parameter count the linter allows.
struct MapScreenRefusals {
    /// The record button's End Hike and Record — see
    /// ``RecordingEntry/walkEndRefused``.
    let walkEnd: Binding<Bool>
    /// The hikes list's *Delete*. The hike is still in the list, its photos
    /// and its saved map with it — see ``HikeDeletion/Outcome/refused``.
    let hikeDeletion: Binding<Bool>
}

private struct MapScreenAlerts: ViewModifier {
    @Binding var importReport: HikeImportReport
    @Binding var searchFailure: SearchFailure?
    @Binding var startupIssue: Bool
    @Binding var locationAccess: Bool
    @Binding var photoCapture: PhotoCaptureState
    @Binding var walkEndRefused: Bool
    @Binding var hikeDeletionRefused: Bool

    private var placeNoticeShown: Binding<Bool> {
        Binding(
            get: { importReport.placeNotice != nil && importReport.failure == nil },
            set: { if !$0 { importReport.placeNotice = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(isPresented: $importReport.failure.isPresent(), error: importReport.failure) {
                Button("OK", role: .cancel) { /* dismiss */ }
            }
            // Behind the failure, which one pick of several files can raise
            // beside it: presented once that one is dismissed, rather than
            // lost to it. See ``HikeImportReport``.
            .alert(
                "Not Every Place Was Imported",
                isPresented: placeNoticeShown,
                presenting: importReport.placeNotice
            ) { _ in
                Button("OK", role: .cancel) { /* dismiss */ }
            } message: { notice in
                Text(notice.message)
            }
            // A silent search is indistinguishable from a broken one.
            .alert(isPresented: $searchFailure.isPresent(), error: searchFailure) {
                Button("OK", role: .cancel) { /* dismiss */ }
            }
            .alert("Saved Hikes Unavailable", isPresented: $startupIssue) {
                Button("OK", role: .cancel) { /* dismiss */ }
            } message: {
                Text(
                    """
                        OpenHikes couldn’t open its saved hikes. This launch is using temporary storage, so \
                        changes won’t survive a relaunch. Existing data was left untouched.
                        """
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
            // The hike is still in the list behind it, so this says only what
            // to do — in the words a refused place removal uses, see
            // ``HikePlaceRefusal``. A refusal is what a full disk does.
            .alert("Couldn’t Delete Hike", isPresented: $hikeDeletionRefused) {
                Button("OK", role: .cancel) { /* dismiss */ }
            } message: {
                Text("Check that the device has storage available, then try again.")
            }
    }
}
