//
//  CommunityHikeView.swift
//  OpenHikes
//
//  Somebody else's hike, before it is yours.
//
//  Pushed from a community search result, and the one screen between seeing a
//  trail's name and having it in the library. It exists because importing
//  blind is not a decision anyone can make: a name and a distance say nothing
//  about whether a route goes where the hiker wants, and the photographs are
//  half of why they would want it.
//
//  Reached only for a hike this hiker does not have. A row badged *Saved* and
//  a pin for a trail already imported open that hiker's own copy of it
//  instead — see ``SheetPresentation/open(_:importedAs:selectedHike:)`` — so
//  the question this page asks is still open whenever it is asked. What is
//  left of the answered case is the *Open in My Hikes* state of the button
//  below: the import that has just landed, and a copy a second device made
//  while this page was open.
//
//  ## The route is on the map, and the rest of the page is here
//
//  This screen used to draw the route itself, as an unscaled outline with no
//  ground under it. That was the right answer while a shared hike had no line
//  anywhere — it answered *does this route go where I think it does* without
//  costing a map — but it answered it in the abstract, on a screen presented
//  over a real map that was drawing the same trail as a single pin.
//
//  Both halves of that have moved. The map draws every shared hike in the
//  answer, and draws *this* one properly, from the full route loaded here —
//  see ``MapCommunityRoutes`` and ``CommunityBrowser/previewLoaded(_:of:)``.
//  So the sketch is gone, and what replaces it is the thing the sketch could
//  never show: the hike detail screen's own page, off the same route and out
//  of the same types. ``ElevationChartView`` at the top, ``StatSummary``
//  under it, then the photographs, then ``TrailSurfaceSection``
//  and ``TrailDifficultySection`` — the order ``HikeDetailView`` puts them in,
//  because what somebody deciding whether to keep a stranger's trail compares
//  is *their* hike against *this* one, and two layouts would make that
//  comparison work.
//
//  Reused rather than rebuilt, and that is a constraint on this screen rather
//  than a convenience: not one of those views takes a `Hike`. Each takes the
//  value it draws — a profile, a breakdown, a tint — and the wrapper that
//  reads one off a hike stays on the hike's own screen. See
//  ``TrailSurfaceSection``.
//
//  What deliberately does *not* come across is everything that customises a
//  hike somebody owns: no route colour, no line pattern, no auto-follow, no
//  offline tiles, no walk. This is not their hike yet, and the two controls
//  that would be lying about that are the ones this screen must not offer. The
//  chart is drawn in the listing's own colour for the same reason the lines
//  and the pins are — it is the colour the map behind is already drawing this
//  very route in — and that colour is the listing's identity rather than
//  anything the hiker picked. See ``CommunityListing/tint``.
//
//  ## OpenStreetMap is asked on open, and the answer is not kept
//
//  Surface and Difficulty need a trail graph, and a shared hike has nowhere to
//  put the result: ``Hike/surfaceBreakdown`` is a column on a model this
//  screen does not have and must not create to hold a measurement about a
//  trail nobody has imported. So the analysis runs when the route lands and
//  its answer lives in the visit's ``CommunityPreviewSession`` for as long as
//  the preview is on the stack — opened twice is measured twice, and what
//  keeps that cheap is ``OverpassTrailGraphProvider``'s own region cache,
//  which this shares with the hiker's hikes and with the recorder.
//
//  It is a request on a screen that refuses to fetch a single map tile, and
//  the difference is what each one buys. Tiles mean a provider, the
//  entitlement check, the cache and a download, for ground the map behind is
//  already drawing. The analysis is a bounded run over the route's own regions
//  — capped by ``TrailGraphProviding/maximumPrefetchRegions``, tied to no
//  account and no API key, cancelled when the screen goes — and it answers the
//  question that brought the hiker here, which is what this trail is actually
//  like. Failure stays invisible exactly as it does on a hike in the library:
//  an outage, a flight-mode gap or a valley nobody has mapped leaves both
//  sections absent rather than explaining itself to somebody who never asked.
//  There is still no map of its own here.
//
//  Everything downloaded lands in one directory owned by this visit and
//  deleted when the preview leaves the stack — or when the last thing using it
//  finishes, whichever is later. These are a stranger's photographs held for
//  as long as they are being looked at, and no longer, unless the hiker
//  imports the hike, at which point ``CommunityImport`` makes copies that are
//  theirs.
//
//  A *visit* and not a screen, because a turn of the phone builds this screen
//  again in the other host — the sheet in portrait, the side panel in
//  landscape — and the screen built there is the same visit. Everything this
//  page has loaded, and the work still loading it, is held by
//  ``CommunityPreviewSession``, which ``SheetPresentation`` keeps for as long
//  as the route is on the path and ends when it leaves (#1336).
//
//  One directory per *visit*, and not per listing, for the reason a share
//  stages one per attempt rather than one per hike — see ``CommunityStaging``,
//  which owns both names and sweeps up after the ones a kill orphaned: the
//  same listing can be open twice over, and the second time is not the first.
//  A hiker who backs out mid-download and opens the same hike again leaves the
//  first visit's discard still waiting on the first visit's tasks — and a
//  discard removes a *path*, so a name carrying only the listing would have it
//  take the second visit's photographs the moment the first visit's download
//  finished. Waiting for work protects one visit's files from that visit's
//  own tasks; it says nothing about another visit holding the same name. See
//  ``CommunityPreviewSession/visit``.
//
//  *The last thing using it* is two tasks and not one, and the second half is
//  a fix. The import reads out of the directory, so deleting underneath it
//  costs the hiker the pictures of a hike they asked for. The download
//  **writes** into it, so deleting underneath that leaves files behind
//  instead: the writer re-creates the directory after the remove, and nothing
//  ever comes back for it. So the load is held in
//  ``CommunityPreviewSession/loadTask`` like the import, cancelled when the
//  hiker leaves, and waited for before anything is removed — and
//  ``CloudKitCommunityTransport/detail(for:downloadingInto:)``
//  checks that cancellation before it writes, since a cancelled task that
//  never looks is a task that carries on. The check it cannot make is the one
//  *after* it returns, and that is ``detail(of:from:downloadingInto:)``: a
//  copy that finished before the cancellation arrived hands back a detail
//  rather than throwing, and everything ``load()`` does next would then be
//  done for a screen that has gone.
//
//  ## Why reporting and blocking are here and not on the row
//
//  This is the screen that shows the content, and both gestures are about
//  content. A row carries a title, a distance and a name; a hiker reporting
//  from one would be reporting a title they read rather than a photograph they
//  saw, and a reviewer would open the listing to find nothing wrong with it.
//  The menu sits in the toolbar rather than under the fold because it must be
//  reachable in every phase — a listing whose route never loads can still be
//  one whose *title* is the problem, and a hiker who cannot open a hike is
//  exactly the one with nothing else to do about it.
//
//  The two are together because they are one reach in most apps and are wanted
//  at the same moment, and they are two items because they do different
//  things: a report asks a person to look at the hike and can take it down for
//  everybody, a block hides that author on this device and takes nothing down.
//  See ``CommunityReport`` for where a report goes and ``CommunityBlockList``
//  for where a block lives.
//
//  The import is in that menu too, and is not a third moderation gesture: it
//  is the page's own action, offered a second time where a hiker who has
//  already decided can reach it without scrolling the page they decided
//  without. See ``actionsToolbarItem``.
//

