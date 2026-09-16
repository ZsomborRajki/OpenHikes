//
//  CommunityBrowser.swift
//  OpenHikes
//
//  The published hikes the sheet is currently showing, and the one place that
//  decides when to go and get more of them.
//
//  A stable `@Observable` reference type, held by ``OpenHikesModel`` and
//  handed down, for the same reason ``MapController`` and ``SearchCompleter``
//  are: the map feeds it a region on every pan, and a SwiftUI body that read
//  that region would re-run at gesture frequency. So the region is
//  `@ObservationIgnored` and the *results* are not — a list re-drawing when
//  its contents change is the whole job, while a list re-drawing because the
//  map moved two streets is the cost render isolation exists to refuse.
//
//  ## Why the map drives this at all
//
//  Because a hike is a place before it is a name. A hiker looking for
//  somewhere to go on Saturday pans to the hills they can drive to, and
//  typing the name of a trail they have never heard of is not something they
//  can do. The map is the query.
//
//  ## The map asks, and the hiker answers
//
//  What that must not become is a request per pan, and for a while the
//  thresholds in ``CommunityQueryPolicy`` were the whole of the defence: a
//  pan past them re-queried on its own. That was cheap and illegible. The
//  list replaced itself under the hiker's thumb for reasons nothing on
//  screen gave, and the pans the thresholds refused left it describing
//  somewhere the map had already left — equally silently.
//
//  So the policy's answer is now an *offer*. A region that clears the
//  thresholds raises ``areaPrompt``, which the map draws as *Search this
//  area*; ``searchVisibleArea()`` is what the hiker's tap runs, and the only
//  thing that spends a request. The thresholds are unchanged and still
//  load-bearing — they decide when the offer is worth making — and this is
//  strictly cheaper than what it replaced, because a pan nobody confirms
//  costs nothing at all. ``areaName`` then says which area answered, so the
//  list is headed with a place rather than with the word *Nearby*.
//
//  The one request the hiker does not have to confirm is the first: selecting
//  the *Community* tab is itself the confirmation, and asking twice for one
//  intention would be a worse bargain than the automatic re-query ever was.
//  Leaving the tab calls ``stopBrowsing()``, so the session lasts exactly as
//  long as the list that is showing it.
//
//  ## Where blocked authors are taken out
//
//  Here, once, at the point both lists are read — see ``nearbyResults``. The
//  two lists are deliberately separate and answer different questions, so the
//  one thing they must not disagree about is who is hidden; filtering as the
//  results land would have meant remembering to re-filter whichever list was
//  standing when a block was made. ``CommunityBlockList`` holds the list and
//  the reasoning for it being device-local.
//

import CoreLocation
import Foundation
import MapKit
import Observation
import os

/// What the community section is currently able to say.
enum CommunityBrowseState: Equatable {
    case failed(CommunityFailure)
    /// Nothing has been asked for. The hiker has not opted in, or has just
    /// hidden the section again.
    case idle
    /// The last request finished. An empty list here means "nowhere near
    /// there", which is a real answer and not a failure.
    case loaded
    /// A request is in flight and there is nothing to show yet. Distinct from
    /// ``refreshing`` because only one of the two should replace the list with
    /// a spinner.
    case loading
    /// A request is in flight over results that are already on screen.
    case refreshing
}

/// What the map is offering to do about the region on screen, as distinct
/// from what the list is already showing.
///
/// Observed by two things that cannot see each other — the *Search this area*
/// control, which MapKit draws, and the section header in the sheet — so it
/// is a value both can read rather than a control's own hidden state.
enum CommunityAreaPrompt: Equatable {
    /// The map has moved far enough to be a different question.
    case search
    /// The list is answering about what is on screen, near enough.
    case settled
    /// The map is zoomed out past the point where "near here" means anything.
    /// Nothing to offer, and something to say — see
    /// ``CommunityQueryPolicy/maximumRadiusMeters``.
    case zoomIn
}

