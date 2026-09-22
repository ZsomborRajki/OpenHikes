//
//  TrailStopSearch.swift
//  OpenHikes
//
//  Finding a place, and putting it in the row the search was started from.
//
//  Through Phase 6 the maker carried a *Find a Place* field that moved the
//  camera and placed nothing — somewhere to look while drawing, and nothing
//  more. That field is gone, and this is what replaced it: a sheet raised *by a
//  row*, which fills that row with what it finds. It is the Apple Maps
//  arrangement and it is better than the field was for one reason — every
//  search now ends in the hiker's route rather than only in the camera, and the
//  camera still moves, so "go and look at that valley" costs exactly what it
//  did and leaves a point behind when it gets there.
//
//  ## The list is the completer's, and the resolve happens on the tap
//
//  A `MKLocalSearchCompleter` answers a keystroke with a title and a subtitle,
//  and the subtitle *is* the address — "Lurdy Ház" over "Könyves Kálmán körút
//  12-14, Budapest". That is already the list the hiker asked to see, it costs
//  no `MKLocalSearch` per keystroke, and it is what this draws.
//
//  What a completion has *not* got is a coordinate, so one `MKLocalSearch` runs
//  when a row is tapped — one per place actually chosen, rather than one per
//  character typed. The row shows a spinner while that is in flight, because it
//  is the one moment in this sheet where a tap is not instant.
//
//  ## It borrows the map's completer, and gives it back
//
//  The same one ``MapSheet``'s own field uses, which is fed the settled region
//  by `MapView.Coordinator` — so a hiker drawing in Bavaria is offered places
//  in Bavaria rather than places on the other side of the planet. Because it is
//  shared, this sheet clears it on the way out, exactly as the field it
//  replaced did.
//
//  ## The travel mode is not chosen here
//
//  Apple Maps puts its car/walk/transit selector above this list; the maker
//  puts it above the stops instead — see ``TrailTravelModePicker``. It is a
//  property of the whole draft rather than of one stop, so a search that
//  fills a row changes where the line goes and never how it is routed.
//

import CoreLocation
import MapKit
import Observation
import SwiftUI

/// Which row a search was started from, and therefore what picking a result
/// does.
///
/// The two cases are the two things a row can be on the screen below: a stop
/// that is already down, which a result *moves*; and the *Add Stop* row at the
/// bottom, which has no point behind it and appends one. Carried by the sheet
/// rather than decided when a result lands, because it is a fact about the tap
/// that opened it.
nonisolated enum TrailStopSearchTarget: Equatable, Sendable {
    /// Replace the place this point stands for, keeping its place in the line.
    case existing(id: UUID, role: TrailStopRole)
    /// Put a new stop on the end.
    case newStop

    /// What the sheet is called while it is up. The row's own word, so a hiker
    /// who opened the wrong row can see that they did.
    var title: String {
        switch self {
        case .existing(_, let role): role.title
        case .newStop: String(localized: "Add Stop")
        }
    }
}

