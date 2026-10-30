//
//  ShownLine.swift
//  OpenHikes
//
//  The line of the hike a screen shows, read off the main actor, and read
//  again only when it really changes (#1252).
//
//  A screen that reads `hike.route` decodes the externally stored line whole
//  on the main actor: about 23 ms of a 20,000-point trail and 240 of a
//  200,000-point one, measured on the simulator. It paid that again after
//  every save to the hikes store. While the hikes list is up, a save
//  refreshes every hike in the main context and notifies `route` on each,
//  changed or not (#1228), and the next read of a refreshed column decodes it
//  afresh. On iOS 18.6 the refresh itself decodes a line the main context has
//  read. A hike's screen read the line in its body, so a rename, a tint, a
//  photo or another hike's save each cost one decode, and often two.
//
//  So nothing on the screen reads the line from its hike. The screen is handed
//  one read of it from here, and draws, counts and follows that. While the
//  hike is the selected one, which every way of opening a hike's screen makes
//  it, that is the read the map, its colours, auto-save and the widget share
//  (``SelectedLine``), so the screen decodes nothing of its own either.
//
//  ## When the line changes
//
//  ``revision`` moves once for each line that lands and is not the line
//  before it. A screen keys its route-derived work on it. A line is new when:
//  - it was written through the hike's own context, which moves
//    ``Hike/lineRevision``, a counter no refresh reaches;
//  - another context saved a new one, such as an edit mirrored in from the
//    hiker's other device. The store watch that follows the hike finds it, and
//    ``SelectedLine/refresh()`` hands it out.
//
//  A rename, a tint, a photo and another hike's save are neither, and read
//  nothing.
//
//  ## A screen whose hike is not the selected one
//
//  The selection can move while a hike's screen stays up. A GPX file opened
//  from Files lands on the map behind an open screen, and a recording started
//  from Siri or the watch selects its draft. The selection's store watch then
//  follows another hike, or none, and ``SelectedLine`` answers for the
//  selection. Asking it about this hike would take its read from the map's
//  readers. So the screen reads its hike through a pair of its own instead,
//  wired the way the model wires the selection's: a ``SelectedLine``, and a
//  ``SelectedLineStoreWatch`` following the hike for it. A line saved
//  elsewhere still reaches the screen that way.
//
//  The screen notices the move at the next save to the store. That save
//  refreshes its hike, and the refresh notifies `route`, which is registered
//  here for that alone: it asks which pair to read through, and reads
//  nothing. When the selection comes back to the hike, the screen goes back
//  to the shared read. Either switch compares the new read with the line on
//  screen, off the main actor, and the same line moves nothing.
//

import Foundation
import Observation
import OpenHikesData
import SwiftData

@Observable
final class ShownLine {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``RouteStyle``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The screen's own reader and the watch that follows the hike in the
    /// store for it, while the hike is not the one the selection follows.
    private struct OwnLines {
        let lines: SelectedLine
        let watch: SelectedLineStoreWatch
        var isFollowing = false
    }

    /// The line on screen, once read: its points and the length stored beside
    /// them, from one save of the row. `nil` until the first read lands.
    private(set) var current: SelectedLine.Line?
    /// How many lines have landed since the first that were not the line
    /// before them. What a screen keys its route-derived work on.
    private(set) var revision = 0

    /// The read ``current`` came from, or the one it is waiting for.
    @ObservationIgnored private(set) var read: SelectedLine.Read?
    /// The landing in flight, if any. Readable so a suite can wait on the
    /// effect rather than on a duration.
    @ObservationIgnored private(set) var landing: Task<Void, Never>?
    @ObservationIgnored private weak var hike: Hike?
    @ObservationIgnored private var selection: SelectedLine?
    @ObservationIgnored private var selectionWatch: SelectedLineStoreWatch?
    @ObservationIgnored private var own: OwnLines?
    /// The reader the watch on the line is armed on, so it is armed again
    /// only when it has fired or the reader changed: an observation can be
    /// ignored but never cancelled, so arming it on every save would pile
    /// them up.
    @ObservationIgnored private var watchedLines: SelectedLine?
    @ObservationIgnored private var lineWrite = SelectedLine.Write()
    @ObservationIgnored private var saveWrite = SelectedLine.Write()
    /// How the screen's own reader fetches a saved row. A seam, as
    /// ``SelectedLine``'s own is; ``SelectedLine/fetchHike(_:_:)`` everywhere
    /// else.
    @ObservationIgnored private let fetch: @Sendable (ModelContext, PersistentIdentifier) throws -> Hike?

    init(
        fetch: @escaping @Sendable (ModelContext, PersistentIdentifier) throws -> Hike? = SelectedLine.fetchHike
    ) {
        self.fetch = fetch
    }

