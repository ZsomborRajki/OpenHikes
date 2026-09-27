//
//  HikeOpenRequests.swift
//  OpenHikes
//
//  How something outside the view tree asks for a hike to be opened.
//
//  An App Intent runs **in the app process but outside the view hierarchy**,
//  so it cannot reach `SheetPresentation`'s route state the way a button can.
//  What it can do is leave a request somewhere the view tree is watching,
//  which is all this is.
//
//  ## Why a deep link and not a hike id
//
//  Because there must not be two ways in. ``OpenHikesView`` already routes
//  the widget's taps — `openInboundURL(_:)` to `openWidgetLink(_:)` to
//  `openHike(id:)` — and that path already knows the things this would
//  otherwise have to learn again: that a hike already on screen is left alone
//  rather than reshuffled, that a hike belonging to a live recording opens the
//  recording screen instead, and that a hike deleted since the request was
//  made is a ghost to ignore rather than a crash. Handing this a
//  ``TrailWidgetDeepLink`` URL means the intent arrives *as* a widget tap and
//  gets all of that by construction. Two routes into the same state is how
//  they come to disagree about what "selected" means.
//
//  ## The shape
//
//  An event rather than state: each request goes to the readers of
//  ``links()`` — in practice the one `OpenHikesView`'s `.task` holds — as
//  the system's `onOpenURL` hands over a widget tap. The same hike asked for
//  twice is two requests, and nothing is kept for a reader that is not there
//  yet. ``EventFeed`` says why this is a stream and not a token observed by
//  `onChange`, which is what it was.
//

import Foundation
import OpenHikesShared

/// One request to open a hike, from outside the view tree.
@MainActor
final class HikeOpenRequests {
    private let feed = EventFeed<URL>()

    init() {
        // Nothing pending, which is what a launch that was not started by an
        // intent means.
    }

    /// The requests made from now on, for one reader. Nothing asked before
    /// the call is replayed — see ``EventFeed``.
    func links() -> AsyncStream<URL> {
        feed.events()
    }

    /// Asks for `hikeID` to be opened, as though its widget had been tapped.
    ///
    /// Silently does nothing when the id cannot be made into a link, which is
    /// the same answer the widget path gives a URL it cannot parse. An intent
    /// has already told the hiker it is opening the app by the time this runs,
    /// and there is nothing further to say.
    func open(hikeID: UUID) {
        guard let url = TrailWidgetDeepLink.url(hikeID: hikeID) else { return }
        feed.send(url)
    }

    /// Asks for the live recording's screen, as though the widget showing it
    /// had been tapped — which is also what the map's record button does once
    /// it has started one. See ``RecordingEntry``.
    func openRecording() {
        guard let url = TrailWidgetDeepLink.recordingURL() else { return }
        feed.send(url)
    }
}
