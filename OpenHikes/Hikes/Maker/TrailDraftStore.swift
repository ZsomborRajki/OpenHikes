//
//  TrailDraftStore.swift
//  OpenHikes
//
//  Reading and writing the one ``TrailDraftRecord``.
//
//  Its own type rather than three calls spread through the controller,
//  because "there is exactly one draft row" is a rule and a rule wants one
//  place to live. Every write goes through
//  ``save(waypoints:places:snapsToPaths:travelMode:startIsOpen:)``, which updates the row that is
//  there rather than inserting beside it.
//
//  A failed read or write is logged and swallowed, deliberately. What is at
//  stake is a convenience — coming back to a half-drawn line — and there is
//  nothing a hiker mid-draw could do about a store that refused, while an
//  alert over the map would interrupt the drawing to report that the drawing
//  may not survive being interrupted. The line itself is in ``TrailDraft`` and
//  is unaffected.
//
//  Swallowed is not the same as ignored. A read that threw is answered as a
//  failure rather than as an empty store, because the two differ by exactly
//  one thing: whether ``save(waypoints:places:snapsToPaths:travelMode:startIsOpen:)`` writes a second
//  row beside the first. See the note on it.
//

import Foundation
import os
import SwiftData

/// What was left half-drawn: the points and routing choices.
///
/// A type rather than a tuple for the reason ``CommunityNearbyAnswer`` is one:
/// the second field is the one a reader has to be able to find, and a caller
/// that forgets it resumes a drawing in the wrong mode — silently, because a
/// straight line and a straightened line look identical until the next point
/// goes down.
///
/// The resolved leg shapes are deliberately absent. They are re-derivable, the
/// graph behind them is on disk for a month, and a restored draft asks for
/// them again the moment the maker opens — see
/// ``TrailDraftController/setEditing(_:)``.
nonisolated struct StoredTrailDraft: Equatable, Sendable {
    var waypoints: [TrailWaypoint]
    /// What was marked along it. Kept apart from the points for the reason
    /// ``TrailDraft/places`` is: a place is a spot on the ground rather than a
    /// rank in the line, and a hiker can have marked the hut before drawing
    /// anything at all.
    var places: [TrailPlace] = []
    var snapsToPaths: Bool
    var travelMode: TrailTravelMode = .hiking
    var startIsOpen = false
    /// The hike this drawing is an edit of — see
    /// ``TrailDraftRecord/editingHikeID``.
    var editingHikeID: UUID?
    /// See ``TrailDraftRecord/editingPlaceIDs``.
    var editingPlaceIDs: [UUID] = []

    /// Both lists, because either on its own is a drawing worth coming back
    /// to — see ``TrailDraft/isEmpty``.
    var isEmpty: Bool { waypoints.isEmpty && places.isEmpty }

    /// No drawing to come back to. The toggle's own default, so a maker opened
    /// against an empty store starts the way a new draft starts.
    static let nothing = Self(waypoints: [], places: [], snapsToPaths: true)
}

@MainActor
struct TrailDraftStore {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailDraft")

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// The stored draft, and empty when nothing has been drawn.
    ///
    /// Empty rather than an optional, and the two would say the same thing
    /// anyway: a row left behind by a cleared draft, no row at all, and a read
    /// that threw all mean *there is no drawing to come back to*, so answering
    /// one way for all three is what keeps the caller from having to know
    /// which of them it got.
    func load() -> StoredTrailDraft {
        do {
            guard let record = try existingRecord() else { return .nothing }
            // The names are read only when there is exactly one per point. Two
            // columns holding one list is an invariant rather than a type — see
            // ``TrailDraftRecord/waypointNames`` — and the honest answer to a
            // row where they have come apart is the line with nothing written
            // beside it, never a name matched to whichever point shares its
            // index.
            let names = record.waypointNames.count == record.waypoints.count
                ? record.waypointNames
                : []
            return StoredTrailDraft(
                waypoints: record.waypoints.enumerated().map { index, point in
                    TrailWaypoint(
                        latitude: point.latitude,
                        longitude: point.longitude,
                        name: names.indices.contains(index) ? names[index] : ""
                    )
                },
                places: record.places,
                snapsToPaths: record.snapsToPaths,
                travelMode: record.travelMode,
                startIsOpen: record.startIsOpen,
                editingHikeID: record.editingHikeID,
                editingPlaceIDs: record.editingPlaceIDs
            )
        } catch {
            log("load", error)
            return .nothing
        }
    }

