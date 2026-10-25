//
//  CommunitySharePhotoViewer.swift
//  OpenHikes
//
//  The photographs a hiker is about to send, one at a time and as large as the
//  screen, with the same choice the strip offers on each.
//
//  The strip under *What gets shared* is a row of 76-point squares, which is
//  enough to count photographs and not enough to choose between them. A walk
//  with sixty pictures on it is sixty decisions about what strangers will see,
//  and the hiker had no way to look at any of them properly before making
//  them — the hike's own gallery is one sheet down, under the form.
//
//  ## What it reuses
//
//  The pages are ``HikePhotoPager``, which ``HikePhotoViewer`` pages through:
//  the same decode, and the same three ways a page that cannot be drawn says
//  why. The black surface is ``SwiftUI/View/photoGalleryChrome()`` and the
//  chevrons are ``PhotoStepControls``, which both existing galleries wear.
//
//  The choice is the strip's, not a copy of it: the toggle writes the same
//  `excluded` set through ``CommunitySharePhotoStrip/toggle(_:in:)``, so
//  striking a picture off here fades its tile when the hiker goes back, and
//  the number above the strip has already moved. Two spellings of that rule is
//  how the two screens would end up meaning different things by the same tap —
//  see the strip's own header.
//
//  ## What it does not inherit
//
//  Delete, *Show on map* and the system share button. All three are about
//  owning the photograph rather than about choosing it, and the first is the
//  dangerous one: a hiker paging through to *leave a picture out* who instead
//  deletes it has lost the only copy — photo files stay on the device they
//  were added on. An unreadable page offers *Try Again* alone for the same
//  reason; see ``HikePhotoPage/onRemove``.
//
//  ## How it is reached
//
//  Pushed onto the form's own navigation stack, which is what both existing
//  galleries do on theirs. The form is a sheet already, and in landscape the
//  system draws a sheet across the whole window, so the push is full-screen
//  there without asking.
//

import OpenHikesData
import SwiftUI

struct CommunitySharePhotoViewer: View {
    /// Every picture the form offers, in the strip's order — which is the
    /// order the upload takes them in.
    let photos: [HikePhoto]
    /// The tile the gallery was opened from. Only the opening position.
    let startID: UUID
    /// Which pictures are struck off. The form's own set, so a choice made here
    /// is the strip's choice.
    @Binding var excluded: Set<UUID>
    /// Which of them this device holds the files of, once the form has
    /// asked — what decides which pictures the cap holds back, as on the
    /// strip. See ``CommunitySharePhotoChoices``.
    var files: CommunityPhotoFiles = .unasked
    var store: HikePhotoStore = .shared
    /// Whether the form is mid-send, the one state the choice is not offered
    /// in — the strip refuses taps then too.
    var isSending = false

    @State private var currentID: UUID?
    @State private var didRestoreStart = false

    var body: some View {
        let currentIndex = currentID.flatMap { id in photos.firstIndex { $0.id == id } }
        let current = currentIndex.map { photos[$0] }
        let choices = CommunitySharePhotoChoices(
            photos: photos,
            excluding: excluded,
            files: files
        )
        // The identifier goes on the pages and not on the overlay: SwiftUI
        // pushes a container's identifier down onto every descendant, and the
        // toggle below has a name of its own to answer to.
        return HikePhotoPager(photos: photos, currentID: $currentID, store: store)
            .photoGalleryChrome()
            .accessibilityIdentifier("community-share-photo-viewer")
            .overlay(alignment: .bottom) {
                bottomBar(current, choices: choices, currentIndex: currentIndex)
            }
            .navigationTitle(title(currentIndex))
            .navigationSubtitle(sharedSummary(choices), below: title(currentIndex))
            .onAppear {
                // Assigning the scroll position before the scroll view exists
                // is ignored, so the opening page is set on the first
                // appearance and never again — the reason both other galleries
                // give.
                guard !didRestoreStart else { return }
                didRestoreStart = true
                currentID = photos.contains { $0.id == startID } ? startID : photos.first?.id
            }
    }

    // MARK: - Controls

    /// The choice about the picture on screen, over the way to the next one.
    ///
    /// One ``GlassStack`` around both, for the reason ``HikePhotoViewer``'s
    /// credit and chevrons share one: two pieces of glass that nearly touch
    /// should merge rather than render as two panes.
    private func bottomBar(
        _ current: HikePhoto?,
        choices: CommunitySharePhotoChoices,
        currentIndex: Int?
    ) -> some View {
        GlassStack(spacing: 6) {
            VStack(spacing: 10) {
                if let current {
                    choice(current, choice: choices.choice(for: current))
                }
                PhotoStepControls(
                    previousIdentifier: "community-share-previous-photo-button",
                    nextIdentifier: "community-share-next-photo-button",
                    hasDestination: { destination(from: currentIndex, by: $0) != nil },
                    step: { step(by: $0) }
                )
                .photoStepVisibility(count: photos.count)
            }
        }
        .padding(.bottom, 20)
    }