import Foundation
import OpenHikesData
import OpenHikesShared
import os
import SwiftData
import SwiftUI

struct CommunityHikeView: View {
    private static let photoTileSize: CGFloat = 96

    /// This visit: the hike it is to, what the page has loaded, the work
    /// loading it, and the import. Kept by ``SheetPresentation`` until the
    /// route is popped, so the screen a turn of the phone builds in the other
    /// host draws the same answer rather than asking again — see
    /// ``CommunityPreviewSession``.
    let session: CommunityPreviewSession
    var listing: CommunityListing { session.listing }
    let transport: any CommunityTransporting
    /// The hiker's own block list. Written by this screen and read by the
    /// lists behind it — see ``CommunityBlockList``.
    let blockList: CommunityBlockList
    /// The browser behind the map, told when this preview opens, what its
    /// route turned out to be, where its chart is pointing, and when it goes.
    ///
    /// **Written and never read.** Nothing in this body touches a property of
    /// it, which is what keeps a screen presented over the map out of the
    /// map's own redraw path — the calls are one-way, and what they produce
    /// is a line and a dot on the map behind this sheet rather than anything
    /// here. See ``CommunityBrowser/previewOpened(_:)``.
    let browser: CommunityBrowser
    /// Read for one thing: whether this account may take a published hike
    /// down, which is a fact about the account and not about this hike. See
    /// ``CommunityReviewQueue/isReviewer``.
    var review: CommunityReviewQueue?
    /// Called with the imported hike, so the caller can pop this screen and
    /// open the real one.
    let onImport: (Hike) -> Void
    /// Called once this author has been blocked, so the caller can pop a
    /// screen that is now showing hidden content.
    let onBlock: () -> Void
    /// Called with the whole strip and the picture that was tapped, so the
    /// caller can push the gallery over this screen.
    ///
    /// Both halves travel because there is nowhere else to get them: the
    /// photographs are files in ``CommunityPreviewSession/downloadDirectory``,
    /// which this visit owns, and the detail holding them never leaves it. See
    /// ``SheetRoute/communityPhoto(_:_:_:)``.
    ///
    /// Defaulted to nothing so a preview and a suite can build this screen
    /// without a navigation stack behind it, exactly as ``remainsPushed`` is.
    var onOpenPhoto: ([CommunityGalleryPhoto], Int) -> Void = { _, _ in /* no-op default */ }
    /// Whether this screen is still on the navigation stack while it is
    /// disappearing — which is the difference between a push over it, or a
    /// turn of the phone, and the hiker leaving.
    ///
    /// Injected rather than inferred, because the only thing that knows is
    /// the stack: SwiftUI reports a pushed-over view and a popped one the
    /// same way. See ``SheetPresentation/isPresentingCommunityHike(_:)``.
    /// What it decides is only the map's line now; the downloads go with the
    /// route itself — see ``CommunityPreviewSession/end()``.
    var remainsPushed: () -> Bool = { false }
    /// OSM walking graph behind the Surface and Difficulty sections. `nil`
    /// leaves both absent and asks nothing — which is what a preview and a
    /// suite get, exactly as on ``HikeDetailView``.
    var trailGraphProvider: (any TrailGraphProviding)?

