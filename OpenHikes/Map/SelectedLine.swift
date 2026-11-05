//
//  SelectedLine.swift
//  OpenHikes
//
//  The selected hike's line, read once, off the main actor, for the four
//  things that draw or measure it.
//
//  Selecting a hike hands its line to the map's projection
//  (``DisplayedRouteCoordinateCache``), the *Color By* stretches
//  (``RouteShading``), auto-save's corridor (``AutoSaveController``) and the
//  widget's snapshot (``BackgroundTrailTracker``). Each does its own work off
//  the main actor, but each used to read `hike.route` on it first, in the
//  selection's change handler, and the first of those reads decodes the
//  externally stored route whole: about 25 ms of a 20,000-point trail and
//  250 of a 200,000-point one, measured on the simulator (#1232). SwiftData
//  keeps the decode per context, which made the other three reads nearly
//  free — and meant that moving any one of them to a context of its own would
//  have decoded a second copy and left the first where it was.
//
//  So the line is read here, in a context of its own off the main actor, the
//  way ``HikePhotoSearchPlan/SourceRead`` reads a photo search's hike
//  (#1226), and all four are handed the same ``Read``: whichever asks first
//  starts it, and the rest wait on it. The main actor only names the row.
//  The hike's own screen takes the same read while its hike is the selected
//  one (#1252) — see ``ShownLine``.
//
//  ## A hike the store has not had yet
//
//  A context of its own reads the store, and the store holds a hike the way
//  its own context does only once that context has saved it. A hike holding
//  edits the store has not had — one never saved, such as a suite's fixture,
//  or one with a write still pending — is read where those edits are, on the
//  main actor, by ``HikePhotoSearchPlan/SourceRead``'s rule and for its
//  reason. Every writer of a line saves at once, and a selection is made of
//  rows the store handed back, so in the app that is the rare case.
//
//  ## A new line
//
//  A read is kept for as long as its hike's line is the line it read. A
//  colour, a width or a rename leaves it alone, and the same hike asked about
//  again — selected again, *Color By* moved, another map source picked —
//  costs nothing. Every read watches its hike's line from before it is
//  named, and the first write to it marks the read replaced, synchronously,
//  so the next reader to ask starts a new one.
//
//  The readers watch the line too, each to do its own work again, and every
//  one of those watches is armed here, by ``watch(_:onChange:)``, so what
//  counts as a new line is decided in one place, ``trackLine(of:hearingRefreshes:)``.
//  That is ``Hike/lineRevision``, which only a line written through the
//  hike's own context moves, and not `route` itself. While the hikes list is
//  up, every save of any hike refreshes every hike in this context, and that
//  refresh notifies `route` whether or not the line changed (#1228). Watched
//  there, every rename or tint saved anywhere made the drawn line and its
//  colours again.
//
//  ## A line another context saved
//
//  A line another context saved, such as an edit mirrored in from the
//  hiker's other device, moves no revision here. ``SelectedLineStoreWatch``
//  notices it in the store's history, refreshes the hike in its own context,
//  and calls ``refresh()``. That reads the line again from the store, and
//  when it is not the line handed out, every watch hears it as it hears a
//  write.
//
//  ## A read that fails
//
//  A fetch can fail, and a failure says nothing about the row: the hike
//  still has its line. A read used to answer a failed fetch as it answers a
//  row the store no longer holds, with no line at all (#1333). A failed
//  first read was then kept, and handed again to whoever asked, with nothing
//  read; a failed ``refresh()`` handed every reader the empty line over the
//  one they held. So a read says which it found (``Found``).
//
//  A failed refresh hands nothing out, and the readers keep the line they
//  hold. A failed first read has no line to keep, and its readers draw
//  nothing for now. Either leaves the line owed, and a refresh reads it
//  again: the one way a line reaches every reader at once, and only a line
//  they do not hold. The first failure in a row asks for that refresh at
//  once, as a library line's does (`LibraryLines`), because the selection or
//  the save it was read for may be the last ask. A failure that holds asks
//  for nothing more, and the line waits for the next ask of ``read(of:)``,
//  which the hike's screen makes when a save refreshes its hike, or for the
//  store watch's refresh at the next save of the row. Nothing tries again
//  on a timer, for the reason `LibraryLines` gives.
//
//  ## A read of its own
//
//  One of these made for one read is how a reader with no screen and nothing
//  to follow gets a line off the main actor: the walk session asking whether
//  its line has changed, heights checked against the line they were asked
//  about, the community's check. The read is armed like any other, so
//  ``Read/isReplaced`` still says a write overtook it.
//