    /// Writes the draft, replacing whatever was there.
    ///
    /// **A read that failed is not an empty store**, and this writes nothing
    /// when it cannot tell the two apart. Treating a thrown fetch as "no row"
    /// is what takes the branch below and inserts a *second* row beside the
    /// one that is already there — breaking the single rule this type exists
    /// to hold, and leaving ``load()`` to answer with whichever of the two an
    /// unsorted fetch limit hands back. Losing one write of a convenience is
    /// the cheaper failure, and it is the same one a refused `context.save()`
    /// already takes.
    func save(
        waypoints: [TrailWaypoint],
        places: [TrailPlace],
        snapsToPaths: Bool,
        travelMode: TrailTravelMode = .hiking,
        startIsOpen: Bool = false,
        editingHikeID: UUID? = nil,
        editingPlaceIDs: [UUID] = []
    ) {
        let points = waypoints.map(\.routeCoordinate)
        // Written in the same statement that writes the points, every time, so
        // the two columns cannot come apart through a path that remembered one
        // and forgot the other — the invariant
        // ``TrailDraftRecord/waypointNames`` describes, kept by there being one
        // writer.
        let names = waypoints.map(\.name)
        do {
            if let record = try existingRecord() {
                record.waypoints = points
                record.waypointNames = names
                record.places = places
                record.snapsToPaths = snapsToPaths
                record.travelMode = travelMode
                record.startIsOpen = startIsOpen
                record.editingHikeID = editingHikeID
                record.editingPlaceIDs = editingPlaceIDs
                record.updatedAt = .now
            } else {
                context.insert(
                    TrailDraftRecord(
                        waypoints: points,
                        waypointNames: names,
                        places: places,
                        snapsToPaths: snapsToPaths,
                        updatedAt: .now,
                        travelMode: travelMode,
                        startIsOpen: startIsOpen,
                        editingHikeID: editingHikeID,
                        editingPlaceIDs: editingPlaceIDs
                    )
                )
            }
        } catch {
            log("save", error)
            return
        }
        commit("save")
    }

    /// Throws the draft away, which is what Cancel and a completed Save both
    /// do. Deleting the row rather than emptying it: a draft nobody is drawing
    /// should leave nothing behind.
    func clear() {
        do {
            guard let record = try existingRecord() else { return }
            context.delete(record)
        } catch {
            log("clear", error)
            return
        }
        commit("clear")
    }

    /// The one row, or none.
    ///
    /// A fetch limit rather than a uniqueness constraint, for the reason
    /// ``TrailDraftRecord`` gives. If a second row ever existed — nothing here
    /// writes one — this answers with the same one every time rather than
    /// alternating, since a `FetchDescriptor` with no sort is stable for a
    /// store nothing else is writing to.
    ///
    /// Throwing rather than answering `nil`, because "the fetch failed" and
    /// "there is no draft" are the same word to a caller that cannot tell them
    /// apart, and one of the three callers writes a row on the second — see
    /// ``save(waypoints:places:snapsToPaths:travelMode:startIsOpen:)``.
    private func existingRecord() throws -> TrailDraftRecord? {
        var descriptor = FetchDescriptor<TrailDraftRecord>()
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func commit(_ operation: String) {
        do {
            try context.save()
        } catch {
            log(operation, error)
        }
    }

    private func log(_ operation: String, _ error: any Error) {
        Self.logger.error(
            """
            A trail draft could not be read or written (\(operation, privacy: .public)): \
            \(error.localizedDescription, privacy: .public)
            """
        )
    }
}