    @Environment(\.modelContext) var context
    @State private var isReporting = false
    @State private var isConfirmingBlock = false
    @State private var isConfirmingTakeDown = false
    @State private var isTakingDown = false
    @State private var takeDownFailure: CommunityFailure?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Above the header and outside the switch, both deliberately.
                // Above, because that is where ``HikeDetailView`` puts it and
                // this page is meant to read as that one. Outside, because it
                // is keyed on the walk of the route rather than on the fetch,
                // and it draws nothing at all until there is one — so a screen
                // still loading is the header and a spinner, exactly as it was.
                elevationSection
                header
                switch session.phase {
                case .loading:
                    loadingState
                case .failed(let failure):
                    failureState(failure)
                case .loaded(let detail):
                    // Filtered on the draw, because a block or a takedown
                    // decided in the gallery over this screen cannot reach the
                    // request that fetched these. See ``visible(_:)``.
                    loadedState(visible(detail))
                }
            }
            .padding()
        }
        // The chart now runs up under the navigation bar, so it gets the
        // progressive blur the hike's own detail screen gives it rather than
        // meeting the bar's glass at a hard line.
        .softScrollEdgeEffect(for: .top)
        .navigationTitle(listing.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { actionsToolbarItem }
        .sheet(isPresented: $isReporting) {
            CommunityReportSheet(listing: listing)
        }
        // Presented from this screen rather than from the menu's closure: a
        // `.confirmationDialog` attached inside a `Menu` goes with the menu
        // when it dismisses, which is the moment the item is tapped.
        .confirmationDialog(
            blockPrompt,
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { block() }
                .accessibilityIdentifier("community-block-confirm")
            // Dismisses, and nothing else has to happen.
            Button("Cancel", role: .cancel) { /* intentionally empty */ }
        } message: {
            Text("""
            Their hikes stop appearing on this device. You can undo this in \
            Settings. Blocking doesn’t report the hike or take it down.
            """)
        }
        // Here for the reason the one above is: a dialog attached inside the
        // `Menu` dismisses with it.
        .confirmationDialog(
            "Take this hike down?",
            isPresented: $isConfirmingTakeDown,
            titleVisibility: .visible
        ) {
            Button("Take Down", role: .destructive) { takeDown() }
                .accessibilityIdentifier("community-take-down-confirm")
            Button("Cancel", role: .cancel) { /* intentionally empty */ }
        } message: {
            Text("""
            It stops appearing for everybody, and the route and photographs \
            behind it are deleted for good. This can’t be undone.
            """)
        }
        .communityFailureAlert("Couldn’t take it down", failure: $takeDownFailure)
        .onAppear {
            // `try?`, deliberately: this decides which button the screen
            // draws, and a store that cannot answer should offer *Save* and
            // let the import refuse — which it now does — rather than claim
            // the hike is already saved.
            session.existingHike = try? CommunityImport.existingImport(of: listing.id, in: context)
            // Before the route exists, deliberately: this only says which hike
            // the map is now about, so that a fetch landing after the hiker
            // backed out is ignored rather than drawn.
            browser.previewOpened(listing)
            // Coming *back* to this screen, or up in the host a turn of the
            // phone moved it to, with the answer the visit already has. The
            // load is not asked again once the visit has started one, so
            // without this the map would be told which hike it is about and
            // never told where that hike goes — the line the preview exists to
            // show, missing on the second appearance and every one after it.
            // Published here rather than from the load so it cannot race the
            // call above, which is what retires the previous preview's line.
            if case .loaded(let detail) = session.phase {
                browser.previewLoaded(detail.route, of: listing)
                // The same filtered answer the strip is drawing, so the pins
                // and the pages agree about which picture is which — coming
                // back from the gallery is exactly when the two can differ.
                // Which is also why the gallery a tapped pin opens is built
                // from this same value: a pin and the page it opens have to be
                // one picture. See ``publishPhotoPins(_:)``.
                publishPhotoPins(visible(detail))
                // And the dot, where the chart's marker was left.
                publishChartPosition()
            }
            // Last, so the map is told which hike it is about before anything
            // the load hands it, and held by the visit rather than run by a
            // `.task`: a turn of the phone takes this screen away while the
            // load is still out, and a `.task`'s cancellation would reach
            // only the closure waiting on it. The screen the turn builds asks
            // again and is told the load has started — see
            // ``CommunityPreviewSession/startLoading(_:)``.
            session.startLoading { await load() }
        }
        .onDisappear {
            // A screen pushed over this one is not the hiker leaving it — its
            // gallery pushes over it — and neither is a turn of the phone, and
            // all three look identical from here. Taking the line off the map
            // for either of the first two would leave the hiker one Back from,
            // or looking at, a preview whose trail the map no longer draws.
            // The downloads are not this screen's to discard: they go when the
            // route leaves the path — see ``CommunityPreviewSession/end()``.
            guard !remainsPushed() else { return }
            browser.previewClosed(listing)
        }
    }
}

// MARK: - The toolbar menu

