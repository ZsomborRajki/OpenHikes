//
//  DrawnRouteTap.swift
//  OpenHikes
//
//  The way back from the line the map draws into the screen it belongs to.
//
//  The map draws exactly one of the hiker's own routes — the selected hike's,
//  and see ``DisplayedRoute/forSelection(_:cache:recordingPresented:)`` for
//  when it draws none — and that line was scenery. A hiker who opened a trail,
//  read it, and went back to the search field was left looking at their own
//  route with no way into it but finding the row again in the list underneath.
//  Tapping the thing you are looking at is the shorter way, and it is already
//  how the shared hikes around it work.
//
//  A reference type holding a closure, which is the shape ``CommunityBrowser``
//  and ``PhotoMapPinController`` already use for the same problem: MapKit
//  draws the line, the destination is a push into a navigation stack the map
//  cannot see, and the screen that owns that stack is the one that can say
//  what a tap means. ``OpenHikesView`` sets the handler once and the
//  coordinator calls it; nothing here observes anything, so the map holds it
//  weakly beside ``CommunityBrowser`` and ``SearchCompleter`` rather than
//  observing it.
//

/// What a tap on the hiker's own drawn route opens.
@MainActor
final class DrawnRouteTap {
    /// Set once by ``OpenHikesView``, which owns the sheet's navigation path.
    private var handler: (() -> Void)?

    /// Points a tap on the drawn line at the screen it should open.
    func onOpen(_ open: @escaping () -> Void) {
        handler = open
    }

    /// Opens the drawn route's hike. Nothing happens before ``onOpen(_:)`` has
    /// been called, which is the window between the map being built and the
    /// view that owns the stack appearing.
    func open() {
        handler?()
    }
}
