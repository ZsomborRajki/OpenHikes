//
//  HikeImport.swift
//  OpenHikes
//
//  Turning a picked .gpx file into a hike that is actually on disk.
//
//  Reading the file is ``GPXImport``'s subject; what happens after it is this
//  one's, and that is where a walk can be lost. Everything downstream of a
//  successful import acts on the claim that the hike is *kept*: the row is
//  selected and drawn on the map, and for a file the system copied into the
//  app rather than opened in place, ``GPXInbox`` removes the only copy
//  OpenHikes controls. An insert is not that claim — it is a change pending in
//  a context that autosave will get to eventually — so the commit happens
//  here, before anything is told there is a hike.
//
//  A refused save therefore comes back as a failure rather than as a hike, and
//  says that it was the *storage* that refused. That distinction is not
//  wording: the hiker's file parsed, so it is still the one thing that can be
//  imported again, and the copy in the inbox is the only source the app has
//  left to try it from.
//
//  Waiting for the commit is not the same as blocking on it. The write goes
//  through a background context and only the hike's id comes back, because
//  serializing an externally stored route is the longest thing an import does
//  and every millisecond of it would otherwise be spent on the main actor,
//  under a document picker that is still dismissing.
//

import Foundation
import OpenHikesData
import os
import SwiftData

/// Why a picked file did not become a hike.
///
/// Two unrelated things fail here and they are not the same sentence to the
/// hiker. ``GPXImport/ImportFailure`` says the first — the bytes could not
/// become a route, which is something they can act on — and nothing the parser
/// does can express the second, which is why this wraps that enum rather than
/// growing a case inside it that ``GPXImport/load(from:limits:)`` could never
/// throw.
nonisolated enum HikeImportFailure: LocalizedError, Equatable, Sendable {
    /// The file could not become a route. See ``GPXImport/ImportFailure``.
    case file(GPXImport.ImportFailure)
    /// The route was read, and the store refused to keep it.
    ///
    /// Carries no diagnostic: what SwiftData says about a refused commit is
    /// not a sentence anyone can act on, so it is logged where it is useful
    /// and the alert says the part that is the hiker's to know. Same division
    /// ``HikeIntentFailure`` makes.
    case notSaved
    /// Several picked files, some of which did not become hikes — one alert
    /// for all of them rather than one per file. Each names its file and why.
    case several([FileFailure])

    /// One file of several that did not become a hike, for ``several(_:)``.
    struct FileFailure: Equatable, Sendable {
        let fileName: String
        let reason: String
    }

    var errorDescription: String? {
        switch self {
        case .file(let failure): failure.errorDescription
        // One of several picked is the common case — a folder of walks with
        // one bad file in it — so the count is said in the singular too.
        case .several(let failures) where failures.count == 1: "1 file couldn't be imported."
        case .several(let failures): "\(failures.count) files couldn't be imported."
        case .notSaved: "This hike couldn't be saved."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .file(let failure): failure.recoverySuggestion
        // Says the file is untouched, because the obvious reading of a failed
        // import is that the file was the problem — and here it wasn't, so the
        // next thing to try is the same file again.
        case .notSaved: "The file wasn't changed. Check that the device has storage available, then import it again."
        // The others are hikes now, and this says which were not and why —
        // the one thing a single "some failed" would leave the hiker to find
        // out by scrolling their library.
        case .several(let failures):
            failures.map { "\($0.fileName): \($0.reason)" }.joined(separator: "\n")
        }
    }
}

/// What one import did.
///
/// Returned rather than an optional `Hike` because two callers ask different
/// questions of the same import: one has something left to do to the new hike,
/// and the one that arrived with a copy of the file asks whether that copy is
/// still worth anything.
enum HikeImportOutcome {
    case imported(Hike)
    case refused(HikeImportFailure)

    /// The hike, for a caller with something left to do to it.
    var hike: Hike? {
        guard case .imported(let hike) = self else { return nil }
        return hike
    }

    /// Whether the app's own copy of the imported file has nothing left to
    /// offer, and can go.
    ///
    /// A file that couldn't become a hike still won't on the next launch, so
    /// its copy goes with the failure — leaving it behind only hides it in a
    /// directory nothing else reads. A save the store refused is the other way
    /// round: the file parsed, the app is what failed, and this copy is the
    /// only source OpenHikes controls. See ``GPXInbox``.
    var discardsSourceCopy: Bool {
        switch self {
        case .imported, .refused(.file), .refused(.several): true
        case .refused(.notSaved): false
        }
    }
}