    /// Whether this picture goes, as the strip's tick says it — the same
    /// glyphs, so the two read as one control at two sizes.
    ///
    /// A picture a previous send already carried says so on the button, which
    /// is the fact the strip draws as a badge in the tile's corner.
    private func choice(_ photo: HikePhoto, choice: CommunitySharePhotoChoices.Choice) -> some View {
        let isExcluded = choice == .struckOff
        return Button {
            withAnimation(.snappy) {
                CommunitySharePhotoStrip.toggle(photo, in: &excluded)
            }
        } label: {
            Label {
                Text(Self.title(of: choice, alreadySent: photo.hasBeenSentToCommunity))
            } icon: {
                Image(systemName: CommunitySharePhotoStrip.symbol(for: choice))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, choice == .shared ? Color.accentColor : Color.secondary)
            }
            .contentTransition(.symbolEffect(.replace))
            .padding(.horizontal, 4)
            .minimumTapTarget()
        }
        .glassButtonStyle()
        .disabled(isSending)
        // The backdrop is black whatever the device is set to — the same
        // reason the credit capsule in the hiker's own gallery is told this.
        .environment(\.colorScheme, .dark)
        // The strip's own sentence for the same state, so VoiceOver says the
        // same thing about a picture at either size.
        .accessibilityLabel(
            CommunitySharePhotoStrip.label(for: photo, choice: choice, among: photos.count)
        )
        // The tap, not what it leads to. Whether a picture goes depends on
        // the cap as well as on its tick: striking off a picture past the cap
        // changes nothing that is sent, and putting one back past it leaves it
        // over the limit. The label says the outcome, and VoiceOver reads it
        // again after the tap.
        .accessibilityHint(isExcluded ? "Puts this photo back" : "Strikes this photo off")
        .accessibilityIdentifier("community-share-photo-toggle")
        // The set rather than this page's state of it: paging from a picture
        // left out to one being shared changes `isExcluded` without anybody
        // choosing anything, and that must not tick.
        .sensoryFeedback(.selection, trigger: excluded)
    }

    /// What the choice button says, in the strip's three states.
    private static func title(
        of choice: CommunitySharePhotoChoices.Choice,
        alreadySent: Bool
    ) -> LocalizedStringKey {
        switch (choice, alreadySent) {
        case (.shared, false): "Sharing"
        case (.struckOff, false): "Left Out"
        case (.overTheLimit, false): "Over the Limit"
        case (.shared, true): "Already Sent \u{00B7} Sharing"
        case (.struckOff, true): "Already Sent \u{00B7} Left Out"
        case (.overTheLimit, true): "Already Sent \u{00B7} Over the Limit"
        }
    }

    // MARK: - Titles

    private func title(_ currentIndex: Int?) -> String {
        guard let index = currentIndex else { return String(localized: "Photo") }
        return String(localized: "\(index + 1) of \(photos.count)")
    }

    /// How many are going, so a hiker paging through sixty can see the tally
    /// move without going back to the form. Counted after the cap, so it is
    /// the number the form's count row says rather than the ticks.
    private func sharedSummary(_ choices: CommunitySharePhotoChoices) -> String {
        String(localized: "\(choices.sharedCount) of \(photos.count) shared")
    }

    // MARK: - Actions

    /// The index `offset` steps away, or `nil` at either end.
    private func destination(from index: Int?, by offset: Int) -> Int? {
        guard let index else { return nil }
        let target = index + offset
        return photos.indices.contains(target) ? target : nil
    }

    private func step(by offset: Int) {
        let index = currentID.flatMap { id in photos.firstIndex { $0.id == id } }
        guard let target = destination(from: index, by: offset) else { return }
        withAnimation { currentID = photos[target].id }
    }
}

private extension View {
    /// `navigationSubtitle(_:)` on iOS 26 and later. Below 26 there is no
    /// subtitle, so the bar's middle draws the two lines iOS 18's own apps
    /// draw there, and the tally still moves with every tick.
    @ViewBuilder
    func navigationSubtitle(_ subtitle: String, below title: String) -> some View {
        if #available(iOS 26.0, *) {
            navigationSubtitle(subtitle)
        } else {
            toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

extension View {
    /// Pushes ``CommunitySharePhotoViewer`` when `startID` is set, over a send
    /// form's own navigation stack.
    ///
    /// One modifier for both forms that draw ``CommunitySharePhotoStrip``, so
    /// the gallery the strip opens is the same screen on each.
    func communitySharePhotoGallery(
        _ startID: Binding<UUID?>,
        photos: [HikePhoto],
        excluded: Binding<Set<UUID>>,
        files: CommunityPhotoFiles,
        store: HikePhotoStore,
        isSending: Bool
    ) -> some View {
        navigationDestination(item: startID) { id in
            CommunitySharePhotoViewer(
                photos: photos,
                startID: id,
                excluded: excluded,
                files: files,
                store: store,
                isSending: isSending
            )
        }
    }
}
