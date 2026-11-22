//
//  RecordingPlaceSheet.swift
//  OpenHikes
//
//  *Add Place*, while a walk is being recorded: mark where you are standing,
//  as the thing OpenStreetMap says is here or as a place of your own.
//
//  What OpenStreetMap has within reach is offered first — see
//  ``NearbyPlaceSuggestions`` — because a hut marked from the map arrives with
//  its name, its kind, its height and its link, and a hut typed in by hand
//  arrives with whatever the hiker spelled. Adding one closes the sheet and
//  opens the place's own screen, where the camera files what it takes under
//  the place — which is what makes *add a place and photograph it* one
//  gesture rather than two trips through the gallery.
//
//  *Places Nearby* is the first thing in it, for a hiker who wants to look
//  around before marking anything: what OpenStreetMap has in the area the
//  map shows — see ``HikePlacesNearbyView``. It was a button of its own in the
//  recording screen's bar, beside *Add Place*, until the bar was given to
//  Pause and Stop and *Add Place* moved to the camera pill (2026-11-22).
//
//  *Your own place* is always there under it, and never waits on the search.
//  It closes the sheet and opens the form a hike's own screen adds places
//  with — see ``HikePlaceAdder`` — at the spot the hiker is standing on, with
//  the map uncovered and its pin in the middle of it: the place a hiker marks
//  on a walk is often the one they have just walked past, and the map is the
//  one thing that can put it back. The form names it, takes its photographs
//  and puts it on the walk; this sheet asks nothing about it.
//

import CoreLocation
import OpenHikesData
import OpenHikesShared
import SwiftData
import SwiftUI
import TipKit

/// The glyphs of *Add Place*, on the camera pill while a walk is recorded,
/// and of *Places Nearby* in the sheet it opens, named once because the
/// first-run tips about them draw them too — see ``AddPlaceTip`` and
/// ``PlacesNearbyTip``.
nonisolated enum RecordingPlaceSymbols {
    static let addPlace = "mappin.and.ellipse"
    static let placesNearby = "binoculars"
}

struct RecordingPlaceSheet: View {
    let hike: Hike
    /// Where the hiker was standing when they tapped *Add Place*. Held rather
    /// than followed: the place is where they stopped, not where they have
    /// walked to while typing its name.
    let coordinate: CLLocationCoordinate2D
    /// `nil` for a launch that must not ask OpenStreetMap, which offers only
    /// the hiker's own place.
    var source: (any TrailPointSourcing)?
    /// Called with the new place's id once it is on the hike.
    let onAdded: (UUID) -> Void
    /// Called with ``coordinate`` once the sheet is going, to open the form
    /// that places one of the hiker's own there.
    let onAddOwn: (CLLocationCoordinate2D) -> Void
    /// Called once the sheet is going, to open *Places Nearby*, or `nil` for
    /// a launch that must not ask OpenStreetMap, which offers no row.
    var onFindNearby: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var finder = NearbyPlaceFinder()
    /// Set when adding a mapped place was refused. The sheet stays up under
    /// it, so adding again is the retry.
    @State private var refusal: HikePlaceRefusal?
    /// Why the sheet is closing, once it is. The sheet goes first and the map
    /// is told after, so a screen pushed in answer opens over a map and not
    /// under a sheet.
    @State private var exit: Exit?

    @Environment(\.appTips) private var tips

    private enum Exit: Equatable {
        case addOwn
        case findNearby
        /// The place to open, if the add found one.
        case opened(UUID?)
    }