private extension CommunityHikeView {
    /// Adding the hike, reporting it, and blocking its author: everything this
    /// screen can do that is not scrolling it.
    ///
    /// Both halves of the Guideline 1.2 affordance are here because this is
    /// the screen showing the content. A menu rather than the plain
    /// destructive button this was while reporting was the only destination:
    /// a menu in front of a single one is a tap spent on nothing — the same
    /// call ``MapAttributionView`` makes about its licence links — while
    /// actions a hiker reaches for at the same moment and must not confuse are
    /// the case a menu is for, and the alternative, a toolbar button each,
    /// spends the navigation bar of a screen whose title is a stranger's trail
    /// name.
    ///
    /// The import is first and is deliberately a *second* way to the same
    /// thing. The button under the page is where a hiker who has read the page
    /// arrives; this is for one who decided from the row and does not want to
    /// scroll a chart, a grid, a strip of photographs and two trail sections
    /// to say so. It draws only once the route is here, because the route is
    /// what there is to import — before then this page is a spinner, and the
    /// button below it does not exist either.
    @ToolbarContentBuilder var actionsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                importMenuItem

                // Absent rather than disabled for a curated route, and the
                // difference is not cosmetic. Both of these are Guideline 1.2
                // affordances about *user-generated content*, and an OSM
                // relation is not that: there is no author to block — the menu
                // item would read "Block This Hiker" about nobody — and no
                // record for a reviewer to delete, so a report would ask a
                // person to act on something they cannot reach. What can be
                // done about a wrong trail is done upstream, which is what
                // ``curatedAttribution`` links to.
                if !listing.isCurated {
                    Button {
                        isReporting = true
                    } label: {
                        Label("Report Hike", systemImage: "exclamationmark.bubble")
                    }
                    .accessibilityHint("Tells the reviewer something is wrong with it")
                    .accessibilityIdentifier("community-report-button")

                    Button(role: .destructive) {
                        isConfirmingBlock = true
                    } label: {
                        Label(blockActionTitle, systemImage: "hand.raised.slash")
                    }
                    .accessibilityHint("Hides their hikes on this device")
                    .accessibilityIdentifier("community-block-button")
                }

                // A last entry, and only for an account the server has already
                // let read the queue. Not a permission check — the permission
                // is on the record type, and this account would be refused the
                // delete anyway — but an ordinary hiker should not be offered
                // a control that can only fail. It is the one action here that
                // reaches everybody rather than this device: reporting sends a
                // mail and blocking writes to `UserDefaults`, while this
                // unlists a hike for the whole world.
                if review?.isReviewer == true, !listing.isCurated {
                    Divider()
                    Button(role: .destructive) {
                        isConfirmingTakeDown = true
                    } label: {
                        Label("Take Down", systemImage: "trash")
                    }
                    .disabled(isTakingDown)
                    .accessibilityHint("Unlists it for everybody and deletes the submission")
                    .accessibilityIdentifier("community-take-down-button")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Add, report or block")
            .accessibilityIdentifier("community-actions-menu")
        }
    }

    /// The import, at the top of the menu and above a divider of its own.
    ///
    /// Its own property rather than four more lines inside the menu, because
    /// the menu's closure was already at the length the linter allows — and
    /// because what it draws is conditional on a phase the rest of the menu
    /// does not care about.
    ///
    /// Drawn only once the route is here. The route is what there is to
    /// import, and an item that could only fail is worse than one that is not
    /// offered — the same argument ``actionsToolbarItem`` makes about *Take
    /// Down* for an ordinary hiker.
    ///
    /// Title and glyph come from the button under the page rather than being
    /// written a second time here, so the two ways to one tap cannot end up
    /// describing it differently. See ``importButtonTitle``.
    @ViewBuilder var importMenuItem: some View {
        if case .loaded(let detail) = session.phase {
            Button {
                // Filtered, exactly as the button under the page is — see
                // ``visible(_:)``. The two are one tap doing one thing, and
                // the import copies contributed photographs now, so an
                // unfiltered detail here would save a blocked contributor's
                // pictures into the library of the hiker who blocked them, or
                // a set a reviewer had just taken down. The strip on the
                // screen behind the menu is already showing neither.
                performImport(visible(detail))
            } label: {
                Label(importButtonTitle, systemImage: importGlyph)
            }
            .disabled(session.isImporting)
            .accessibilityIdentifier("community-import-menu-button")

            Divider()
        }
    }

    /// "Block Anna", or "Block This Hiker" when they published without a
    /// name.
    ///
    /// The name is a label and never the thing being blocked — see
    /// ``CommunityBlockList`` — but it is what the hiker recognises, and an
    /// item reading "Block" alone on a screen with an import button under it
    /// leaves them guessing what the object is.
    var blockActionTitle: String {
        listing.authorName.isEmpty
            ? String(localized: "Block This Hiker")
            : String(localized: "Block \(listing.authorName)")
    }

    var blockPrompt: String {
        listing.authorName.isEmpty
            ? String(localized: "Block this hiker?")
            : String(localized: "Block \(listing.authorName)?")
    }

    /// Unlists this hike for everybody and deletes what is behind it.
    ///
    /// Leaves by ``onBlock`` rather than a route of its own, because what has
    /// to happen next is the same pop blocking needs: the screen is about a
    /// record that is gone.
    ///
    /// The row is taken off the list *here* rather than by that closure,
    /// which is the difference between this and a block. A block hides an
    /// author at read time, so its rows go on their own and
    /// ``CommunityBrowser/refreshAfterBlock()`` only re-asks for the page a
    /// block emptied; nothing filters a hike that has merely been deleted, so
    /// without ``CommunityBrowser/forgetTakenDown(_:)`` the row and its line
    /// would sit on the list until the next search, and the next tap on it
    /// would open a preview that fails.
    ///
    /// A failure is reported rather than swallowed. This is an action somebody
    /// is waiting on, unlike the queue read that decided whether to offer it —
    /// see ``CommunityReviewQueue``.
    func takeDown() {
        guard !isTakingDown else { return }
        isTakingDown = true
        Task {
            do {
                try await transport.takeDown(listing)
            } catch {
                isTakingDown = false
                takeDownFailure = CommunityFailure(error)
                HapticMoment.outcomeFailed.play()
                return
            }
            isTakingDown = false
            // For the reason ``CommunityPhotoActions/takeDown()`` gives: the
            // success of this is the screen leaving.
            HapticMoment.outcomeSucceeded.play()
            // Before the pop, so the list the pop lands on already agrees
            // with the delete that has just happened.
            browser.forgetTakenDown(listing)
            onBlock()
        }
    }

    /// Blocks the author and hands the screen back, because what is on it is
    /// now hidden everywhere else.
    ///
    /// Leaving it up would be the one place in the app still showing content
    /// the hiker has just said they do not want to see, and backing out of it
    /// into a list the hike has vanished from reads as a glitch rather than as
    /// the thing they asked for.
    func block() {
        blockList.block(listing)
        // Before the pop, so an import still in flight finds it set when it
        // lands — see ``performImport(_:)`` for what it stops.
        session.wasAuthorBlocked = true
        onBlock()
    }
}

