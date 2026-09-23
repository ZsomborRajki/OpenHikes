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
/// The cases are the things a row can be on the screen below: a stop that is
/// already down, which a result *moves*; an open start or destination field,
/// which a result fills; and the *Add Stop* row at the bottom, which appends.
/// Carried by the sheet rather than decided when a result lands, because it is
/// a fact about the tap that opened it.
nonisolated enum TrailStopSearchTarget: Equatable, Sendable {
    /// Replace the place this point stands for, keeping its place in the line.
    case existing(id: UUID, role: TrailStopRole)
    /// Put a new stop on the end.
    case newStop
    /// Fill the open start or destination field.
    case open(TrailStopRole)

    /// What the sheet is called while it is up. The row's own word, so a hiker
    /// who opened the wrong row can see that they did.
    var title: String {
        switch self {
        case .existing(_, let role), .open(let role): role.title
        case .newStop: String(localized: "Add Stop")
        }
    }

    /// Whether the place picked here ends up as the start or the destination.
    ///
    /// What decides where the camera goes afterwards. An end is what gives the
    /// line its extent, so a pick that puts one down frames the whole line —
    /// the destination is where the route appears, and zooming to its pin
    /// would leave most of it off the screen. A stop in the middle is a detail
    /// of a line already in view, and the camera goes to it.
    ///
    /// *Add Stop* is an end too: it fills an open start or destination while
    /// there is one, and otherwise appends a new destination — see
    /// ``TrailDraftController/appendWaypoint(at:named:)``.
    var landsOnAnEnd: Bool {
        switch self {
        case .existing(_, .stop): false
        case .existing, .open, .newStop: true
        }
    }
}

