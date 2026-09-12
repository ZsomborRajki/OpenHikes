//
//  CommunityHikeView.swift
//  OpenHikes
//
//  Somebody else's hike, before it is yours.
//
//  Pushed from a community search result, and the one screen between seeing a
//  trail's name and having it in the library. It exists because importing
//  blind is not a decision anyone can make: a name and a distance say nothing
//  about whether a route goes where the walker wants, and the photographs are
//  half of why they would want it.
//
//  The route is drawn as a plain shape rather than on a map, which is a
//  deliberate limit rather than a missing feature. A map here would mean tiles
//  — a provider, the entitlement check, the cache, a download over whatever
//  connection the walker is on — for a screen they may back out of in two
//  seconds. The shape answers the question this screen is for, which is *does
//  this route go where I think it does*; the moment the hike is imported it
//  becomes an ordinary ``Hike`` and gets the real map like every other.
//
//  Everything downloaded lands in one directory owned by this screen and
//  deleted when it goes — or when an import that is still reading out of it
//  finishes, whichever is later. These are a stranger's photographs held for
//  as long as they are being looked at, and no longer, unless the walker
//  imports the hike, at which point ``CommunityImport`` makes copies that are
//  theirs.
//
//  ## Why reporting and blocking are here and not on the row
//
//  This is the screen that shows the content, and both gestures are about
//  content. A row carries a title, a distance and a name; a walker reporting
//  from one would be reporting a title they read rather than a photograph they
//  saw, and a reviewer would open the listing to find nothing wrong with it.
//  The menu sits in the toolbar rather than under the fold because it must be
//  reachable in every phase — a listing whose route never loads can still be
//  one whose *title* is the problem, and a walker who cannot open a hike is
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
    private static let routeShapeHeight: CGFloat = 180
    private static let photoTileSize: CGFloat = 96
    private static let routeLineWidth: CGFloat = 2.5

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
    /// The walker's own block list. Written by this screen and read by the
    /// lists behind it — see ``CommunityBlockList``.
    let blockList: CommunityBlockList
    /// Called with the imported hike, so the caller can pop this screen and
    /// open the real one.
    let onImport: (Hike) -> Void
    /// Called once this author has been blocked, so the caller can pop a
    /// screen that is now showing hidden content.
    let onBlock: () -> Void

    @Environment(\.modelContext)
    private var context
    @State private var phase: Phase = .loading
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
    /// Read by the import when it finishes, so a hike the walker asked for a
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
        .onAppear { existingHike = CommunityImport.existingImport(of: listing.id, in: context) }
        .onDisappear { discardDownloads() }
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
    /// a walker reaches for at the same moment and must not confuse are the
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

    /// "Block Anna", or "Block This Walker" when they published without a
    /// name.
    ///
    /// The name is a label and never the thing being blocked — see
    /// ``CommunityBlockList`` — but it is what the walker recognises, and an
    /// item reading "Block" alone on a screen with an import button under it
    /// leaves them guessing what the object is.
    var blockActionTitle: String {
        listing.authorName.isEmpty
            ? String(localized: "Block This Walker")
            : String(localized: "Block \(listing.authorName)")
    }

    var blockPrompt: String {
        listing.authorName.isEmpty
            ? String(localized: "Block this walker?")
            : String(localized: "Block \(listing.authorName)?")
    }

    /// Blocks the author and hands the screen back, because what is on it is
    /// now hidden everywhere else.
    ///
    /// Leaving it up would be the one place in the app still showing content
    /// the walker has just said they do not want to see, and backing out of it
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
        CommunityRouteShape(coordinates: detail.route.map(\.clCoordinate))
            .stroke(.tint, style: StrokeStyle(lineWidth: Self.routeLineWidth, lineJoin: .round))
            .frame(height: Self.routeShapeHeight)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityHidden(true)

        statsGrid(detail)

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

    func statsGrid(_ detail: CommunityHikeDetail) -> some View {
        let profile = RouteProfile(route: detail.route)
        return HStack(spacing: 24) {
            stat(
                "Distance",
                value: HikeFormat.length(
                    Measurement(
                        value: CommunityImport.routeLength(of: detail.route),
                        unit: UnitLength.meters
                    )
                )
            )
            if let gain = profile.elevation.gainMeters {
                stat(
                    "Ascent",
                    value: HikeFormat.length(Measurement(value: gain, unit: UnitLength.meters))
                )
            }
            stat("Photos", value: "\(detail.photoFileURLs.count)")
        }
    }

    func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        // One element with one label and one value, the same contract every
        // other composite row in the app keeps.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
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
        } catch {
            phase = .failed(
                error as? CommunityFailure ?? .unavailable(error.localizedDescription)
            )
        }
    }

    /// Adds the hike, and holds the task that does it.
    ///
    /// Held because the walker can leave — by backing out, or by blocking this
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
                // two things the walker said. The hike stays in the library —
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
    /// underneath it would cost the walker the pictures of a hike they asked
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
