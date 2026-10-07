//
//  HikePhotoPager.swift
//  OpenHikes
//
//  The hiker's own photographs, one full-bleed page at a time.
//
//  The half of a photo gallery that does not depend on why it was opened.
//  ``HikePhotoViewer`` pages through a hike's photographs to look at, delete
//  and share them; ``CommunitySharePhotoViewer`` pages through the same
//  photographs to decide which of them go public. What each one puts *around*
//  the pages differs — that is the whole of what those two screens are — and
//  what the pages themselves do must not: the decode, the three ways a file
//  can fail to be drawn, and the paging that a swipe and the two chevrons
//  drive together. Two copies of that is how one gallery ends up with a
//  spinner that never resolves while the other says *Not on This Device*.
//
//  Paging is a horizontally paged `ScrollView` rather than a `TabView`, so a
//  swipe and the step buttons drive the same `scrollPosition` and cannot
//  disagree about which photo is showing. Snapped to the pages themselves
//  rather than by `.paging` — see ``ScrollTargetBehavior/photoPages``.
//

import OpenHikesData
import SwiftUI

/// The paged photographs, with the page on screen bound to the caller.
struct HikePhotoPager: View {
    let photos: [HikePhoto]
    /// The page the scroll view is resting on. Owned by the gallery, which
    /// steps it from its own buttons and titles itself from it.
    @Binding var currentID: UUID?
    let store: HikePhotoStore
    /// Told what each page's load found out about its file — see
    /// ``HikePhotoPage/onFileFound``.
    var onFileFound: (UUID, Bool) -> Void = { _, _ in /* nothing to remember */ }
    /// Takes a photograph out of the hike, or `nil` where the gallery has no
    /// business doing that — see ``HikePhotoPage/onRemove``.
    var onRemove: ((HikePhoto) -> Void)?
    /// What a tap on a drawn photograph does, or `nil` for nothing — see
    /// ``HikePhotoPage/onTap``.
    var onTapPhoto: (() -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos) { photo in
                    HikePhotoPage(
                        photo: photo,
                        store: store,
                        onFileFound: { found in onFileFound(photo.id, found) },
                        onRemove: onRemove.map { remove in { remove(photo) } },
                        onTap: onTapPhoto
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(photo.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.photoPages)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentID)
        .ignoresSafeArea(edges: .bottom)
    }
}

/// One full-bleed page.
///
/// Separate from the viewer so paging redraws a page rather than the toolbar,
/// the title and the button pill with it — and so the `.task(id:)` that
/// decodes belongs to the page that needs it and is cancelled when that page
/// is recycled.
struct HikePhotoPage: View {
    let photo: HikePhoto
    let store: HikePhotoStore
    /// Tells the viewer whether this photograph's file is on this device,
    /// which is what its *Share* is offered on.
    ///
    /// Answered from here because the load below already answers it, and a
    /// second look at the disk would be both a duplicate and a main-thread
    /// file check that ``HikePhotoStore`` refuses. The mapping is
    /// ``Self/hasFile(_:)``.
    var onFileFound: (Bool) -> Void
    /// Takes this photo's row out of the hike, for the case where its file is
    /// not coming back.
    ///
    /// Handed down rather than done here so it goes through the viewer's own
    /// `delete(_:)`, which steps the paging off this page first — a page that
    /// removes itself while the scroll view is resting on it leaves
    /// `scrollPosition` pointing at an id that no longer exists.
    ///
    /// `nil` on a gallery that does not own the photographs it is showing —
    /// the share form's, where the question is which pictures go and a
    /// deletion would be an answer to a different one. The unreadable page
    /// then offers *Try Again* alone.
    var onRemove: (() -> Void)?
    /// What a tap on the photograph does: the hiker's own gallery, with the
    /// map brought in beside it, takes the whole screen back. `nil` while
    /// there is nothing for a tap to do, which is also when VoiceOver hears
    /// the photograph as a picture rather than a button.
    ///
    /// On the picture alone rather than the page, so the recovery states'
    /// buttons keep their taps to themselves.
    var onTap: (() -> Void)?

