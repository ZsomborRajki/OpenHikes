//
//  CameraPicker.swift
//  OpenHikes
//
//  The camera itself, and the permission it needs.
//
//  Access is asked for here — at the moment the shutter button is tapped —
//  and nowhere else. Nothing about the camera is touched at launch, so a
//  hiker who never photographs a walk is never asked about a camera, exactly
//  as the app already treats Always-location: the prompt belongs to the
//  feature, not to the app.
//
//  `UIImagePickerController` rather than a hand-built `AVCapturePhotoOutput`
//  session. Its camera source is not deprecated, it is the system camera a
//  user already knows how to operate, and it comes with the flash, focus and
//  retake affordances that a custom viewfinder would have to reimplement badly.
//

import SwiftUI

#if os(iOS)
import AVFoundation
import UIKit

/// Whether the app may use the camera, asked for on demand.
nonisolated enum CameraAccess {
    enum Outcome: Equatable {
        /// Refused, or restricted by a policy the user can't change here.
        /// Either way the only thing left to offer is Settings.
        case denied
        case granted
        /// No camera on this device — a simulator, chiefly, which is also
        /// where the UI tests run.
        case unavailable
    }

    @MainActor
    static func request() async -> Outcome {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return .unavailable
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
                ? .granted
                : .denied
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
}

/// The system camera, presented full screen.
///
/// Hands back the captured frame in a box rather than a `UIImage`: the
/// encoding that follows runs off the main thread, and this is where the image
/// crosses that boundary — see ``CapturedFrame``.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (CapturedFrame) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ controller: UIImagePickerController,
        context: Context
    ) {
        // Nothing to push at it: the picker is configured once and then owns
        // its own state until it reports a result.
    }

    final class Coordinator: NSObject,
        UIImagePickerControllerDelegate,
        UINavigationControllerDelegate {
        private let onCapture: (CapturedFrame) -> Void
        private let onCancel: () -> Void

        init(
            onCapture: @escaping (CapturedFrame) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // `.originalImage`, never `.editedImage`: no editing is offered, so
            // the edited key is absent, and falling back to it would be a
            // silent way to store a crop nobody asked for.
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            // The metadata is the other half of what the camera produced, and
            // this is the only place it is offered: the `UIImage` above has
            // none of it, so a shutter time not taken here is one the app can
            // never ask for again. See ``CameraCaptureMetadata``.
            let metadata = info[.mediaMetadata] as? [String: Any]
            onCapture(
                CapturedFrame(
                    image: image,
                    capturedAt: metadata.flatMap { properties in
                        CameraCaptureMetadata.capturedAt(in: properties)
                    }
                )
            )
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
#endif
