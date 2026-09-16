//
//  CommunityPhotoShareSheet.swift
//  OpenHikes
//
//  What the publish button opens when the trail is already in the list: the
//  screen where a hiker decides to put their photographs on somebody else's
//  walk.
//
//  ## Why this is not the share form with rows hidden
//
//  ``CommunityShareSheet`` asks for a title, notes and a credit, warns about a
//  route that starts at a front door, and promises what a whole hike carries.
//  Here **none of that is being sent**. The route stays on this device, the
//  title belongs to whoever published the trail, and the notes describe a walk
//  that already has a description. A form with four of its six rows greyed out
//  would be the app pretending to still be considering them — the same
//  argument the refusal section already makes one screen over, where a refusal
//  *replaces* the form rather than sitting above it.
//
//  What the two screens do share is the strip — see
//  ``CommunitySharePhotoStrip`` — because striking a photograph off means
//  exactly the same thing in both, and the publisher behind them applies the
//  exclusion the same way.
//
//  ## What this screen has to say that the other does not
//
//  **Where they are going.** A contribution is the one thing this app
//  publishes that lands on somebody else's record, so the trail is named at
//  the top and the reason the route is staying behind is kept underneath it.
//  Naming it is also the only defence against the one mistake this flow can
//  make: a hiker who imported the wrong trail and photographed a different
//  one.
//
//  **That the pictures are the whole of it.** The disclosure below is
//  ``CommunityShareDisclosure``'s sibling and is held to the same standard —
//  it is a separate type from this view for the reason that one is, and
//  `CommunityPhotoDisclosureTests` asserts its wording against a real draft,
//  so a field added to ``CommunityPhotoDraft`` that nobody discloses fails a
//  test rather than shipping.
//
//  **That nothing has happened yet.** The success state says *sent*, which is
//  the only thing true at the moment an upload lands. Whether a reviewer said
//  yes is asked later and elsewhere — see ``CommunityContributionCheck``.
//

import SwiftData
import SwiftUI

struct CommunityPhotoShareSheet: View {
    /// Where the sheet is in the one-way trip from form to outcome.
    private enum Phase: Equatable {
        case editing
        case failed(CommunityFailure)
        case sending
        case sent
    }

    let hike: Hike
    /// The trail the photographs go on. Handed in rather than worked out here,
    /// because working it out is ``CommunityPublishingCheck``'s job and this
    /// screen must not be able to reach a second opinion about it.
    let target: CommunityPhotoTarget
    let transport: any CommunityTransporting
    /// Where the photo files are, so the form can ask which of this hike's
    /// pictures this device actually holds.
    var store: HikePhotoStore = .shared

    @Environment(\.dismiss)
    private var dismiss
    @AppStorage(SettingsKey.communityAuthorName)
    private var authorName = ""
    @State private var phase: Phase = .editing
    /// The photographs struck off the strip, by id.
    @State private var excludedPhotoIDs: Set<UUID> = []
    /// How many photographs this device can send, once the disk has been
    /// asked. `nil` until then — see ``photoCount``.
    @State private var sendablePhotoCount: Int?

    /// Where these photographs already are on the way to being published,
    /// which decides whether the form warns about adding a second set.
    private var contribution: CommunityContributionState {
        CommunityContributionState(
            submissionID: hike.communityPhotoSubmissionID,
            contributionID: hike.communityPhotoContributionID
        )
    }

    /// The photographs this send would actually carry.
    ///
    /// Rows are not files, the distinction ``CommunityShareSheet`` draws for
    /// the same number and for the same reason: a photo row mirrors between a
    /// hiker's devices and its pixels never do, so the iPad shows a full strip
    /// for a walk recorded on the phone and can send none of it.
    private var photoCount: Int {
        sendablePhotoCount ?? min(includedPhotoCount, CommunityPublisher.maximumPhotos)
    }

    private var includedPhotoCount: Int {
        hike.photos.count(where: { !excludedPhotoIDs.contains($0.id) })
    }

    /// How many of this hike's pictures are on another device.
    private var unsendablePhotoCount: Int {
        guard let sendablePhotoCount else { return 0 }
        return min(includedPhotoCount, CommunityPublisher.maximumPhotos) - sendablePhotoCount
    }

    /// The name this contribution is credited to, bounded the way every other
    /// piece of free text reaching the public database is.
    private var boundedAuthorName: String {
        BoundedText.boundedOrEmpty(authorName, to: .credit)
    }

    /// Whether there is anything to send at all.
    ///
    /// Asked of the *files* once the disk has answered, and of the rows before
    /// then. A hike somebody saved and has not photographed yet reaches this
    /// screen perfectly legitimately — it is the ordinary state of a trail
    /// waiting to be walked — so the empty case is a sentence rather than a
    /// failure. See ``CommunityFailure/noPhotosToShare``.
    private var hasSomethingToSend: Bool { photoCount > 0 }

