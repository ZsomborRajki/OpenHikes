//
//  HikePlaceChange.swift
//  OpenHikes
//
//  Adding, editing and removing one of a saved hike's places by hand, and
//  saving it — or, when the store refuses, putting the hike back as it was.
//
//  The four screens that do this — *Add Place* from the pill and while
//  recording, a place's *Edit* and its *Remove* — each used to save with
//  `try?` and carry on as though the change were kept (#719). A place that is
//  only pending is not one the hiker has: it is gone at the next launch unless
//  a later autosave happens to succeed. So every change here saves before it
//  answers, and a refusal undoes the change by hand and throws, leaving the
//  screen up with what the hiker entered so they can try again.
//
//  Undone by hand rather than through `ModelContext.rollback()`, for the
//  reason ``TrailWalkSession`` gives: the context is the
//  shared main one, and a rollback would also discard every other pending edit
//  in it.
//

import OpenHikesData
import os
import SwiftData
import SwiftUI

/// Why a place was not added, edited or removed.
///
/// Carries no diagnostic, for the reason ``TrailDraftRefusal/notSaved``
/// carries none.
enum HikePlaceRefusal: LocalizedError, Equatable {
    case notAdded
    case notEdited
    case notRemoved

    var errorDescription: String? {
        switch self {
        case .notAdded: String(localized: "This place couldn't be added.")
        case .notEdited: String(localized: "Your changes to this place couldn't be saved.")
        case .notRemoved: String(localized: "This place couldn't be removed.")
        }
    }

    // Says what was entered is still there, because the obvious reading of a
    // failed save is that it is gone.
    var recoverySuggestion: String? {
        switch self {
        case .notAdded, .notEdited:
            String(
                localized: "What you entered wasn't lost. Check that the device has storage available, then try again."
            )
        case .notRemoved:
            String(localized: "Check that the device has storage available, then try again.")
        }
    }
}

@MainActor
enum HikePlaceChange {
    typealias Save = (ModelContext) throws -> Void

    private static let logger = Logger(subsystem: "OpenHikes", category: "Places")

    /// Puts `place` on `hike` and saves it, answering whether it went in —
    /// `false`, with nothing saved, for an OpenStreetMap element the hike
    /// already has. See ``Hike/addPlace(_:in:now:)``.
    ///
    /// A refused save takes the row back out, so trying again cannot leave
    /// the place on the hike twice.
    @discardableResult static func add(
        _ place: TrailPlace,
        to hike: Hike,
        in context: ModelContext,
        save: Save = { try $0.save() }
    ) throws(HikePlaceRefusal) -> Bool {
        guard hike.addPlace(place, in: context) else { return false }
        do {
            try save(context)
        } catch {
            // A row's id is its place's — see ``TrailPoint``.
            let inserted = hike.trailPoints?.first { $0.id == place.id }
            hike.trailPoints?.removeAll { $0.id == place.id }
            if let inserted { context.delete(inserted) }
            logger.error("A place could not be added: \(error.localizedDescription, privacy: .public)")
            throw .notAdded
        }
        return true
    }

    /// Renames, re-kinds and re-describes one of the hiker's own places and
    /// saves it. Nothing is saved for a place that is not theirs to edit —
    /// see ``Hike/editPlace(id:name:symbol:note:)``.
    ///
    /// A refused save writes back what the place said before.
    static func edit(
        id: UUID,
        on hike: Hike,
        name: String,
        symbol: TrailPlaceSymbol?,
        note: String,
        in context: ModelContext,
        save: Save = { try $0.save() }
    ) throws(HikePlaceRefusal) {
        guard let row = hike.trailPoints?.first(where: { $0.id == id }) else { return }
        let before = row.place
        guard hike.editPlace(id: id, name: name, symbol: symbol, note: note) else { return }
        do {
            try save(context)
        } catch {
            row.apply(name: before.name, symbol: before.symbol, note: before.note)
            logger.error("A place could not be edited: \(error.localizedDescription, privacy: .public)")
            throw .notEdited
        }
    }

    /// Takes one place off `hike`, returning its photographs to the hike's
    /// gallery, and saves it. See ``Hike/removePlace(id:in:)``.
    ///
    /// A refused save puts the place back, and files the same photographs
    /// under it again.
    static func remove(
        id: UUID,
        from hike: Hike,
        in context: ModelContext,
        save: Save = { try $0.save() }
    ) throws(HikePlaceRefusal) {
        guard let row = hike.trailPoints?.first(where: { $0.id == id }) else { return }
        let place = row.place
        let createdAt = row.createdAt
        let filed = Set(hike.photos.filter { $0.placeID == id }.map(\.id))
        hike.removePlace(id: id, in: context)
        do {
            try save(context)
        } catch {
            // A new row rather than the deleted one: a row deleted from a
            // context cannot be taken back into it. The deleted one goes at
            // the next save, and this one, with the same id, stays.
            let restored = TrailPoint(hikeID: hike.id, place: place, createdAt: createdAt)
            context.insert(restored)
            hike.trailPoints = (hike.trailPoints ?? []) + [restored]
            if !filed.isEmpty {
                // One assignment, for the reason `unfilePhotos` gives.
                hike.photos = hike.photos.map { photo in
                    guard filed.contains(photo.id) else { return photo }
                    var refiled = photo
                    refiled.placeID = id
                    return refiled
                }
            }
            logger.error("A place could not be removed: \(error.localizedDescription, privacy: .public)")
            throw .notRemoved
        }
    }
}

extension View {
    /// The alert for a place change the store refused. Dismissing it is all
    /// it does: the screen under it is still up, so trying again is the
    /// retry.
    func hikePlaceRefusalAlert(_ refusal: Binding<HikePlaceRefusal?>) -> some View {
        alert(
            isPresented: Binding(get: { refusal.wrappedValue != nil }, set: { if !$0 { refusal.wrappedValue = nil } }),
            error: refusal.wrappedValue
        ) {
            Button("OK", role: .cancel) { /* dismisses */ }
        }
    }
}