/// A place the sheet is about to hand back: what it is called, and where.
///
/// An empty name is a stop for ``TrailStopNamer`` to name — which is what the
/// *My Location* row hands back, for the reason it gives.
nonisolated struct TrailStopSearchPick: Equatable, Sendable {
    var name: String
    /// The address line the suggestion carried — what a recent entry shows
    /// under the name. Empty where there was none.
    var subtitle: String = ""
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
    init?(firstOf items: [MKMapItem], fallbackName: String, subtitle: String = "") {
        guard let item = items.first else { return nil }
        let coordinate = item.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        // MapKit's own spelling in preference to the completion's title,
        // because they differ exactly where it matters: "kehlstein" comes
        // back as "Kehlsteinhaus". The completion's title is the fallback
        // rather than nothing, because a search that resolved to a coordinate
        // has found the place whatever it declines to call it.
        name = TrailStopName.chosen(item) ?? fallbackName
        self.subtitle = subtitle
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    init(name: String, coordinate: CLLocationCoordinate2D, subtitle: String = "") {
        self.name = name
        self.subtitle = subtitle
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

/// What the sheet is doing, for as long as it is up.
///
/// A reference type rather than the sheet's `@State`, and for once the reason
/// is not the screen underneath: this is held by ``TrailDraftView``, so it
/// survives the sheet being torn down while the resolve it started is still in
/// flight. A hiker who taps a row and swipes the sheet away has not asked for
/// the stop to be put down, and the `target` going `nil` is what says so.
@MainActor
@Observable
final class TrailStopSearchRun {
    /// Which row this is about, or `nil` when the sheet is not up.
    private(set) var target: TrailStopSearchTarget?

    /// What the field opens holding: the name or address of the stop already
    /// in the row — see ``TrailStopSearchSheet``. Empty for an open field and
    /// for *Add Stop*.
    private(set) var prefill = ""

    /// The completion currently being resolved, so its row can say so.
    private(set) var resolving: MKLocalSearchCompletion?

    /// Whether the last resolve found nothing. Cleared by the next keystroke,
    /// so the sheet does not keep reporting a failure the hiker has moved on
    /// from.
    private(set) var didFail = false

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Points the sheet at a row, with what its field opens holding.
    func begin(_ target: TrailStopSearchTarget, prefill: String = "") {
        cancel()
        self.target = target
        self.prefill = prefill
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
                      fallbackName: completion.title,
                      subtitle: completion.subtitle
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
    /// The hiker's own position, or `nil` for a launch with no location — the
    /// *My Location* row then waits, disabled, as it does before a first fix.
    var locationManager: LocationManager?
    /// The places picked here before — shown while nothing has been typed, as
    /// Apple Maps' *Recents* are. See ``TrailStopRecents``.
    let recents: TrailStopRecents
    var onPick: (TrailStopSearchPick) -> Void
    var onClose: () -> Void

    @State private var query = ""
    /// The field's selection — the whole of what it opened holding, so a
    /// keystroke replaces it. See `onAppear` below.
    @State private var selection: TextSelection?
    /// Whether that first selection has been made; once per presentation, so
    /// focusing the field again later does not select over the hiker's typing.
    @State private var hasSelectedPrefill = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                queryField
                // Recents while nothing has been typed, *My Location* always
                // first among them — see ``TrailStopRecentsSection``. The
                // text a row opens holding counts as nothing typed: it is a
                // place already chosen, and the hiker has not searched yet.
                if query.isEmpty || query == run.prefill {
                    TrailStopRecentsSection(recents: recents, locationManager: locationManager, onPick: onPick)
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
            //
            // **A row that already holds a place opens with it in the field**,
            // as Apple Maps' own fields do — its address, street and number
            // and all — and selected whole, so one keystroke replaces it and
            // one delete clears it. Until then the list under it is the one an
            // empty field shows, *My Location* first, rather than places
            // matching a name the hiker did not type.
            .onAppear {
                query = run.prefill
                isFocused = true
            }
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
                TextField("Search for a place", text: $query, selection: $selection)
                    .accessibilityIdentifier("trail-stop-search-field")
                    .focused($isFocused)
                    // Selected once the field has the keyboard, which is when
                    // a selection is something it can hold — see `onAppear`.
                    .onChange(of: isFocused) { _, focused in
                        guard focused, !hasSelectedPrefill, !query.isEmpty else { return }
                        hasSelectedPrefill = true
                        selection = TextSelection(range: query.startIndex..<query.endIndex)
                    }
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: query) { _, value in
                        run.cancel()
                        // The opening text is not a search — see `onAppear`.
                        completer.update(query: value == run.prefill ? "" : value)
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }
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

/// *Recents*: where the hiker is, and then the places picked here before,
/// newest first, each one a tap from being put down again with no search at
/// all. Swiping one away forgets it.
///
/// Its own `View`, so a recent being recorded or forgotten re-renders this
/// section and not the field above it.
private struct TrailStopRecentsSection: View {
    let recents: TrailStopRecents
    /// The hiker's own position, or `nil` for a launch with no location.
    var locationManager: LocationManager?
    var onPick: (TrailStopSearchPick) -> Void

    var body: some View {
        Section("Recents") {
            myLocationRow
            ForEach(recents.entries) { recent in
                Button { onPick(recent.pick) } label: {
                    row(for: recent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trail-stop-search-recent")
            }
            .onDelete { offsets in recents.remove(atOffsets: offsets) }
        }
    }

    /// Where the hiker is — **always the first row**, as Apple Maps' own list
    /// starts, because a walk usually starts where you are standing and the
    /// alternative is searching for the name of a car park you can see.
    ///
    /// Always there, rather than appearing with the first fix: a row that is
    /// sometimes missing is a row a hiker learns not to look for. Until there
    /// is a fix it says so and waits, disabled, instead of doing nothing when
    /// pressed. Offered on ``LocationManager/hasFix``, which changes once, and
    /// resolved on the tap, so the sheet is not rebuilt once a second while
    /// the hiker is typing.
    ///
    /// **The stop it puts down is not called "My Location".** Apple Maps' row
    /// means the hiker, and follows them; this one puts a point where they are
    /// standing *now*, which stays there. A row reading "My Location" would be
    /// true until they took a step, and the draft is kept across launches, so
    /// tomorrow it would name yesterday's car park after wherever the phone
    /// happens to be. The stop goes down unnamed instead and
    /// ``TrailStopNamer`` gives it the address of the spot it stands on — the
    /// one description of it that stays true, and the one a tapped stop gets.
    /// For the same reason it is never kept as a recent.
    private var myLocationRow: some View {
        let hasFix = locationManager?.hasFix == true
        // Said, rather than waited on for ever: a refusal is the one state
        // no fix is coming from — see ``LocationManager/isAccessDenied``.
        let isDenied = locationManager?.isAccessDenied == true
        return Button {
            guard let here = locationManager?.coordinate else { return }
            onPick(TrailStopSearchPick(name: "", coordinate: here))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "location.circle.fill")
                    .font(.title2)
                    .foregroundStyle(hasFix ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Location").foregroundStyle(hasFix ? .primary : .secondary)
                    if !hasFix {
                        Text(isDenied ? "Location access is off" : "Waiting for your location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .disabled(!hasFix)
        // Not a recent, so a swipe cannot take it away.
        .deleteDisabled(true)
        .accessibilityIdentifier("trail-stop-search-here")
    }

    private func row(for recent: TrailStopRecent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.name).foregroundStyle(.primary)
                if !recent.subtitle.isEmpty {
                    Text(recent.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        // One element rather than three, the rule every composite row here
        // follows — see ``HikeRow``.
        .accessibilityElement(children: .combine)
    }
}
