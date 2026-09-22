//
//  TrailStopNaming.swift
//  OpenHikes
//
//  What is at a point, in words, for the row that stands for it.
//
//  A tap on the map puts a coordinate down and a coordinate is not something a
//  hiker reads. Through Phase 6 the list said so honestly — "Point 3", and how
//  far along it sat — but once the list became a list of *stops* the row has
//  room for the one thing that makes a route legible away from the map: the
//  name of the place it goes through. A hiker who picks a stop out of the
//  search sheet has already said what it is. This is the other half: what to
//  call the ones they simply tapped.
//
//  ## It is a description, never a choice
//
//  Everything else in this feature that writes to ``TrailDraft`` is a hiker
//  doing something, and takes a step of undo. This is not: the answer arrives a
//  second after a tap, from a request nobody is watching, about a point that is
//  already down. So it goes in through ``TrailDraft/describe(waypointWith:as:)``,
//  which records no step, moves no leg and refuses a point that has since been
//  named — and ``TrailDraft/move(waypointAt:to:)`` throws the name away again,
//  because a description of where a point *was* is the one thing on that row
//  that could be false.
//
//  ## One request at a time, and never twice for the same point
//
//  The same shape ``TrailDraftController`` routes legs in, and for the same
//  reason: a hiker putting down five points in five seconds is five questions,
//  and five at once from one phone is the burst that earns a rate limit. They
//  are queued and drained one at a time instead, newest last, and a point that
//  has been answered — or refused — is not asked about again. A refusal is not
//  retried by itself, exactly as a refused leg is not: asking again on the next
//  tap would spend a request per point to be told the same thing.
//
//  **A point is its id *and* where it stands.** A stop that is dragged keeps its
//  id and loses its name, so a record kept by id alone would call the dragged
//  stop finished-with and leave its row reading "Stop 2" for the rest of the
//  drawing. Keyed by ``TrailStopQuestion`` instead, the moved stop is a new
//  question, and an answer that lands after the move is about the spot it left
//  — which is why the answer carries the question back and
//  ``TrailDraftController`` refuses it for a stop that has moved since.
//
//  ## MapKit's own geocoder, not Core Location's
//
//  `CLGeocoder` is deprecated as of iOS 26 and this project builds with
//  warnings as errors, so it is not an option here even where it would do.
//  `MKReverseGeocodingRequest` is the replacement, its completion handler is
//  declared on the main actor, and ``TrailStopNaming`` is main-actor isolated
//  to match rather than hopping twice to arrive back where it started.
//

import CoreLocation
import Foundation
import MapKit
import os

/// What MapKit knows about a coordinate, or `nil` for a lookup that found
/// nothing or could not be made. A stop's name and the place sheet's address
/// are both read off it — see ``TrailStopName``.
///
/// A seam for the reason the tile, transport, elevation and trail-point sources
/// are ones — see *Deliberate test seams* in the repository instructions. The
/// app hands the maker ``MapKitTrailStopNaming``; a suite hands it a stub or
/// nothing at all, and `nil` is the launch that must not ask: a preview, and
/// every launch running tests, which is what keeps a row's text a fact about
/// the code rather than about the network the runner was on.
@MainActor
protocol TrailStopNaming {
    func mapItem(at coordinate: CLLocationCoordinate2D) async -> MKMapItem?
}

/// MapKit's answer to *what is here*.
@MainActor
struct MapKitTrailStopNaming: TrailStopNaming {
    func mapItem(at coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
        let location = CLLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Failable, for a location MapKit will not accept — the same refusal
        // `MKLocalSearch` makes of a region that is not a place.
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return nil
        }
        return try? await request.mapItems.first
    }
}

/// Which of the things MapKit says about a place is the one a row reads.
///
/// Its own type, and free of everything but `MKMapItem`, because this is the
/// half worth asserting on: an `MKMapItem` can be built by hand since iOS 26
/// (`init(location:address:)`), so a suite can hand this every shape a response
/// takes without a network call — which is the whole of what
/// ``MapKitTrailStopNaming`` cannot be asked.
///
/// ## Two questions, two orders, and `name` is not a reliable answer to either
///
/// **`MKMapItem.name` is never empty.** Assign `nil` to it and it hands back a
/// localized placeholder — "Unknown Location" on this SDK — which is neither a
/// name nor detectable by asking whether there is one. So a rule that simply
/// preferred the name would put that placeholder in a row for every spot MapKit
/// has nothing to call, which on a hillside is most of them.
///
/// The split that removes the problem is not a workaround, it is the two
/// questions being genuinely different:
///
/// - ``chosen(_:)`` answers *what did the hiker pick*, and the hiker picked a
///   row that said a name. A search result always carries a real one.
/// - ``here(_:)`` answers *what is at this coordinate*, which is what an
///   address is for — the same answer Apple Maps gives a dropped pin. It never
///   falls back to the name, so the placeholder has nowhere to get in.
nonisolated enum TrailStopName {
    /// The best line for a place the hiker chose out of the search: its name,
    /// and its address only if MapKit declines to name it.
    static func chosen(_ item: MKMapItem?) -> String? {
        guard let item else { return nil }
        return first(of: [item.name, item.address?.shortAddress, item.address?.fullAddress])
    }

    /// The best line for a coordinate nobody named — a tap on the map.
    ///
    /// The address and nothing else. `nil` for an item with no address at all,
    /// which is an item MapKit could not place: its `name` in that state is the
    /// placeholder described above, and a row reading "Unknown Location" says
    /// strictly less than one reading "Stop 2".
    /// The whole address, for the place sheet, where there is room for it.
    static func address(of item: MKMapItem) -> String? {
        first(of: [item.address?.fullAddress, item.address?.shortAddress])
    }

    static func here(_ item: MKMapItem?) -> String? {
        guard let item else { return nil }
        return first(of: [item.address?.shortAddress, item.address?.fullAddress])
    }

    /// The first candidate with anything in it, bounded.
    ///
    /// Bounded where it enters, like every other name in this app that did not
    /// come from a keyboard — see ``HikeTitle``. This one arrives from a
    /// service, which is precisely the unattended input that bound exists for.
    private static func first(of candidates: [String?]) -> String? {
        for candidate in candidates {
            let bounded = BoundedText.boundedOrEmpty(candidate ?? "", to: .title)
            guard !bounded.isEmpty else { continue }
            return bounded
        }
        return nil
    }
}

