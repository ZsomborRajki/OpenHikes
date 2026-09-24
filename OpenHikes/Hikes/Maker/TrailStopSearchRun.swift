//
//  TrailStopSearchRun.swift
//  OpenHikes
//
//  What the stop search *does*, apart from how it is drawn: which row it was
//  opened from, the place a pick resolves to, and the one `MKLocalSearch` a
//  tapped suggestion runs. `TrailStopSearch.swift` is the sheet, and its header
//  is the argument for the arrangement.
//
//  A file of its own so the coverage floor keeps measuring this while the
//  sheet, which is view bodies only CI's unmeasured UI suite evaluates, is on
//  `Scripts/coverage-exclusions.txt`.
//

import CoreLocation
import MapKit
import Observation

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
