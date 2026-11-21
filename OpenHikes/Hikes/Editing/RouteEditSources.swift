//
//  RouteEditSources.swift
//  OpenHikes
//
//  Everything *Edit Route* works from: the hike's line as it is drawn, the
//  line as it was saved, the recorded trace and what the hike remembers of
//  its edits.
//
//  ## The whole line, not the drawn one
//
//  The editor does not open on the line the hike has now. It opens on the
//  whole line — the saved one, put together again under the choices that
//  stand (see ``RouteAssembly``) — with the hike's trim as two cuts on it. So
//  a handle can be dragged back out over ground an earlier save cut off, and
//  a stretch's answer can be changed on a hike that has since been trimmed.
//
//  ## Read off the main actor, and only when there is something to read
//
//  The saved line and the trace are external storage, read whole, so they
//  are fetched in a context of their own for the reason the hike's own line
//  is (see ``ShownLine``). A hike with no edit and nothing to check has
//  neither to read: its drawn line is all there is.
//

import Foundation
import OpenHikesData
import os
import SwiftData

nonisolated struct RouteEditSources: Equatable, Sendable {
    /// The hike's line as it is drawn now, which a save replaces.
    let current: [RouteCoordinate]
    /// The line as it was saved, before any edit: ``Hike/originalRoute``
    /// once an edit has kept one, and `current` until then.
    let saved: [RouteCoordinate]
    /// The recorded trace, or nothing where the hike kept none.
    let raw: [RouteCoordinate]
    /// What the hike remembers of its edits and its stretches to check.
    let edit: RouteEdit?
    /// Whether the hike was edited and the line it was edited from is not
    /// on this device: iCloud has brought the hike and not yet its original.
    /// Nothing can be edited until it has, because the hike's trim and its
    /// stretches are measured on that line.
    var isMissingOriginal = false

    private static let logger = Logger(subsystem: "OpenHikes", category: "RouteEdit")

    /// A hike with nothing but its line.
    init(current: [RouteCoordinate]) {
        self.init(current: current, saved: current, raw: [], edit: nil)
    }

    init(current: [RouteCoordinate], saved: [RouteCoordinate], raw: [RouteCoordinate], edit: RouteEdit?) {
        self.current = current
        self.saved = saved
        self.raw = raw
        self.edit = edit
    }

    /// The whole line the editor opens on — see the file header — with where
    /// each stretch to check is in it.
    var whole: RouteAssembly.Line {
        whole(under: edit?.assembly)
    }

    /// The same, under the choices of `assembly`.
    func whole(under assembly: RouteAssembly?) -> RouteAssembly.Line {
        assembly?.line(saved: saved, raw: raw) ?? RouteAssembly.Line(route: saved, checkRanges: [:])
    }

    /// The sources of `hike`, whose line its screens hold as `current`.
    @MainActor
    static func reading(
        _ hike: Hike,
        drawn current: [RouteCoordinate],
        in container: ModelContainer
    ) async -> Self {
        guard let record = hike.routeEdit, record.original != nil || record.assembly != nil else {
            return Self(current: current)
        }
        let stored = await storedLines(of: hike.persistentModelID, in: container)
        // A hike never edited has no original: the line it has is the one it
        // was saved with.
        let isEdited = record.original != nil
        let hasOriginal = stored.original.count > 1
        var sources = Self(
            current: current,
            saved: isEdited && hasOriginal ? stored.original : current,
            raw: stored.raw,
            edit: record
        )
        sources.isMissingOriginal = isEdited && !hasOriginal
        return sources
    }

    @concurrent
    private static func storedLines(
        of id: PersistentIdentifier,
        in container: ModelContainer
    ) async -> (original: [RouteCoordinate], raw: [RouteCoordinate]) {
        assertOffMainThread("A hike's stored lines are read off the main thread")
        do {
            guard let hike = try SelectedLine.fetchHike(ModelContext(container), id) else { return ([], []) }
            return (hike.originalRoute, hike.rawRoute)
        } catch {
            logger.error("Could not read a hike's stored lines: \(error.localizedDescription, privacy: .public)")
            return ([], [])
        }
    }
}
