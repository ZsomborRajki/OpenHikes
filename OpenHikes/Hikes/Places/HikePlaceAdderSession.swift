//
//  HikePlaceAdderSession.swift
//  OpenHikes
//
//  *Add Place*'s form, held where a turn of the phone cannot reach it.
//
//  The form is drawn in the sheet in portrait and in the side panel in
//  landscape, so a rotation replaces it and every `@State` it had. Held
//  there, a turn took down the camera the form had open — it was presented
//  from that state, which went with the old host — and the form that came
//  back in the other host was a new one: the name back to the kind's, the
//  strip empty. ``SheetPresentation`` keeps one of these for each *Add Place*
//  on the stack, as it keeps a walk's ``WalkShareSession``, so the form in the
//  new host is the same form, the camera it had open is presented again over
//  it, and whatever a camera hands back lands here, whichever form presented
//  it.
//
//  Released with its route, at *Cancel* or once *Add* replaces the form with
//  the new place's screen — the photographs held here are camera frames, and
//  they go when the form does.
//

import Foundation
import Observation
import PhotosUI
import SwiftUI

@Observable
final class HikePlaceAdderSession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The name, kind and note the hiker has given so far.
    var draft = HikePlaceDraft()
    /// What was taken or picked and is waiting for *Add*, in that order.
    private(set) var photos: [HikePlaceStagedPhoto] = []
    /// The form's own camera and picker — see ``HikePlaceAdder`` for why not
    /// the pill's. Here rather than on the form, so a camera a turn took down
    /// is presented again by the form in the new host.
    var capture = PhotoCaptureState()
    /// Photographs taken or picked that are still being read into the strip.
    /// *Add* waits for them: it files what the strip holds, and a frame
    /// straight off the camera that arrived a moment after it would be lost.
    private(set) var stagingCount = 0
    /// The held photographs are being filed under the new place.
    var isAdding = false
    /// The place, once it is on the hike, while an alert about a photograph
    /// that did not make it is still up. The place's screen opens when the
    /// alert goes.
    var addedID: UUID?
    /// Set when *Add*'s save was refused. The form stays up under it, as it
    /// was, so tapping *Add* again is the retry.
    var refusal: HikePlaceRefusal?

    /// Holds a frame straight off the camera, once the strip has a thumbnail
    /// of it.
    @discardableResult func stage(_ frame: CapturedFrame) -> Task<Void, Never> {
        stagingCount += 1
        return Task {
            defer { stagingCount -= 1 }
            let thumbnail = await HikePlaceStagedPhoto.thumbnail(of: frame.image)
            photos.append(HikePlaceStagedPhoto(source: .captured(frame), thumbnail: thumbnail))
        }
    }

    /// Loads what was picked now rather than at *Add*, so the strip can show
    /// it and a picture that cannot be read is reported while the hiker is
    /// still choosing.
    @discardableResult func stage(_ items: [PhotosPickerItem]) -> Task<Void, Never> {
        stagingCount += 1
        return Task {
            defer { stagingCount -= 1 }
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    capture.failure = .importFailed
                    continue
                }
                let thumbnail = await HikePlaceStagedPhoto.thumbnail(of: data)
                photos.append(HikePlaceStagedPhoto(
                    source: .picked(data, assetLocalIdentifier: item.itemIdentifier),
                    thumbnail: thumbnail
                ))
            }
        }
    }

    /// Takes a held photograph back out of the strip.
    func remove(_ id: UUID) {
        photos.removeAll { $0.id == id }
    }
}
