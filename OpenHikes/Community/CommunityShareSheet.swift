//
//  CommunityShareSheet.swift
//  OpenHikes
//
//  What the share button opens: the one screen where a hiker decides to make
//  a private walk public.
//
//  It is a form rather than a confirmation alert, and the difference is the
//  point. Publishing a hike hands over a route somebody walked, the
//  photographs they took on it, and a name to put beside both — and an alert
//  with "Share" and "Cancel" would be asking for that without ever showing it.
//  So the screen says what goes, says what happens next, and asks for the name
//  in the same breath.
//
//  What it must not say is that the hike is now visible. It is not. A
//  submission waits for a person to review it, and this app cannot find out
//  whether one has — see ``Hike/communitySubmissionID``. The success state
//  therefore says *sent*, which is the only thing that is true.
//

import SwiftUI

struct CommunityShareSheet: View {
    /// Where the sheet is in the one-way trip from form to outcome.
    private enum Phase: Equatable {
        case editing
        case failed(CommunityFailure)
        case sending
        case sent
    }

    let hike: Hike
    let transport: any CommunityTransporting
    /// The Pro unlock, observed rather than snapshotted, so a subscription
    /// that lapses while this form is open is refused by the Share button
    /// rather than by the upload. ``HikeDetailView`` holds it for the same
    /// reason — a snapshot that cannot invalidate a body is a snapshot that
    /// lets a lapsed subscription start work against a paid resource.
    let entitlement: MapEntitlementStore
    /// Where the photo files are, so the form can ask which of this hike's
    /// pictures this device actually holds. Injected rather than reached for,
    /// like every other store this app hands a view.
    var store: HikePhotoStore = .shared

    @Environment(\.dismiss)
    private var dismiss
    @AppStorage(SettingsKey.communityAuthorName)
    private var authorName = ""
    @State private var phase: Phase = .editing
    /// How many photographs this device can send, once the disk has been
    /// asked. `nil` until then — see ``photoCount``.
    @State private var sendablePhotoCount: Int?

    /// Where this hike already is on the way to being published, which decides
    /// whether the form warns about making a second copy of it.
    private var publication: CommunityPublicationState {
        CommunityPublicationState(
            submissionID: hike.communitySubmissionID,
            listingID: hike.communityListingID
        )
    }

    /// The photographs this share would actually carry, worked out once here
    /// rather than described twice — the cap is ``CommunityPublisher``'s, and
    /// a screen that quoted its own number would eventually quote a stale one.
    ///
    /// Rows are not files. A photo row mirrors between a hiker's devices and
    /// its pixels never do, so the iPad shows a full strip for a walk recorded
    /// on the phone and can send none of it — and the upload drops exactly
    /// those, silently. Until the disk has answered, the capped row count is
    /// the best guess available; after that this is the number that will
    /// really go.
    private var photoCount: Int {
        sendablePhotoCount ?? min(hike.photos.count, CommunityPublisher.maximumPhotos)
    }

    /// How many of this hike's pictures are on another device, and so are not
    /// going anywhere from here.
    private var unsendablePhotoCount: Int {
        guard let sendablePhotoCount else { return 0 }
        return min(hike.photos.count, CommunityPublisher.maximumPhotos) - sendablePhotoCount
    }

    /// What to say about the pictures that are staying behind.
    ///
    /// Number-neutral after the count, like the disclosure sentence: one
    /// photograph reads as written English rather than as a template with a 1
    /// in it.
    private var photosOnAnotherDevice: String {
        unsendablePhotoCount == 1
            ? String(
                localized: """
                One of this hike's photos is on the device it was added on, \
                so it can't be shared from here.
                """
            )
            : String(
                localized: """
                \(unsendablePhotoCount) of this hike's photos are on the device \
                they were added on, so they can't be shared from here.
                """
            )
    }

