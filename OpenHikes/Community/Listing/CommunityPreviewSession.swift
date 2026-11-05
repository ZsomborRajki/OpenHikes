//
//  CommunityPreviewSession.swift
//  OpenHikes
//
//  One visit to a shared hike's preview, held where a turn of the phone
//  cannot reach it.
//
//  The preview is drawn in the sheet in portrait and in the side panel in
//  landscape, so a turn builds it again in the other host. While what it had
//  loaded was the screen's own `@State`, the one built there started the visit
//  over (#1336): it asked for the hike again, downloaded a stranger's
//  photographs again into a directory of its own, put the chart's marker back
//  at the trailhead and forgot the photographs an import had missed. The work
//  the first screen had started went on beside it, for a screen nobody could
//  see.
//
//  ``SheetPresentation`` keeps one of these for each preview on the stack, as
//  it keeps *Places Around Trail*'s ``HikePlacesAroundSearch``, so the screen
//  in the new host draws the same answer and waits on the same work. What is
//  here is what the screen held, moved and not reinterpreted: the fetch's
//  phase, the walk of the route, what OpenStreetMap said about it, the chart's
//  position, the import and what it came to, the five tasks writing all of
//  that, and the visit's own name. The work itself stays on
//  ``CommunityHikeView`` and writes in here, so a task a screen started lands
//  on whichever screen is drawing the visit when it finishes.
//
//  ## The route is the lifetime
//
//  A visit ends when its route leaves the path — Back, a block, an import that
//  opened the saved hike, a pin that put another preview in its place — and
//  never because a screen went. A turn to landscape takes one screen away
//  while its route stays, and the turn back takes the new one away, brings
//  one up, takes it away and brings it up again. So ``end()`` is called from
//  ``SheetPresentation``'s path, where that difference is a fact rather than
//  something a disappearing screen has to ask about, and it is what the
//  screen's `onDisappear` used to do: stop the downloads, stop the analysis,
//  and delete the directory once nothing is reading from or writing into it.
//  The line on the map is still the screen's to retire — see
//  ``CommunityHikeView``'s `remainsPushed`.
//
//  ## What the screen's body reads
//
//  What it read as `@State`, and as often. None of it is high frequency — it
//  changes when a download lands, when the route has been walked and when an
//  import finishes, the reason ``CommunityReviewDecisions`` gives for being
//  one of these. The task handles and ``wasAuthorBlocked`` are untracked,
//  which is less than before: a handle written into `@State` invalidated the
//  screen whether or not anything drew it. The one thing here that moves
//  under a finger is the chart's position, and that is a ``TrackerState`` the
//  body hands down without reading — a `let`, so observation never sees it.
//

import Foundation
import Observation
import OpenHikesData