// MARK: - Sections

private extension CommunityHikeView {
    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(listing.title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(credit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Who to thank for this hike, and when it was walked.
    ///
    /// Three shapes, because there are three things that can be known. A
    /// published hike names the hiker and the day. One published without a
    /// typed name shows the day alone, which is what it always did. A curated
    /// route has neither — nobody walked it and nobody shared it — so it
    /// credits the people who mapped it, which is also the attribution ODbL
    /// requires and the reason this string is never empty. The licence itself
    /// is reachable from ``curatedAttribution``, one row below.
    var credit: String {
        guard !listing.isCurated else { return String(localized: "From OpenStreetMap contributors") }
        let day = listing.hikeDate?.formatted(date: .abbreviated, time: .omitted)
        switch (listing.authorName.isEmpty, day) {
        case (false, let day?): return String(localized: "Shared by \(listing.authorName) · \(day)")
        case (false, nil): return String(localized: "Shared by \(listing.authorName)")
        case (true, let day?): return day
        case (true, nil): return ""
        }
    }

    var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Loading route…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("community-hike-loading")
    }

    func failureState(_ failure: CommunityFailure) -> some View {
        VStack(spacing: 8) {
            Text(failure.localizedDescription)
                .font(.headline)
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Try Again") {
                // The same handle the first attempt used. An unowned retry is
                // the leak in ``CommunityPreviewSession/loadTask`` by a second
                // route: the end of the visit would neither stop it nor wait
                // for it, and backing out of a retry would leave its download
                // writing into a directory that had already been removed.
                session.reload { await load() }
            }
            .glassButtonStyle()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("community-hike-failure")
    }

    /// The page below the header, in ``HikeDetailView``'s order: the numbers,
    /// the photographs, what the trail runs on, how hard it is, and then what
    /// the hiker who shared it wrote about it.
    ///
    /// The description moved down here from directly under the stats when the
    /// two trail sections arrived, because the hike's own screen has always
    /// put *Details* last and this page is meant to read as that one. Its
    /// sections are each absent until they have something to say, which is why
    /// the order is stated once here rather than negotiated between them.
    @ViewBuilder
    func loadedState(_ detail: CommunityHikeDetail) -> some View {
        statsSummary

        // Asked of the *merged* gallery rather than of the submission's own
        // files, which is the whole difference a contribution makes to this
        // screen: a trail whose author published no photographs — every
        // curated route, and plenty of published hikes — has a strip as soon
        // as somebody else adds one, and gating on `photoFileURLs` drew
        // nothing for exactly the case the feature exists for.
        if !detail.galleryPhotos.isEmpty {
            photoStrip(detail)
            commonsAttribution(detail)
        }

        // Where the hike's own screen puts them: under the photographs. What
        // saving the hike copies into the library — see ``CommunityImport``.
        SharedTrailPlaceSection(places: detail.places, route: detail.route)

        trailFactsSection
        surfaceSection
        difficultySection

        if let description = detail.trackDescription, !description.isEmpty {
            detailsSection(description)
        }

        importButton(detail)
        curatedAttribution
    }

    /// The route's shape, in the same chart the hiker's own hikes draw.
    ///
    /// ``ElevationChartView`` rather than anything built for this screen, and
    /// the scrub comes with it: reading an elevation off a point of a trail is
    /// most of what a hiker is deciding on, and it is the one interaction on
    /// this page that costs nothing to offer. Its dot on the map comes with it
    /// too, standing on the line the map draws for this preview, because a
    /// climb on the graph is only half read until it is a slope somewhere on
    /// the ground — see ``publishChartPosition(_:along:)``. What does not come
    /// with it is everything that needs a hike — the route tint and the live
    /// dot.
    ///
    /// Absent entirely when there are no heights to draw, rather than replaced
    /// by a card saying so.
    ///
    /// This screen's rule everywhere else — a section with nothing in it is
    /// not drawn, see ``trailFactsSection`` — and the curated routes are what
    /// made it matter here. OpenStreetMap carries no elevation on a hiking
    /// relation: measured over one Berchtesgaden box, `ele` was on **zero** of
    /// 1,725 geometry nodes, so *every* curated trail took the empty state.
    /// That turned it from a rare admission about one person's upload into a
    /// permanent grey card on most of the screens this feature opens, sitting
    /// where a hiker looks first and saying only that there is nothing to look
    /// at. A section that is simply not there says the same thing and takes up
    /// none of the page.
    ///
    /// A hike in the library keeps its placeholder — see
    /// ``HikeElevationPlaceholder``. The difference is what the hiker can do
    /// about it: that file is theirs, so *no elevation data in this file* tells
    /// them something true about a thing they chose to import.
    ///
    /// Without OpenHikes Pro, a curated route's missing chart is the card that
    /// sells the heights instead — see ``ElevationProPrompt``.
    @ViewBuilder var elevationSection: some View {
        if let profile = chartProfile {
            VStack(alignment: .leading, spacing: 6) {
                ElevationChartView(
                    profile: profile,
                    // The listing's own colour, exactly as the line and the
                    // marker on the map behind this screen are: the map is
                    // drawing this very route in it. Still not a `Hike`'s route
                    // tint, which belongs to hikes the hiker owns — see
                    // ``CommunityListing/tint``.
                    tint: listing.tint,
                    tracker: session.tracker,
                    onScrub: { distance in
                        session.tracker.trackerDistance = distance
                        publishChartPosition(distance, along: profile)
                    }
                )
                .equatable()
                // The credit for the heights, and only where it is owed. A
                // published hike's profile came from the hiker who walked it;
                // a curated route's came from Stadia, fetched when this screen
                // opened, because OpenStreetMap carries none — see
                // ``CuratedElevation``. Under the chart rather than beside the
                // ODbL credit below, so the sentence sits with the thing it is
                // about, and drawn only when a chart is: a credit for a chart
                // nobody could draw credits nothing.
                if listing.isCurated {
                    Text("Elevation from \(TileAttribution.Credit.stadiaMaps.title).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("community-elevation-attribution")
                }
            }
        } else if listing.isCurated, session.prepared != nil {
            // The one route here a subscription gives heights to — see
            // ``ElevationProPrompt``. Drawn only for a hiker without one: a
            // subscriber whose request failed gets no section, as before.
            ElevationProPrompt(
                tint: listing.tint,
                message: "No elevation data for this route",
                onUnlocked: fetchHeights
            )
        }
    }

    /// The profile the chart draws, or `nil` when there is no chart: the route
    /// has not been walked yet, or carries no heights to draw.
    var chartProfile: RouteProfile? {
        guard let profile = session.prepared?.profile, profile.samples.count > 1 else { return nil }
        return profile
    }

    /// Hands the map the point `distance` along this route, where it stands
    /// the dot that mirrors the chart's marker — the dot a hike of the
    /// hiker's own has always had, on the line the map draws for this
    /// preview. See ``CommunityBrowser/previewScrubbed(to:of:)``.
    func publishChartPosition(_ distance: Double, along profile: RouteProfile) {
        browser.previewScrubbed(to: profile.coordinate(atDistance: distance), of: listing)
    }

    /// The same, for wherever the chart's marker stands now: at the trailhead
    /// when the chart first appears — where the hike's own screen puts its dot
    /// — and wherever a finger left it after that. Nothing when there is no
    /// chart, since the dot is the chart's and says nothing on its own.
    func publishChartPosition() {
        guard let chartProfile else { return }
        publishChartPosition(session.tracker.trackerDistance, along: chartProfile)
    }

    /// What OpenStreetMap says this stretch of trail runs on, in the hike
    /// detail screen's own section — see ``TrailSurfaceSection``.
    ///
    /// Absent until the analysis answers, and absent for good if it never
    /// does. The `if let` is here rather than inside the section because the
    /// section draws a breakdown and does not decide whether there is one.
    @ViewBuilder var surfaceSection: some View {
        if let surface = session.breakdowns.surface {
            TrailSurfaceSection(breakdown: surface)
        }
    }

    /// Mirrors ``surfaceSection``.
    @ViewBuilder var difficultySection: some View {
        if let difficulty = session.breakdowns.difficulty {
            TrailDifficultySection(breakdown: difficulty)
        }
    }

    /// What the hiker who shared this wrote about it, under the heading and in
    /// the row a hike in the library gives its own description.
    ///
    /// ``DetailRow`` rather than the bare paragraph this used to be, for the
    /// reason the numbers above are labelled rows: the label is what makes a
    /// stranger's sentence read as the hike's description rather than as a
    /// caption on the photographs it sat under.
    func detailsSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            DetailRow(label: "Description", value: description)
        }
    }

