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
//  arrives with whatever the hiker spelled. *Your own place* is always there
//  under it, and never waits on the search.
//
//  Adding closes the sheet and opens the place's own screen, where the camera
//  files what it takes under the place — which is what makes *add a place and
//  photograph it* one gesture rather than two trips through the gallery.
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

    @Environment(\.modelContext)
    private var modelContext
    @Environment(\.dismiss)
    private var dismiss
    @State private var finder = NearbyPlaceFinder()
    @State private var name = ""
    @State private var symbol: TrailPlaceSymbol?
    @State private var note = ""
    /// Set when adding's save was refused. The sheet stays up under it, with
    /// what was typed, so adding again is the retry.
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
                    Button("Cancel", role: .cancel) { dismiss() }
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
            TextField("Name", text: $name, prompt: Text(TrailPlace.unnamedName(for: symbol)))
                .accessibilityIdentifier("recording-place-name")
            TrailPlaceKindPicker(selection: $symbol)
            TextField("Note", text: $note, axis: .vertical)
                .lineLimit(1...4)
            Button("Add Your Own Place", systemImage: "mappin.and.ellipse") {
                add(TrailPlace(
                    coordinate: coordinate,
                    name: BoundedText.boundedOrEmpty(name, to: .title),
                    symbol: symbol,
                    note: BoundedText.boundedOrEmpty(note, to: .notes)
                ))
            }
            .accessibilityIdentifier("recording-place-add-own")
        } header: {
            Text("Your Own Place")
        } footer: {
            Text("You can add photos to it next.")
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
    /// way, and the sheet it opens.
    ///
    /// - Parameter onAdded: Called with the walk and the new place once it is
    ///   on the walk — the recording screen opens it.
    func recordingAddPlace(
        recorder: HikeRecorder,
        source: (any TrailPointSourcing)?,
        onAdded: @escaping (Hike, UUID) -> Void
    ) -> some View {
        modifier(RecordingAddPlace(recorder: recorder, source: source, onAdded: onAdded))
    }
}

/// The button, the sheet and the one refusal, as a modifier so the recording
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

    @State private var spot: Spot?
    @State private var isMissingLocation = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if recorder.currentHike != nil, recorder.isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Add Place", systemImage: "mappin.and.ellipse") { addPlace() }
                            .accessibilityIdentifier("recording-add-place")
                    }
                }
            }
            .sheet(item: $spot) { spot in
                RecordingPlaceSheet(hike: spot.hike, coordinate: spot.coordinate, source: source) { placeID in
                    onAdded(spot.hike, placeID)
                }
            }
            .alert("No Location Yet", isPresented: $isMissingLocation) {
                Button("OK", role: .cancel) { /* no-op */ }
            } message: {
                Text("A place is marked where you are standing. Try again once the walk has a location.")
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
