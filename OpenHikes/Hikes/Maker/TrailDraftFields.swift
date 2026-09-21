//
//  TrailDraftFields.swift
//  OpenHikes
//
//  The maker's fields, its snapping switch, its notices and its waypoint row.
//
//  Each is its own `View` type and that is a render-isolation decision rather
//  than tidiness: only a `View` is a boundary, so a name typed into a field
//  declared inside ``TrailDraftView``'s body would re-evaluate that body — and
//  with it the whole list of points — once per character. See
//  ``SheetPresentation/searchText``, which is the same problem one screen up
//  and has the same answer.
//
//  That holds for the name field even though it is inside an alert: an alert
//  is presented *over* the list rather than instead of it, so the body behind
//  it is evaluated exactly as often and the points are rebuilt exactly as
//  many times.
//

import CoreLocation
import MapKit
import Observation
import SwiftUI

/// What the hiker is typing into the save alert, for as long as that alert is
/// up.
///
/// A reference type rather than the screen's `@State`, for the reason
/// ``TrailDraftSearchRun`` is one and the file header states: a `@State`
/// mutation invalidates the view holding it whether or not its body reads it,
/// so a name typed into an alert declared by ``TrailDraftView`` would rebuild
/// that screen's list of points once per character.
///
/// Nowhere near ``TrailDraft``, and that is the point of it: the drawing is
/// kept across launches and this is not. A name belongs to the save it was
/// typed for, so a hiker who starts naming a trail, thinks better of it and
/// cancels comes back to a blank field rather than to their own second
/// thoughts.
@Observable
final class TrailDraftName {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    var text = ""

    func clear() {
        guard !text.isEmpty else { return }
        text = ""
    }
}

/// What the hiker is calling this trail, asked once, on the way out.
///
/// The placeholder is the name a blank field writes, which is what makes
/// leaving it blank a choice rather than an omission — see
/// ``TrailDraftView`` for why the date behind it is taken at the tap.
struct TrailDraftNameField: View {
    let name: TrailDraftName
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { name.text },
            set: { name.text = $0 }
        ))
        .accessibilityIdentifier("trail-draft-name")
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.words)
        #endif
    }
}