/// A place the sheet is about to hand back: what it is called, and where.
///
/// One value for both lists, where the maker used to carry two. The *places*
/// list marks one of these and the *route* goes through one, which are
/// different lists for the reason ``TrailDraft`` gives — but "a place a lookup
/// found" is one fact, and keeping two types for it meant two ways of deciding
/// what MapKit had actually said.
nonisolated struct TrailStopSearchPick: Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The first result of a response, or `nil` for one with nothing in it or
    /// nothing at a valid coordinate.
    ///
    /// The *first*: it is the one the request was about, and offering a second
    /// answer to a row the hiker has already chosen would be the sheet arguing
    /// with them.
    init?(firstOf items: [MKMapItem], fallbackName: String) {
        guard let item = items.first else { return nil }
        let coordinate = item.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        // MapKit's own spelling in preference to the completion's title,
        // because they differ exactly where it matters: "kehlstein" comes
        // back as "Kehlsteinhaus". The completion's title is the fallback
        // rather than nothing, because a search that resolved to a coordinate
        // has found the place whatever it declines to call it.
        name = TrailStopName.chosen(item) ?? fallbackName
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    init(name: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

/// What the sheet is doing, for as long as it is up.
///
/// A reference type rather than the sheet's `@State`, and for once the reason
/// is not the screen underneath: this is held by ``TrailDraftView``, so it
/// survives the sheet being torn down while the resolve it started is still in
/// flight — the same arrangement ``TrailPlaceEdit`` has, and for the same
/// reason. A hiker who taps a row and swipes the sheet away has not asked for
/// the stop to be put down, and the `target` going `nil` is what says so.
@MainActor
@Observable
final class TrailStopSearchRun {
    /// Which row this is about, or `nil` when the sheet is not up.
    private(set) var target: TrailStopSearchTarget?

    /// The completion currently being resolved, so its row can say so.
    private(set) var resolving: MKLocalSearchCompletion?

    /// Whether the last resolve found nothing. Cleared by the next keystroke,
    /// so the sheet does not keep reporting a failure the hiker has moved on
    /// from.
    private(set) var didFail = false

    /// The last place this sheet actually resolved, kept after it has closed.
    ///
    /// It is what lets the *places* list offer to mark it — the fourth of that
    /// list's add flows, and the only one that arrives with a name already on
    /// it. Before this sheet existed the maker's own *Find a Place* field kept
    /// the same thing for the same menu; the field is gone and the fact it held
    /// is not, because a hiker who has just searched out the hut at the col has
    /// plausibly two uses for it.
    ///
    /// Observed, so the entry appears with the answer, and read by one small
    /// section's body and nothing else — see ``TrailDraftPlaceSection``.
    private(set) var lastPick: TrailStopSearchPick?

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Points the sheet at a row.
    func begin(_ target: TrailStopSearchTarget) {
        cancel()
        self.target = target
    }

    /// The sheet has gone. Whatever it had in flight goes with it.
    func end() {
        cancel()
        target = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        if resolving != nil { resolving = nil }
        if didFail { didFail = false }
    }

    /// Runs one `MKLocalSearch` for a tapped completion and hands the answer to
    /// `deliver`, which is where the drawing changes.
    ///
    /// Biased to the same region the suggestions were, so the two halves of one
    /// list do not answer at two scales — the rule the field this replaced
    /// already followed.
    func resolve(
        _ completion: MKLocalSearchCompletion,
        near region: MKCoordinateRegion?,
        deliver: @escaping (TrailStopSearchPick) -> Void
    ) {
        cancel()
        resolving = completion
        let request = MKLocalSearch.Request(completion: completion)
        if let region {
            request.region = region
            request.regionPriority = .default
        }
        task = Task { [weak self] in
            let response = try? await MKLocalSearch(request: request).start()
            guard let self, !Task.isCancelled else { return }
            resolving = nil
            guard let response,
                  let pick = TrailStopSearchPick(
                      firstOf: response.mapItems,
                      fallbackName: completion.title
                  )
            else {
                // Said rather than swallowed, unlike the field this replaced.
                // There, a failure interrupted a hiker who was drawing; here
                // they have tapped a row and are waiting for it to do
                // something, and a row that does nothing is the one outcome a
                // sheet like this must never have.
                didFail = true
                return
            }
            if lastPick != pick { lastPick = pick }
            deliver(pick)
        }
    }
}

/// The sheet: a field, the places it finds, and the hiker's own position.
struct TrailStopSearchSheet: View {
    /// Fed the settled map region by the coordinator, so suggestions are
    /// answered near what the hiker is looking at — see ``SearchCompleter``.
    let completer: SearchCompleter
    /// Held by the screen, for the reason ``TrailStopSearchRun`` gives.
    let run: TrailStopSearchRun
    /// The hiker's own position, or `nil` for a launch with no location or one
    /// that has not had a fix yet. Withholds the *My Location* row.
    var locationManager: LocationManager?
    var onPick: (TrailStopSearchPick) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                queryField
                if locationManager?.hasFix == true, query.isEmpty {
                    myLocationRow
                }
                suggestions
                if run.didFail { failureRow }
            }
            .navigationTitle(run.target?.title ?? String(localized: "Add Stop"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onClose)
                        .accessibilityIdentifier("trail-stop-search-cancel")
                }
            }
            // Focused on the way in, because a sheet whose whole purpose is a
            // field is a sheet that should be ready to type into. `onAppear`
            // rather than at declaration: a `@FocusState` set before the field
            // is in the hierarchy is set on nothing.
            .onAppear { isFocused = true }
            // The completer is shared with the sheet underneath, so what this
            // asked it has to be given back — the same hand-back the field this
            // replaced made, and for the same reason. On the `NavigationStack`
            // rather than on a row, because a `List` is lazy.
            .onDisappear {
                run.cancel()
                completer.clear()
            }
        }
    }

    @ViewBuilder private var queryField: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search for a place", text: $query)
                    .accessibilityIdentifier("trail-stop-search-field")
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: query) { _, value in
                        run.cancel()
                        completer.update(query: value)
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }
        }
    }

    /// Where the hiker is, offered only while nothing has been typed.
    ///
    /// Apple Maps' own first row, and it earns its place on the one row that
    /// wants it most: a walk starts where you are standing, and the alternative
    /// is searching for the name of a car park you are looking at.
    ///
    /// Named rather than reverse-geocoded. "My Location" is what the hiker
    /// chose and is true wherever they end up standing, while an address
    /// resolved here would be the address of the spot they *were* at when they
    /// tapped — the same thing ``TrailDraft/move(waypointAt:to:)`` throws a
    /// name away for.
    ///
    /// Offered on ``LocationManager/hasFix`` and resolved on the tap, so the
    /// sheet is not rebuilt once a second while the hiker is typing.
    @ViewBuilder private var myLocationRow: some View {
        Section {
            Button {
                guard let here = locationManager?.coordinate else { return }
                onPick(
                    TrailStopSearchPick(
                        name: String(localized: "My Location"),
                        coordinate: here
                    )
                )
            } label: {
                Label("My Location", systemImage: "location.fill")
            }
            .accessibilityIdentifier("trail-stop-search-here")
        }
    }

    @ViewBuilder private var suggestions: some View {
        Section {
            ForEach(completer.suggestions, id: \.self) { suggestion in
                Button { pick(suggestion) } label: {
                    row(for: suggestion)
                }
                .buttonStyle(.plain)
                // Anything already being resolved holds the sheet: a second
                // tap while the first is in flight would leave two searches
                // racing to fill one row.
                .disabled(run.resolving != nil)
            }
        }
    }

    private func row(for suggestion: MKLocalSearchCompletion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).foregroundStyle(.primary)
                // The address, which is the whole reason this list is the
                // completer's rather than a list of bare names.
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if run.resolving == suggestion {
                ProgressView()
                    #if os(iOS)
                    .controlSize(.small)
                    #endif
            }
        }
        .contentShape(.rect)
        // One element rather than three, the rule every composite row here
        // follows — see ``HikeRow``.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var failureRow: some View {
        Section {
            Label("That place couldn't be found. Try another search.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("trail-stop-search-failed")
        }
    }

    /// **The field is not written with what was tapped**, and the absence is
    /// load-bearing rather than a simplification. Writing it would fire the
    /// `onChange` above on the next update — which cancels whatever is being
    /// resolved, including the resolve this very tap has just started. The
    /// suggestions stay on screen for the same reason a `commit(query:)` is not
    /// made here: a resolve that fails leaves the hiker looking at the list
    /// they were choosing from, with a line underneath saying why nothing
    /// happened, rather than at an empty sheet.
    private func pick(_ suggestion: MKLocalSearchCompletion) {
        isFocused = false
        run.resolve(suggestion, near: completer.region, deliver: onPick)
    }
}
