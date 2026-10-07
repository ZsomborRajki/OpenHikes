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
import SwiftData
import SwiftUI

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

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var finder = NearbyPlaceFinder()
    /// Set when adding a mapped place was refused. The sheet stays up under
    /// it, so adding again is the retry.
    @State private var refusal: HikePlaceRefusal?

    var body: some View {
        NavigationStack {
            Form {
                if source != nil { mappedSection }
                ownSection
            }
            .navigationTitle("Add Place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
            .hikePlaceRefusalAlert($refusal)
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

    private var ownSection: some View {
        Section {
            Button("Add Your Own Place", systemImage: "mappin.and.ellipse") {
                dismiss()
                onAddOwn(coordinate)
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
        dismiss()
        guard added else {
            let held = hike.places.first { held in
                guard let osm = place.osm, let other = held.osm else { return false }
                return osm.isSameElement(as: other)
            }
            if let held { onAdded(held.id) }
            return
        }
        onAdded(place.id)
    }

    private static func distance(from coordinate: CLLocationCoordinate2D, to place: TrailPlace) -> String {
        let meters = RouteGeometry.distanceMeters(from: coordinate, to: place.clCoordinate)
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

extension View {
    /// *Add Place* in the navigation bar while `recorder` has a walk under
    /// way, and the sheet it opens — with *Places Nearby* beside it.
    ///
    /// - Parameters:
    ///   - onAdded: Called with the walk and the new place once it is on the
    ///     walk — the recording screen opens it.
    ///   - onAddOwn: Called with the walk and where the hiker stood, to open
    ///     the form that places one of their own — see ``HikePlaceAdder``.
    ///   - onFindNearby: Opens *Places Nearby* for the walk — see
    ///     ``HikePlacesNearbyView`` — or `nil` for a launch that must not ask
    ///     OpenStreetMap, which offers no button.
    func recordingAddPlace(
        recorder: HikeRecorder,
        source: (any TrailPointSourcing)?,
        onAdded: @escaping (Hike, UUID) -> Void,
        onAddOwn: @escaping (Hike, CLLocationCoordinate2D) -> Void,
        onFindNearby: ((Hike) -> Void)? = nil
    ) -> some View {
        modifier(RecordingAddPlace(
            recorder: recorder,
            source: source,
            onAdded: onAdded,
            onAddOwn: onAddOwn,
            onFindNearby: onFindNearby
        ))
    }
}

/// The buttons, the sheet and the one refusal, as a modifier so the recording
/// screen's own body gains a line rather than a feature.
private struct RecordingAddPlace: ViewModifier {
    /// Where *Add Place* was tapped, and on which walk.
    private struct Spot: Identifiable {
        let id = UUID()
        let hike: Hike
        let coordinate: CLLocationCoordinate2D
    }

    let recorder: HikeRecorder
    let source: (any TrailPointSourcing)?
    let onAdded: (Hike, UUID) -> Void
    let onAddOwn: (Hike, CLLocationCoordinate2D) -> Void
    let onFindNearby: ((Hike) -> Void)?

    @State private var spot: Spot?
    @State private var isMissingLocation = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if let hike = recorder.currentHike, recorder.isActive {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // Looking before marking: what is around, then the
                        // spot underfoot.
                        if let onFindNearby {
                            Button("Places Nearby", systemImage: "binoculars") { onFindNearby(hike) }
                                .accessibilityIdentifier("recording-places-nearby")
                        }
                        Button("Add Place", systemImage: "mappin.and.ellipse") { addPlace() }
                            .accessibilityIdentifier("recording-add-place")
                    }
                }
            }
            .sheet(item: $spot) { spot in
                RecordingPlaceSheet(
                    hike: spot.hike,
                    coordinate: spot.coordinate,
                    source: source,
                    onAdded: { placeID in onAdded(spot.hike, placeID) },
                    onAddOwn: { coordinate in onAddOwn(spot.hike, coordinate) }
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
        guard let hike = recorder.currentHike,
              let coordinate = PhotoTrailAnchor.recordingCoordinate(recorder.lastAcceptedPoint)
        else {
            isMissingLocation = true
            return
        }
        spot = Spot(hike: hike, coordinate: coordinate)
    }
}