    /// How many points the line on screen has, and none before it lands.
    var pointCount: Int { current?.route.count ?? 0 }

    /// Shows `hike`'s line from here on and hands back the read in force,
    /// the one the screen builds its work from.
    ///
    /// Asked again by every start of that work. The same hike asked about
    /// again changes nothing that has not changed: a screen shows one hike
    /// for its life.
    ///
    /// - Parameters:
    ///   - selection: where the selected hike's line is read.
    ///   - watch: what follows the selected hike in the store, asked whether
    ///     that is this hike.
    @discardableResult func show(
        _ hike: Hike,
        selection: SelectedLine,
        followedBy watch: SelectedLineStoreWatch
    ) -> SelectedLine.Read {
        if self.hike !== hike || self.selection !== selection {
            self.hike = hike
            self.selection = selection
            selectionWatch = watch
            stopOwnLines()
            watchedLines = nil
            read = nil
            landing = nil
            if current != nil { current = nil }
            watchSaves(of: hike)
        }
        return follow(hike, rearming: false)
    }

    /// Reads `hike`'s line through the reader in force now, arming the watch
    /// on its line first, so that a write after the read is heard.
    @discardableResult private func follow(_ hike: Hike, rearming: Bool) -> SelectedLine.Read {
        let lines = lines(for: hike)
        if rearming || watchedLines !== lines {
            watchedLines = lines
            lineWrite = lines.watch(hike) { [weak self] write in self?.lineDidChange(write) }
        }
        let next = lines.read(of: hike)
        if var own, !own.isFollowing, own.lines === lines {
            own.watch.follow(hike, since: lines.readBegan(for: hike) ?? .now)
            own.isFollowing = true
            self.own = own
        }
        install(next)
        return next
    }

    /// The selection's reader while the selection's watch follows `hike`,
    /// and the screen's own otherwise.
    private func lines(for hike: Hike) -> SelectedLine {
        if let selection, selectionWatch?.follows(hike) == true {
            stopOwnLines()
            return selection
        }
        if let own { return own.lines }
        let lines = SelectedLine(fetch: fetch)
        own = OwnLines(lines: lines, watch: SelectedLineStoreWatch { lines.refresh() })
        return lines
    }

    private func stopOwnLines() {
        own?.watch.stopFollowing()
        own = nil
    }

    /// A write to the line, or a ``SelectedLine/refresh()`` that found one in
    /// the store.
    private func lineDidChange(_ write: SelectedLine.Write) {
        guard write === lineWrite, let hike, hike.isAttached else { return }
        follow(hike, rearming: true)
    }

    /// Hears every refresh of the hike, which under the hikes list's query is
    /// every save to the store, to ask again whose reader to read through.
    /// Registers `route` without decoding it, and reads nothing for it.
    private func watchSaves(of hike: Hike) {
        let write = SelectedLine.Write()
        saveWrite = write
        withObservationTracking {
            hike.trackRouteChanges()
        } onChange: { [weak self] in
            Task { @MainActor in self?.hikeWasSaved(write) }
        }
    }

    /// Nothing for a hike no longer in its context, whose screen is on its
    /// way out: a new read of one would decode a line no row holds.
    private func hikeWasSaved(_ write: SelectedLine.Write) {
        guard write === saveWrite, let hike, hike.isAttached else { return }
        watchSaves(of: hike)
        follow(hike, rearming: false)
    }

    /// Makes `next` the read in force, and the line on screen once it lands,
    /// unless a newer read has replaced it by then. It moves ``revision``
    /// only when its line is not the one on screen.
    private func install(_ next: SelectedLine.Read) {
        guard next !== read else { return }
        let replacing = read != nil
        read = next
        let shown = current
        landing = Task { [weak self] in
            let line = await Self.line(of: next)
            let isNew = await Self.isNew(line, replacing: shown)
            guard let self, read === next else { return }
            current = line
            if replacing, isNew { revision &+= 1 }
        }
    }

    /// The line `read` holds, waited for off the main actor.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor, and the caller is the main actor.
    @concurrent
    nonisolated private static func line(of read: SelectedLine.Read) async -> SelectedLine.Line {
        SelectedLine.Line(route: await read.route, distanceMeters: await read.distanceMeters)
    }

    /// Whether `line` is not `shown`, compared off the main actor: a long
    /// route is a long comparison.
    @concurrent
    nonisolated private static func isNew(
        _ line: SelectedLine.Line,
        replacing shown: SelectedLine.Line?
    ) async -> Bool {
        guard let shown else { return true }
        return line.distanceMeters != shown.distanceMeters || line.route != shown.route
    }
}
