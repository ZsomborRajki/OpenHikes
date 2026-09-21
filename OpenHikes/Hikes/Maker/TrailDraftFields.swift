//
//  TrailDraftFields.swift
//  OpenHikes
//
//  The maker's two fields and its waypoint row.
//
//  Each is its own `View` type and that is a render-isolation decision rather
//  than tidiness: only a `View` is a boundary, so a name typed into a field
//  declared inside ``TrailDraftView``'s body would re-evaluate that body — and
//  with it the whole list of points — once per character. See
//  ``SheetPresentation/searchText``, which is the same problem one screen up
//  and has the same answer.
//

import MapKit
import SwiftUI

/// What the hiker is calling this trail.
///
/// Bound straight to ``TrailDraft/name`` through the controller, which is not
/// written to disk per keystroke — see
/// ``TrailDraftController/nameBinding``.
struct TrailDraftNameField: View {
    let maker: TrailDraftController

    var body: some View {
        TextField("Trail name", text: maker.nameBinding)
            .accessibilityIdentifier("trail-draft-name")
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
    }
}

/// Somewhere to look, while drawing.
///
/// **It moves the camera and places nothing.** The hole this closes is having
/// to leave the maker to find the valley you meant to draw in; putting a point
/// down is still a tap on the map, which is the one meaning a tap has while
/// this screen is up.
///
/// It borrows ``SearchCompleter``, which the map already feeds its settled
/// region to, so suggestions are answered near what the hiker is looking at
/// rather than globally — and clears it on the way out so the sheet's own
/// field does not come back holding this screen's leftovers.
///
/// The search it runs is deliberately smaller than ``MapSheet``'s: that one
/// also moves the weather badge, asks the community about the new area and
/// drops the sheet to the detent the camera framed against. None of the three
/// belongs to a hiker panning the map they are drawing on.
struct TrailDraftSearchField: View {
    let completer: SearchCompleter
    let mapController: MapController

    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search Maps", text: $query)
                    .accessibilityIdentifier("trail-draft-search")
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(searchTypedQuery)
                    .onChange(of: query) { _, value in
                        completer.update(query: value)
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }
            ForEach(completer.suggestions, id: \.self) { suggestion in
                Button { select(suggestion) } label: {
                    suggestionRow(for: suggestion)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Find a Place")
        } footer: {
            Text("Moves the map. Tap the map to put a point down.")
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
            completer.clear()
        }
    }

    private func suggestionRow(for suggestion: MKLocalSearchCompletion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).foregroundStyle(.primary)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func select(_ suggestion: MKLocalSearchCompletion) {
        query = suggestion.title
        isFocused = false
        completer.commit(query: suggestion.title)
        run(MKLocalSearch.Request(completion: suggestion))
    }

    private func searchTypedQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isFocused = false
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        // The same bias the suggestions above already carry, so the two halves
        // of one field do not answer at two scales.
        if let region = completer.region {
            request.region = region
            request.regionPriority = .default
        }
        run(request)
    }

    /// Cancels whatever was in flight and moves the camera to what comes back.
    ///
    /// A failure is silent here, unlike the sheet's own search, and that is the
    /// one place the two deliberately differ: this field is a convenience
    /// inside an editor, and an alert over a half-drawn trail to say a place
    /// lookup failed interrupts the thing the hiker is actually doing. An
    /// empty response moves nothing, for the reason ``MapSheet`` gives — a
    /// successful request with nothing in it has a `boundingRegion` that is
    /// not a place.
    private func run(_ request: MKLocalSearch.Request) {
        searchTask?.cancel()
        searchTask = Task {
            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled,
                  !response.mapItems.isEmpty else { return }
            mapController.show(response.boundingRegion)
        }
    }
}

/// One point in the list, named by its place in the line and how far along it
/// sits.
struct TrailDraftWaypointRow: View {
    let number: Int
    let distanceMeters: Double

    var body: some View {
        HStack {
            Text("Point \(number)")
            Spacer(minLength: 12)
            Text(Self.length(distanceMeters))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        // One element rather than two, the rule every composite row here
        // follows — see ``HikeRow``.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trail-draft-point-\(number)")
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
