//
//  RecordingView.swift
//  OpenHikes
//

import CoreLocation
import Foundation
import OpenHikesData
import SwiftUI

struct RecordingView: View {
    let recorder: HikeRecorder
    /// What the bar's idle Start goes through, so that it asks before ending
    /// a walk as the map's record button does — see ``RecordingEntry``.
    let entry: RecordingEntry
    /// What the bar's Stop asks, which the map's capsule asks too — see
    /// ``RecordingStopQuestion``.
    let stopQuestion: RecordingStopQuestion
    var mapController: MapController
    /// Offers the map's camera pill while a walk is being recorded. Optional
    /// so previews and tests can build this view without one.
    var photoCapture: PhotoCaptureController?
    /// Draws the photos already taken on this walk as pins on the live track,
    /// the same way a saved hike's detail screen draws its own. Optional for
    /// the same reason as above.
    var photoPins: PhotoMapPinController?
    /// Pushes the gallery when one of those pins is tapped. Carries the draft
    /// with it because the caller builds a route out of the pair, and the
    /// recorder's hike is this screen's to know, not the sheet's.
    var onOpenPhoto: (Hike, HikePhoto) -> Void = { _, _ in /* no-op default */ }
    /// Draws the places added on this walk. See ``RecordingPlaceSheet``.
    var placePins: TrailPlacePinController?
    /// Where the camera pill's *Add Place* asks OpenStreetMap what is here,
    /// or `nil` for a launch that must not ask.
    var placeSource: (any TrailPointSourcing)?
    /// Pushes one of the walk's places, where its photographs are taken.
    var onOpenPlace: (Hike, UUID) -> Void = { _, _ in /* no-op default */ }
    /// Pushes *Add Place* for a place of the hiker's own at where they stood —
    /// see ``HikePlaceAdder``.
    var onAddOwnPlace: (Hike, CLLocationCoordinate2D) -> Void = { _, _ in /* no-op default */ }
    /// Pushes *Places Nearby* for the walk — see ``HikePlacesNearbyView``.
    var onFindPlacesNearby: (Hike) -> Void = { _ in /* no-op default */ }

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
        ScrollView {
            // The first-run tip about *Add Place*, on the camera pill — see
            // ``RecordingPlaceTips``.
            RecordingPlaceTips(recorder: recorder)
            RecordingCard(recorder: recorder, question: stopQuestion)
                .padding()
            // The places added so far on this walk, each opening its own
            // screen. Nothing at all until the first one.
            if let hike = recorder.currentHike {
                HikePlaceSection(hike: hike, mapPins: placePins, onOpen: { placeID in
                    onOpenPlace(hike, placeID)
                })
                .padding(.horizontal)
                .background {
                    HikePlacePinClaim(hike: hike, controller: placePins) { placeID in
                        onOpenPlace(hike, placeID)
                    }
                }
            }
        }
        // What the side panel stands as tall as — see ``SidePanelFit``.
        .fitsSidePanel()
        .navigationTitle("Record Hike")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .softScrollEdgeEffect(for: .top)
        // Status, Pause or Resume, and Stop, at every detent — see
        // ``RecordingBar``.
        .toolbar {
            RecordingBar(recorder: recorder, entry: entry, question: stopQuestion)
        }
        // *Add Place* on the camera pill while a walk is under way, and
        // *Places Nearby* in the sheet it opens — see
        // ``RecordingPlaceSheet``. Nearby only where the map can ask
        // OpenStreetMap, which a test launch cannot. It claims the pill for
        // the photographs too, which are pinned where the walk was when the
        // shutter fired.
        .recordingAddPlace(
            recorder: recorder,
            photoCapture: photoCapture,
            source: placeSource,
            onAdded: onOpenPlace,
            onAddOwn: onAddOwnPlace,
            onFindNearby: placePins?.around.finder.isAvailable == true ? onFindPlacesNearby : nil
        )
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
        // …and each one stands on the map as soon as it is taken, rather than
        // only once the walk has been saved. A background because the claim is
        // all this draws — see ``HikePhotoPinClaim`` for why it is a separate
        // view rather than a modifier on this one.
        .background {
            if let hike = recorder.currentHike {
                HikePhotoPinClaim(hike: hike, controller: photoPins) { photo in
                    onOpenPhoto(hike, photo)
                }
            }
        }
        // The phase is a coloured dot and a word in the bar, so a change
        // nobody is looking at is a change nobody hears.
        .onChange(of: recorder.phase) { _, phase in
            AccessibilityNotification.Announcement(phase.accessibilityTitle)
                .post()
        }
        .alert(isPresented: showingFailure, error: recordingFailure) {
            if failureNeedsSettings {
                OpenSettingsLink.link
            }
            Button("OK", role: .cancel) { /* no-op */ }
        }
    }
}