    private var trimmedAuthorName: String {
        authorName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The hike's description, if it has one worth showing.
    ///
    /// Shown rather than merely mentioned, because this is the field a hiker
    /// is least likely to remember the contents of: a hike imported from a GPX
    /// file carries whatever its author wrote in it, which can be personal
    /// notes nothing in this app has displayed since the import. It goes to
    /// the public database either way — see ``CommunityPublisher/share``, which
    /// copies `trackDescription` into the draft — so the only question is
    /// whether the hiker sees it before or after it is published.
    private var sharedDescription: String? {
        CommunityShareDisclosure.notes(from: hike.trackDescription)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .sent:
                    sentSection
                default:
                    duplicateSection
                    contentsSection
                    nameSection
                    reviewSection
                    if case .failed(let failure) = phase {
                        failureSection(failure)
                    }
                }
            }
            .navigationTitle("Share Hike")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .interactiveDismissDisabled(phase == .sending)
            // Asked once, when the form opens: the answer is about files on
            // this device, and nothing can add one to this hike while this
            // sheet is the screen on top.
            .task {
                sendablePhotoCount = await CommunityPublisher.sendablePhotoCount(
                    of: hike,
                    store: store
                )
            }
        }
    }
}

// MARK: - Sections

private extension CommunityShareSheet {
    var contentsSection: some View {
        Section {
            LabeledContent("Hike", value: hike.displayTitle)
            LabeledContent("Route", value: hike.subtitle)
            if let sharedDescription {
                // Multi-line and not truncated to a line: the point of showing
                // it is that the hiker can read what is about to be published
                // under their name, and half of a sentence would not serve
                // that.
                LabeledContent("Notes") {
                    Text(sharedDescription)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityIdentifier("community-share-notes")
            }
            LabeledContent(
                "Photos",
                value: photoCount == 0 ? "None" : "\(photoCount)"
            )
            if unsendablePhotoCount > 0 {
                // Said here rather than left to the footer, because it is
                // about the row directly above it: the number there is
                // smaller than the strip on the hike screen, and a hiker who
                // is not told why will read it as the app having lost their
                // pictures.
                //
                // Same shape as everywhere else a photo's pixels are missing
                // — see ``PhotoUnavailability/notOnThisDevice``, which the
                // gallery, the map callout and the viewer all speak through.
                Label {
                    Text(photosOnAnotherDevice)
                } icon: {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("community-share-photos-elsewhere")
            }
        } header: {
            Text("What gets shared")
        } footer: {
            // Said plainly because it is the one surprise in the feature: a
            // hiker who has not thought about it assumes a shared trail is a
            // line on a map, and the photographs are the part they would want
            // to have been asked about.
            //
            // It has to be *complete* as well as plain, which is the harder
            // half. A submission carries the description and the date shown
            // above, and the route it carries is the recorded one — every
            // point with the time it was reached, so the pace of the walk goes
            // with the line. Saying "nothing else from this hike" while
            // sending those was a promise the upload did not keep.
            Text(
                CommunityShareDisclosure.text(
                    hasNotes: sharedDescription != nil,
                    photoCount: photoCount
                )
            )
        }
    }

    var nameSection: some View {
        Section {
            TextField("Name", text: $authorName)
                .accessibilityIdentifier("community-author-field")
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .disabled(phase == .sending)
        } header: {
            Text("Shared as")
        } footer: {
            Text("Shown next to your hike. Leave it blank to share without a name.")
        }
    }

    var reviewSection: some View {
        Section {
            Label {
                Text("Every community hike is checked by a person before anyone else can see it.")
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
        }
    }

    /// Shown only for a hike that has already been sent, which the share
    /// button normally keeps out of here — it is disabled while a submission
    /// is waiting. What reaches this is the published case, where sharing
    /// again is a legitimate thing to want (it is the only way to publish an
    /// amended route) and also the one way to end up with two of the same walk
    /// in the list.
    ///
    /// A warning rather than a refusal, because the app cannot tell an
    /// accidental second tap from a deliberate re-share of a corrected
    /// route — and it cannot offer the thing that would make the choice
    /// unnecessary, since ``CommunityTransporting`` has no method to replace
    /// or withdraw a submission. So it says exactly what will happen and lets
    /// the hiker decide.
    @ViewBuilder var duplicateSection: some View {
        if publication.wouldDuplicate {
            Section {
                Label {
                    Text(
                        """
                        You've already shared this hike. Sending it again adds a \
                        second copy for other hikers — it doesn't replace or update \
                        the first, and this app can't take that one down. Ask for it \
                        to be removed by reporting it from its own screen.
                        """
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
                .accessibilityIdentifier("community-share-duplicate")
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
            .accessibilityIdentifier("community-share-failure")
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
                Text("It'll appear for other hikers once it's been checked.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-share-sent")
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
                Button("Share") { share() }
                    .accessibilityIdentifier("community-share-confirm")
                    // The second half is the lapse case. This form is only
                    // reachable while the subscription is current, but it can
                    // outlive one — a renewal that fails while it is open — and
                    // a live button would send the hiker through an upload that
                    // ``CommunityPublisher/share`` is going to refuse anyway.
                    .disabled(hike.pointCount < 2 || entitlement.state.publishTap != .allow)
            }
        }
    }
}

// MARK: - Sharing

private extension CommunityShareSheet {
    func share() {
        phase = .sending
        Task {
            let outcome = await CommunityPublisher.share(
                hike,
                authorName: trimmedAuthorName,
                entitlement: entitlement.state,
                transport: transport
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

// MARK: - What the footer promises

/// The sentence under *What gets shared*, worked out apart from the view that
/// draws it.
///
/// Its own type so a suite can hold it against what ``CommunityPublisher``
/// actually uploads. That is the only way this stays true: the promise and the
/// payload are written in two different files, and the first version of this
/// screen said "nothing else from this hike" while the upload carried the
/// description, the date and a timestamp on every point of the route. A
/// wording that cannot be tested is a wording that drifts the next time a
/// field is added to ``CommunitySubmissionDraft``.
nonisolated enum CommunityShareDisclosure {
    /// The description a share would publish, or `nil` for a hike whose
    /// description is absent or blank.
    ///
    /// Here rather than in the view so that the row showing it and the
    /// sentence promising it cannot disagree about what counts as having one
    /// — and so a suite can ask the same question of a draft.
    static func notes(from trackDescription: String?) -> String? {
        guard let notes = trackDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !notes.isEmpty
        else { return nil }
        return notes
    }

    /// - Parameters:
    ///   - hasNotes: Whether the hike has a description, which is uploaded and
    ///     shown publicly — see ``CommunityShareSheet``'s `sharedDescription`.
    ///   - photoCount: How many photographs this share would carry, already
    ///     capped at ``CommunityPublisher/maximumPhotos``.
    static func text(hasNotes: Bool, photoCount: Int) -> String {
        // Assembled rather than written out four times: notes and photographs
        // are each present or not, and four separate spellings is how one of
        // them ends up describing an upload that has moved on.
        var sentences = [
            """
            Your route — each point on it with the time you reached it — \
            its name, its length and the date you walked it.
            """,
        ]
        if hasNotes {
            sentences.append("The notes above go with it.")
        }
        if photoCount > 0 {
            // Number-neutral after the count, so one photograph reads as
            // written English rather than as a template with a 1 in it.
            let photos = photoCount == 1
                ? "One photo goes with it, with the spot on the trail it was taken at"
                : "\(photoCount) photos go with it, each with the spot on the trail it was taken at"
            sentences.append(
                """
                \(photos) — resized before sending, with camera details and original \
                location data removed.
                """
            )
        }
        sentences.append("Nothing else from this hike.")
        return sentences.joined(separator: " ")
    }
}
