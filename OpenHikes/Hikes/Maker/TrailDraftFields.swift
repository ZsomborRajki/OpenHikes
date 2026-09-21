//
//  TrailDraftFields.swift
//  OpenHikes
//
//  The maker's fields, its snapping switch, its notices, its running figures
//  and its waypoint row.
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

/// What the line is so far: how long, and — once anybody has been able to
/// measure it — what it climbs and drops.
///
/// Its own `View` and this is the one on the screen that most needed to be.
/// The length changes when the drawing does, so a body carrying it rebuilds
/// the list of points at exactly the moments that list has to be rebuilt
/// anyway. The climb does not: it lands a couple of seconds after the hiker
/// stops, from a task nobody is watching, and a figure read in
/// ``TrailDraftView``'s body would rebuild every point, every place and every
/// candidate row to say it. See ``TrailDraftElevation``.
///
/// **Nothing at all is drawn where there is no height**, which is a free
/// hiker's drawn trail, a build with no key and every launch running tests.
/// That is the same degradation a curated route already has — a line, a
/// length, and no chart — rather than a prompt for a subscription in the
/// middle of a drawing.
struct TrailDraftLineHeader: View {
    let draft: TrailDraft
    let elevation: TrailDraftElevation

    var body: some View {
        // Read once and handed to both layouts below, so the one that is
        // discarded costs a measurement rather than a second read of an
        // observable.
        let climb = elevation.summary
        let waiting = elevation.isMeasuring
        let length = Self.length(draft.distanceMeters)
        // Stacked rather than clipped at the accessibility type sizes, where
        // three figures and a heading do not fit across a phone. The audit
        // measures exactly this — see ``AccessibilityUITests``.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Points")
                Spacer(minLength: 12)
                figures(climb, waiting: waiting, length: length)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Points")
                figures(climb, waiting: waiting, length: length)
            }
        }
        // One element rather than four, and a value rather than four labels,
        // the rule every composite row here follows — see ``HikeRow``. The
        // units are spoken in full because "km" and "m" are read out as
        // letters otherwise; ``HikeFormat/spokenElevation(_:locale:)`` is the
        // same fix the elevation chart already carries.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Points")
        .accessibilityValue(
            Self.spoken(draft.distanceMeters, climb: climb, measuring: waiting)
        )
    }

    @ViewBuilder
    private func figures(
        _ climb: RouteElevationSummary?,
        waiting: Bool,
        length: String
    ) -> some View {
        HStack(spacing: 10) {
            // The same thing the *Search this area* pill's spinner says, in
            // the slot the answer will land in: a figure is coming. It is on
            // screen once, after the hiker stops drawing, for as long as one
            // request takes — never during the drawing itself.
            if waiting {
                ProgressView()
                    #if os(iOS)
                    .controlSize(.mini)
                    #endif
            }
            if let gain = climb?.gainMeters {
                Label(Self.height(gain), systemImage: "arrow.up")
            }
            if let loss = climb?.lossMeters {
                Label(Self.height(loss), systemImage: "arrow.down")
            }
            Text(length)
        }
        .monospacedDigit()
        .imageScale(.small)
        .accessibilityIdentifier("trail-draft-length")
    }

    private static func height(_ meters: Double) -> String {
        HikeFormat.elevation(Measurement(value: meters, unit: UnitLength.meters))
    }

    /// The same height with its unit said in full, because "m" is read out as
    /// a letter otherwise.
    private static func spokenHeight(_ meters: Double) -> String {
        HikeFormat.spokenElevation(Measurement(value: meters, unit: UnitLength.meters))
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// The same figures as a sentence, with every unit said in full.
    ///
    /// The spinner is a shape and says nothing, so the sentence is where a
    /// hiker who cannot see it is told a number is on its way.
    static func spoken(
        _ meters: Double,
        climb: RouteElevationSummary?,
        measuring: Bool = false
    ) -> String {
        let length = Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .wide, usage: .road))
        let parts = [
            length,
            measuring ? String(localized: "measuring the climb") : nil,
            climb?.gainMeters.map { gain in
                String(localized: "\(Self.spokenHeight(gain)) of climb")
            },
            climb?.lossMeters.map { loss in
                String(localized: "\(Self.spokenHeight(loss)) of descent")
            },
        ]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

/// One point in the list, named by its place in the line and how far along it
/// sits.
///
/// The second line is about the **leg arriving at it**, and only when there is
/// something to say: a leg that snapped or that the hiker straightened
/// themselves says nothing, so the list is quiet until something is worth
/// reading. See ``TrailLegSnap/notice``.
///
/// **It reads the drawing itself rather than being handed three values off
/// it**, and that is the render-isolation decision on this screen. A
/// twenty-point trail waits on nineteen separate Overpass answers, and every
/// one of them writes ``TrailDraft/legs`` and ``TrailDraft/distancesAlongLine``
/// — so a parent body that read either of those to *build* these rows would be
/// re-evaluated nineteen times, taking the places list, the candidate list and
/// the search field with it, because a `View` holding a closure cannot be
/// compared and is rebuilt whether or not anything it draws has changed. Read
/// here, the same answer redraws the rows and the footer and nothing else —
/// and a `List` is lazy, so it asks only the rows on screen.
struct TrailDraftWaypointRow: View {
    let draft: TrailDraft
    /// Where in the line this row sits. The number a hiker reads is one more:
    /// a list is counted from one and an array from zero.
    let index: Int

    var body: some View {
        let number = index + 1
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Point \(number)")
                Spacer(minLength: 12)
                Text(Self.length(draft.distanceAlongLine(toWaypointAt: index)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // The leg *into* this point, which is why the first row never has
            // one: nothing arrives at it.
            if let notice = draft.leg(arrivingAtWaypointAt: index)?.snap.notice {
                TrailDraftNoticeLabel(notice: notice)
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

/// What the whole line has to say for itself, under the points.
///
/// Its own `View` for the reason the row above is: both of the things it draws
/// are read off ``TrailDraft/legs``, which every leg that lands rewrites.
struct TrailDraftLineFooter: View {
    let draft: TrailDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One line for the whole line, saying the worst thing any leg has
            // to report — see ``TrailDraft/notice``. The per-leg sentence is on
            // the row it belongs to; this is what a hiker who has not scrolled
            // sees.
            if let notice = draft.notice {
                TrailDraftNoticeLabel(notice: notice)
            }
            // The two gestures on the map that nothing on screen could
            // otherwise announce. Both are discoverable only by being told: a
            // leg looks like a drawing rather than a control, and a pin that
            // answers a press but not a tap advertises nothing. Withheld until
            // there is a line to do either to.
            if !draft.legs.isEmpty {
                Text(
                    """
                    Tap a leg to add a point in the middle. \
                    Press and hold a point to move it.
                    """
                )
            }
        }
    }
}

/// *Try Again*, offered only when Overpass refused something.
///
/// Not for a leg with nothing mapped under it and not for one the hiker
/// straightened themselves: asking again about either would spend a request to
/// be told the same thing. See ``TrailLegSnap/isRetryable``.
///
/// Its own `View` for the reason the two above are — it reads
/// ``TrailDraft/legs``, and it is a row inside the same section they are.
struct TrailDraftRetryRow: View {
    let maker: TrailDraftController

    var body: some View {
        if maker.draft.hasRetryableLegs {
            Button("Try Again", systemImage: "arrow.clockwise", action: maker.retryRefusedLegs)
                .accessibilityIdentifier("trail-draft-retry")
        }
    }
}
