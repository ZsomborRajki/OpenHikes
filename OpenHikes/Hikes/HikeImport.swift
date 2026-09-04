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
//  wording: the walker's file parsed, so it is still the one thing that can be
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
import os
import SwiftData

/// Why a picked file did not become a hike.
///
/// Two unrelated things fail here and they are not the same sentence to the
/// walker. ``GPXImport/ImportFailure`` says the first — the bytes could not
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
    /// and the alert says the part that is the walker's to know. Same division
    /// ``HikeIntentFailure`` makes.
    case notSaved

    var errorDescription: String? {
        switch self {
        case .file(let failure): failure.errorDescription
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
        case .imported, .refused(.file): true
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
        let scoped = url.startAccessingSecurityScopedResource()
        let span = FieldSignpost.begin(.hikeImport)
        defer {
            FieldSignpost.end(span)
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let track = try await parsed(url)
        let id = try await stored(
            track,
            // Both settled here, on the actor that owns the UI types they
            // reach: the title is bounded rather than absorbed downstream,
            // because this name came out of a file the walker may never have
            // opened (see ``HikeTitle``), and the tint is mixed through
            // SwiftUI's `Color`.
            titled: HikeTitle.imported(trackName: track.name, fileURL: url),
            tintedWith: Hike.randomTintHex(),
            in: modelContext.container,
            save: save
        )
        return try imported(id, into: modelContext)
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
        _ track: GPXImport.Track,
        titled title: String,
        tintedWith tintHex: String,
        in container: ModelContainer,
        save: @Sendable (ModelContext) throws -> Void
    ) async throws(HikeImportFailure) -> UUID {
        assertOffMainThread(
            "Serializing an imported route must stay off the main thread"
        )
        let context = ModelContext(container)
        let hike = Hike(
            title: title,
            distanceMeters: track.distanceMeters,
            date: track.startTime ?? .now,
            tintHex: tintHex,
            route: track.route,
            trackDescription: track.trackDescription,
            author: track.author,
            keywords: track.keywords
        )
        context.insert(hike)
        do {
            try save(context)
        } catch {
            // The row goes with the context, which is this call's and nothing
            // else's. A pending insert left somewhere the *next* save might
            // accept would put the hike back on the list a moment after the
            // walker was told it wasn't there — the same disagreement between
            // screen and disk, only later and with no alert beside it.
            logger.error(
                """
                An imported hike could not be saved: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            throw .notSaved
        }
        return hike.id
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
    ) async throws(HikeImportFailure) -> GPXImport.Track {
        let track: GPXImport.Track
        do throws(GPXImport.ImportFailure) {
            track = try await GPXImport.loadOffMain(from: url)
        } catch {
            throw .file(error)
        }
        // Policy rather than a parse failure, which is why the parser hands
        // such a track back and the import is what refuses it. See
        // ``GPXImport/ImportFailure/tooShort``.
        guard track.points.count > 1 else { throw .file(.tooShort) }
        return track
    }
}
