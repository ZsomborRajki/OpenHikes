//
//  RecordingView.swift
//  OpenHikes
//

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RecordingView: View {
    private static let cardID = "recording-card"

    let recorder: HikeRecorder
    var mapController: MapController
    /// Offers the map's camera pill while a walk is being recorded. Optional
    /// so previews and tests can build this view without one.
    var photoCapture: PhotoCaptureController?
    /// Draws the photos already taken on this walk as pins on the live track,
    /// the same way a saved hike's detail screen draws its own. Optional for
    /// the same reason as above.
    var photoPins: PhotoMapPinController?
    var onSaved: (Hike) -> Void
    var onDiscarded: (UUID?) -> Void
    /// Pushes the gallery when one of those pins is tapped. Carries the draft
    /// with it because the caller builds a route out of the pair, and the
    /// recorder's hike is this screen's to know, not the sheet's.
    var onOpenPhoto: (Hike, HikePhoto) -> Void = { _, _ in /* no-op default */ }
    /// Draws the places added on this walk. See ``RecordingPlaceSheet``.
    var placePins: TrailPlacePinController?
    /// Where *Add Place* asks OpenStreetMap what is here, or `nil` for a
    /// launch that must not ask.
    var placeSource: (any TrailPointSourcing)?
    /// Pushes one of the walk's places, where its photographs are taken.
    var onOpenPlace: (Hike, UUID) -> Void = { _, _ in /* no-op default */ }

    private var recordingFailure: RecordingFailure? {
        if case let .failed(failure) = recorder.phase {
            failure
        } else {
            nil
        }
    }

    private var showingFailure: Binding<Bool> {
        Binding(
            get: {
                recordingFailure != nil && !recorder.canRetrySave
            },
            set: { if !$0 { recorder.dismissFailure() } }
        )
    }

    private var failureNeedsSettings: Bool {
        recordingFailure == .locationDenied
            || recordingFailure == .preciseLocationRequired
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                RecordingCard(
                    recorder: recorder,
                    onSaved: onSaved,
                    onDiscarded: onDiscarded
                )
                .padding()
                .id(Self.cardID)
                // The places added so far on this walk, each opening its own
                // screen. Nothing at all until the first one.
                if let hike = recorder.currentHike {
                    HikePlaceSection(hike: hike, mapPins: placePins) { placeID in
                        onOpenPlace(hike, placeID)
                    }
                    .padding(.horizontal)
                    .background {
                        HikePlacePinClaim(hike: hike, controller: placePins) { placeID in
                            onOpenPlace(hike, placeID)
                        }
                    }
                }
            }
            // The review is drawn at the top of the card, which is only where
            // the hiker is looking if the card is scrolled to its top: one who
            // was reading the numbers when they stopped would otherwise be
            // left below the decision. A reader rather than a bound scroll
            // position, so scrolling writes no state into this body.
            .onChange(of: recorder.phase) { _, phase in
                guard phase == .reviewing else { return }
                withAnimation { proxy.scrollTo(Self.cardID, anchor: .top) }
            }
        }
        .navigationTitle("Record Hike")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .softScrollEdgeEffect(for: .top)
        // *Add Place*, in the bar while a walk is under way — see
        // ``RecordingPlaceSheet``.
        .recordingAddPlace(recorder: recorder, source: placeSource, onAdded: onOpenPlace)
        .onAppear {
            mapController.followUser()
        }
        // A recording being read on this screen is the case the switch exists
        // for — see ``ScreenWakePolicy``. `isActive` rather than
        // `isCapturingFixes`, because a hiker who paused at a junction to
        // work out where they are is precisely the one asking not to have the
        // screen dim on them. The read is in the closure so it belongs to the
        // modifier's body, though this one is free either way: the body above
        // already reads `phase`.
        .keepsScreenAwake { recorder.isActive }
        // Each photo is pinned to the hiker's last accepted fix — read at the
        // shutter, so a picture taken twenty minutes in is pinned twenty
        // minutes along. The recorder's live fix, not the draft `Hike`'s
        // `route`: that is only written when the recording stops. A draft only
        // exists once recording starts, which is why the modifier takes an
        // optional hike.
        .photoCaptureSubject(photoCapture, for: recorder.currentHike) {
            PhotoTrailAnchor.recordingCoordinate(recorder.lastAcceptedPoint)
        }
        // …and each one stands on the map as soon as it is taken, rather than
        // only once the walk has been saved. A background because the claim is
        // all this draws — see ``RecordingPhotoPins`` for why it is a separate
        // view rather than a modifier on this one.
        .background {
            if let hike = recorder.currentHike {
                RecordingPhotoPins(hike: hike, controller: photoPins) { photo in
                    onOpenPhoto(hike, photo)
                }
            }
        }
        // The walk's whole haptic vocabulary, and a boundary for the same
        // reason the pins above are one — see ``RecordingHaptics``.
        .background { RecordingHaptics(recorder: recorder) }
        // The phase is a coloured dot and a word at the top of a scrolling
        // card, so a change nobody is looking at is a change nobody hears.
        .onChange(of: recorder.phase) { _, phase in
            AccessibilityNotification.Announcement(phase.accessibilityTitle)
                .post()
        }
        .alert(isPresented: showingFailure, error: recordingFailure) {
            #if os(iOS)
            if failureNeedsSettings {
                Button("Open Settings") {
                    guard let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) else { return }
                    UIApplication.shared.open(url)
                }
            }
            #endif
            Button("OK", role: .cancel) { /* no-op */ }
        }
    }
}

/// The photos already taken on this walk, as pins on the map's live track.
///
/// Its own view for the reason ``HikePhotoSection`` is one on the detail
/// screen: ``Hike/orderedPhotos`` is a full sort behind a computed property,
/// and `hike.photos` is a `@Model` relationship, which notifies on *every*
/// write to it. Reading the gallery from `RecordingView`'s body would put both
/// up there — a sort per body pass, and a body pass per photograph taken,
/// across the whole of a six-hour walk, to produce the same handful of pins
/// every time.
///
/// It is **not** true, and used to be claimed here, that the screen's body
/// re-runs on every accepted fix. `HikeRecorder.stats` is a `let` holding a
/// stable ``RecordingStats``, and `@Observable` instruments `var`s only, so
/// reading it registers the reference and nothing in it: the per-fix readers
/// are ``RecordingStatsSection`` and the trail line under the card's title,
/// which are the boundaries, and the screen's own
/// observable inputs are `phase` and `currentHike`, both of which move a
/// handful of times a session. The note is worth keeping as a correction
/// because the wrong version made a per-fix body pass on this screen sound
/// like the expected cost.
///
/// It draws nothing itself. The pins are MapKit annotations published through
/// ``PhotoMapPinController``; this exists only to own the claim, which is why
/// it is a zero-sized background rather than anything on the screen.
private struct RecordingPhotoPins: View {
    let hike: Hike
    var controller: PhotoMapPinController?
    var onOpen: (HikePhoto) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .photoMapPins(controller, photos: hike.orderedPhotos) { photoID in
                guard let photo = hike.photos.first(where: { $0.id == photoID }) else { return }
                onOpen(photo)
            }
    }
}
