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
        // A tick per ticked box means the selection is an input of the *sheet*
        // rather than of the cell that owns it, which rebuilds every visible
        // tile — and every tile's accessibility label — for one tap.
        RenderSignpost.mark(
            "PhotoDiscoveryBody",
            "\(controller.matches.count) matches"
        )
        return NavigationStack {
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
        case .empty: DiscoveryEmptyState(hike: hike, controller: controller)
        case .idle, .searching: searchingView
        case let .importing(completed, total):
            importingView(completed: completed, total: total)
        case .results: grid
        case .unsupported: unsupportedView
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
                // A view of its own, and not because the toolbar is crowded.
                // Its title counts the selection, so reading it here would put
                // `selection` back into this sheet's inputs — which is the
                // whole thing the cells were moved out for. A `.toolbar`
                // closure is evaluated with the body around it, so a toolbar
                // item is no more insulated than a row is.
                DiscoveryAddButton(controller: controller, hike: hike, onFinished: dismiss.callAsFunction)
            }
        }
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
                    DiscoveredPhotoCell(
                        match: match,
                        controller: controller,
                        index: index,
                        size: Self.cellSize,
                        cornerRadius: Self.cornerRadius,
                        badgeSize: Self.badgeSize
                    )
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

    private var selectionBar: some View {
        DiscoverySelectionBar(controller: controller)
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

    /// A route with no clock on it. The offer is made on every hike, so this
    /// is the screen that explains the one case it cannot be honoured on —
    /// which is a better answer than a button that quietly isn't there.
    private var unsupportedView: some View {
        ContentUnavailableView {
            Label("No Times on This Route", systemImage: "clock.badge.questionmark")
        } description: {
            Text(
                """
                This hike\u{2019}s route doesn\u{2019}t record when each point \
                was reached, so there is nothing to match a photo\u{2019}s own \
                timestamp against. Hikes you record in OpenHikes always carry \
                those times.
                """
            )
        }
        .accessibilityIdentifier("photo-discovery-unsupported")
    }

    /// What a cell says to VoiceOver: when the picture was taken, whether it
    /// is going to be added, and on what evidence it was placed.
    ///
    /// The time goes through ``HikeFormat`` rather than being formatted here
    /// for the reason stated there: this label is attached to every square in
    /// the grid, and a `Date.FormatStyle` written at the call site is rebuilt
    /// for each of them on each pass.
    static func label(for match: LibraryPhotoMatch) -> String {
        let taken = HikeFormat.timeOfDay(match.asset.createdAt)
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

/// The end of a search that found nothing — which is two different statements
/// depending on how much of the library the app was allowed to look at.
///
/// Under full access "nothing was taken while this hike was being recorded" is
/// true, and it is the whole answer. Under limited access it is false: the app
/// looked at a subset somebody chose for it, and the walk's photographs may be
/// sitting just outside that subset. Saying the first thing in the second
/// situation is a screen telling the user their pictures do not exist, on the
/// one control whose entire job is finding them.
///
/// A view of its own rather than a `var` on the sheet, for the reason stated
/// at the top of this file: a computed property is inlined into the body that
/// reads it, so the access level and the presenter would both become inputs of
/// the whole sheet.
private struct DiscoveryEmptyState: View {
    let hike: Hike
    let controller: PhotoDiscoveryController

    /// Owned here, and only meaningful while this state is on screen — which
    /// is exactly the anchor's lifetime. It holds no changing value SwiftUI
    /// can observe, so declaring it as `@State` costs no invalidation.
    @State private var presenter = LimitedLibraryPresenter()

    private static let spacing: CGFloat = 16

    var body: some View {
        let canSelectMore = controller.canSelectMorePhotos
        return VStack(spacing: Self.spacing) {
            ContentUnavailableView {
                Label(
                    canSelectMore ? "No Shared Photos From This Hike" : "No Photos Found",
                    systemImage: "photo.on.rectangle.angled"
                )
            } description: {
                Text(canSelectMore ? Self.limitedMessage : Self.fullMessage)
            }
            // The button is a sibling rather than a `ContentUnavailableView`
            // action, so this identifier stays off it: SwiftUI pushes a
            // container's identifier down onto every descendant, and the
            // button underneath it would end up answering to this name
            // instead of its own.
            .accessibilityIdentifier("photo-discovery-empty")

            if canSelectMore { selectMoreButton }
        }
        .limitedLibraryAnchor(presenter)
    }

    private var selectMoreButton: some View {
        Button("Select More Photos\u{2026}") {
            Task { await controller.selectMorePhotos(in: hike, from: presenter) }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("photo-discovery-select-more-button")
    }

    private static let fullMessage = String(
        localized: """
            Nothing in your photo library was taken while this hike was being \
            recorded — or everything that was is already here.
            """
    )

    /// Says what was actually looked at, and stops short of a claim about the
    /// library as a whole, because the app is in no position to make one.
    private static let limitedMessage = String(
        localized: """
            OpenHikes can only see the photos you have shared with it, and none \
            of those were taken while this hike was being recorded. If your \
            pictures of this walk are elsewhere in your library, share them and \
            OpenHikes will look again.
            """
    )
}

/// One square of the review grid, and the only thing that reads whether it is
/// ticked.
///
/// The read is the whole point of this type existing. `selection` is one
/// property on one `@Observable`, so whoever reads it re-renders when it
/// changes — and while that reader was the sheet, one tick mark rebuilt the
/// navigation stack, the scroll view, the grid, the toolbar and every visible
/// cell's accessibility label. Here it rebuilds a border and a glyph.
private struct DiscoveredPhotoCell: View {
    let match: LibraryPhotoMatch
    let controller: PhotoDiscoveryController
    let index: Int
    let size: CGFloat
    let cornerRadius: CGFloat
    let badgeSize: CGFloat

    var body: some View {
        let isSelected = controller.isSelected(match.id)
        return Button {
            controller.toggle(match.id)
        } label: {
            DiscoveredPhotoTile(
                match: match,
                controller: controller,
                isSelected: isSelected,
                size: size,
                cornerRadius: cornerRadius,
                badgeSize: badgeSize
            )
        }
        .buttonStyle(.plain)
        // One element, not a picture plus a checkmark plus two captions. A
        // cell is a single tap target, so four stops through it would say the
        // same thing four times.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PhotoDiscoverySheet.label(for: match))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("discovered-photo-\(index)")
    }
}

/// The count and the select-all switch, which are the other two readers of the
/// selection — kept out of the sheet for the same reason the cell is.
private struct DiscoverySelectionBar: View {
    let controller: PhotoDiscoveryController

    var body: some View {
        let selected = controller.selectedCount
        let total = controller.matches.count
        return VStack(spacing: 0) {
            if controller.importFailed { failureNotice }
            HStack {
                Button(selected == total ? "Deselect All" : "Select All") {
                    if selected == total {
                        controller.deselectAll()
                    } else {
                        controller.selectAll()
                    }
                }
                .accessibilityIdentifier("photo-discovery-select-all-button")

                Spacer()

                Text("\(selected) of \(total) selected")
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
}

/// The toolbar's Add button, which counts the selection in its own title.
private struct DiscoveryAddButton: View {
    let controller: PhotoDiscoveryController
    let hike: Hike
    let onFinished: () -> Void

    var body: some View {
        let count = controller.selectedCount
        return Button(count > 0 ? String(localized: "Add \(count)") : String(localized: "Add")) {
            Task {
                let added = await controller.importSelected(into: hike)
                // Something landed and nothing is left to review: the sheet
                // has finished its job, and leaving it up on its empty state
                // would read as an import that found nothing rather than as
                // one that just succeeded. Anything that failed stays in
                // `matches`, which keeps the sheet open to be retried.
                if added > 0, controller.matches.isEmpty { onFinished() }
            }
        }
        .disabled(!controller.canImport)
        .accessibilityIdentifier("photo-discovery-add-button")
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