    var body: some View {
        NavigationStack {
            Form { formContent }
                .navigationTitle("Add Photos")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
                .interactiveDismissDisabled(phase == .sending)
                // Re-asked whenever the hiker strikes a photograph off or puts
                // one back, because the answer is about a particular set of
                // files: the count has to be what will really go, and the cap
                // means taking one out can let another in.
                .task(id: excludedPhotoIDs) {
                    sendablePhotoCount = await CommunityPublisher.sendablePhotoCount(
                        of: hike,
                        excludingPhotos: excludedPhotoIDs,
                        store: store
                    )
                }
        }
    }

    @ViewBuilder private var formContent: some View {
        switch phase {
        case .sent:
            sentSection
        default:
            targetSection
            contentsSection
            if contribution.wouldDuplicate {
                duplicateSection
            }
            nameSection
            reviewSection
            if case .failed(let failure) = phase {
                failureSection(failure)
            }
        }
    }
}

// MARK: - Sections

private extension CommunityPhotoShareSheet {
    /// Which trail these are going on, and why the walk itself is not.
    ///
    /// The headline is the trail's name rather than the reason's, because the
    /// hiker is here to do something and the thing they are about to do has a
    /// subject. The reason follows as the footer — it is context now rather
    /// than a verdict, which is the whole difference between this screen and
    /// the refusal it replaced.
    var targetSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.title)
                        .font(.callout.weight(.medium))
                    Text(Self.destination(target))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: target.isCurated ? "map" : "person.2")
                    .foregroundStyle(.tint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-photos-target")
        } header: {
            Text("Adding to")
        } footer: {
            if let reason = Self.reason(for: hike) {
                Text(reason.explanation())
                    .accessibilityIdentifier("community-photos-reason")
            }
        }
    }

    /// What is going, and what is not.
    var contentsSection: some View {
        Section {
            LabeledContent(
                "Photos",
                value: photoCount == 0 ? "None" : "\(photoCount)"
            )
            // One element with an explicit value, rather than the pair
            // `LabeledContent` composes on its own — an identifier on a
            // container is pushed down onto every descendant. The lesson
            // ``CommunityPhotoViewer`` taught, applied here for the same
            // reason.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photos")
            .accessibilityValue(photoCount == 0 ? "None" : "\(photoCount)")
            .accessibilityIdentifier("community-photos-count")
            CommunitySharePhotoStrip(
                photos: CommunityPublisher.shareablePhotos(of: hike),
                excluded: $excludedPhotoIDs,
                store: store,
                isSending: phase == .sending
            )
            if unsendablePhotoCount > 0 {
                Text(Self.photosOnAnotherDevice(count: unsendablePhotoCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("community-photos-unsendable")
            }
        } header: {
            Text("What gets added")
        } footer: {
            Text(
                CommunityPhotoDisclosure.text(
                    photoCount: photoCount,
                    trailTitle: target.title
                )
            )
        }
    }

    /// Shown only when photographs from this hike have already been sent.
    ///
    /// A warning rather than a refusal, for the reason
    /// ``CommunityShareSheet``'s duplicate warning is one: the app cannot
    /// replace or withdraw a photo submission, so a second send is a second set
    /// beside the first — which is a perfectly good thing to want, since it is
    /// the only way to add the pictures from today's walk to a trail somebody
    /// contributed to in the spring.
    var duplicateSection: some View {
        Section {
            Label {
                Text(
                    """
                    You've already added photos from this hike. Sending again adds a \
                    second set beside the first — it doesn't replace it, and this app \
                    can't take that one down. Ask for it to be removed from this hike's \
                    own screen.
                    """
                )
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.footnote)
            .accessibilityIdentifier("community-photos-duplicate")
        }
    }

    /// What the photographs are credited to.
    ///
    /// The same ``SettingsKey/communityAuthorName`` a shared hike is published
    /// under, and deliberately the same field: it is one person's one credit,
    /// and two settings for it would let somebody be two people by accident.
    /// It matters more here than there — these pictures sit among a stranger's
    /// on a screen headed with the stranger's name, so the credit is the only
    /// thing saying whose they are.
    var nameSection: some View {
        Section {
            TextField("Display name", text: $authorName)
                .accessibilityIdentifier("community-photos-author-field")
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .disabled(phase == .sending)
        } header: {
            Text("Shared as")
        } footer: {
            Text("""
            Shown publicly beside your photos, so other hikers can tell them from \
            the ones whoever shared this trail took. You can leave it blank.
            """)
        }
    }

    /// That a person looks at these first, and what sending them agrees to.
    ///
    /// The terms are linked here for the reason they are linked on the share
    /// form: they are the rules this screen is an entry point to, and a page
    /// nobody can reach from the screen it governs is a page nobody has agreed
    /// to. One rule of the four is doing most of the work here — *publish only
    /// what is yours to publish* — because the whole point of this screen is
    /// that the walk is somebody else's and the pictures are not.
    var reviewSection: some View {
        Section {
            Label {
                Text("Every photo is checked by a person before anyone else can see it.")
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                Add photos you took yourself, on this trail. A photo taken at your \
                front door shows where you live.
                """)
                Link(destination: MapPurchaseLinks.termsAndConditions) {
                    Text("By adding photos, you agree to the Terms & Conditions.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityIdentifier("community-photos-terms-link")
            }
        }
    }

    func failureSection(_ failure: CommunityFailure) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.localizedDescription)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                if let suggestion = failure.recoverySuggestion {
                    Text(suggestion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-photos-failure")
        }
    }

    var sentSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Sent for review")
                    .font(.headline)
                Text("They'll appear on this trail once they've been checked.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-photos-sent")
        }
    }

    @ToolbarContentBuilder var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(phase == .sent ? "Done" : "Cancel") { dismiss() }
                .disabled(phase == .sending)
        }
        ToolbarItem(placement: .confirmationAction) {
            if phase == .sending {
                ProgressView()
                    .accessibilityLabel("Sending")
            } else if phase != .sent {
                Button("Add") { send() }
                    .accessibilityIdentifier("community-photos-confirm")
                    // The same floor ``CommunityPhotoPublisher/contribute``
                    // refuses below, so a hike with nothing to send cannot
                    // start an upload that was always going to come back as a
                    // failure. Held while the disk has not answered, which is
                    // the one window a tap could start a send the next line of
                    // this screen is about to forbid.
                    .disabled(!hasSomethingToSend || sendablePhotoCount == nil)
            }
        }
    }
}

// MARK: - Sending

private extension CommunityPhotoShareSheet {
    func send() {
        phase = .sending
        Task {
            let outcome = await CommunityPhotoPublisher.contribute(
                hike,
                to: target,
                authorName: boundedAuthorName,
                transport: transport,
                excludingPhotos: excludedPhotoIDs,
                store: store
            )
            switch outcome {
            case .submitted:
                phase = .sent
            case .refused(let failure):
                phase = .failed(failure)
            }
        }
    }
}

// MARK: - What the screen says

private extension CommunityPhotoShareSheet {
    /// Where the photographs are going, in one line under the trail's name.
    static func destination(_ target: CommunityPhotoTarget) -> String {
        if target.isCurated {
            return String(localized: "A trail from OpenStreetMap, which has no photos of its own.")
        }
        guard let author = target.authorName else {
            return String(localized: "A trail already in the community list.")
        }
        return String(localized: "Shared by \(author).")
    }

    /// Why the route is staying behind, read off the hike the same way the
    /// button that opened this screen read it.
    ///
    /// Re-derived rather than carried on ``CommunityPhotoTarget``, because it
    /// is a sentence about the hike rather than about the target — and a
    /// target that carried its own copy would be a second place for the two to
    /// disagree.
    static func reason(for hike: Hike) -> CommunityPublishingEligibility.Reason? {
        CommunityPublishingEligibility.of(
            importedFromListingID: hike.importedFromListingID,
            importedAuthorName: hike.importedAuthorName,
            distanceMeters: hike.distanceMeters,
            title: hike.displayTitle
        ).reason
    }

    /// What to say about the pictures that are staying behind.
    ///
    /// Number-neutral after the count, the rule the rest of this feature's
    /// wording follows: one photograph reads as written English rather than as
    /// a template with a 1 in it.
    static func photosOnAnotherDevice(count: Int) -> String {
        count == 1
            ? String(
                localized: """
                One of this hike's photos is on the device it was added on, \
                so it can't be shared from here.
                """
            )
            : String(
                localized: """
                \(count) of this hike's photos are on the device they were \
                added on, so they can't be shared from here.
                """
            )
    }
}

// MARK: - What the footer promises

/// The sentence under *What gets added*, worked out apart from the view that
/// draws it.
///
/// ``CommunityShareDisclosure``'s sibling, its own type for the same reason:
/// the promise and the payload are written in different files, and a wording
/// that cannot be tested is a wording that drifts the next time a field is
/// added to ``CommunityPhotoDraft``.
///
/// The sentence it has to keep is the short one at the end. A contribution
/// carries the pictures, where each was taken and when — and **not** the
/// route, the walk's name, its length, its date or the notes, every one of
/// which the hike share does carry. That asymmetry is the feature, so it is
/// the thing the footer says out loud.
nonisolated enum CommunityPhotoDisclosure {
    static func text(photoCount: Int, trailTitle: String) -> String {
        guard photoCount > 0 else {
            return String(
                localized: """
                Nothing yet. Add photos to this hike and they can go on \(trailTitle) \
                for other hikers to see.
                """
            )
        }
        // Number-neutral after the count, like every other sentence in this
        // feature that quotes one.
        let photos = photoCount == 1
            ? String(
                localized: """
                One photo goes on \(trailTitle), with the spot on the trail and the \
                time it was taken at
                """
            )
            : String(
                localized: """
                \(photoCount) photos go on \(trailTitle), each with the spot on the \
                trail and the time it was taken at
                """
            )
        return String(
            localized: """
            \(photos) — resized before sending, with camera details and original \
            location data removed. Your route, your notes and this walk's name stay \
            on your device.
            """
        )
    }
}
