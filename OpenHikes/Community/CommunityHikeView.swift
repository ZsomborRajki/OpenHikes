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
//  ## The route is on the map, and the numbers are here
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
//  never show: the same statistics a hike in the library carries, built by the
//  same ``HikeDetailPreparation`` off the same route. Track points, elevation
//  loss, moving speed, when the walk started and ended.
//
//  It is still not a map of its own, and for the reason it never was: tiles
//  mean a provider, the entitlement check, the cache and a download, for a
//  screen a hiker may back out of in two seconds. There is already a map
//  behind this one.
//
//  Everything downloaded lands in one directory owned by this screen and
//  deleted when it goes — or when an import that is still reading out of it
//  finishes, whichever is later. These are a stranger's photographs held for
//  as long as they are being looked at, and no longer, unless the hiker
//  imports the hike, at which point ``CommunityImport`` makes copies that are
//  theirs.
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

import SwiftData
import SwiftUI

struct CommunityHikeView: View {
    private static let photoTileSize: CGFloat = 96

    /// What the screen is doing, as one value.
    ///
    /// A single enum rather than a `detail` plus an `isLoading` plus an
    /// `error`, because those three can express states that do not exist — a
    /// failure with a detail behind it, a load that is both finished and
    /// running — and every one of them would be a screen somebody has to
    /// reason about.
    private enum Phase {
        case failed(CommunityFailure)
        case loaded(CommunityHikeDetail)
        case loading
    }

    let listing: CommunityListing
    let transport: any CommunityTransporting
    /// The hiker's own block list. Written by this screen and read by the
    /// lists behind it — see ``CommunityBlockList``.
    let blockList: CommunityBlockList
    /// The browser behind the map, told when this preview opens, what its
    /// route turned out to be, and when it goes.
    ///
    /// **Written and never read.** Nothing in this body touches a property of
    /// it, which is what keeps a screen presented over the map out of the
    /// map's own redraw path — the three calls are one-way, and what they
    /// produce is a line on the map behind this sheet rather than anything
    /// here. See ``CommunityBrowser/previewOpened(_:)``.
    let browser: CommunityBrowser
    /// Called with the imported hike, so the caller can pop this screen and
    /// open the real one.
    let onImport: (Hike) -> Void
    /// Called once this author has been blocked, so the caller can pop a
    /// screen that is now showing hidden content.
    let onBlock: () -> Void

    @Environment(\.modelContext)
    private var context
    @State private var phase: Phase = .loading
    /// The same tiles a hike in the library shows, from the same builder.
    ///
    /// Held apart from ``phase`` because they arrive after it: the route is
    /// what the screen is waiting for and the statistics are a walk of that
    /// route, so folding them together would hold the photographs and the Add
    /// button back on a computation nothing is blocked by.
    @State private var stats: [Stat] = []
    @State private var isImporting = false
    @State private var importFailure: CommunityFailure?
    @State private var existingHike: Hike?
    @State private var isReporting = false
    @State private var isConfirmingBlock = false
    /// The import, held rather than fired and forgotten.
    ///
    /// It outlives this screen — an unstructured `Task` is not tied to a view
    /// — and two things have to wait for it: the download directory, which it
    /// is still reading photographs out of, and nothing else may delete
    /// underneath it. See ``discardDownloads()``.
    @State private var importTask: Task<Void, Never>?
    /// Whether this author was blocked while the screen was up.
    ///
    /// Read by the import when it finishes, so a hike the hiker asked for a
    /// moment before blocking does not re-open itself over the list — see
    /// ``performImport(_:)``.
    @State private var wasAuthorBlocked = false

