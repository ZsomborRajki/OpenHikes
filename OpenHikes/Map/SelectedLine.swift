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

import Foundation
import Observation
import OpenHikesData
import SwiftData
import Synchronization

@Observable
final class SelectedLine {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``RouteStyle``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// What a read takes from one save of the row: the line, and the length
    /// stored beside it. Read together, because a context of its own can see
    /// a later save than the main context holds, and a line measured by
    /// another save's length would give the widget a wrong distance left.
    nonisolated struct Line: Sendable {
        let route: [RouteCoordinate]
        let distanceMeters: Double

        /// What a row the store no longer holds reads as.
        static let nothing = Self(route: [], distanceMeters: 0)
    }

    /// One read of one hike's line, under way or landed. `Sendable`, so the
    /// off-main work each reader does with the line can wait for it there.
    nonisolated final class Read: Sendable {
        let hikeID: UUID
        /// When the read was started: a line saved after this may not be in
        /// it, and one saved before it is.
        let began: Date
        private let line: Task<Line, Never>
        private let replacement: Write

        init(hikeID: UUID, began: Date, replacement: Write, line: Task<Line, Never>) {
            self.hikeID = hikeID
            self.began = began
            self.replacement = replacement
            self.line = line
        }

        /// The line, once read. Empty for a row the store no longer holds —
        /// a hike deleted on another device that this one has not merged
        /// yet, or one it cannot read — which has nothing to draw.
        var route: [RouteCoordinate] {
            get async { await line.value.route }
        }

        /// The length stored beside ``route``, from the same save of the row.
        /// Zero for a row the store no longer holds.
        var distanceMeters: Double {
            get async { await line.value.distanceMeters }
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
    /// otherwise. What each of the four reads in place of `hike.route`.
    func read(of hike: Hike) -> Read {
        if let current, currentHike === hike, !current.isReplaced { return current }
        let read = start(hike)
        current = read
        currentHike = hike
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
                guard await Self.differ(previous, fresh), current === previous else { continue }
                current = fresh
                previous.markReplaced()
                refreshes &+= 1
            } while self?.refreshesAgain == true
            self?.refreshing = nil
        }
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
            hikeID: hike.id,
            began: .now,
            replacement: replacement,
            line: Self.reading(Source(hike), fetch: fetch)
        )
    }

    /// The read itself, as a task started outside any actor, so that a
    /// reader waiting for the line off the main actor is never kept waiting
    /// for the main actor to finish it.
    nonisolated private static func reading(
        _ source: Source,
        fetch: @escaping @Sendable (ModelContext, PersistentIdentifier) throws -> Hike?
    ) -> Task<Line, Never> {
        Task { await readOffMain(source, fetch: fetch) }
    }

    /// Fetches and reads a saved row in a context made here and dropped on
    /// return, and hands an unsaved hike's line straight back. Only the line
    /// and its length leave: ``Line/nothing`` for a row the store did not
    /// hand back.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor.
    @concurrent
    nonisolated private static func readOffMain(
        _ source: Source,
        fetch: @Sendable (ModelContext, PersistentIdentifier) throws -> Hike?
    ) async -> Line {
        assertOffMainThread("Reading the selected hike's line must stay off the main thread")
        switch source {
        case let .saved(id, container):
            guard let hike = try? fetch(ModelContext(container), id) else { return .nothing }
            return Line(route: hike.route, distanceMeters: hike.distanceMeters)
        case let .unsaved(line):
            return line
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
