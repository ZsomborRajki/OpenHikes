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
//  The one request the hiker does not have to confirm is the first: tapping
//  *Find community hikes near here* is itself the confirmation, and asking twice
//  for one intention would be a worse bargain than the automatic re-query
//  ever was.
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
    /// How the *nearby* request is getting on.
    ///
    /// The nearby one only, because it is the only one with anywhere to say
    /// so — see ``MapSheetHikes``'s empty state, which distinguishes a failure
    /// from an area with nothing in it. A title search that fails draws no
    /// rows and is logged; it must not put an error over a nearby list that
    /// is perfectly good.
    private(set) var state: CommunityBrowseState = .idle
    /// Whether the hiker has asked for shared hikes at all. Drawn as the
    /// difference between the section's opt-in row and its results, so it is
    /// observed on purpose.
    private(set) var isBrowsing = false
    /// Whether the map has moved somewhere the list does not describe.
    ///
    /// Coarse by construction: ``CommunityQueryPolicy`` refuses everything
    /// smaller than a quarter of the search radius, so this moves a handful of
    /// times in a browsing session and never at gesture frequency. `Equatable`
    /// so `@Observable` filters the same-value writes a run of settles
    /// produces — see *Render isolation, in practice*.
    private(set) var areaPrompt: CommunityAreaPrompt = .settled
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
    @ObservationIgnored private var nameTask: Task<Void, Never>?
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

    /// Requests that have not landed yet, of either question.
    ///
    /// Kept for the same reason ``issuedRequests`` is, and needed for a
    /// sharper one: ``state`` describes the nearby request alone, so a suite
    /// that waited on it would be waiting on the map while asserting about a
    /// title search that had not come back. Waiting on the effect rather than
    /// on a duration is the house rule; for a question with nothing to draw,
    /// this is the effect.
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
        // The opt-in that arrived before the map did — see ``startBrowsing()``.
        if wantsFirstRegion, case .offer(let area) = policy.action(for: region) {
            wantsFirstRegion = false
            commit(area)
            return
        }
        switch policy.action(for: region) {
        case .ignore:
            offeredArea = nil
            areaPrompt = .settled
        case .offer(let area):
            offeredArea = area
            areaPrompt = .search
        case .tooFarOut:
            offeredArea = nil
            areaPrompt = .zoomIn
        }
    }

    /// Asks about the area the map is showing: what *Search this area* runs.
    ///
    /// Takes the offered area rather than re-reading the map, so the question
    /// asked is the one the offer was made about — a settle landing between
    /// the hiker seeing the button and hitting it would otherwise change it
    /// underneath them.
    func searchVisibleArea() {
        guard isBrowsing, let offeredArea else { return }
        commit(offeredArea)
    }

    // MARK: - Opting in

    /// Turns the community section on and asks about wherever the map is.
    ///
    /// The one request nobody has to confirm — the tap that gets here *is*
    /// the confirmation. See this file's header.
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
            commit(area)
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

    /// Hides the section again.
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
        nearbyResults = []
        offeredArea = nil
        resultsArea = nil
        pendingArea = nil
        pendingName = nil
        wantsFirstRegion = false
        areaPrompt = .settled
        areaName = nil
        state = .idle
    }

    /// Asks again about the current region, ignoring the thresholds.
    ///
    /// What a failed request needs: the policy remembers a query that produced
    /// nothing, so without forgetting it first the same region would be
    /// refused as "the same question" and the hiker's only recourse would be
    /// to pan away and back.
    func retry() {
        guard isBrowsing, let latestRegion else { return }
        policy.forgetLastQuery()
        guard case .offer(let area) = policy.action(for: latestRegion) else { return }
        commit(area)
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
        requestNearby(resultsArea)
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

    /// Opens a published hike's preview. Called from the map's own pins.
    func open(_ listing: CommunityListing) {
        openListing?(listing)
    }

    // MARK: - The search field

    /// Published hikes whose title matches a typed query.
    ///
    /// Separate from the location path and deliberately not gated by opting
    /// in: somebody who types a trail's name has asked for it by name,
    /// wherever they are and whether or not they have asked for the section.
    func search(matching query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            matchTask?.cancel()
            matchTask = nil
            // Dropping the matches is the whole of it. The map's answer was
            // never replaced by them and so has nothing to be restored from —
            // which is also why this no longer depends on the policy agreeing
            // to re-ask: above the zoom ceiling it would refuse, and the title
            // matches used to be left on screen as a result.
            matchingResults = []
            return
        }
        // Snapshotted here rather than read inside the request: the closure is
        // `@Sendable` and runs off this actor, and a set taken at the moment
        // the question is asked is the right one — a block made while it is in
        // flight is applied by the read-time filter above.
        let excluded = blockList.blockedIDs
        perform(.title, describing: "a title search") { transport in
            try await transport.listings(
                matching: trimmed,
                limit: Self.resultLimit,
                excluding: excluded
            )
        }
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
    private func commit(_ area: CommunitySearchArea) {
        policy.commit(area)
        offeredArea = nil
        areaPrompt = .settled
        nameArea(area)
        requestNearby(area)
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
    private func requestNearby(_ area: CommunitySearchArea) {
        let excluded = blockList.blockedIDs
        perform(.nearby, describing: "a nearby search", about: area) { transport in
            try await transport.listings(
                near: area.coordinate,
                radiusMeters: area.radiusMeters,
                limit: Self.resultLimit,
                excluding: excluded
            )
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
    private func perform(
        _ question: Question,
        describing reason: String,
        about area: CommunitySearchArea? = nil,
        _ work: @escaping @Sendable (any CommunityTransporting) async throws -> [CommunityListing]
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
                let results = try await work(transport)
                guard !Task.isCancelled else { return }
                self?.accept(results, answering: question, about: area)
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
        _ results: [CommunityListing],
        answering question: Question,
        about area: CommunitySearchArea?
    ) {
        switch question {
        case .nearby:
            nearbyResults = results
            resultsArea = area
            // The header describes these rows from here on. If MapKit has
            // already said what this area is called, say it; if it has not,
            // say nothing rather than keep the last area's name — the geocode
            // will publish it when it lands. A refill of the area already on
            // screen re-publishes the name it already had, since the pending
            // area is unchanged.
            areaName = area == pendingArea ? pendingName : nil
            state = .loaded
        case .title:
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
            // Logged and no more. There is nowhere on screen that reports a
            // failed title search, and the two things this could touch instead
            // both belong to the map: ``state`` draws the nearby list's empty
            // state, and the remembered query is the nearby one. A typed word
            // that could not be looked up must not cost either.
            break
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