    /// Where this screen's downloads live. Per-listing so two pushes of
    /// different hikes cannot overwrite each other's photographs, and removed
    /// in `onDisappear`.
    private var downloadDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityHike-\(listing.id)", isDirectory: true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                switch phase {
                case .loading:
                    loadingState
                case .failed(let failure):
                    failureState(failure)
                case .loaded(let detail):
                    loadedState(detail)
                }
            }
            .padding()
        }
        .navigationTitle(listing.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { moderationToolbarItem }
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
            Settings. Blocking doesn't report the hike or take it down.
            """)
        }
        .task { await load() }
        .onAppear {
            existingHike = CommunityImport.existingImport(of: listing.id, in: context)
            // Before the route exists, deliberately: this only says which hike
            // the map is now about, so that a fetch landing after the hiker
            // backed out is ignored rather than drawn.
            browser.previewOpened(listing)
        }
        .onDisappear {
            browser.previewClosed(listing)
            discardDownloads()
        }
    }
}

// MARK: - Reporting and blocking

private extension CommunityHikeView {
    /// Both halves of the Guideline 1.2 affordance, in one place on the screen
    /// showing the content.
    ///
    /// A menu now that there are two destinations behind it. While reporting
    /// was the only one this was a plain destructive button, because a menu in
    /// front of a single destination is a tap spent on nothing — the same call
    /// ``MapAttributionView`` makes about its licence links. Two actions that
    /// a hiker reaches for at the same moment and must not confuse are the
    /// case a menu is for, and the alternative — two toolbar buttons — spends
    /// the navigation bar of a screen whose title is a stranger's trail name.
    @ToolbarContentBuilder var moderationToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
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
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Report or block")
            .accessibilityIdentifier("community-moderation-menu")
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
        wasAuthorBlocked = true
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

    var credit: String {
        let day = listing.hikeDate.formatted(date: .abbreviated, time: .omitted)
        guard !listing.authorName.isEmpty else { return day }
        return "Shared by \(listing.authorName) · \(day)"
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
                phase = .loading
                Task { await load() }
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("community-hike-failure")
    }

    @ViewBuilder
    func loadedState(_ detail: CommunityHikeDetail) -> some View {
        statsGrid

        if let description = detail.trackDescription, !description.isEmpty {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        if !detail.photoFileURLs.isEmpty {
            photoStrip(detail)
        }

        importButton(detail)
    }

    /// The hike's numbers, in the same grid and the same tiles the hiker's own
    /// hikes use.
    ///
    /// Literally the same: ``StatGrid`` and ``StatTile`` rather than a pair
    /// built for this screen, so the two columns, the single column at an
    /// accessibility text size and the one-label-one-value reading all come
    /// along without being decided a second time. What is compared when
    /// somebody is deciding whether to keep a stranger's trail is *their* hike
    /// against *this* one, and two layouts would make that comparison work.
    ///
    /// Empty until the walk of the route finishes, which is a beat after the
    /// route lands — see ``preparedStats(for:)``. Nothing is drawn in the
    /// meantime rather than a row of placeholders: the photographs and the Add
    /// button are already up, and a grid of dashes that fills itself in is a
    /// worse thing to look at than a grid that appears.
    @ViewBuilder var statsGrid: some View {
        if !stats.isEmpty {
            StatGrid {
                ForEach(stats) { stat in
                    StatTile(label: stat.label, value: stat.value)
                }
            }
        }
    }

    func photoStrip(_ detail: CommunityHikeDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photos")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(detail.photoFileURLs, id: \.self) { url in
                        CommunityPhotoTile(url: url, size: Self.photoTileSize)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func importButton(_ detail: CommunityHikeDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                performImport(detail)
            } label: {
                HStack {
                    if isImporting {
                        ProgressView()
                    } else {
                        Image(systemName: existingHike == nil ? "square.and.arrow.down" : "checkmark")
                    }
                    Text(importButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)
            .accessibilityIdentifier("community-import-button")

            if let importFailure {
                Text(importFailure.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if existingHike != nil {
                Text("This hike is already in your list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    var importButtonTitle: String {
        if isImporting { return "Adding…" }
        return existingHike == nil ? "Add to My Hikes" : "Open in My Hikes"
    }
}

// MARK: - Work

private extension CommunityHikeView {
    func load() async {
        guard case .loading = phase else { return }
        do {
            let detail = try await transport.detail(
                for: listing,
                downloadingInto: downloadDirectory
            )
            phase = .loaded(detail)
            // The route this screen no longer draws, handed to the map that
            // does — see this file's header. Before the statistics, because it
            // is what the hiker is waiting to see and it costs nothing to
            // compute.
            browser.previewLoaded(detail.route, of: listing)
            stats = await Self.preparedStats(for: detail)
        } catch {
            phase = .failed(
                error as? CommunityFailure ?? .unavailable(error.localizedDescription)
            )
        }
    }

    /// One walk of the route, off the main actor, producing the same tiles a
    /// hike in the library shows.
    ///
    /// The distance is the route's own length rather than
    /// ``CommunityListing/distanceMeters``, and that is the same call
    /// ``CommunityImport`` makes for the same reason: the listing's figure is
    /// typed by a person in the CloudKit Console, the route is what was
    /// uploaded, and a preview whose stated length disagreed with the hike it
    /// is about to become would be wrong in the one place the hiker can see
    /// both.
    ///
    /// A cancelled preparation — the hiker backing out mid-walk — leaves no
    /// tiles and says nothing. There is nothing to report: the screen it would
    /// have drawn on has gone.
    static func preparedStats(for detail: CommunityHikeDetail) async -> [Stat] {
        let prepared = try? await HikeDetailPreparation.prepare(
            route: detail.route,
            distanceMeters: CommunityImport.routeLength(of: detail.route)
        )
        return prepared?.stats ?? []
    }

    /// Adds the hike, and holds the task that does it.
    ///
    /// Held because the hiker can leave — by backing out, or by blocking this
    /// author — while the photographs are still being copied, and an
    /// unstructured task keeps running when the screen goes. What that costs
    /// is covered in ``discardDownloads()`` and just below.
    func performImport(_ detail: CommunityHikeDetail) {
        // Already in the library: this is the "Open" case, and re-importing
        // would make a second copy of the same trail.
        if let existingHike {
            onImport(existingHike)
            return
        }
        isImporting = true
        importFailure = nil
        // Inherits the main actor from here, which is what every assignment
        // inside it needs and what ``CommunityImport/importHike(_:into:)``
        // requires anyway.
        importTask = Task {
            let outcome = await CommunityImport.importHike(detail, into: context)
            isImporting = false
            switch outcome {
            case .imported(let hike), .alreadyImported(let hike):
                existingHike = hike
                // Blocked while this was running, which is the later of the
                // two things the hiker said. The hike stays in the library —
                // it committed before the photographs began copying, and
                // blocking is a control over what the *community* shows rather
                // than a retraction of a save — but nothing re-opens it. The
                // alternative is the screen they just hid reappearing on top
                // of the list they were sent back to.
                guard !wasAuthorBlocked else { return }
                onImport(hike)
            case .refused(let failure):
                importFailure = failure
            }
        }
    }

    /// Off the main actor, in the shape the photo and tile deletions already
    /// use. What a kill leaves behind is a directory the system reclaims on
    /// its own.
    ///
    /// It waits for the import first, and that is not tidiness. These files
    /// are what ``CommunityImport`` copies a stranger's photographs out of,
    /// this runs from `onDisappear`, and the screen can be left — backed out
    /// of, or blocked away from — while the copy is still going. Deleting
    /// underneath it would cost the hiker the pictures of a hike they asked
    /// for, silently and for no reason they could ever connect to what they
    /// did.
    func discardDownloads() {
        let directory = downloadDirectory
        let pendingImport = importTask
        Task.detached(priority: .utility) {
            await pendingImport?.value
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
