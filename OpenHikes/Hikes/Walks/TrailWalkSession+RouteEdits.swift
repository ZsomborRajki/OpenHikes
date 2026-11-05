//
//  TrailWalkSession+RouteEdits.swift
//  OpenHikes
//
//  A walk is bound to its line, so a line edited under it ends it. Split from
//  the session for length, and because it is a question asked about the hike
//  rather than a step in running the walk.
//
//  Answered without reading the line on the main actor (#1263). The session
//  holds the hike, not its line, and a read of `route` there decoded all of it
//  after any save under the hikes list's query, about 30 ms of 20,000 points,
//  then hashed every point, about 5 ms more, on every fix of a walk in a
//  pocket. Each caller that has read the line off the main actor anyway hands
//  over what it found: the hike's screen, and the background feed, which
//  reads it to match the fix. A moment with no line in hand reads one in a
//  read of its own. A fix matched on another hike's screen has none either,
//  and can come every second, so it goes by the last of those reads until a
//  write replaces it or it is a minute old.
//

import Foundation
import OpenHikesData
import SwiftData

extension TrailWalkSession {
    /// How long a look at the walked line stands for the fixes matched on
    /// another hike's screen — see ``lookAtWalkedLineIfDue(at:)``.
    static let walkedLineLookInterval: TimeInterval = 60

    /// Ends a walk whose hike's route is no longer the line it was started
    /// along — see ``TrailWalkEndReason/routeChanged``.
    ///
    /// Asked of the hike rather than of the profile a caller hands in,
    /// because an edit arrives by three roads and only one of them brings a
    /// profile: the detail's follow loop rebuilds its own, the background
    /// feed matches against the line it was armed with, and an edit mirrored
    /// from the hiker's other device tells nobody. What they share is the
    /// hike, which is where the edit landed. Checked on every fix, on every
    /// return to the foreground, at launch, and whenever the hike's screen
    /// builds its line — which is where the maker's save lands — so the
    /// walk's controls do not go on showing a fraction of a line the screen
    /// no longer draws. Nothing in the app asks it on the main actor: each
    /// of those has the line's revision from an off-main read, or leaves it
    /// to ``checkWalkedLine(at:)``.
    ///
    /// An ordinary end otherwise, and kept as one: the row it leaves is the
    /// walk along the old line, with the old line's length — what
    /// ``TrailWalkRecord/routeDistanceMeters`` is kept for — and the next
    /// walk waits for what an End waits for. A hiker still on the trail who
    /// wants the new line walked taps Start, which does not wait.
    ///
    /// - Parameter known: a hike and the line it has now, as a feed or its
    ///   screen read it off the main actor (#1252). A walk along that hike is
    ///   checked against it, without reading the hike's line on the main
    ///   actor; a walk along another hike, such as a fix matched on another
    ///   hike's screen, is left to ``lookAtWalkedLineIfDue(at:)``. `nil` asks the
    ///   hike here, for a caller with no line, which is only ever a suite.
    func endIfRouteChanged(at now: Date? = nil, knowing known: (hikeID: UUID, revision: String)? = nil) {
        guard let record, let walkedHike, walkedHike.isAttached else { return }
        if let known, known.hikeID != walkedHike.id {
            lookAtWalkedLineIfDue(at: now)
            return
        }
        let isAlong = known.map { record.isAlong(revision: $0.revision) } ?? record.isAlong(walkedHike.route)
        guard !isAlong else { return }
        finish(reason: .routeChanged, at: now ?? clock())
    }

    /// ``endIfRouteChanged(at:knowing:)`` for a moment that has no line in
    /// hand: the walked line is read off the main actor, in a read of its
    /// own, and the walk ended when that lands. A hike under a list's query
    /// decodes all of it on the main actor after any save, and hashing it
    /// walks every point.
    ///
    /// One at a time. A read that a write overtook is made again. An answer
    /// about a walk that has since ended says nothing about the next one, and
    /// a row the store no longer holds has no line to compare: ending the
    /// walk for that is ``discardWalkIfHikeGone()``'s to decide.
    func checkWalkedLine(at now: Date? = nil) {
        guard lineLooks.inFlight == nil, let started = record?.startedAt, let walkedHike, walkedHike.isAttached
        else { return }
        let read = SelectedLine(fetch: lineLooks.fetch).read(of: walkedHike)
        let lookedAt = now ?? clock()
        lineLooks.inFlight = Task { [weak self] in
            let revision = await Self.revision(of: read)
            guard let self else { return }
            lineLooks.inFlight = nil
            guard record?.startedAt == started, let walkedHikeID else { return }
            if read.isReplaced {
                checkWalkedLine(at: now)
                return
            }
            lineLooks.last = WalkedLineLooks.Look(read: read, walkStartedAt: started, at: lookedAt)
            if let revision { endIfRouteChanged(at: now, knowing: (walkedHikeID, revision)) }
        }
    }

    /// The look out now, if any. Readable so a suite can wait on the effect
    /// rather than on a duration.
    var lineCheck: Task<Void, Never>? { lineLooks.inFlight }

    /// ``checkWalkedLine(at:)`` for a fix matched on another hike's screen,
    /// which can come every second: the line the last look at this walk read
    /// stands for ``walkedLineLookInterval``, unless a write through the
    /// hike's context has replaced it since.
    ///
    /// Each look decodes and hashes the whole line in a context of its own,
    /// about 30 ms of 20,000 points, and leaves a watch on the line that only
    /// its next write releases. An edit on this device is still heard at the
    /// next fix, and one mirrored in from another device, which raises
    /// nothing here, within the interval. A return to the foreground, a launch
    /// and every background fix look regardless.
    func lookAtWalkedLineIfDue(at now: Date?) {
        if let last = lineLooks.last, last.walkStartedAt == record?.startedAt, !last.read.isReplaced,
           (now ?? clock()).timeIntervalSince(last.at) < Self.walkedLineLookInterval {
            return
        }
        checkWalkedLine(at: now)
    }

    /// The line `read` holds, as a walk names it, or `nil` for a row the store
    /// no longer holds.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor, and this hashes every point.
    @concurrent
    nonisolated private static func revision(of read: SelectedLine.Read) async -> String? {
        let route = await read.route
        return route.isEmpty ? nil : TrailWalkRecord.routeRevision(of: route)
    }
}

/// What ``TrailWalkSession`` keeps of its looks at the walked line.
struct WalkedLineLooks {
    /// One look that landed, about the walk that began at `walkStartedAt`.
    struct Look {
        /// Kept for ``SelectedLine/Read/isReplaced``, which a write through
        /// the hike's context raises. It holds the line it read until the
        /// next look replaces it.
        let read: SelectedLine.Read
        let walkStartedAt: Date
        let at: Date
    }

    /// The look out now, if any — see ``TrailWalkSession/checkWalkedLine(at:)``.
    var inFlight: Task<Void, Never>?
    /// The last look that landed.
    var last: Look?
    /// How a look fetches the row: ``SelectedLine/fetchHike(_:_:)``, or a
    /// suite's count of the reads.
    var fetch: @Sendable (ModelContext, PersistentIdentifier) throws -> Hike? = SelectedLine.fetchHike
}
