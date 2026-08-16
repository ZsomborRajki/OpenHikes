//
//  PhotoCapturePresentation.swift
//  OpenHikes
//
//  Where the camera and the photo picker are actually put on screen.
//
//  Split in two, because the two halves have to hang off different views.
//
//  The pickers go *inside* the sheet. The app keeps its sheet up permanently,
//  and a view can only have one modal presented at a time: a `.photosPicker`
//  or `.fullScreenCover` attached to the same view as that sheet is simply
//  never presented — no error, no picker, nothing. This is the same reason
//  ``MapSheet`` presents the GPX importer from inside itself.
//
//  The alerts stay on the root view, where the app's other alerts already are.
//  An alert is not a view-controller presentation and reaches the screen over
//  the sheet regardless, and keeping it out of the sheet means it survives the
//  sheet being rebuilt.
//
//  The state is one value rather than five flags, so it can be threaded to two
//  places without widening every call site.
//

import PhotosUI
import SwiftUI

/// Everything the camera and the picker need to be on screen, and everything
/// they can report back.
///
/// A single value rather than separate `@State` flags because the root view
/// owns all of it and hands all of it to one modifier: the pieces are only
/// ever passed together, and the two failures are alternatives rather than
/// independent states.
struct PhotoCaptureState {
    var showCamera = false
    var showLibraryPicker = false
    var pickedPhotos: [PhotosPickerItem] = []
    /// Set when the camera was refused, driving the alert that offers Settings.
    var cameraAccessDenied = false
    var failure: Failure?

    /// Why a photo didn't make it onto the hike. Two cases rather than one
    /// because what the user has lost differs: a capture that could not be
    /// stored is gone, while an import that failed still has its original in
    /// the photo library.
    enum Failure: Equatable {
        case captureNotStored
        case importFailed
    }
}

extension View {
    /// Attaches the camera and the photo picker to the view they can actually
    /// be presented from — the sheet's content, not the view that presents the
    /// sheet.
    ///
    /// - Parameters:
    ///   - state: The presentation flags, owned by the root view.
    ///   - onCaptured: A frame straight off the camera.
    ///   - onPicked: Assets chosen in the library picker. Called with the
    ///     picker's items, which still have to be loaded — that is I/O and
    ///     belongs to the caller's task.
    func photoCapturePickers(
        _ state: Binding<PhotoCaptureState>,
        onCaptured: @escaping (CapturedFrame) -> Void,
        onPicked: @escaping ([PhotosPickerItem]) -> Void
    ) -> some View {
        modifier(
            PhotoCapturePickers(
                state: state,
                onCaptured: onCaptured,
                onPicked: onPicked
            )
        )
    }

    /// Attaches the alerts that report what the pickers couldn't do.
    ///
    /// Belongs on the root view rather than on the sheet: an alert owned by a
    /// view that is being rebuilt does not reliably appear, and the sheet is
    /// rebuilt on every navigation.
    func photoCaptureAlerts(_ state: Binding<PhotoCaptureState>) -> some View {
        modifier(PhotoCaptureAlerts(state: state))
    }
}

private struct PhotoCapturePickers: ViewModifier {
    @Binding var state: PhotoCaptureState
    let onCaptured: (CapturedFrame) -> Void
    let onPicked: ([PhotosPickerItem]) -> Void

    /// A walk produces a handful of pictures at a time at most, and every one
    /// picked is decoded, re-encoded and written; an unbounded selection would
    /// be a long stall with no progress to show for it.
    private static let selectionLimit = 10

    func body(content: Content) -> some View {
        content
        #if os(iOS)
            // Full screen, because a camera in a sheet is a viewfinder with a
            // hole punched in it.
            .fullScreenCover(isPresented: $state.showCamera) {
                CameraPicker(
                    onCapture: { frame in
                        state.showCamera = false
                        onCaptured(frame)
                    },
                    onCancel: { state.showCamera = false }
                )
                .ignoresSafeArea()
            }
        #endif
            // `PhotosPicker` rather than a `UIImagePickerController` on the
            // library side: it runs out of process, so importing costs no
            // photo-library permission and raises no prompt at all. The app
            // sees only what the user handed it.
            .photosPicker(
                isPresented: $state.showLibraryPicker,
                selection: $state.pickedPhotos,
                maxSelectionCount: Self.selectionLimit,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: state.pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                onPicked(items)
                state.pickedPhotos = []
            }
    }
}

private struct PhotoCaptureAlerts: ViewModifier {
    @Binding var state: PhotoCaptureState

    func body(content: Content) -> some View {
        content
            .alert("Camera Access Off", isPresented: $state.cameraAccessDenied) {
                #if os(iOS)
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: settings)
                }
                #endif
                Button("Not Now", role: .cancel) { /* dismiss */ }
            } message: {
                Text(
                    "OpenHikes needs the camera to take photos on a hike. "
                        + "You can turn it on in Settings. "
                        + "Photos already on your device can still be added from your library."
                )
            }
            // A capture that could not be encoded or written is simply gone:
            // the frame is not retained and there is no copy in the photo
            // library unless the user opted into one. Saying nothing would be
            // the user losing a picture and never finding out.
            .alert(
                failureTitle,
                isPresented: Binding(
                    get: { state.failure != nil },
                    set: { if !$0 { state.failure = nil } }
                )
            ) {
                Button("OK", role: .cancel) { /* dismiss */ }
            } message: {
                Text(failureMessage)
            }
    }

    private var failureTitle: LocalizedStringKey {
        state.failure == .captureNotStored
            ? "Couldn\u{2019}t Save Photo"
            : "Couldn\u{2019}t Add Photo"
    }

    private var failureMessage: LocalizedStringKey {
        state.failure == .captureNotStored
            ? """
            OpenHikes couldn\u{2019}t store the photo you just took, so it \
            hasn\u{2019}t been added to this hike. Check that your device has \
            free space and try again.
            """
            : """
            At least one photo couldn\u{2019}t be added to this hike. \
            It\u{2019}s still in your photo library.
            """
    }
}