@MainActor
@Observable
final class CommunityBrowser {
    /// Non-isolated so releasing the last reference never requires proving we
    /// are on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    @ObservationIgnored private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "Community"
    )

    /// How many rows one query asks for. More than fits on a phone, few enough
    /// that a list nobody scrolls to the bottom of does not pay for a second
    /// page — see ``CloudKitCommunityTransport``'s `run`, which deliberately
    /// drops the cursor.
    private static let resultLimit = 25

    /// What the *Community Hikes* section draws: the map's own answer.
    ///
    /// Kept apart from ``matchingListings`` rather than sharing one array with
    /// it, and the separation is the whole of a fix. Two different questions
    /// are being asked — *what is near this area* and *what is called this* —
    /// they are drawn in two different places, and while one array held both
    /// answers each could overwrite the other: a pan past the policy's
    /// threshold replaced a typed search's results under a heading that still
    /// said *Community Hikes*, and clearing the field left the title matches
    /// standing wherever the zoom ceiling refused the replacement query. An
    /// answer now outlives the other question entirely.
    ///
    /// Computed, with blocked authors taken out — see ``nearbyResults``.
    var nearbyListings: [CommunityListing] { blockList.excludingBlocked(nearbyResults) }
    /// What the search results draw: published hikes whose title matches what
    /// the hiker typed. Nothing the map does touches this.
    var matchingListings: [CommunityListing] { blockList.excludingBlocked(matchingResults) }

    /// The nearby answer as it came back, before anybody was blocked out of it.
    ///
    /// Filtered on the way *out* rather than on the way in, which is the whole
    /// of why a block takes effect on results that are already on screen. The
    /// two lists above are deliberately separate and would otherwise disagree
    /// about what is blocked — a block made while a typed search is standing
    /// would have had to remember to re-filter it too, and the one that was
    /// forgotten would be the bug. One filter, one source of truth, applied at
    /// the point of reading.
    ///
    /// It also means a hiker who unblocks somebody gets their hikes back
    /// without a request: the rows were never thrown away, only hidden.
    private var nearbyResults: [CommunityListing] = []
    private var matchingResults: [CommunityListing] = []

    /// Each nearby listing's thinned route, keyed by listing.
    ///
    /// Deliberately not merged into ``nearbyResults``: a listing is a snapshot
    /// of a record and these arrive in a second request that can fail on its
    /// own, so folding them together would mean either withholding rows until
    /// the geometry landed or inventing an empty route for a hike that has
    /// one. Kept beside the rows, read through them.
    private var nearbyOutlines: [String: [RouteCoordinate]] = [:]

    /// The hike whose preview is open, once its route has loaded.
    ///
    /// The preview used to draw a little unscaled sketch of the route instead,
    /// which answered the one question it had to — *does this go where I think
    /// it does* — and answered it in the abstract, beside a map that could
    /// have answered it properly. Now the screen carries the hike's numbers
    /// and the map carries its line.
    ///
    /// `nil` until the preview's own fetch lands, which is why the outline
    /// under it is left drawn in the meantime: a line that vanished on the way
    /// in and came back a second later would read as a glitch.
    private var previewedRoute: CommunityRouteLine?
    /// Where the open preview's photographs were taken, once they have
    /// arrived.
    ///
    /// Separate from ``previewedRoute`` rather than folded into it, because
    /// the two are separate answers to separate questions and only one of
    /// them is ever shared with the rest of the list: every hike in the nearby
    /// answer has a line, drawn from its outline, and none of them has pins.
    /// A photograph's place on a trail is in the submission's pins asset,
    /// which only the screen that opened the hike ever downloads.
    ///
    /// Retired by the same two calls that retire the line, which is what keeps
    /// a pin from outliving the files behind it — see
    /// ``CommunityPreviewPhoto/fileURL``.
    private var previewedPhotos: [CommunityPreviewPhoto] = []
    /// Which preview is open, whether or not its route has arrived.
    ///
    /// Separate from ``previewedRoute`` because the two are set at different
    /// moments — the screen appears, and some time later it has something to
    /// draw — and because it is what the later two calls are matched against:
    /// a screen being replaced by another push tears down *after* the new one
    /// appears, so an unmatched close would clear a preview that had just
    /// started.
    @ObservationIgnored private var previewedListingID: String?
    /// How the *nearby* request is getting on.
    ///
    /// The nearby one only, because it is the only one with anywhere to say
    /// so — see ``MapSheetHikes``'s empty state, which distinguishes a failure
    /// from an area with nothing in it. A title search that fails draws no
    /// rows and is logged; it must not put an error over a nearby list that
    /// is perfectly good.
    private(set) var state: CommunityBrowseState = .idle
    /// Whether a nearby answer is on its way.
    ///
    /// Derived rather than stored, for the reason ``nearbyListings`` is: one
    /// source for each fact. ``state`` already knows, and a second flag could
    /// only disagree with it about whether the map's question is still open.
    ///
    /// It covers **both** halves of that question and could not cover one:
    /// ``MergedCommunityTransport`` asks CloudKit and Overpass side by side
    /// and returns when both have answered or failed, so there is a single
    /// request here and this is its whole life. The outlines that follow an
    /// answer are deliberately outside it — the rows and pins are already up
    /// by then, and a control that kept spinning for the lines would be
    /// reporting work the hiker is not waiting on.
    ///
    /// Read by the *Search this area* pill, which draws it as a spinner in
    /// place of its glyph and stops answering taps while it is true. See
    /// ``MapCommunitySearchControl``.
    var isSearching: Bool { state == .loading || state == .refreshing }
    /// Whether the hiker has asked for shared hikes at all.
    ///
    /// Also *which list the sheet is showing*: the ``MapSheetList`` picker is
    /// bound to this rather than to a `@State` of its own, because the
    /// *Community* tab and the browse session are the same thing and a second
    /// flag could only disagree with this one. Observed on purpose, by the
    /// sheet and by the map's *Search this area* pill, which stands for as
    /// long as the tab does.
    private(set) var isBrowsing = false
    /// Whether the map has moved somewhere the list does not describe.
    ///
    /// Coarse by construction: ``CommunityQueryPolicy`` refuses everything
    /// smaller than half the search radius, so this moves a handful of times
    /// in a browsing session and never at gesture frequency. `Equatable`
    /// so `@Observable` filters the same-value writes a run of settles
    /// produces — see *Render isolation, in practice*.
    private(set) var areaPrompt: CommunityAreaPrompt = .settled
    /// Why the last search that asked for OpenStreetMap trails has none, when
    /// that is a failure rather than an answer.
    ///
    /// Observed, and drawn beside the *Search this area* pill rather than over
    /// the rows — see ``MapCommunitySearchControl``. It is not a
    /// ``CommunityBrowseState``: the request succeeded, the list underneath is
    /// real, and the button stays enabled, because the one thing a
    /// rate-limited hiker can still usefully do is search this area for the
    /// hikes people published in it.
    ///
    /// Written only by a ``CommunityNearbyScope/withCuratedTrails`` answer, so
    /// a refill after a block cannot clear a limit that is still running, and
    /// cleared by leaving the tab. `Equatable` so `@Observable` filters the
    /// same-value writes a run of refused taps produces.
    private(set) var curatedOutage: CuratedTrailOutage?
    /// What to call the area the list is answering about, once something has
    /// answered. `nil` until then, and for a launch with no ``areaNames``.
    private(set) var areaName: String?

    /// The last region the map settled on.
    ///
    /// Ignored by observation and that is the point: this is written on every
    /// pan, and nothing that draws may depend on it. Held rather than merely
    /// passed through so that opting in can ask about wherever the map already
    /// is, without the opt-in row's call site knowing about the map.
    @ObservationIgnored private var latestRegion: MKCoordinateRegion?
    /// The area behind an ``CommunityAreaPrompt/search`` offer, kept so the
    /// hiker's tap asks about the region that raised it rather than
    /// re-deriving one from a map that may have drifted since.
    @ObservationIgnored private var offeredArea: CommunitySearchArea?
    /// The area ``nearbyResults`` actually came back for.
    ///
    /// Written when results *land*, never when a request starts, and that is
    /// the distinction the two bugs it fixes both turned on. Three areas are
    /// in play at once and they are routinely different: ``latestRegion`` is
    /// wherever the map happens to be, ``offeredArea`` is a question the
    /// hiker has not accepted, and this is the only one the rows on screen
    /// are an answer to.
    ///
    /// It survives a failure, because the rows do — see ``fail(with:answering:)``.
    /// So it is what a block refill re-asks about, and what ``areaName`` is
    /// allowed to describe.
    @ObservationIgnored private var resultsArea: CommunitySearchArea?
    /// The area a name is currently being resolved for, and the name once
    /// MapKit has given one.
    ///
    /// Held apart from ``areaName`` so a name can arrive before, after, or
    /// instead of the results it describes without ever being published over
    /// rows it is not about. The geocode and the query are two independent
    /// requests with two independent failure modes, and the header is only
    /// ever allowed to say what the *rows* are about.
    @ObservationIgnored private var pendingArea: CommunitySearchArea?
    @ObservationIgnored private var pendingName: String?
    /// Whether an opt-in is still waiting for a region to be about. See
    /// ``startBrowsing()``.
    @ObservationIgnored private var wantsFirstRegion = false
    @ObservationIgnored private var policy = CommunityQueryPolicy()
    @ObservationIgnored private let transport: (any CommunityTransporting)?
    /// `nil` for a launch that must not reach the network, and for one that
    /// has nowhere to show a name — see ``CommunityAreaNaming``.
    @ObservationIgnored private let areaNames: (any CommunityAreaNaming)?
    /// The hiker's own block list, which both result sets are read through.
    ///
    /// The *reference* is ignored by observation because it never changes;
    /// what a body reading ``nearbyListings`` ends up tracking is the block
    /// list's own state, which is how a block made on a pushed screen redraws
    /// the list underneath it. Held rather than owned — ``OpenHikesModel``
    /// builds it, because the Settings screen writes to the same one.
    @ObservationIgnored let blockList: CommunityBlockList
    /// One in-flight task per question, for the same reason there is one list
    /// per question: a typed search cancelling the map's request, or the other
    /// way round, is how the two used to interfere.
    @ObservationIgnored private var nearbyTask: Task<Void, Never>?
    @ObservationIgnored private var matchTask: Task<Void, Never>?
    @ObservationIgnored private var titleQuery = ""
    @ObservationIgnored private var requestedTitle: String?
    @ObservationIgnored private var nameTask: Task<Void, Never>?
    /// The outline fetch for whatever the nearby list currently holds.
    ///
    /// Its own task rather than part of the nearby one, because it is a
    /// second request that must not delay the first: the rows and the pins go
    /// up as soon as they land, and the lines arrive under them. A failure
    /// here costs the lines and nothing else.
    @ObservationIgnored private var outlineTask: Task<Void, Never>?
    /// Where a tapped map pin goes. Set once by ``OpenHikesView``, which owns
    /// the sheet's navigation path; see ``open(_:)``.
    @ObservationIgnored private var openListing: ((CommunityListing) -> Void)?

    /// - Parameter transport: `nil` for a launch that must not reach CloudKit
    ///   — a hosted test bundle, or UI automation. Every entry point is then a
    ///   no-op, in the same shape ``HikeLiveActivityController`` is absent for
    ///   those launches rather than stubbed.
    /// - Parameter areaNames: `nil` for those same launches, and for any
    ///   caller that does not care what the searched area is called.
    init(
        transport: (any CommunityTransporting)?,
        blockList: CommunityBlockList,
        areaNames: (any CommunityAreaNaming)? = nil
    ) {
        self.transport = transport
        self.blockList = blockList
        self.areaNames = areaNames
    }

    /// Requests that reached the transport. The policy above is what makes
    /// this smaller than the number of pans, and this is what proves it.
    @ObservationIgnored private(set) var issuedRequests = 0

    /// Requests that have not landed yet: either question, and the outline
    /// fetch that follows a nearby answer.
    ///
    /// Kept for the same reason ``issuedRequests`` is, and needed for a
    /// sharper one: ``state`` describes the nearby request alone, so a suite
    /// that waited on it would be waiting on the map while asserting about a
    /// title search that had not come back. Waiting on the effect rather than
    /// on a duration is the house rule; for a question with nothing to draw,
    /// this is the effect.
    ///
    /// The outlines are counted here and deliberately **not** in
    /// ``issuedRequests``, which counts questions asked *about an area* — the
    /// number the policy exists to keep below the number of pans. One answer
    /// is one question however many requests carrying it back.
    @ObservationIgnored private(set) var requestsInFlight = 0

    /// Whether this launch can reach the community at all.
    ///
    /// False for a hosted suite or UI automation — see
    /// ``OpenHikesModel/makeCommunityTransport()``. The section and the share
    /// button are *absent* rather than disabled when it is false, because a
    /// disabled control is a promise to do something later and this launch is
    /// never going to.
    var hasTransport: Bool { transport != nil }

    // MARK: - The map

    /// The map came to rest. Called from `MapView.Coordinator`, never from a
    /// SwiftUI body.
    ///
    /// Cheap by contract: while browsing is off this stores a value and
    /// returns, which is what lets it sit on `regionDidChangeAnimated`
    /// alongside the highlight update without costing a hiker who has never
    /// used this feature anything at all. While browsing is *on* it still
    /// reaches no network — the most it does is raise an offer.
    func regionDidSettle(_ region: MKCoordinateRegion) {
        latestRegion = region
        // Asked once and read twice. ``CommunityQueryPolicy/action(for:)`` is
        // side-effect free by contract, so the two calls this used to make
        // could not disagree — but a settle is the hot path this whole type is
        // arranged around, and one answer is also one thing to reason about.
        let action = policy.action(for: region)
        // The opt-in that arrived before the map did — see ``startBrowsing()``.
        if wantsFirstRegion, case .offer(let area) = action {
            wantsFirstRegion = false
            // The published half only, like the opt-in it is finishing. See
            // ``startBrowsing()``.
            commit(area, from: .publishedOnly)
            return
        }
        switch action {
        case .ignore:
            offeredArea = nil
            areaPrompt = .settled
        case .offer(let area):
            offeredArea = area
            areaPrompt = .search
        case .tooFarOut:
            offeredArea = nil
            areaPrompt = .zoomIn
            // A deferred opt-in whose first region turns out to be above the
            // ceiling. Nothing was asked and nothing is coming until the hiker
            // zooms in, so the spinner ``startBrowsing()`` put up has to come
            // down: `.loading` means a request exists, and the header draws it
            // as a promise of an answer. This is the resting state
            // ``startBrowsing()`` already reaches for itself when the map had
            // settled somewhere too wide before the tab was selected — the two
            // paths express one intention and must agree about it.
            //
            // `wantsFirstRegion` deliberately stays set. The tap that opted in
            // is still the confirmation, so the first region that *does* clear
            // the ceiling is asked about rather than offered.
            if wantsFirstRegion { state = .loaded }
        }
    }

    /// Asks about the area the map is showing: what *Search this area* runs.
    ///
    /// Takes the offered area when there is one, so the question asked is the
    /// one the offer was made about — a settle landing between the hiker
    /// seeing the button and hitting it would otherwise change it underneath
    /// them.
    ///
    /// Without an offer it asks about wherever the map is, and that is not a
    /// stray call any more: the pill stands for the whole of the *Community*
    /// tab rather than only while an offer is up, so a tap with the map
    /// sitting where the list already describes is a hiker asking for that
    /// list again. The policy has to forget its last query first or the region
    /// would be refused as the same question — which is exactly ``retry()``,
    /// so this asks it rather than spelling the same three lines again.
    /// `.tooFarOut` still asks nothing, which is what the pill being disabled
    /// above the ceiling says on screen.
    ///
    /// **This is the tap OpenStreetMap is asked on, and the only one.** Every
    /// other path into ``commit(_:from:)`` asks for the published hikes alone
    /// — see ``CommunityNearbyScope`` for what that costs and why the
    /// distinction is the question's rather than the transport's.
    func searchVisibleArea() {
        // A second question while the first is unanswered buys nothing and
        // costs an Overpass listing pass: ``perform(_:describing:about:matching:from:)``
        // awaits the task it supersedes before starting, so a tap during a
        // search cannot arrive sooner — it can only queue another one. The
        // pill is dimmed and spinning while this is true, so a tap that gets
        // here at all is a race rather than an instruction.
        guard isBrowsing, !isSearching else { return }
        if let offeredArea {
            commit(offeredArea, from: .withCuratedTrails)
        } else {
            retry()
        }
    }

    // MARK: - Opting in

    /// Turns the community list on and asks about wherever the map is.
    ///
    /// The one request nobody has to confirm — the tab selection that gets
    /// here *is* the confirmation. See this file's header.
    func startBrowsing() {
        guard !isBrowsing else { return }
        policy.startBrowsing()
        isBrowsing = true
        guard let latestRegion else {
            // The map has not reported a region yet — a sheet opened before
            // the first `regionDidChangeAnimated`. Nothing to ask about, so
            // the first one that arrives is asked rather than offered: the tap
            // that got here is still the confirmation, and a hiker who opted
            // in a moment too early should not be left looking at a spinner
            // beside a button asking them to opt in again.
            wantsFirstRegion = true
            state = .loading
            return
        }
        switch policy.action(for: latestRegion) {
        case .offer(let area):
            // The hiker's own published hikes, and not OpenStreetMap. Opening
            // the tab is one tap standing in for a question nobody typed, and
            // two Overpass round trips is not what it should buy — the pill it
            // raises is right there, and that tap is the one that asks. See
            // ``CommunityNearbyScope``.
            commit(area, from: .publishedOnly)
        case .tooFarOut:
            // Saying so is better than an empty list, which would read as
            // "there are none near you".
            areaPrompt = .zoomIn
            state = .loaded
        case .ignore:
            // Unreachable in practice — the policy has just forgotten its last
            // query, so any region inside the ceiling is a new question — and
            // a state rather than a `preconditionFailure` because there is a
            // perfectly good answer: nothing was asked, so nothing is loading.
            state = .loaded
        }
    }

    /// Puts the community list away again: what leaving the tab runs.
    ///
    /// Takes the map's answer with it and leaves the typed one alone:
    /// somebody who searched for a trail by name asked for it by name — see
    /// ``search(matching:)``.
    func stopBrowsing() {
        policy.stopBrowsing()
        isBrowsing = false
        nearbyTask?.cancel()
        nearbyTask = nil
        nameTask?.cancel()
        nameTask = nil
        outlineTask?.cancel()
        outlineTask = nil
        nearbyResults = []
        // The lines go with the pins. The open preview's own line does not —
        // it belongs to a screen that is still up, and hiding the section
        // from underneath it must not blank the trail it is showing.
        nearbyOutlines = [:]
        offeredArea = nil
        resultsArea = nil
        pendingArea = nil
        pendingName = nil
        wantsFirstRegion = false
        areaPrompt = .settled
        areaName = nil
        // The notice goes with the tab that drew it. A limit that is still
        // running will say so again on the next tap — ``CuratedTrailSource``
        // refuses one without a round trip — and a caption left standing over
        // a list nobody is looking at is a caption nothing will ever clear.
        curatedOutage = nil
        state = .idle
    }

    /// Asks again about the current region, ignoring the thresholds.
    ///
    /// What a failed request needs, and what a tap on the pill with no offer
    /// standing needs: the policy remembers a query that produced nothing, so
    /// without forgetting it first the same region would be refused as "the
    /// same question" and the hiker's only recourse would be to pan away and
    /// back. Above the ceiling it still asks nothing — a region that means
    /// "this continent" is not a question however many times it is put.
    func retry() {
        guard isBrowsing, !isSearching, let latestRegion else { return }
        policy.forgetLastQuery()
        guard case .offer(let area) = policy.action(for: latestRegion) else { return }
        // Both halves, because every caller is a hiker's tap: *Try Again* in
        // the list, and the pill with no offer standing. A retry that quietly
        // dropped the trails would leave a rate-limited hiker no way back to
        // them but panning away and returning.
        commit(area, from: .withCuratedTrails)
    }

    /// Refills the nearby list when a block has just emptied it.
    ///
    /// The read-time filter hides a blocked author's rows without asking
    /// anything, which is what should happen — but a page that was *all* that
    /// author leaves the hiker looking at *No community hikes here* for an area
    /// that may have plenty. Blocking one person must not empty the map.
    ///
    /// Deliberately narrow. It asks again only when the block took the last
    /// visible row and there were rows to take, so the ordinary block — a few
    /// rows out of twenty-five — costs nothing. The new request carries the
    /// author in its exclusion set, so it pages past them rather than coming
    /// back with the same hidden page; see ``CommunityPageBudget``.
    ///
    /// Nothing equivalent for the typed search, and that is not an oversight:
    /// it has no remembered question to re-ask, and the field the hiker typed
    /// into is still in front of them.
    ///
    /// It re-asks about ``resultsArea`` — the area the emptied rows were an
    /// answer to — and deliberately **not** about wherever the map is now.
    /// This used to go through ``retry()``, which reads ``latestRegion`` and
    /// commits it, so blocking somebody while the map sat over an unaccepted
    /// pan silently accepted that pan: the list was replaced with a different
    /// area's hikes, the *Search this area* offer the hiker had not taken was
    /// cleared, and none of it was anything they asked for. A block is not an
    /// answer to the map's question.
    ///
    /// So this touches neither the policy, the offer, nor the prompt. It is
    /// the same question as before with one more author excluded.
    func refreshAfterBlock() {
        guard isBrowsing, !nearbyResults.isEmpty, nearbyListings.isEmpty else { return }
        guard let resultsArea else { return }
        // Published only: a block is not a hiker asking OpenStreetMap
        // anything, and the curated rows in the list are unaffected by it —
        // they have no author to block. Re-asking Overpass here would spend
        // two round trips to get back the same trails.
        requestNearby(resultsArea, from: .publishedOnly)
    }

    /// Takes a hike out of both lists, because it is no longer in the
    /// database at all.
    ///
    /// What a takedown runs — see ``CommunityTransporting/takeDown(_:)``.
    /// ``refreshAfterBlock()`` is the wrong tool for it and looks like the
    /// right one: a block hides an author at *read* time, so its rows go on
    /// their own and that method exists only for the page a block emptied
    /// entirely. Nothing filters a taken-down listing, so left alone the row
    /// and its line stay on a list describing a database they are no longer
    /// in, and the next tap opens a preview that fails with *this hike isn't
    /// available any more*.
    ///
    /// Locally and at once, for the reason ``CommunityReviewQueue/forget(_:)``
    /// gives: the delete has already landed, and a round trip before the row
    /// goes would put the reviewer through a request to be told what their own
    /// device just did. The outline goes with it, because the line is drawn
    /// through the row.
    func forgetTakenDown(_ listing: CommunityListing) {
        nearbyResults.removeAll { $0.id == listing.id }
        matchingResults.removeAll { $0.id == listing.id }
        nearbyOutlines[listing.id] = nil
    }

    // MARK: - Map pins

    /// Where a tapped pin goes.
    ///
    /// Set by ``OpenHikesView``, which owns the sheet's navigation path, for
    /// the reason ``PhotoMapPinController`` takes its `onOpen` from the screen
    /// that claims the pins: MapKit draws them and the destination is a push
    /// into a stack the map cannot see.
    func onOpenListing(_ open: @escaping (CommunityListing) -> Void) {
        openListing = open
    }

    /// Opens a published hike's preview. Called from the map's own pins and
    /// from a tap on its line.
    func open(_ listing: CommunityListing) {
        openListing?(listing)
    }

    // MARK: - Requests

    /// Which of the two questions a request is answering.
    ///
    /// Named rather than implied because everything that follows is kept in
    /// two: two lists, two tasks, and — for the nearby one alone — a state
    /// somebody can see. See ``nearbyListings``.
    private enum Question {
        case nearby
        case title
    }

    /// Records an area as the one the list now answers about, and asks.
    ///
    /// The single door every nearby request goes through, so the three things
    /// that have to move together cannot drift apart: what the policy
    /// remembers, what the transport is asked, and what the header says the
    /// answer is about.
    ///
    /// The scope is the caller's to state and there is no default, because the
    /// two callers mean opposite things by it and a default would quietly give
    /// one of them the other's. See ``CommunityNearbyScope``.
    private func commit(_ area: CommunitySearchArea, from scope: CommunityNearbyScope) {
        policy.commit(area)
        offeredArea = nil
        areaPrompt = .settled
        nameArea(area)
        requestNearby(area, from: scope)
    }

    /// Asks the transport about `area`, and nothing else.
    ///
    /// Split out from ``commit(_:)`` because a block refill needs the request
    /// without any of the rest of it: re-asking the question already on screen
    /// must not re-commit a region, clear an offer, or restart a geocode for
    /// an area whose name has not changed. See ``refreshAfterBlock()``.
    ///
    /// The exclusion set is read here rather than passed in, which is what
    /// makes the refill carry the author who was just blocked.
    private func requestNearby(_ area: CommunitySearchArea, from scope: CommunityNearbyScope) {
        let excluded = blockList.blockedIDs
        perform(.nearby, describing: "a nearby search", about: area, from: scope) { transport in
            try await transport.listings(
                near: area.coordinate,
                radiusMeters: area.radiusMeters,
                limit: Self.resultLimit,
                excluding: excluded,
                scope: scope
            )
        }
    }

    /// Asks what the shapes of `listings` are, so the map can draw them.
    ///
    /// The second half of a nearby answer and deliberately a separate request.
    /// The rows and the pins are already up by the time this is issued, and
    /// what it adds — the lines — is the difference between knowing eleven
    /// hikes start near here and seeing where they go. It runs once per
    /// accepted page, not once per row: one fetch carries the lot, which is
    /// what ``CommunitySchema/Submission/routeOutline`` exists to allow.
    ///
    /// The outlines already held are dropped first rather than merged into.
    /// They describe the *previous* answer, and a pan to the next valley that
    /// kept them would leave the map drawing trails that are no longer in the
    /// list beside it.
    ///
    /// Failing is silent, like the publication check and for the same reason:
    /// nobody asked for this, there is nothing on screen that reports it, and
    /// what a hiker is left with is the pins and rows they already had.
    private func requestOutlines(for listings: [CommunityListing]) {
        outlineTask?.cancel()
        nearbyOutlines = [:]
        guard let transport, !listings.isEmpty else { return }
        requestsInFlight += 1
        outlineTask = Task { [weak self] in
            defer { self?.requestsInFlight -= 1 }
            do {
                let outlines = try await transport.outlines(for: listings)
                guard !Task.isCancelled, let self else { return }
                // Only for rows still on screen: a block or a newer answer
                // can land between the request and its reply, and an outline
                // keyed on a listing nobody holds draws nothing but is a line
                // of state nothing will ever clear.
                let wanted = Set(nearbyResults.map(\.id))
                nearbyOutlines = outlines.filter { wanted.contains($0.key) }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    """
                    Community outlines failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
    }

    /// Asks what the area being searched is called, superseding any earlier
    /// ask. Publishes nothing on its own.
    ///
    /// The name lands in ``pendingName`` and reaches ``areaName`` only when
    /// the rows it describes are the rows on screen — either here, if the
    /// results got back first, or in ``accept(_:answering:about:)`` if they
    /// have not.
    ///
    /// It used to clear ``areaName`` up front and publish straight into it,
    /// on the reasoning that the old name described somewhere the list was no
    /// longer about. That is true only if the new request succeeds. When it
    /// failed — the rows are deliberately kept, see
    /// ``fail(with:answering:)`` — the geocode had already renamed the header,
    /// so the section sat there showing one area's hikes under another area's
    /// name, with nothing on screen saying anything had gone wrong. A name
    /// and a list are two answers to two questions that fail separately, and
    /// the header may only ever describe the one that arrived.
    private func nameArea(_ area: CommunitySearchArea) {
        nameTask?.cancel()
        pendingArea = area
        pendingName = nil
        guard let areaNames else { return }
        nameTask = Task { [weak self] in
            let name = await areaNames.name(for: area)
            guard !Task.isCancelled, let self else { return }
            guard pendingArea == area else { return }
            pendingName = name
            // The rows this names are already up, so it is safe to say now.
            // Otherwise the results publish it when they land.
            if resultsArea == area { areaName = name }
        }
    }

    /// Runs one request, superseding whatever the *same question* had in
    /// flight.
    ///
    /// The new task awaits the old one before doing anything, which is what
    /// makes "supersede" true rather than merely likely: cancelling a task
    /// asks it to stop and does not stop it, so two results could otherwise
    /// still land in either order and the stale one could land last.
    ///
    /// Per question rather than per browser, which is the part that had to
    /// change: a pan superseding a typed search is not a newer answer to the
    /// same question, it is an answer to a different one — and it used to
    /// arrive in the same array.
    /// - Parameter area: The area a nearby request is about, carried through
    ///   so the results can be published together with the name and the area
    ///   they belong to. `nil` for a title search, which is about a word.
    /// - Parameter title: The normalized word a title search is about, for the
    ///   same reason — an answer is published only while it is still an answer
    ///   to what is being asked. `nil` for a nearby search.
    /// - Parameter scope: Which sources the nearby question covered, carried
    ///   through so ``curatedOutage`` is only ever written by a request that
    ///   asked about OpenStreetMap. A published-only refresh has nothing to
    ///   say about a rate limit and must not clear one that still stands.
    ///   `nil` for a title search.
    private func perform(
        _ question: Question,
        describing reason: String,
        about area: CommunitySearchArea? = nil,
        matching title: String? = nil,
        from scope: CommunityNearbyScope? = nil,
        _ work: @escaping @Sendable (any CommunityTransporting) async throws
            -> CommunityNearbyAnswer
    ) {
        guard let transport else { return }
        issuedRequests += 1
        if question == .nearby {
            // Against what is *drawn* rather than what came back: a list whose
            // every row is blocked out shows nothing, and replacing nothing
            // with a spinner is the honest half of `.loading`.
            state = nearbyListings.isEmpty ? .loading : .refreshing
        }
        let previous = task(for: question)
        previous?.cancel()
        requestsInFlight += 1
        let task = Task { [weak self] in
            // Runs on every exit, superseded and cancelled ones included —
            // the closure inherits this actor, so the decrement lands here
            // rather than hopping.
            defer { self?.requestsInFlight -= 1 }
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let answer = try await work(transport)
                guard !Task.isCancelled else { return }
                self?.accept(
                    answer,
                    answering: question,
                    about: area,
                    matching: title,
                    from: scope
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? CommunityFailure
                    ?? .unavailable(error.localizedDescription)
                Self.logger.error(
                    "Community \(reason, privacy: .public) failed: \(failure.localizedDescription, privacy: .public)"
                )
                self?.fail(with: failure, answering: question)
            }
        }
        setTask(task, for: question)
    }

    /// Publishes an answer: the rows, the area they are about, and the name
    /// of that area, in one place so the three cannot disagree.
    private func accept(
        _ answer: CommunityNearbyAnswer,
        answering question: Question,
        about area: CommunitySearchArea?,
        matching title: String?,
        from scope: CommunityNearbyScope?
    ) {
        let results = answer.listings
        switch question {
        case .nearby:
            nearbyResults = results
            resultsArea = area
            requestOutlines(for: results)
            // Only a question that asked about OpenStreetMap may answer for
            // it. A `nil` here from a published-only refresh means "not asked"
            // rather than "fine", and writing it would take the notice off the
            // button while the address was still rate-limited.
            if scope == .withCuratedTrails { curatedOutage = answer.curatedOutage }
            // The header describes these rows from here on. If MapKit has
            // already said what this area is called, say it; if it has not,
            // say nothing rather than keep the last area's name — the geocode
            // will publish it when it lands. A refill of the area already on
            // screen re-publishes the name it already had, since the pending
            // area is unchanged.
            areaName = area == pendingArea ? pendingName : nil
            state = .loaded
        case .title:
            // Only while the answer is still an answer to what is being
            // asked. `perform` already supersedes the same question, so this
            // is the belt to that braces: matches are keyed to a word rather
            // than to whichever request happened to land last.
            guard title == titleQuery else { return }
            matchingResults = results
        }
    }

    /// What a failed request leaves behind.
    ///
    /// The rows already on screen are kept either way. They were true when
    /// they arrived, and replacing a usable list with an error because one
    /// request failed is worse than showing it alongside one.
    private func fail(with failure: CommunityFailure, answering question: Question) {
        switch question {
        case .nearby:
            state = .failed(failure)
            // The area that failed is forgotten, so the map offers it again
            // rather than refusing it as "the same question".
            policy.forgetLastQuery()
        case .title:
            // Nothing on screen is touched, and that much is deliberate.
            // There is nowhere that reports a failed title search, and the two
            // things this could reach for instead both belong to the map:
            // ``state`` draws the nearby list's empty state, and the
            // remembered query is the nearby one. A typed word that could not
            // be looked up must not cost either.
            //
            // What it does forget is that the word was asked, which is what
            // lets Return ask it again. The deduplication in ``search`` is
            // there to stop a submission re-asking a question already
            // *answered*; a question that failed has no answer to reuse, and
            // the field the hiker typed into is the only retry this has.
            // Without this line the same word could never be submitted twice,
            // so a search that failed while the train was in a tunnel stayed
            // failed until the query was edited to something else and back.
            requestedTitle = nil
        }
    }

    private func task(for question: Question) -> Task<Void, Never>? {
        switch question {
        case .nearby: nearbyTask
        case .title: matchTask
        }
    }

    private func setTask(_ task: Task<Void, Never>?, for question: Question) {
        switch question {
        case .nearby: nearbyTask = task
        case .title: matchTask = task
        }
    }
}

// MARK: - The search field

// An extension rather than more of the class, for the reason the one
// below is: this is a whole question of its own — a word the hiker typed,
// answered against titles rather than against the map's region — and it
// shares only the two arrays it writes with everything above. Private
// state is file-scoped, so nothing had to be opened up to move it here.
extension CommunityBrowser {
    /// Invalidates an old response synchronously, before the new quiet period.
    /// The field calls this on edits, including an empty edit, so clearing never
    /// waits for SwiftUI to start the replacement task.
    func prepareTitleSearch(matching query: String) {
        let normalized = Self.normalizedTitle(query)
        guard normalized != titleQuery else { return }
        titleQuery = normalized
        requestedTitle = nil
        matchTask?.cancel()
        matchTask = nil
        // Whatever is on screen answered the *previous* word, so it goes with
        // it. Matches are the answer to a word the hiker typed, and a word
        // they have edited is a different question — keeping the rows would
        // offer Pilis Ridge as a match for "alps" the moment the new request
        // failed or while it was still in flight, with nothing saying which
        // word they belong to. The nearby list is deliberately the other way
        // round: those rows are about an area that is still on screen, which
        // is why a failed refresh keeps them.
        matchingResults = []
    }

    private static let titleQuietPeriodMilliseconds = 300
    private static let titleQuietPeriod: Duration = .milliseconds(titleQuietPeriodMilliseconds)

    static func normalizedTitle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Owned by the search field's `.task(id:)`: a new normalized edit or a
    /// disappearing field cancels the clock wait. Return uses `search` directly.
    func searchAfterQuietPeriod(
        matching query: String,
        clock: some Clock<Duration> = ContinuousClock()
    ) async {
        guard !Task.isCancelled, hasTransport else { return }
        prepareTitleSearch(matching: query)
        let normalized = Self.normalizedTitle(query)
        guard !normalized.isEmpty, requestedTitle != normalized else { return }
        do {
            try await clock.sleep(for: Self.titleQuietPeriod)
        } catch { return }
        guard !Task.isCancelled, titleQuery == normalized else { return }
        search(matching: query)
    }

    /// Published title matches need no nearby opt-in: typing asks by name.
    /// Submits immediately, also flushing a pending debounce without a second
    /// request when its clock later expires. Equivalent edits reuse the answer.
    func search(matching query: String) {
        prepareTitleSearch(matching: query)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, requestedTitle != titleQuery, hasTransport else { return }
        requestedTitle = titleQuery
        // Snapshotted here rather than read inside the request: the closure is
        // `@Sendable` and runs off this actor, and a set taken at the moment
        // the question is asked is the right one — a block made while it is in
        // flight is applied by the read-time filter above.
        let excluded = blockList.blockedIDs
        perform(.title, describing: "a title search", matching: titleQuery) { transport in
            // Wrapped rather than given a shape of its own: a title search has
            // no curated half to fail — see ``MergedCommunityTransport`` — so
            // there is one thing for it to answer and it is the rows.
            CommunityNearbyAnswer(
                listings: try await transport.listings(
                    matching: trimmed,
                    limit: Self.resultLimit,
                    excluding: excluded
                )
            )
        }
    }
}

// MARK: - What the map draws

// An extension rather than more of the class, and it is the same split the
// file already makes in prose: above this line is when to ask and what came
// back, and below it is the one derived thing the map reads. Everything here
// is computed from state declared above, so there is still exactly one source
// for each fact.
extension CommunityBrowser {
    /// The lines the map draws for the shared hikes it found, and for the one
    /// whose preview is open.
    ///
    /// Computed from the three things that can move independently — the rows,
    /// the block list, and whatever the preview has loaded — for the reason
    /// ``nearbyListings`` is computed: there is one source for each fact and
    /// no fourth array that can fall behind them. A block reaches the map's
    /// lines the moment it reaches its rows, because it is the same filter.
    ///
    /// The previewed hike is drawn from its *real* route and replaces its own
    /// outline rather than being drawn over it, so the map never carries two
    /// versions of one trail. It is appended last so it draws on top, and it
    /// is included even when it is nowhere in the nearby answer — a hike found
    /// by typing its name is still a hike the hiker is looking at, and its
    /// preview no longer draws a route of its own.
    var routeLines: [CommunityRouteLine] {
        var lines = nearbyListings.compactMap { listing -> CommunityRouteLine? in
            guard listing.id != previewedRoute?.id,
                  let outline = nearbyOutlines[listing.id],
                  outline.count >= 2
            else { return nil }
            return CommunityRouteLine(
                listing: listing,
                coordinates: outline,
                isPreviewed: false
            )
        }
        if let previewedRoute {
            lines.append(previewedRoute)
        }
        return lines
    }

    /// The pins the map stands where the open preview's photographs were
    /// taken.
    ///
    /// Only the open preview's, ever. This is the one thing on the map that
    /// needs a whole submission's pins asset to draw, so a page of results
    /// could not have it — see ``CommunityListing``, which carries a photo
    /// *count* precisely because carrying the pictures would not scale.
    var photoPins: [CommunityPreviewPhoto] {
        previewedPhotos
    }

    // MARK: - The open preview

    /// A published hike's preview is on screen. Called from the screen itself.
    ///
    /// It records *which* hike, and retires whatever the last preview had
    /// loaded. There is nothing to draw for this one until its own fetch
    /// lands, and until then the map goes on showing the faded outline it
    /// already had — which is the right thing to fall back to, and is not
    /// what the previous hike's full-strength line would be.
    ///
    /// Retiring it here rather than leaving it to the close is the difference
    /// between the two orderings mattering and not. A map pin replaces an
    /// open preview with another, and SwiftUI then tears the first screen
    /// down *after* the second appears — so the close that would have
    /// cleared it arrives matched against the new hike and is rejected, as it
    /// must be. Without this line the old trail stays emphasised until the
    /// new one loads, and stays emphasised for good if the new one fails.
    func previewOpened(_ listing: CommunityListing) {
        guard previewedListingID != listing.id else { return }
        previewedListingID = listing.id
        previewedRoute = nil
        // Retired here for the reason the line is, and with one more of its
        // own: these pins point at files in the previous screen's download
        // directory, which that screen deletes on its way out.
        previewedPhotos = []
    }

    /// The open preview has its route. The map draws this one properly.
    ///
    /// Ignored for anything but the preview currently open, which is what
    /// stops a fetch that landed after the hiker backed out from putting a
    /// line on a map with no screen behind it.
    func previewLoaded(_ route: [RouteCoordinate], of listing: CommunityListing) {
        guard previewedListingID == listing.id, route.count >= 2 else { return }
        previewedRoute = CommunityRouteLine(
            listing: listing,
            coordinates: route,
            isPreviewed: true
        )
    }

    /// The preview is gone. Called when the screen disappears.
    ///
    /// Matched on the listing rather than clearing unconditionally: SwiftUI
    /// tears a replaced screen down after its replacement appears, so an
    /// unmatched close would take the new preview's line off the map on the
    /// way into it.
    /// The open preview's photographs know where they were taken. The map
    /// stands a pin on each.
    ///
    /// Its own call rather than an argument to ``previewLoaded(_:of:)``,
    /// because the two facts do not always arrive together and one of them can
    /// change while the screen stays put: a reviewer removing a photograph
    /// republishes the pins against the same route. Matched on the listing for
    /// the same reason that one is.
    func previewPhotosLoaded(
        _ photos: [CommunityPreviewPhoto],
        of listing: CommunityListing
    ) {
        guard previewedListingID == listing.id else { return }
        previewedPhotos = photos
    }

    func previewClosed(_ listing: CommunityListing) {
        guard previewedListingID == listing.id else { return }
        previewedListingID = nil
        previewedRoute = nil
        previewedPhotos = []
    }
}