    /// The hike's numbers, in the same place card the hiker's own hikes use.
    ///
    /// Literally the same: ``StatSummary`` rather than a card built for this
    /// screen, so the strip, the list, the column an accessibility text size
    /// turns them into and the one-label-one-value reading all come along
    /// without being decided a second time. What is compared when somebody is
    /// deciding whether to keep a stranger's trail is *their* hike against
    /// *this* one, and two layouts would make that comparison work.
    ///
    /// Empty until the walk of the route finishes, which is a beat after the
    /// route lands — see ``prepare(_:)``. Nothing is drawn in the meantime
    /// rather than a row of placeholders: the photographs and the Add button
    /// are already up, and a card of dashes that fills itself in is a worse
    /// thing to look at than a card that appears.
    @ViewBuilder var statsSummary: some View {
        if let stats = session.prepared?.stats, !stats.isEmpty {
            StatSummary(stats: stats)
        }
    }

    /// The photographs, each one a way into the gallery.
    ///
    /// A tile used to be decoration, and the strip was the only place a
    /// stranger's pictures could be looked at, at 96 points a side. It is a
    /// row of buttons now, for the reason the hiker's own strip is one: what
    /// somebody deciding on a trail is deciding on is partly the pictures, and
    /// a thumbnail is enough to count them and not to see them. The name is
    /// handed to the tile rather than put on the button, because a button
    /// whose whole content is hidden has no accessibility element for the name
    /// to land on — see ``CommunityPhotoTile/label``.
    func photoStrip(_ detail: CommunityHikeDetail) -> some View {
        let photos = detail.galleryPhotos
        return VStack(alignment: .leading, spacing: 12) {
            Text("Photos")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy for the reason ``HikePhotoSection/gallery(_:)`` is: an eager
                // stack starts a decode for every tile at once, for a row that shows
                // a handful.
                LazyHStack(spacing: 8) {
                    ForEach(photos) { photo in
                        Button {
                            onOpenPhoto(photos, photo.index)
                        } label: {
                            CommunityPhotoTile(
                                url: photo.fileURL,
                                size: Self.photoTileSize,
                                label: String(
                                    localized: "Photo \(photo.index + 1) of \(photos.count)"
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("community-photo-\(photo.index)")
                    }
                }
            }
        }
    }
}

// MARK: - Work

private extension CommunityHikeView {
    func load() async {
        guard case .loading = session.phase else { return }
        // A preview about to stage a directory of its own is the moment to
        // clear away the ones an earlier preview or share never got to remove
        // — a kill reaches neither teardown, and no name is ever reused. See
        // ``CommunityStaging``.
        CommunityStaging.sweep()
        do {
            let detail = try await Self.detail(
                of: listing,
                from: transport,
                downloadingInto: session.downloadDirectory
            )
            session.phase = .loaded(detail)
            // The route this screen no longer draws, handed to the map that
            // does — see this file's header. Before anything derived from it,
            // because it is what the hiker is waiting to see and it costs
            // nothing to compute.
            browser.previewLoaded(detail.route, of: listing)
            // And where its photographs were taken, which the strip below can
            // only count — see ``MapCommunityPhotoAnnotations``. Alongside the
            // line rather than after the analysis, for the same reason: it is
            // already in hand and costs nothing to hand over.
            publishPhotoPins(detail)
            // Started rather than awaited, so the round trip to Overpass runs
            // alongside the walk of the route below instead of behind it. It
            // is also what a retry re-runs: a first attempt that failed has
            // measured nothing, and the analysis belongs to the route rather
            // than to the screen's first visit.
            analyze(detail.route)
            // And what other hikers have added to this trail, which is a
            // second query against a different record type and is deliberately
            // not part of the fetch above — see
            // ``CommunityTransporting/contributedPhotos(for:excluding:downloadingInto:)``.
            // Started rather than awaited for the reason the analysis is: the
            // route, the numbers and the author's own pictures are what the
            // hiker is waiting for, and none of them should be held behind a
            // request that may return nothing.
            loadContributions()
            // And, for a route from OpenStreetMap, what Wikimedia Commons has
            // along it — a third request on a third service, started for the
            // same reason and absent for the same reason when it fails. See
            // ``CommonsPhoto``.
            loadCommonsPhotos(along: detail.route)
            session.prepared = await Self.prepare(detail)
            // The chart is up, with its marker at the trailhead, so the map's
            // dot goes there too.
            publishChartPosition()
        } catch is CancellationError {
            // The screen has gone. There is nothing to report a failure on and
            // nothing the hiker could do about it — the same call
            // ``CommunityBrowser/perform(_:describing:about:matching:from:_:)``
            // makes, and leaving the phase alone is what keeps a screen that
            // is on its way back from a push showing *Loading route…* rather
            // than an error nobody caused.
            return
        } catch {
            session.phase = .failed(CommunityFailure(error))
        }
    }

    /// Asks for the heights a subscription bought from this screen's
    /// ``ElevationProPrompt``, and draws the chart from them — the request
    /// the transport made on open and was refused, made again now that it
    /// would not be. Onto the detail too, so *Save* keeps them.
    func fetchHeights() {
        guard case .loaded(let detail) = session.phase,
              let source = OpenHikesModel.makeTrailElevationSource() else { return }
        Task {
            let filled = await source.filled(detail.route)
            // The detail on screen *now*, not the one read before the wait:
            // the contributions and the Commons photographs land on `phase`
            // while the heights are out, and writing back the earlier copy
            // would take them off the screen again.
            guard filled != detail.route, case .loaded(var latest) = session.phase else { return }
            latest.route = filled
            session.phase = .loaded(latest)
            session.prepared = await Self.prepare(latest)
            // The first chart this route has had, so its dot goes up with it.
            publishChartPosition()
        }
    }

    /// Asks OpenStreetMap what this route runs on and how hard it is — see
    /// this file's header for why that request is worth making on a screen
    /// that refuses to fetch a map tile.
    ///
    /// Held in ``CommunityPreviewSession/analysisTask`` rather than fired and
    /// forgotten, and the cancellation check is the same one
    /// ``HikeDetailView`` makes before its write: ``HikeTrailAnalysis`` never
    /// throws, so a preview that has gone and a valley nobody has mapped both
    /// come back as an empty answer and only `Task.isCancelled` tells them
    /// apart.
    ///
    /// A provider-less launch — a preview, or any suite — asks nothing and
    /// leaves both sections absent, exactly as one does on a hike in the
    /// library.
    func analyze(_ route: [RouteCoordinate]) {
        guard let trailGraphProvider else { return }
        session.analysisTask = Task {
            let measured = await HikeTrailAnalysis.breakdowns(
                route: route,
                provider: trailGraphProvider
            )
            guard !Task.isCancelled, !measured.isEmpty else { return }
            // No transition and no curve of our own, for the reason the hike's
            // own screen gives: SwiftUI's default insertion is a fade, and it
            // is what every other section that appears late here already uses.
            withAnimation { session.breakdowns = measured }
        }
    }
}

// MARK: - The page, and clearing up after it

// None of these is `private`, and all three are `static`s taking their work
// rather than methods reading the visit's state, for the reason
// `CloudKitCommunityTransport.pins(_:for:of:takenOn:)` is one: what each
// decides is invisible in the result it produces.
extension CommunityHikeView {
    /// Fetches the shared hike, and refuses to hand back one nobody is
    /// waiting for any more.
    ///
    /// The check after the transport returns is the one the transport cannot
    /// make on the caller's behalf.
    /// ``CloudKitCommunityTransport/detail(for:downloadingInto:)`` checks
    /// cancellation before it copies a stranger's photographs and then returns
    /// whatever the copy produced — so a hiker who backs out *during* that
    /// copy gets a detail handed back rather than a `CancellationError`, and
    /// every step ``load()`` takes with a detail would run for a screen that
    /// has gone.
    ///
    /// The analysis is the step that makes this matter. It is spawned into an
    /// unstructured task, which inherits no cancellation and is not yet in
    /// ``CommunityPreviewSession/analysisTask`` for the end of the visit to
    /// have reached — the end has already happened by the time it exists — so
    /// its own `Task.isCancelled` guard stays false and a run of up to
    /// ``TrailGraphProviding/maximumPrefetchRegions`` Overpass requests
    /// carries on for a preview nobody can see. Throwing here instead lands in
    /// ``load()``'s `CancellationError` branch, which is already the "the
    /// screen has gone, report nothing" case.
    ///
    /// A `static` taking its work, like the two below and for the same reason:
    /// what it decides is invisible in the result. A cancellation that was
    /// checked and one that was missed both produce the same detail on a day
    /// when the hiker stays.
    static func detail(
        of listing: CommunityListing,
        from transport: any CommunityTransporting,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        let detail = try await transport.detail(for: listing, downloadingInto: directory)
        try Task.checkCancellation()
        return detail
    }

    /// One walk of the route, off the main actor, producing the elevation
    /// profile and the same stat tiles a hike in the library shows.
    ///
    /// The distance is the route's own length rather than
    /// ``CommunityListing/distanceMeters``, and that is the same call
    /// ``CommunityImport`` makes for the same reason: the listing's figure is
    /// one the submitting app wrote beside the route, the route is what was
    /// uploaded, and a preview whose stated length disagreed with the hike it
    /// is about to become would be wrong in the one place the hiker can see
    /// both. That disagreement is what is invisible here — a page built off
    /// the listing's figure looks entirely correct until somebody imports the
    /// hike and reads the two numbers side by side — so it is asserted rather
    /// than left to the comment.
    ///
    /// A cancelled preparation — the hiker backing out mid-walk — leaves no
    /// chart and no tiles and says nothing. There is nothing to report: the
    /// screen it would have drawn on has gone.
    static func prepare(_ detail: CommunityHikeDetail) async -> HikeDetailPreparedContent? {
        try? await HikeDetailPreparation.prepare(
            route: detail.route,
            distanceMeters: detail.route.lengthMeters
        )
    }

    /// Removes a preview's downloads, once nothing is still using them.
    ///
    /// Off the main actor and fire-and-forget, in the shape the photo and tile
    /// deletions already use: what a kill leaves behind is a directory the
    /// system reclaims on its own, which is the cheapest failure here.
    ///
    /// - Parameter work: Everything that may still be reading from or writing
    ///   into `directory`. Waited on in turn before anything is removed — a
    ///   `nil` is work that never started, and costs nothing.
    ///
    /// What matters here is an *ordering*, and an ordering is invisible in the
    /// result: a discard that waited and a discard that raced both leave no
    /// directory on a good day, and differ only when something is still
    /// writing. A suite can hold a task open across this one and watch.
    static func discardDownloads(
        at directory: URL,
        after work: [Task<Void, Never>?]
    ) {
        Task.detached(priority: .utility) {
            for task in work { await task?.value }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