enum HikeImport {
    nonisolated private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "HikeImport"
    )

    /// Parses the file at `url` and returns the hike it is now kept as.
    ///
    /// The MetricKit span covers the whole import rather than only the parse
    /// ``GPXImport/loadOffMain(from:limits:)`` already times: what is worth
    /// knowing in the field is what opening somebody's 20,000-point GPX costs
    /// end to end, including the SwiftData insert and the commit, and that is
    /// not a number a three-point fixture can produce.
    ///
    /// - Parameter save: The seam the commit goes through, so a suite can
    ///   refuse it — the same shape ``HikeRecorder`` and
    ///   ``HikePhotoImport/remove(_:from:store:save:)`` take theirs in. There
    ///   is no sequence of taps that makes a store say no, and this is the one
    ///   failure whose whole point is what it does *not* leave behind. It is
    ///   handed the background context the write goes through, not the
    ///   screen's.
    static func hike(
        from url: URL,
        into modelContext: ModelContext,
        save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
    ) async throws(HikeImportFailure) -> Hike {
        // A caller with no way to ask which tracks answers "none of them",
        // which is the refusal a multi-track file used to get.
        let hikes = try await hikes(from: url, into: modelContext, choosing: { _, _ in [] }, save: save)
        guard let hike = hikes.first else { throw .file(.multipleTracks) }
        return hike
    }

    /// Parses the file at `url` and returns the hikes it is now kept as —
    /// one for an ordinary file, one per chosen track for a file that holds
    /// several.
    ///
    /// - Parameter choosing: asked only when the file holds more than one
    ///   track, with the tracks and how many of the file's waypoints lie on
    ///   none of them; answers the indices to import, empty for none. See
    ///   ``GPXTrackChoice``. Never asked for a one-track file, which imports
    ///   exactly as it always has.
    ///
    /// All of the chosen tracks are committed together or none of them are:
    /// a refused save that kept three days of a five-day trip would leave the
    /// hiker to work out which three.
    static func hikes(
        from url: URL,
        into modelContext: ModelContext,
        choosing: ([GPXImport.Track], Int) async -> [Int],
        save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
    ) async throws(HikeImportFailure) -> [Hike] {
        let scoped = url.startAccessingSecurityScopedResource()
        let span = FieldSignpost.begin(.hikeImport)
        defer {
            FieldSignpost.end(span)
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let contents = try await parsed(url)
        let chosen: [(number: Int, track: GPXImport.Track)]
        if contents.tracks.count == 1, let only = contents.tracks.first {
            chosen = [(1, only)]
        } else {
            let picks = await choosing(contents.tracks, contents.unplacedWaypoints)
            guard !picks.isEmpty else { throw .file(.multipleTracks) }
            chosen = Set(picks).sorted()
                .filter { contents.tracks.indices.contains($0) }
                .map { ($0 + 1, contents.tracks[$0]) }
        }
        let rows = chosen.map { number, track in
            PendingRow(
                track: track,
                // Both settled here, on the actor that owns the UI types they
                // reach: the title is bounded rather than absorbed downstream,
                // because this name came out of a file the hiker may never
                // have opened (see ``HikeTitle``), and the tint is mixed
                // through SwiftUI's `Color`.
                title: chosen.count == 1 && contents.tracks.count == 1
                    ? HikeTitle.imported(trackName: track.name, fileURL: url)
                    : HikeTitle.imported(trackName: track.name, fileURL: url, trackNumber: number),
                tintHex: Hike.randomTintHex()
            )
        }
        let ids = try await stored(rows, in: modelContext.container, save: save)
        var hikes: [Hike] = []
        for id in ids { hikes.append(try imported(id, into: modelContext)) }
        return hikes
    }

    /// One row to write: a track, and the two things settled for it on the
    /// main actor.
    struct PendingRow: Sendable {
        let track: GPXImport.Track
        let title: String
        let tintHex: String
    }

    /// Builds the row and commits it, off the main actor.
    ///
    /// Serializing a route is the expensive half of an import and it grows
    /// with the walk — an externally stored route of a few hundred thousand
    /// points measured in the hundreds of milliseconds inside `save()`, all of
    /// it while the document picker is dismissing. The parse is already
    /// off-main for the same reason and is the *shorter* half, so this goes
    /// the same way.
    ///
    /// Safe rather than clever, and the same shape as
    /// ``BackgroundTrailTracker``'s off-main read: `ModelContainer` is
    /// `Sendable`, the `ModelContext` built from it is created, used and
    /// discarded inside this one call, and the only thing that leaves is the
    /// hike's id — never the non-`Sendable` `Hike` itself.
    @concurrent
    nonisolated private static func stored(
        _ rows: [PendingRow],
        in container: ModelContainer,
        save: @Sendable (ModelContext) throws -> Void
    ) async throws(HikeImportFailure) -> [UUID] {
        assertOffMainThread(
            "Serializing an imported route must stay off the main thread"
        )
        let context = ModelContext(container)
        var ids: [UUID] = []
        for row in rows {
            let track = row.track
            let hike = Hike(
                title: row.title,
                distanceMeters: track.distanceMeters,
                date: track.startTime ?? .now,
                tintHex: row.tintHex,
                route: track.route,
                trackDescription: track.trackDescription,
                author: track.author,
                keywords: track.keywords
            )
            hike.photos = placeOnlyPhotos(of: track)
            context.insert(hike)
            // After the insert, because a place is a row of its own and a
            // relationship assigned to a hike that is not in a context yet
            // has nowhere to put it — the same order ``TrailDraftSave``
            // takes, and for the same reason.
            hike.replacePlaces(with: track.places, in: context)
            ids.append(hike.id)
        }
        do {
            try save(context)
        } catch {
            // The row goes with the context, which is this call's and nothing
            // else's. A pending insert left somewhere the *next* save might
            // accept would put the hike back on the list a moment after the
            // hiker was told it wasn't there — the same disagreement between
            // screen and disk, only later and with no alert beside it.
            logger.error(
                """
                An imported hike could not be saved: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            throw .notSaved
        }
        return ids
    }

    /// The file's photo waypoints as rows on the imported hike.
    ///
    /// Each is a ``HikePhoto`` with a place, a time and
    /// ``HikePhoto/isPlaceOnly`` set, because that is all a `<wpt>` can say —
    /// see ``GPXImport/Photograph``. Nothing is written to
    /// ``HikePhotoStore``: there are no bytes to write, and a row whose file
    /// is missing because it never existed is exactly what that flag is for.
    ///
    /// Assigned rather than appended, on a hike built two lines above whose
    /// `photos` is empty by construction.
    nonisolated private static func placeOnlyPhotos(of track: GPXImport.Track) -> [HikePhoto] {
        track.photographs.map { photograph in
            HikePhoto(
                capturedAt: photograph.capturedAt,
                coordinate: photograph.coordinate,
                isPlaceOnly: true
            )
        }
    }

    /// The committed row, in the context the screen draws from.
    ///
    /// A fetch rather than a handover: the `Hike` the write above built
    /// belongs to a context that no longer exists, and a `@Model` is not
    /// something SwiftData lets cross an isolation boundary in any case.
    private static func imported(
        _ id: UUID,
        into modelContext: ModelContext
    ) throws(HikeImportFailure) -> Hike {
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        guard let hike = try? modelContext.fetch(descriptor).first else {
            // On disk, and unreadable from here — nothing this call can put
            // right. Reported as the storage failure it is nearest to, which
            // also keeps the copy the file arrived as: a duplicate on the next
            // attempt is recoverable and a deleted copy is not.
            logger.error("An imported hike was saved but could not be read back")
            throw .notSaved
        }
        return hike
    }

    /// The parse, with its refusals widened to the ones an import can have.
    private static func parsed(
        _ url: URL
    ) async throws(HikeImportFailure) -> GPXImport.Contents {
        var contents: GPXImport.Contents
        do throws(GPXImport.ImportFailure) {
            contents = try await GPXImport.loadAllOffMain(from: url)
        } catch {
            throw .file(error)
        }
        // Policy rather than a parse failure, which is why the parser hands
        // such a track back and the import is what refuses it. See
        // ``GPXImport/ImportFailure/tooShort``. In a file of several, a
        // one-point track is left out and the others go on.
        contents.tracks.removeAll { $0.points.count < 2 }
        guard !contents.tracks.isEmpty else { throw .file(.tooShort) }
        return contents
    }
}
