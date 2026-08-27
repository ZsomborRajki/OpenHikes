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
    /// screen the coordinate this resolves to is the one the walker is
    /// standing on when the shutter fires.
    func attachCapturedPhoto(_ frame: CapturedFrame) {
        guard let subject = photoCapture.currentSubject() else { return }
        Task {
            let stored = await HikePhotoImport.add(
                captured: frame,
                to: subject.hike,
                coordinate: subject.coordinate,
                savesToPhotoLibrary: savePhotosToLibrary
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
    /// They all get the same anchor, which is the anchor at the moment the
    /// picker closed. Importing is a "these belong to this walk" gesture
    /// rather than a moment of it, so there is no per-asset position to be
    /// had — and an asset's own EXIF location is deliberately not used: it
    /// says where the photographer was, not where on *this* trail it belongs,
    /// and a picture taken from a summit of the valley below would pin itself
    /// to a point the route never passes.
    ///
    /// Nothing is mirrored to the photo library here either — it is already
    /// there.
    func attachPickedPhotos(_ items: [PhotosPickerItem]) {
        guard let subject = photoCapture.currentSubject() else { return }
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
                let stored = await HikePhotoImport.add(
                    data,
                    to: subject.hike,
                    coordinate: subject.coordinate,
                    savesToPhotoLibrary: false
                )
                if stored == nil, subject.hike.isAttached {
                    photoPresentation.failure = .importFailed
                }
            }
        }
    }
}