import Foundation
import Observation
import OpenHikesData
import os
import SwiftData
import Synchronization

@Observable
final class SelectedLine {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``RouteStyle``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "SelectedLine")

    /// What a read takes from one save of the row: the line, and the length
    /// stored beside it. Read together, because a context of its own can see
    /// a later save than the main context holds, and a line measured by
    /// another save's length would give the widget a wrong distance left.
    nonisolated struct Line: Sendable {
        let route: [RouteCoordinate]
        let distanceMeters: Double

        /// What a row the store no longer holds reads as, and a fetch that
        /// failed: nothing to draw.
        static let nothing = Self(route: [], distanceMeters: 0)
    }

    /// What a read found of the row. A fetch that failed is told from a row
    /// that is gone, because only the failure leaves the line owed: see
    /// *A read that fails* in the file header.
    nonisolated enum Found: Sendable {
        /// The line, and the length stored beside it.
        case line(Line)
        /// No row: a hike deleted on another device that this one has not
        /// merged yet.
        case gone
        /// The fetch failed, which says nothing about the row.
        case failed
    }

    /// One read of one hike's line, under way or landed. `Sendable`, so the
    /// off-main work each reader does with the line can wait for it there.
    nonisolated final class Read: Sendable {
        /// When the read was started: a line saved after this may not be in
        /// it, and one saved before it is.
        let began: Date
        private let found: Task<Found, Never>
        private let replacement: Write

        init(began: Date, replacement: Write, found: Task<Found, Never>) {
            self.began = began
            self.replacement = replacement
            self.found = found
        }

        /// The line, once read. Empty for a row the store no longer holds —
        /// a hike deleted on another device that this one has not merged
        /// yet — and for a fetch that failed: neither has anything to draw.
        var route: [RouteCoordinate] {
            get async { await line.route }
        }

        /// The length stored beside ``route``, from the same save of the row.
        /// Zero where ``route`` is empty.
        var distanceMeters: Double {
            get async { await line.distanceMeters }
        }

        /// Whether the fetch failed, once the read has landed. Its line is
        /// then owed — see *A read that fails* in the file header.
        var failed: Bool {
            get async {
                guard case .failed = await found.value else { return false }
                return true
            }
        }

        private var line: Line {
            get async {
                switch await found.value {
                case .line(let line): line
                case .gone, .failed: .nothing
                }
            }
        }

        /// Whether the hike's line has been replaced since this read named
        /// it: written through the hike's own context, or found new in the
        /// store by ``SelectedLine/refresh()``.
        var isReplaced: Bool { replacement.isRaised }

        /// What ``SelectedLine/refresh()`` does to the read it replaces.
        func markReplaced() { replacement.raise() }
    }

    /// Raised, from wherever the write happened, by the first change to a
    /// hike's line after a watch on it was armed.
    ///
    /// Raised synchronously as well as answered by a hop, because work begun
    /// on the line before the change can still be in flight, and its answer
    /// can land before the hop does: the flag is what drops it rather than
    /// using it. One per watch, so a registration left over from an earlier
    /// one — an observation can only be ignored, never cancelled — raises a
    /// flag nothing reads any more.
    nonisolated final class Write: Sendable {
        private let raised = Mutex(false)

        var isRaised: Bool { raised.withLock { $0 } }

        func raise() { raised.withLock { $0 = true } }
    }

    /// Where a read takes the line from — the two cases of
    /// ``HikePhotoSearchPlan/SourceRead``, for the line and its length alone.
    nonisolated enum Source: Sendable {
        /// A row its context has saved, fetched by its identifier into a
        /// context of the read's own.
        case saved(PersistentIdentifier, in: ModelContainer)
        /// The line itself, read off a hike holding edits its store has not
        /// had yet.
        case unsaved(Line)

        /// From the store when `hike`'s context has written every edit to
        /// it, and from `hike`, here, when it has not. The hike's own flag
        /// rather than its context's, for the reason
        /// ``HikePhotoSearchPlan/SourceRead`` gives: a pending write to any
        /// other row would send every read back to the main actor.
        @MainActor
        init(_ hike: Hike) {
            if !hike.hasChanges, let container = hike.modelContext?.container {
                self = .saved(hike.persistentModelID, in: container)
            } else {
                self = .unsaved(Line(route: hike.route, distanceMeters: hike.distanceMeters))
            }
        }
    }

    /// The read handed out last, and the hike it is of — weakly, so a read
    /// does not keep a deleted hike around.
    @ObservationIgnored private var current: Read?
    @ObservationIgnored private weak var currentHike: Hike?
    /// The one observed property: bumped by a ``refresh()`` that found a
    /// line the store holds and the current read does not. Read only inside
    /// the watches ``watch(_:onChange:)`` arms, never by a body.
    private var refreshes = 0
    /// The comparison a ``refresh()`` is making, if any, and any asked for
    /// while it was out, made after it under the same task. Readable so a
    /// suite can wait on the effect rather than on a duration.
    @ObservationIgnored private(set) var refreshing: Task<Void, Never>?
    /// Whether a ``refresh()`` was asked for while one was being made.
    @ObservationIgnored private var refreshesAgain = false
    /// Whether the line of the hike last asked about is owed: the last read
    /// of it failed, so what its readers hold says nothing of the row. See
    /// *A read that fails* in the file header.
    @ObservationIgnored private var owesLine = false
    /// The look at whether the read ``read(of:)`` started last failed.
    /// Readable so a suite can wait on the effect rather than on a duration.
    @ObservationIgnored private(set) var landing: Task<Void, Never>?
    /// How a saved row is fetched, as a seam so a suite can see which thread
    /// it ran on. ``fetchHike(_:_:)`` everywhere else.
    @ObservationIgnored private let fetch: @Sendable (ModelContext, PersistentIdentifier) throws -> Hike?

    init(
        fetch: @escaping @Sendable (ModelContext, PersistentIdentifier) throws -> Hike? = SelectedLine.fetchHike
    ) {
        self.fetch = fetch
    }

    /// `hike`'s line as it stands: the read already made of it, under way
    /// or landed, while nothing has replaced its line since, and a new read
    /// otherwise. What each of the four, and the hike's own screen, reads in
    /// place of `hike.route`.
    ///
    /// A read whose fetch failed is still the one handed out, because every
    /// reader holds it, but its line is owed, so asking makes a ``refresh()``,
    /// which hands the line to every reader if it finds it.
    func read(of hike: Hike) -> Read {
        if let current, currentHike === hike, !current.isReplaced {
            if owesLine { refresh() }
            return current
        }
        let read = start(hike)
        current = read
        currentHike = hike
        owesLine = false
        landing = Task { [weak self] in
            guard await read.failed, let self, current === read else { return }
            oweLine()
        }
        return read
    }

    /// When the read handed out for `hike` began, or `nil` while none is.
    /// Asks without starting one, as ``read(of:)`` would.
    func readBegan(for hike: Hike) -> Date? {
        guard let current, currentHike === hike else { return nil }
        return current.began
    }

    /// Watches `hike`'s line for a reader: the flag it returns is raised
    /// synchronously by the first change to the line — a write, or a
    /// ``refresh()`` that found a new one — and `onChange` is called on the
    /// main actor after it, once, with that flag, which is how a reader tells
    /// its current watch from one it has since replaced. A reader arms one
    /// per reading of the line, before asking ``read(of:)`` for it.
    func watch(_ hike: Hike, onChange: @escaping @MainActor @Sendable (Write) -> Void) -> Write {
        let write = Write()
        withObservationTracking {
            trackLine(of: hike, hearingRefreshes: true)
        } onChange: {
            write.raise()
            Task { @MainActor in onChange(write) }
        }
        return write
    }

    /// Registers what a new line is, inside a `withObservationTracking`: a
    /// line written through `hike`'s context (``Hike/trackLineReplacements()``),
    /// and, for a reader, a ``refresh()`` that found one. The one place a
    /// selected hike's line is registered, for the reads and the readers
    /// alike, so what counts as a new line is decided here and nowhere else.
    ///
    /// Not `route`. While the hikes list is up, a refresh after any save
    /// notifies it for every hike, changed or not (#1228). The line revision
    /// is not stored, so no refresh reaches it.
    ///
    /// A read's own watch does not hear refreshes: the refresh that installs
    /// a read is not a change to the line that read holds.
    private func trackLine(of hike: Hike, hearingRefreshes: Bool) {
        hike.trackLineReplacements()
        if hearingRefreshes { _ = refreshes }
    }

    /// Reads the line of the hike last asked about again, from the store,
    /// and hands it out if it is not the line the current read holds: it
    /// becomes the read ``read(of:)`` answers with, and every watch
    /// ``watch(_:onChange:)`` armed is told, so each reader does again what
    /// it does after a write.
    ///
    /// For a line another context may have saved — see the file header.
    /// ``SelectedLineStoreWatch`` calls it once the store's history says the
    /// selected hike's row was saved, and once the hike's own context holds
    /// what the store does. A hike with edits the store has not had is read
    /// where it is, as always, so a refresh then finds nothing new.
    ///
    /// One comparison at a time. Two at once compared against the same read,
    /// so the first to land left the other nothing to replace, and a line
    /// saved while the one before it was being compared was dropped for that
    /// one. A refresh asked for meanwhile is made once the comparison out has
    /// landed, against the read it left current.
    ///
    /// A read that fails hands nothing out, so the readers keep the line they
    /// hold, and leaves the line owed: the first such failure in a row asks
    /// for one more comparison at once — see *A read that fails* in the file
    /// header.
    func refresh() {
        guard refreshing == nil else {
            refreshesAgain = true
            return
        }
        refreshing = Task { [weak self] in
            repeat {
                guard let self, let previous = current, let hike = currentHike else { break }
                refreshesAgain = false
                let fresh = start(hike)
                if await fresh.failed {
                    // The readers keep the line they hold.
                    if current === previous { oweLine() }
                    continue
                }
                let differs = await Self.differ(previous, fresh)
                guard current === previous else { continue }
                owesLine = false
                guard differs else { continue }
                current = fresh
                previous.markReplaced()
                refreshes &+= 1
            } while self?.refreshesAgain == true
            self?.refreshing = nil
        }
    }

    /// Owes the current read's line, after a read of it failed. Only the
    /// first failure in a row asks for a ``refresh()``, at once; one that
    /// holds waits for the next ask — see *A read that fails* in the file
    /// header.
    private func oweLine() {
        guard !owesLine else { return }
        owesLine = true
        refresh()
    }

    private func start(_ hike: Hike) -> Read {
        let replacement = Write()
        // Armed before the line is named, so a write that lands after it is
        // a new line rather than one this read already holds. Raising the
        // flag is all it does: the next reader to ask is what reads again.
        withObservationTracking {
            trackLine(of: hike, hearingRefreshes: false)
        } onChange: {
            replacement.raise()
        }
        return Read(
            began: .now,
            replacement: replacement,
            found: Self.reading(Source(hike), fetch: fetch)
        )
    }

    /// The read itself, as a task started outside any actor, so that a
    /// reader waiting for the line off the main actor is never kept waiting
    /// for the main actor to finish it.
    nonisolated private static func reading(
        _ source: Source,
        fetch: @escaping @Sendable (ModelContext, PersistentIdentifier) throws -> Hike?
    ) -> Task<Found, Never> {
        Task { await readOffMain(source, fetch: fetch) }
    }

    /// Fetches and reads a saved row in a context made here and dropped on
    /// return, and hands an unsaved hike's line straight back. Only the line
    /// and its length leave, or what kept them: a row the store did not hand
    /// back, or a fetch that failed.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor.
    @concurrent
    nonisolated private static func readOffMain(
        _ source: Source,
        fetch: @Sendable (ModelContext, PersistentIdentifier) throws -> Hike?
    ) async -> Found {
        assertOffMainThread("Reading the selected hike's line must stay off the main thread")
        switch source {
        case let .saved(id, container):
            do {
                guard let hike = try fetch(ModelContext(container), id) else { return .gone }
                return .line(Line(route: hike.route, distanceMeters: hike.distanceMeters))
            } catch {
                logger.error("Could not read the selected hike's line: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
        case let .unsaved(line):
            return .line(line)
        }
    }

    /// Whether two reads of one hike hold different lines, compared off the
    /// main actor: a long route is a long comparison.
    @concurrent
    nonisolated static func differ(_ old: Read, _ new: Read) async -> Bool {
        let before = await old.route
        let after = await new.route
        return before != after
    }

    /// The store's own answer for a saved row: the one row, by its
    /// persistent identifier, because that names the very row the caller's
    /// context holds and a column with no uniqueness constraint cannot — the
    /// fetch ``HikePhotoSearchPlan/SourceRead`` makes, for the same reason.
    nonisolated static func fetchHike(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