    @State private var display = PhotoDisplay.loading
    /// Bumped by "Try Again", and part of the load's identity below.
    ///
    /// Retry is worth offering rather than being a placebo: an unreadable file
    /// is often a temporary condition — a photo whose bytes haven't finished
    /// coming down from a restore, a volume that wasn't mounted — and the
    /// alternative to a button is leaving the screen and coming back. Which is
    /// also why only that state offers it: nothing is on its way to a device
    /// that simply never had the file.
    @State private var attempt = 0

    var body: some View {
        ZStack {
            switch display {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityElement()
                    .accessibilityLabel(Self.label(for: photo))
            case .ready(let loaded):
                let image = Image(photoImage: loaded.image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityElement()
                    .accessibilityLabel(Self.label(for: photo))
                if let onTap {
                    image
                        .onTapGesture(perform: onTap)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows the photo full screen")
                } else {
                    image
                }
            case .unavailable(let reason):
                unavailable(reason)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: Attempt(photo: photo.id, count: attempt)) {
            display = .loading
            // Nothing is known about the file while the load is in flight, and
            // *unknown* is reported as *no*: a page recycled onto this photo
            // must not inherit the last one's answer, and a button offered on
            // a guess is the thing this is here to stop.
            onFileFound(false)
            display = await HikePhotoLoader.display(for: photo, in: store)
            onFileFound(Self.hasFile(display))
        }
    }

    /// A photo the hike still lists and the disk cannot produce, in whichever
    /// of the two ways that happened.
    @ViewBuilder
    private func unavailable(_ reason: PhotoUnavailability) -> some View {
        switch reason {
        case .notOnThisDevice:
            notOnThisDevice
        case .unreadable:
            unreadable
        case .placeOnly:
            placeOnly
        }
    }

    /// A place a photograph was taken, read out of an imported file that could
    /// not carry the photograph.
    ///
    /// Nothing to press, and for a firmer reason than ``notOnThisDevice`` has.
    /// That state withholds the removal because some *other* device has the
    /// picture; here there is no picture anywhere, so "Try Again" would retry
    /// a read of a file that was never written. What the row is worth is on
    /// the map, where it is a pin on the trail, and saying so is the whole job
    /// of this page.
    private var placeOnly: some View {
        ContentUnavailableView {
            Label("No Photo in the File", systemImage: "mappin.and.ellipse")
        } description: {
            Text(
                """
                This came from an imported GPX file, which records where a \
                photo was taken but cannot carry the photo itself. Its place \
                on the trail is on the map.
                """
            )
        }
        .accessibilityIdentifier("photo-place-only")
        .environment(\.colorScheme, .dark)
    }

    /// A photo whose file is not here and is not coming.
    ///
    /// Nothing to press, on purpose. "Try Again" would be a placebo — photo
    /// files do not travel between devices and nothing is fetching this one,
    /// which is a decision rather than an omission; see *Settled decisions* in
    /// the repository instructions. And the removal the other state offers
    /// would take the row out of the hike on *every* device, including the one
    /// whose copy of the picture is perfectly fine. The toolbar's trash is
    /// still there for somebody who means exactly that; it is not what this
    /// page suggests they meant.
    private var notOnThisDevice: some View {
        ContentUnavailableView {
            Label("Not on This Device", systemImage: "icloud.slash")
        } description: {
            Text(
                """
                OpenHikes keeps photo files on the device they were added \
                on \u{2014} only where and when the photo was taken travels \
                with the hike.
                """
            )
        }
        .accessibilityIdentifier("photo-not-on-this-device")
        .environment(\.colorScheme, .dark)
    }

    /// A file that is here and could not be read.
    ///
    /// Both ways out are here because neither one is always right. The file
    /// may yet be readable — bytes still arriving from a restore, a volume
    /// that wasn't mounted — so the load can be asked for again; and when it
    /// never will be, the row claiming it is the thing to remove. That exit is
    /// what this state had none of, since it was indistinguishable from a load
    /// in progress and the toolbar's own delete was the only thing that could
    /// end it.
    private var unreadable: some View {
        VStack(spacing: Self.recoverySpacing) {
            ContentUnavailableView {
                Label("Photo Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(
                    """
                    The file behind this photo is here but couldn\u{2019}t be read.
                    """
                )
            }
            // The buttons are siblings rather than `actions:` for the reason
            // `DiscoveryEmptyState` keeps them there: SwiftUI pushes a
            // container's identifier onto every descendant, so a button inside
            // this one would answer to this name instead of its own.
            .accessibilityIdentifier("photo-unavailable")

            HStack(spacing: Self.recoverySpacing) {
                Button("Try Again") { attempt += 1 }
                    .glassButtonStyle()
                    .accessibilityIdentifier("photo-retry-button")
                if let onRemove {
                    Button("Remove Photo", role: .destructive, action: onRemove)
                        .glassButtonStyle()
                        .accessibilityIdentifier("photo-remove-button")
                }
            }
        }
        // The backdrop is black whatever the device is set to, so this subtree
        // has to be told which scheme it is being read against — the same
        // thing the navigation bar is told in the viewer above, and for the
        // same reason: without it the title and the description are black on
        // black.
        .environment(\.colorScheme, .dark)
    }

    /// Whether `display` means there is a file on this device behind the row.
    ///
    /// ``PhotoUnavailability/unreadable`` counts, and deliberately: the file is
    /// there, the share sheet copies it without decoding it, and the hiker
    /// sending their own damaged file somewhere it may still be recoverable is
    /// a reasonable thing to let them do. The other two states have no file at
    /// all — one on another device, one that was never a photograph — and
    /// nothing to hand over.
    private static func hasFile(_ display: PhotoDisplay) -> Bool {
        switch display {
        case .ready, .unavailable(.unreadable): true
        case .loading, .unavailable(.notOnThisDevice), .unavailable(.placeOnly): false
        }
    }

    private static let recoverySpacing: CGFloat = 16

    /// What a page's load is keyed on: the photo, and how many times the user
    /// has asked for it again.
    ///
    /// `.task(id:)` restarts on any change to this, which is what makes retry
    /// a bump of one integer rather than a second path into the loader.
    private struct Attempt: Hashable {
        let photo: UUID
        let count: Int
    }

    /// VoiceOver cannot describe a photograph, so it gets what the app does
    /// know about it: when it was taken, and whether it has a place on the
    /// trail.
    private static func label(for photo: HikePhoto) -> String {
        let taken = HikeFormat.timestamp(photo.capturedAt)
        return photo.isAnchored
            ? String(localized: "Photo taken \(taken), pinned to the trail")
            : String(localized: "Photo taken \(taken)")
    }
}

extension ScrollTargetBehavior where Self == ViewAlignedScrollTargetBehavior {
    /// One photograph per swipe, snapped to the page's own frame.
    ///
    /// Not `.paging`, which steps by a page size of its own reckoning rather
    /// than by the pages' width — and in landscape the two disagree. There the
    /// scroll view spans the 874-point window with the 62-point safe-area
    /// insets as content insets, so a `containerRelativeFrame` page is 750
    /// points wide, and `.paging` stepped 781: measured on an iPhone 18 Pro,
    /// each swipe landed 31 points further left than the last, until the
    /// clamp at the end of the content put the final page back in the middle.
    /// Portrait has no side insets, which is why it never showed there.
    /// View-aligned snapping asks the pages where they are, so no inset can
    /// put the two out of step.
    static var photoPages: Self { .viewAligned(limitBehavior: .alwaysByOne) }
}
