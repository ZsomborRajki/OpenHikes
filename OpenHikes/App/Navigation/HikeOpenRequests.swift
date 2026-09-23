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
//  A token whose *change* is the message, exactly like
//  ``PhotoCaptureController/cameraRequest`` — and for the same reason: the
//  same hike asked for twice is two requests, and a plain `URL?` would make
//  the second one invisible. The URL rides alongside and is read only when
//  the token moves.
//

import Foundation
import Observation
import OpenHikesShared

/// One request to open a hike, from outside the view tree.
@Observable
@MainActor
final class HikeOpenRequests {
    /// A token whose change is the message — see this file's header.
    private(set) var request = 0
    /// The link the current token is for. Read on the token's change and not
    /// otherwise, so nothing has to decide whether an old URL is still live.
    ///
    /// `@ObservationIgnored` because the token is what the view watches: a
    /// body that also depended on this would run twice for one request, once
    /// for each property the same call sets.
    @ObservationIgnored private(set) var link: URL?

    init() {
        // Nothing pending, which is what a launch that was not started by an
        // intent means.
    }

    /// Asks for `hikeID` to be opened, as though its widget had been tapped.
    ///
    /// Silently does nothing when the id cannot be made into a link, which is
    /// the same answer the widget path gives a URL it cannot parse. An intent
    /// has already told the hiker it is opening the app by the time this runs,
    /// and there is nothing further to say.
    func open(hikeID: UUID) {
        guard let url = TrailWidgetDeepLink.url(hikeID: hikeID) else { return }
        link = url
        request &+= 1
    }
}
