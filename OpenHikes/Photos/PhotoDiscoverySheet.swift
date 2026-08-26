//
//  PhotoDiscoverySheet.swift
//  OpenHikes
//
//  The review screen for photographs the app found but did not take: a grid of
//  what a walk's own timestamps say belongs to it, each one shown before it is
//  attached to anything.
//
//  Everything is selected when the grid arrives, because the common answer is
//  "yes, all of these" — but nothing is attached until the button is pressed,
//  because the match is a good guess and a guess should be looked at. What
//  each cell says about *how* it was placed is part of that: a photograph the
//  camera's own position agrees with is a different claim from one worked out
//  from a clock four minutes off the nearest fix, and a grid that drew them
//  identically would be making the weaker claim silently.
//
//  Presented from inside the sheet, like the GPX importer and Settings. The
//  app keeps its bottom sheet up permanently and a view can only have one
//  modal at a time, so a `.sheet` attached beside it is simply never shown.
//

import SwiftUI

struct PhotoDiscoverySheet: View {
    let hike: Hike
    let controller: PhotoDiscoveryController

    @Environment(\.dismiss)
    private var dismiss

    private static let cellSize: CGFloat = 104
    private static let cellSpacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 12
    private static let badgeSize: CGFloat = 22

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Photos of This Hike")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
        }
        .task {
            await controller.search(in: hike)
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .accessDenied: deniedView
        case .accessRestricted: restrictedView
        case .empty: emptyView
        case .idle, .searching: searchingView
        case let .importing(completed, total):
            importingView(completed: completed, total: total)
        case .results: grid
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
                .accessibilityIdentifier("photo-discovery-done-button")
        }
        ToolbarItem(placement: .primaryAction) {
            // Withdrawn rather than disabled when there is nothing to review:
            // a permanently dimmed Add above an explanation of why nothing was
            // found is an offer the screen cannot honour. It comes back the
            // moment there is something in the grid, where `disabled` then
            // means what it should — nothing is ticked.
            if !controller.matches.isEmpty {
                Button(addTitle) {
                    Task {
                        let added = await controller.importSelected(into: hike)
                        // Something landed and nothing is left to review: the
                        // sheet has finished its job, and leaving it up on its
                        // empty state would read as an import that found
                        // nothing rather than as one that just succeeded.
                        // Anything that failed stays in `matches`, which keeps
                        // the sheet open to be retried.
                        if added > 0, controller.matches.isEmpty { dismiss() }
                    }
                }
                .disabled(!controller.canImport)
                .accessibilityIdentifier("photo-discovery-add-button")
            }
        }
    }

    private var addTitle: String {
        let count = controller.selectedCount
        return count > 0
            ? String(localized: "Add \(count)")
            : String(localized: "Add")
    }

    // MARK: - Results

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: Self.cellSize),
                        spacing: Self.cellSpacing
                    ),
                ],
                spacing: Self.cellSpacing
            ) {
                ForEach(Array(controller.matches.enumerated()), id: \.element.id) { index, match in
                    cell(match, at: index)
                }
            }
            .padding()

            footnote
                .padding(.horizontal)
                .padding(.bottom)
        }
        // On the grid's scroll view rather than on a stack around it: SwiftUI
        // pushes a container's identifier down onto every descendant, which
        // would leave every cell answering to this name instead of its own.
        .accessibilityIdentifier("photo-discovery-grid")
        .safeAreaInset(edge: .bottom) { selectionBar }
    }

    private func cell(_ match: LibraryPhotoMatch, at index: Int) -> some View {
        Button {
            controller.toggle(match.id)
        } label: {
            DiscoveredPhotoTile(
                match: match,
                controller: controller,
                isSelected: controller.isSelected(match.id),
                size: Self.cellSize,
                cornerRadius: Self.cornerRadius,
                badgeSize: Self.badgeSize
            )
        }
        .buttonStyle(.plain)
        // One element, not a picture plus a checkmark plus two captions. A
        // cell is a single tap target, so four stops through it would say the
        // same thing four times.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(for: match))
        .accessibilityAddTraits(
            controller.isSelected(match.id) ? [.isButton, .isSelected] : .isButton
        )
        .accessibilityIdentifier("discovered-photo-\(index)")
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            if controller.importFailed { failureNotice }
            HStack {
                Button(
                    controller.selectedCount == controller.matches.count
                        ? "Deselect All"
                        : "Select All"
                ) {
                    if controller.selectedCount == controller.matches.count {
                        controller.deselectAll()
                    } else {
                        controller.selectAll()
                    }
                }
                .accessibilityIdentifier("photo-discovery-select-all-button")

                Spacer()

                Text("\(controller.selectedCount) of \(controller.matches.count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("photo-discovery-selection-count")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    /// What is left on screen when a copy did not go through.
    ///
    /// The photographs that failed are still in the list and still selected,
    /// so the recovery is to tap Add again — which is worth saying, because a
    /// grid that looked like it had been added and then still had things in it
    /// would otherwise be a mystery.
    private var failureNotice: some View {
        Label(
            "Some photos couldn\u{2019}t be added. Try adding them again.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityIdentifier("photo-discovery-import-failed")
    }

    private var footnote: some View {
        Text(
            """
            OpenHikes matched these to the moment each point of this hike was \
            recorded. Photos your camera saved a location with are checked \
            against the route as well. Nothing is added until you tap Add.
            """
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - The other five states

    private var searchingView: some View {
        ProgressView("Looking through your photo library\u{2026}")
            .accessibilityIdentifier("photo-discovery-searching")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func importingView(completed: Int, total: Int) -> some View {
        ProgressView(
            value: Double(completed),
            total: Double(total)
        ) {
            Text("Adding \(completed) of \(total)\u{2026}")
        }
        .progressViewStyle(.linear)
        .padding()
        .accessibilityIdentifier("photo-discovery-importing")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Photos Found", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(
                """
                Nothing in your photo library was taken while this hike was \
                being recorded — or everything that was is already here.
                """
            )
        }
        .accessibilityIdentifier("photo-discovery-empty")
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("Photo Access Off", systemImage: "lock")
        } description: {
            Text(
                """
                OpenHikes needs to read your photo library to find pictures \
                taken during this hike. You can turn that on in Settings.
                """
            )
        } actions: {
            #if os(iOS)
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settings)
            }
            #endif
        }
        .accessibilityIdentifier("photo-discovery-denied")
    }

    private var restrictedView: some View {
        ContentUnavailableView {
            Label("Photo Access Unavailable", systemImage: "lock")
        } description: {
            Text(
                """
                Photo library access is turned off for this device, so \
                OpenHikes can\u{2019}t look for pictures of this hike.
                """
            )
        }
        .accessibilityIdentifier("photo-discovery-restricted")
    }

    /// What a cell says to VoiceOver: when the picture was taken, whether it
    /// is going to be added, and on what evidence it was placed.
    private static func label(for match: LibraryPhotoMatch) -> String {
        let taken = match.asset.createdAt.formatted(
            date: .omitted,
            time: .shortened
        )
        return String(
            localized: "Photo taken at \(taken), \(evidenceDescription(match))"
        )
    }

    static func evidenceDescription(_ match: LibraryPhotoMatch) -> String {
        switch match.evidence {
        case .place: String(localized: "placed by where your camera says it was")
        case .time where match.secondsFromFix < 1:
            String(localized: "taken on a recorded point of this hike")
        case .time:
            String(
                localized: """
                    placed by time, \(HikeFormat.duration(match.secondsFromFix)) \
                    from the nearest recorded point
                    """
            )
        case .timeAndPlace: String(localized: "matched by both time and place")
        }
    }
}

/// One square of the review grid.
///
/// `.task(id:)` rather than `onAppear`, for the same reason
/// ``HikePhotoThumbnail`` uses it: the grid recycles cells, and keying the
/// load on the match is what stops a reused cell from showing the previous
/// photo until its own image lands.
private struct DiscoveredPhotoTile: View {
    let match: LibraryPhotoMatch
    let controller: PhotoDiscoveryController
    let isSelected: Bool
    let size: CGFloat
    let cornerRadius: CGFloat
    let badgeSize: CGFloat

    @State private var image: PhotoImage?

    private static let unselectedBadgeOpacity: Double = 0.8
    private static let badgeInset: CGFloat = 6

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            picture
            badge
                .padding(Self.badgeInset)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .task(id: match.id) {
            image = await controller.thumbnail(for: match)?.image
        }
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(photoImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                // The cell around it speaks for the photograph — when it was
                // taken and how it was placed — which is more than its pixels
                // could say. A second element here would only repeat it.
                .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
        }
    }

    private var badge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: badgeSize))
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                .white,
                isSelected
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(.black.opacity(Self.unselectedBadgeOpacity))
            )
            .shadow(radius: 1)
            // The cell above is one element and carries the whole sentence;
            // the tick is how that sentence is drawn, not a second thing to
            // stop on.
            .accessibilityHidden(true)
    }
}