/// The place lookup this screen has in flight, if any.
///
/// Owned by ``TrailDraftView`` rather than by the field below, and held in a
/// reference type rather than a `@State` task, and both halves of that are
/// deliberate.
///
/// **The screen's root is the only thing here whose disappearance means the
/// maker closed.** A `List` is lazy, so `onDisappear` on the field's own
/// `Section` fires when that section scrolls out of view — and a hiker who
/// taps a suggestion and then scrolls down their points to watch the camera
/// move would scroll the search section off, cancel the lookup they just
/// started and reset a completer the sheet underneath also reads.
///
/// **A class rather than a `@State` value** because a `@State` mutation
/// invalidates the view holding it whether or not its body reads it, which
/// would re-evaluate the whole list on every search — the exact cost this
/// file's header splits the fields apart to avoid.
@MainActor
@Observable
final class TrailDraftSearchRun {
    /// The last place a lookup actually found, or `nil` before one has.
    ///
    /// Kept so the maker can offer to *mark* it, which is the fourth of the
    /// four add flows the plan issue asks for and the only one that arrives
    /// with a name already on it: an `MKLocalSearch` result is a hut, a spring
    /// or a summit that somebody has already labelled. The camera move is
    /// still all that happens on its own — marking is a second, deliberate
    /// tap, because a field that placed something every time it was used would
    /// be a search that edits the trail.
    ///
    /// Observed, so the menu entry appears with the answer. It is read by one
    /// small section's body and nothing else, which is what this file's header
    /// splits the fields apart for.
    private(set) var lastResult: TrailPlaceSearchResult?

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Starts `work`, cancelling whatever was already running. Nothing here
    /// waits on the old one: it is abandoned rather than drained, because what
    /// it would go on to do is move a camera that is about to be moved again.
    func start(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await work() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Remembers what a lookup found, so the maker can offer to mark it.
    func found(_ result: TrailPlaceSearchResult?) {
        guard lastResult != result else { return }
        lastResult = result
    }
}

/// A place a lookup found: what it is called, and where it is.
///
/// A value of its own rather than an `MKMapItem`, because what the maker does
/// with it is build a ``TrailPlace`` — and because `MKMapItem` is a reference
/// type from a framework, which is neither `Equatable` nor something a suite
/// can construct.
nonisolated struct TrailPlaceSearchResult: Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The first result of a response, or `nil` for a response with nothing in
    /// it or nothing named.
    ///
    /// The *first*, because that is the one the camera framed: a field that
    /// moved the map to one place and offered to mark another would be two
    /// answers to one question.
    init?(firstOf items: [MKMapItem]) {
        guard let item = items.first else { return nil }
        let coordinate = item.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        // `name` rather than the typed query: the query is what the hiker
        // guessed and this is what MapKit found, and they differ exactly where
        // it matters — "kehlstein" comes back as "Kehlsteinhaus".
        name = item.name ?? ""
        latitude = coordinate.latitude
        longitude = coordinate.longitude
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
/// rather than globally. Clearing it on the way out — so the sheet's own field
/// does not come back holding this screen's leftovers — belongs to
/// ``TrailDraftView`` rather than to this, for the reason
/// ``TrailDraftSearchRun`` gives.
///
/// The search it runs is deliberately smaller than ``MapSheet``'s: that one
/// also moves the weather badge, asks the community about the new area and
/// drops the sheet to the detent the camera framed against. None of the three
/// belongs to a hiker panning the map they are drawing on.
struct TrailDraftSearchField: View {
    let completer: SearchCompleter
    let mapController: MapController
    /// Held by the screen, for the reason ``TrailDraftSearchRun`` gives.
    let search: TrailDraftSearchRun

    @State private var query = ""
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

    /// Replaces whatever was in flight and moves the camera to what comes back.
    ///
    /// A failure is silent here, unlike the sheet's own search, and that is the
    /// one place the two deliberately differ: this field is a convenience
    /// inside an editor, and an alert over a half-drawn trail to say a place
    /// lookup failed interrupts the thing the hiker is actually doing. An
    /// empty response moves nothing, for the reason ``MapSheet`` gives — a
    /// successful request with nothing in it has a `boundingRegion` that is
    /// not a place.
    private func run(_ request: MKLocalSearch.Request) {
        search.start {
            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled,
                  !response.mapItems.isEmpty else { return }
            mapController.show(response.boundingRegion)
            // Remembered rather than placed — see
            // ``TrailDraftSearchRun/lastResult``. Nothing on the trail changes
            // here; the maker's own menu is where the hiker says to mark it.
            search.found(TrailPlaceSearchResult(firstOf: response.mapItems))
        }
    }
}

/// Whether the legs between the points follow mapped paths.
///
/// Its own `View` for the reason the fields above are, and here the cost it
/// avoids is the larger one: this sits over a list whose every row reads the
/// draft, and a `Toggle` declared inline in ``TrailDraftView``'s body would
/// make the animation of the switch itself a body pass.
///
/// It writes through ``TrailDraftController`` rather than onto the draft, like
/// every other mutation in this feature, because turning it back on is a
/// question for OpenStreetMap and the controller is what asks — see
/// ``TrailDraftController/setSnapsToPaths(_:)``.
struct TrailDraftSnapToggle: View {
    let maker: TrailDraftController

    var body: some View {
        Section {
            Toggle("Follow Paths", isOn: Binding(
                get: { maker.draft.snapsToPaths },
                set: { following in maker.setSnapsToPaths(following) }
            ))
            .accessibilityIdentifier("trail-draft-snap")
        } footer: {
            Text(
                """
                Legs run along paths mapped in OpenStreetMap. \
                Turn this off to draw straight lines.
                """
            )
        }
    }
}

/// One short line about a leg, or about the line as a whole.
///
/// The glyph is the whole of the difference at a glance and its colour is what
/// says whether anything is wrong — the arrangement ``CuratedTrailNotice``
/// already uses under *Search this area*, and the reason a leg with nothing
/// mapped under it does not wear a warning triangle.
struct TrailDraftNoticeLabel: View {
    let notice: TrailLegNotice

    var body: some View {
        Label {
            Text(notice.text)
        } icon: {
            Image(systemName: notice.symbolName)
                .foregroundStyle(notice.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// One point in the list, named by its place in the line and how far along it
/// sits.
///
/// The second line is about the **leg arriving at it**, and only when there is
/// something to say: a leg that snapped or that the hiker straightened
/// themselves says nothing, so the list is quiet until something is worth
/// reading. See ``TrailLegSnap/notice``.
struct TrailDraftWaypointRow: View {
    let number: Int
    let distanceMeters: Double
    let legNotice: TrailLegNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Point \(number)")
                Spacer(minLength: 12)
                Text(Self.length(distanceMeters))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let legNotice {
                TrailDraftNoticeLabel(notice: legNotice)
                    .foregroundStyle(.secondary)
            }
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
