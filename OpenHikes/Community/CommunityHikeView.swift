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
//  deleted when it goes. These are a stranger's photographs held for as long
//  as they are being looked at, and no longer — unless the walker imports the
//  hike, at which point ``CommunityImport`` makes copies that are theirs.
//
//  ## Why the report button is here and not on the row
//
//  This is the screen that shows the content, and reporting is about content.
//  A row carries a title, a distance and a name; a walker reporting from one
//  would be reporting a title they read rather than a photograph they saw, and
//  a reviewer would open the listing to find nothing wrong with it. The button
//  sits in the toolbar rather than under the fold because it must be reachable
//  in every phase — a listing whose route never loads can still be one whose
//  *title* is the problem, and a walker who cannot open a hike is exactly the
//  one with nothing else to do about it. See ``CommunityReport`` for where a
//  report goes.
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
    /// Called with the imported hike, so the caller can pop this screen and
    /// open the real one.
    let onImport: (Hike) -> Void

    @Environment(\.modelContext)
    private var context
    @State private var phase: Phase = .loading
    @State private var isImporting = false
    @State private var importFailure: CommunityFailure?
    @State private var existingHike: Hike?
    @State private var isReporting = false

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
        .toolbar { reportToolbarItem }
        .sheet(isPresented: $isReporting) {
            CommunityReportSheet(listing: listing)
        }
        .task { await load() }
        .onAppear { existingHike = CommunityImport.existingImport(of: listing.id, in: context) }
        .onDisappear { discardDownloads() }
    }
}

// MARK: - Reporting

private extension CommunityHikeView {
    /// The Guideline 1.2 affordance: somewhere on the screen showing the
    /// content to say that something is wrong with it.
    ///
    /// A destructive-tinted button rather than a menu, because there is one
    /// action behind it and a menu in front of a single destination is a tap
    /// spent on nothing — the same call ``MapAttributionView`` makes about its
    /// licence links.
    @ToolbarContentBuilder var reportToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isReporting = true
            } label: {
                Label("Report", systemImage: "exclamationmark.bubble")
            }
            .tint(.red)
            .accessibilityLabel("Report this hike")
            .accessibilityHint("Tells the reviewer something is wrong with it")
            .accessibilityIdentifier("community-report-button")
        }
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
                Task { await performImport(detail) }
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

    func performImport(_ detail: CommunityHikeDetail) async {
        // Already in the library: this is the "Open" case, and re-importing
        // would make a second copy of the same trail.
        if let existingHike {
            onImport(existingHike)
            return
        }
        isImporting = true
        importFailure = nil
        let outcome = await CommunityImport.importHike(detail, into: context)
        isImporting = false
        switch outcome {
        case .imported(let hike), .alreadyImported(let hike):
            existingHike = hike
            onImport(hike)
        case .refused(let failure):
            importFailure = failure
        }
    }

    /// Fire-and-forget, off the main actor, in the shape the photo and tile
    /// deletions already use. What a kill leaves behind is a directory the
    /// system reclaims on its own.
    func discardDownloads() {
        let directory = downloadDirectory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