@Observable
final class CommunityPreviewSession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// What the screen is doing, as one value.
    ///
    /// A single enum rather than a `detail` plus an `isLoading` plus an
    /// `error`, because those three can express states that do not exist — a
    /// failure with a detail behind it, a load that is both finished and
    /// running — and every one of them would be a screen somebody has to
    /// reason about.
    enum Phase {
        case failed(CommunityFailure)
        case loaded(CommunityHikeDetail)
        case loading
    }

    let listing: CommunityListing

    /// This visit, told apart from every other visit to the same listing.
    ///
    /// Made once per route on the stack and kept for as long as the route is
    /// there, so a push over this preview and the Back out of it, and a turn
    /// of the phone, come home to the same downloads. Opening the same
    /// listing again after leaving pushes a new route, and a new route gets a
    /// new one of these.
    ///
    /// Two visits to one listing must not share a directory, because
    /// ``end()`` removes a path once the tasks *it* was given have finished,
    /// and the tasks of a visit that has gone know nothing about the visit
    /// that replaced it.
    let visit = UUID()

    var phase = Phase.loading
    /// The elevation profile and the stat tiles, from the same builder a hike
    /// in the library uses.
    ///
    /// Held apart from ``phase`` because they arrive after it: the route is
    /// what the screen is waiting for and both of these are a walk of that
    /// route, so folding them together would hold the photographs and the Add
    /// button back on a computation nothing is blocked by.
    ///
    /// One optional rather than a profile and an array, because they land
    /// together and the difference between them matters on screen: `nil` is
    /// "the route has not been walked yet" and a value with a flat profile in
    /// it is "this hike has no elevations", which are two different things to
    /// draw. See ``CommunityHikeView``'s `elevationSection`.
    var prepared: HikeDetailPreparedContent?
    /// What OpenStreetMap says this route runs on, measured once per visit and
    /// kept no longer than it — see ``CommunityHikeView``'s header.
    var breakdowns = HikeTrailBreakdowns.empty
    /// The elevation chart's scrub position.
    ///
    /// A reference type for the reason ``HikeDetailView``'s is, and handed
    /// down without ever being read by the screen: a finger dragging the chart
    /// moves the marker and redraws the chart, and nothing above it. Unlike
    /// the hike's own, nothing else writes to it — there is no live location
    /// to project onto a stranger's trail, so
    /// ``TrackerState/liveTrackerDistance`` stays `nil` for the whole visit.
    /// The map's dot follows it through the browser, and a screen coming up
    /// for the visit puts the dot back where this says — see
    /// ``CommunityHikeView``'s `publishChartPosition()`.
    let tracker = TrackerState()

    // MARK: The import

    var isImporting = false
    var importFailure: CommunityFailure?
    var existingHike: Hike?
    /// What the import this visit made came to, for as long as some of its
    /// photographs are still missing — and `nil` the rest of the time.
    ///
    /// Kept here rather than on the hike because this is the only place a
    /// retry can run: the photographs are copied out of this visit's own
    /// downloads, which go when it does. See ``CommunityPhotoCopy``.
    var photoCopy: CommunityPhotoCopy?
    /// Whether this author was blocked while the visit was up.
    ///
    /// Read by the import when it finishes, so a hike the hiker asked for a
    /// moment before blocking does not re-open itself over the list — see
    /// ``CommunityHikeView/performImport(_:)``. Here rather than on the screen,
    /// because the import that reads it can have been started by the screen a
    /// turn took away.
    @ObservationIgnored var wasAuthorBlocked = false

    // MARK: The work

    /// The download, held rather than fired and forgotten.
    ///
    /// This is what *writes* into the directory ``end()`` removes, so leaving
    /// it unowned meant the end could neither stop it nor wait for it: a
    /// hiker backing out mid-download had the directory deleted and then
    /// re-created underneath them, and a stranger's photographs stayed in a
    /// temporary directory with nothing left that would ever collect them.
    /// *Try Again* writes to the same handle, since an unowned retry is the
    /// same leak by a second route.
    ///
    /// Untracked, as every handle here is: no body draws a task, and writing
    /// one into the screen's `@State` invalidated the screen for nothing.
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    /// The import, held for the reason the download is and in the same wait
    /// list: it is still *reading* photographs out of the directory, and
    /// nothing may delete underneath it.
    @ObservationIgnored var importTask: Task<Void, Never>?
    /// The trail analysis, held so leaving stops it.
    ///
    /// Nothing waits for this — it writes two sections that are absent until
    /// it answers — but a hiker who leaves must not leave a run of Overpass
    /// requests going for a preview that has gone. Deliberately **not** in
    /// ``end()``'s wait list: it neither reads from nor writes into the
    /// download directory, and making a stranger's photographs wait on a
    /// trail graph would couple two unrelated things through one `for` loop.
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    /// The other hikers' photographs, held so leaving stops the fetch.
    ///
    /// **In** ``end()``'s wait list, unlike the analysis beside it, and the
    /// difference is exactly the rule that list states: this one writes files
    /// into the download directory.
    @ObservationIgnored var contributionsTask: Task<Void, Never>?
    /// The Wikimedia Commons photographs of a curated route, held for the
    /// reason ``contributionsTask`` is and in the same wait list.
    @ObservationIgnored var commonsTask: Task<Void, Never>?
    /// Whether the route has left the path. Nothing starts after it has.
    @ObservationIgnored private(set) var hasEnded = false

    init(listing: CommunityListing) {
        self.listing = listing
    }

    /// Where this visit's downloads live. Per visit rather than per listing —
    /// see ``visit`` — and removed by ``end()``.
    var downloadDirectory: URL {
        CommunityStaging.previewDirectory(of: listing, in: visit)
    }

    /// Starts the visit's load, unless it has started already.
    ///
    /// Asked by every screen that comes up for this visit, and only the first
    /// one's question is a request: a screen built by a turn of the phone
    /// finds the load the screen before it started, finished or still out,
    /// and draws its answer or waits for it. A load that failed stays failed
    /// until *Try Again* says otherwise — see ``reload(_:)``.
    ///
    /// Leaves ``phase`` alone, which is already `.loading` for a visit that
    /// has not loaded: `Phase` is not `Equatable`, so writing the same value
    /// again would still run the screen's body, in the middle of the push
    /// that is bringing it up.
    func startLoading(_ load: @escaping @MainActor () async -> Void) {
        guard loadTask == nil, !hasEnded else { return }
        loadTask = Task { await load() }
    }

    /// Starts the load again, on the same handle — *Try Again*.
    func reload(_ load: @escaping @MainActor () async -> Void) {
        guard !hasEnded else { return }
        phase = .loading
        loadTask = Task { await load() }
    }

    /// The route has left the path: stops what is still downloading or
    /// asking, and removes the downloads once nothing is using them.
    ///
    /// Both kinds of task are waited for, for opposite reasons. The import is
    /// still *reading* a stranger's photographs out of the directory, so
    /// deleting underneath it costs the hiker the pictures of a hike they
    /// asked for. The three downloads are still *writing*, so deleting
    /// underneath them leaves files behind instead — the writer re-creates
    /// the directory after the remove, and nothing ever comes back for it.
    /// Cancelling them first is what keeps the wait short rather than a whole
    /// download long; an unstructured `Task` inherits no cancellation however
    /// closely the three were started together.
    ///
    /// All of them are this visit's, and so is the path — see ``visit``. What
    /// is waited for and what is removed have to belong to the same visit, or
    /// the wait is for one visit's work and the remove lands on another's.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        loadTask?.cancel()
        contributionsTask?.cancel()
        commonsTask?.cancel()
        // Nothing waits for this one; it is cancelled because a preview that
        // has gone has no use for an answer and no right to keep asking
        // Overpass for it.
        analysisTask?.cancel()
        CommunityHikeView.discardDownloads(
            at: downloadDirectory,
            after: [loadTask, importTask, contributionsTask, commonsTask]
        )
    }
}