    var body: some View {
        NavigationStack {
            Form {
                if onFindNearby != nil { nearbySection }
                if source != nil { mappedSection }
                ownSection
            }
            .navigationTitle("Add Place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DismissButton(role: .cancel)
                }
            }
            .hikePlaceRefusalAlert($refusal)
        }
        .dismiss(after: exit) { exit in
            switch exit {
            case .addOwn: onAddOwn(coordinate)
            case .findNearby: onFindNearby?()
            case .opened(let id): if let id { onAdded(id) }
            }
        }
        .task {
            guard let source else { return }
            finder.start(around: coordinate, excluding: hike.places, from: source)
        }
        .onDisappear { finder.cancel() }
        .accessibilityIdentifier("recording-place-sheet")
    }

    private var mappedSection: some View {
        Section {
            ForEach(finder.suggestions) { place in
                Button { add(place) } label: {
                    HStack(spacing: 12) {
                        TrailPlaceRowView(row: TrailPlaceRow(place: place, anchor: nil))
                        Text(Self.distance(from: coordinate, to: place))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recording-place-suggestion")
            }
            if finder.isSearching, finder.suggestions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking on OpenStreetMap…").foregroundStyle(.secondary)
                }
            } else if finder.suggestions.isEmpty {
                Text("Nothing mapped right here.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Mapped Here")
        } footer: {
            if let outage = finder.outage {
                Text(TrailPointNotice.outage(outage).caption.text)
            }
        }
    }

    /// Looking before marking: what is around, ahead of the spot underfoot.
    /// With its first-run tip over it, once *Add Place*'s has gone — opening
    /// this sheet is what retires that one.
    private var nearbySection: some View {
        Section {
            if let tip = tips?.recording.currentTip as? PlacesNearbyTip {
                TipView(tip).tipImageStyle(Color.primary)
            }
            Button("Places Nearby", systemImage: RecordingPlaceSymbols.placesNearby) {
                tips?.used(PlacesNearbyTip())
                exit = .findNearby
            }
            .accessibilityIdentifier("recording-places-nearby")
        }
    }

    private var ownSection: some View {
        Section {
            Button("Add Your Own Place", systemImage: "mappin.and.ellipse") {
                exit = .addOwn
            }
            .accessibilityIdentifier("recording-place-add-own")
        } header: {
            Text("Your Own Place")
        } footer: {
            Text("Put it on the map where it is, then name it and add photos.")
        }
    }

    /// Puts the place on the walk and opens it — or, for an OpenStreetMap
    /// place the walk already has, opens the one it has. A refused save
    /// leaves the sheet up.
    private func add(_ place: TrailPlace) {
        let added: Bool
        do throws(HikePlaceRefusal) {
            added = try HikePlaceChange.add(place, to: hike, in: modelContext)
        } catch {
            refusal = error
            return
        }
        guard added else {
            let held = hike.places.first { held in
                guard let osm = place.osm, let other = held.osm else { return false }
                return osm.isSameElement(as: other)
            }
            exit = .opened(held?.id)
            return
        }
        exit = .opened(place.id)
    }

    private static func distance(from coordinate: CLLocationCoordinate2D, to place: TrailPlace) -> String {
        let meters = RouteGeometry.distanceMeters(from: coordinate, to: place.clCoordinate)
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

extension View {
    /// *Add Place* on the camera pill while `recorder` has a walk under way,
    /// and the sheet it opens — with *Places Nearby* at its head. Claims the
    /// pill for the walk's photographs too.
    ///
    /// - Parameters:
    ///   - photoCapture: The pill's controller, or `nil` for a preview, which
    ///     offers no pill at all.
    ///   - onAdded: Called with the walk and the new place once it is on the
    ///     walk — the recording screen opens it.
    ///   - onAddOwn: Called with the walk and where the hiker stood, to open
    ///     the form that places one of their own — see ``HikePlaceAdder``.
    ///   - onFindNearby: Opens *Places Nearby* for the walk — see
    ///     ``HikePlacesNearbyView`` — or `nil` for a launch that must not ask
    ///     OpenStreetMap, which offers no row.
    func recordingAddPlace(
        recorder: HikeRecorder,
        photoCapture: PhotoCaptureController?,
        source: (any TrailPointSourcing)?,
        onAdded: @escaping (Hike, UUID) -> Void,
        onAddOwn: @escaping (Hike, CLLocationCoordinate2D) -> Void,
        onFindNearby: ((Hike) -> Void)? = nil
    ) -> some View {
        modifier(RecordingAddPlace(
            recorder: recorder,
            photoCapture: photoCapture,
            source: source,
            onAdded: onAdded,
            onAddOwn: onAddOwn,
            onFindNearby: onFindNearby
        ))
    }
}

/// The first-run tip about *Add Place* — see ``AppTips`` — at the top of the
/// recording screen, carrying the glyph the camera pill draws it with. The
/// tip after it, about *Places Nearby*, is in the sheet *Add Place* opens,
/// over its row — see ``RecordingPlaceSheet``.
///
/// Inline rather than as a popover: a popover over the map would be presented
/// by the permanent sheet — see *First-run tips* in `AGENTS.md`. And in the
/// screen's own content rather than in a `safeAreaInset` under the bar, which
/// is the measured cost of the obvious spelling: an inset on the pushed
/// screen made every change of the recording's phase evaluate the whole sheet
/// twice — *Pause* went from 19 bodies to 40, the screen and the hikes list
/// under it included.
///
/// Only once the walk has a fix, because *Add Place* marks where the hiker
/// stands and has nothing to mark before then. A view of its own, so the
/// phase and the group are read here and not in `RecordingView`'s body.
struct RecordingPlaceTips: View {
    let recorder: HikeRecorder

    @Environment(\.appTips) private var tips

    var body: some View {
        if recorder.phase == .recording, let tip = tips?.recording.currentTip as? AddPlaceTip {
            TipView(tip)
                // The glyph in its button's colour, as on the map's cards —
                // see ``MapTipCardView``.
                .tipImageStyle(Color.primary)
                .padding([.horizontal, .top])
        }
    }
}

/// The pill's claim, the sheet and the one refusal, as a modifier so the
/// recording screen's own body gains a line rather than a feature.
private struct RecordingAddPlace: ViewModifier {
    /// Where *Add Place* was tapped, and on which walk.
    private struct Spot: Identifiable {
        let id = UUID()
        let hike: Hike
        let coordinate: CLLocationCoordinate2D
    }

    let recorder: HikeRecorder
    let photoCapture: PhotoCaptureController?
    let source: (any TrailPointSourcing)?
    let onAdded: (Hike, UUID) -> Void
    let onAddOwn: (Hike, CLLocationCoordinate2D) -> Void
    let onFindNearby: ((Hike) -> Void)?

    /// *Add Place*'s tip is retired from here when the pill's button is used
    /// — the tip itself is ``RecordingPlaceTips``.
    @Environment(\.appTips) private var tips
    @State private var spot: Spot?
    @State private var isMissingLocation = false

    func body(content: Content) -> some View {
        content
            // Each photo is pinned where the walk was when its shutter fired,
            // so a picture taken twenty minutes in is pinned twenty minutes
            // along — and one handed over a minute after it was taken is not
            // pinned a minute further on. The recorder's own fixes, not the
            // draft `Hike`'s `route`: that is only written when the recording
            // stops. See ``HikeRecorder/photoCoordinate(atShutter:)``. A draft
            // only exists once recording starts, which is why the modifier
            // takes an optional hike. And the pill's *Add Place* opens the
            // sheet below rather than the form a saved hike's opens.
            .photoCaptureSubject(photoCapture, for: recorder.currentHike, placeRequest: addPlace) { shutter in
                recorder.photoCoordinate(atShutter: shutter)
            }
            .sheet(item: $spot) { spot in
                RecordingPlaceSheet(
                    hike: spot.hike,
                    coordinate: spot.coordinate,
                    source: source,
                    onAdded: { placeID in onAdded(spot.hike, placeID) },
                    onAddOwn: { coordinate in onAddOwn(spot.hike, coordinate) },
                    onFindNearby: onFindNearby.map { find in { find(spot.hike) } }
                )
            }
            .alert("No Location Yet", isPresented: $isMissingLocation) {
                Button("OK", role: .cancel) { /* no-op */ }
            } message: {
                Text("A place is marked where you are standing. Try again once the hike has a location.")
            }
    }

    /// Marks the spot at the tap, read off the recorder's last accepted fix —
    /// the one a photograph taken now would be pinned to.
    private func addPlace() {
        tips?.used(AddPlaceTip())
        guard recorder.isActive, let hike = recorder.currentHike,
              let coordinate = PhotoTrailAnchor.recordingCoordinate(recorder.lastAcceptedPoint)
        else {
            isMissingLocation = true
            return
        }
        spot = Spot(hike: hike, coordinate: coordinate)
    }
}