/// One lookup: which point, and where it stood when it was asked about.
///
/// The key the namer keeps its record by, rather than the bare id — see the
/// file header for the dragged stop that made the difference.
nonisolated struct TrailStopQuestion: Hashable, Sendable {
    let id: UUID
    let latitude: Double
    let longitude: Double

    init(_ waypoint: TrailWaypoint) {
        id = waypoint.id
        latitude = waypoint.latitude
        longitude = waypoint.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The queue in front of ``TrailStopNaming``, and the record of what has
/// already been asked.
///
/// Owned by ``TrailDraftController``, like ``TrailDraftElevation`` and
/// ``TrailPointFinder``, and it keeps the same bargain those two do: nothing it
/// holds is part of the drawing, and closing the maker forgets all of it. What
/// it *writes* is part of the drawing, which is why the controller hands it a
/// way to write rather than the draft itself — the name has to be persisted in
/// the same turn it lands, and persisting is the controller's job.
@MainActor
final class TrailStopNamer {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailDraft")

    private let source: (any TrailStopNaming)?

    /// Every point this namer is finished with, where it stood: answered, or
    /// asked and refused. Kept so a spot is asked about exactly once — see the
    /// file header for why a refusal is not retried by itself, and for why a
    /// stop that moves is asked about again.
    private var settled: Set<TrailStopQuestion> = []

    /// What is waiting to be asked, oldest first.
    private var queue: [TrailStopQuestion] = []

    /// The one drain in progress, or `nil` when the queue is empty.
    private var drain: Task<Void, Never>?

    /// Which drain is the current one. A drain cancelled by ``clear()`` can
    /// still be finishing its last request when the next one starts, and it
    /// must not hand the handle back on the way out — that would leave the new
    /// drain running unrecorded, and the next call would start a second beside
    /// it: two lookups at once, the burst this queue exists to prevent.
    private var drainGeneration = 0

    /// How a name reaches the drawing. Set by the controller, because writing
    /// one also means writing the draft down.
    private var apply: ((TrailStopQuestion, String) -> Void)?

    init(source: (any TrailStopNaming)?) {
        self.source = source
    }

    /// Whether this namer can ask anything at all — false for a preview and for
    /// every launch running tests.
    var canAsk: Bool { source != nil }

    func onNamed(_ apply: @escaping (TrailStopQuestion, String) -> Void) {
        self.apply = apply
    }

    /// Asks about every point that has no name and has not been asked about.
    ///
    /// Called after each edit to the line rather than per point put down, so
    /// one call covers the tap that added a point, the restore that brought
    /// twenty back and the reorder that changed which of them is the start.
    /// It costs nothing at all once every point is settled, which is the state
    /// a drawing spends nearly all of its life in.
    func nameUnnamed(in waypoints: [TrailWaypoint]) {
        guard source != nil else { return }
        let waiting = Set(queue)
        let wanted = waypoints
            .filter(\.name.isEmpty)
            .map(TrailStopQuestion.init)
            .filter { question in
                !settled.contains(question) && !waiting.contains(question)
            }
        guard !wanted.isEmpty else { return }
        queue.append(contentsOf: wanted)
        startDraining()
    }

    /// Forgets everything in flight and everything asked. What the maker
    /// closing does.
    ///
    /// The record of what has been asked goes too, deliberately: reopening a
    /// drawing whose lookups failed while the phone was in a tunnel is a hiker
    /// who has plausibly moved, and one more attempt per point per opening is a
    /// bound a hiker sets with their thumb.
    func clear() {
        drainGeneration &+= 1
        drain?.cancel()
        drain = nil
        queue = []
        settled = []
    }

    private func startDraining() {
        guard drain == nil else { return }
        let generation = drainGeneration
        drain = Task { [weak self] in
            await self?.drainQueue()
            guard let self, drainGeneration == generation else { return }
            drain = nil
        }
    }

    /// Takes the queue one at a time, re-reading it between answers so a point
    /// added while this was waiting is picked up by the same pass.
    private func drainQueue() async {
        guard let source else { return }
        while !queue.isEmpty {
            guard !Task.isCancelled else { return }
            let question = queue.removeFirst()
            // Marked settled *before* the answer, not after: a refusal must
            // leave the point as finished-with as an answer does, and a second
            // call arriving mid-request must not queue the same point again.
            settled.insert(question)
            let name = TrailStopName.here(await source.mapItem(at: question.clCoordinate))
            guard !Task.isCancelled else { return }
            guard let name else {
                Self.logger.info("No name found for a drawn point")
                continue
            }
            apply?(question, name)
        }
    }
}
