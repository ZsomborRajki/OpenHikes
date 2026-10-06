//
//  OpenHikesView+Photos.swift
//  OpenHikes
//
//  What happens between the camera pill and a photo on a hike.
//
//  Three steps, in this order every time: ask permission only if the thing
//  being done needs it, resolve *what* the photo is of at the moment it is
//  taken, and write the app's own copy before anything optional is attempted.
//  The last one is the important one — a refused photo-library save or a route
//  with nothing to pin to must never be the difference between having the
//  picture and losing it.
//

import OpenHikesData
import PhotosUI
import SwiftData
import SwiftUI

extension OpenHikesView {
    /// Opens the camera, asking for access first if this is the first time.
    ///
    /// The unavailable case is silent on purpose: it is a simulator, where an
    /// alert saying "no camera" would be shown to a developer and to nobody
    /// else.
    func presentCamera() async {
        switch await CameraAccess.request() {
        case .granted: photoPresentation.showCamera = true
        case .denied: photoPresentation.cameraAccessDenied = true
        case .unavailable: break
        }
    }

    /// Files a frame from the camera under whichever screen offered the pill.
    ///
    /// The subject is read here rather than captured when the camera opened:
    /// the walk continues while the viewfinder is up, and on the recording
    /// screen the coordinate this resolves to is the one the hiker is
    /// standing on when the shutter fires.
    func attachCapturedPhoto(_ frame: CapturedFrame) {
        guard let subject = photoCapture.currentSubject() else { return }
        Task {
            let stored = await HikePhotoImport.add(
                captured: frame,
                to: subject.hike,
                coordinate: subject.coordinate,
                savesToPhotoLibrary: savePhotosToLibrary,
                placeID: subject.placeID
            )
            // A photo that cannot be encoded or written is gone the moment the
            // camera closes — there is no copy anywhere else, and the frame
            // itself is not retained. Silence here would be the user losing a
            // picture and never learning that they had.
            if stored == nil, subject.hike.isAttached {
                photoPresentation.failure = .captureNotStored
            }
        }
    }

    /// Files assets picked from the library.
    ///
    /// Each one is placed the way "Find Photos of This Hike" would place it:
    /// by the moment it was taken against the walk's clock, corroborated or
    /// overruled by the position the camera recorded — see
    /// ``PickedPhotoPlacement``. A photo the clock cannot place — taken on
    /// another day, or carrying no time at all — is snapped to the trail where
    /// its camera was, if that is within metres of the route. Only a photo
    /// with no usable position falls back to the anchor in force when the
    /// picker closed, which on a hike's screen is the elevation graph's
    /// selection.
    ///
    /// The camera's position is where the photographer stood, never what the
    /// picture shows, so a shot taken from a summit of the valley below is
    /// pinned to the summit and not to the valley.
    ///
    /// A pick filed under a place is pinned to the place and nowhere else:
    /// that screen is the hiker saying where the picture belongs.
    ///
    /// Nothing is mirrored to the photo library here either — it is already
    /// there.
    ///
    /// Each asset's identity travels with its bytes, which is what stops the
    /// same photograph being attached twice. The picker shows no sign of what
    /// this walk already holds, so re-picking one is an ordinary thing to do —
    /// and the identifier is also what keeps a later scan of the library from
    /// offering a picture that was imported by hand. It costs nothing to know:
    /// `itemIdentifier` is handed back with the selection by the same
    /// out-of-process picker, rather than looked up in the library this path
    /// still never opens.
    func attachPickedPhotos(_ items: [PhotosPickerItem]) {
        guard let subject = photoCapture.currentSubject() else { return }
        // Once for the whole selection: building it is route-sized work.
        let plan = subject.placeID == nil ? subject.hike.photoSearchPlan : nil
        photoCapture.runLibraryImport {
            for item in items {
                guard !Task.isCancelled else { return }
                // The user can pop back and delete the hike while the loader
                // is still working through the selection; there is nothing
                // left to attach the rest of it to.
                guard subject.hike.isAttached else { return }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    photoPresentation.failure = .importFailed
                    continue
                }
                let stored = await HikePhotoImport.addPicked(
                    data,
                    to: subject.hike,
                    plan: plan,
                    fallback: subject.coordinate,
                    assetLocalIdentifier: item.itemIdentifier,
                    placeID: subject.placeID
                )
                if stored == nil, subject.hike.isAttached {
                    photoPresentation.failure = .importFailed
                }
            }
        }
    }
}
