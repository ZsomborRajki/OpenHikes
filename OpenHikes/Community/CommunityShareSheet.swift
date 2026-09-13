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
//  What it must not say is that the hike is now visible. It is not: a
//  submission waits for a person to review it, and at the moment the upload
//  lands nothing has happened beyond that. The success state therefore says
//  *sent*, which is the only thing true then.
//
//  Later is a different question, and the hike's own screen asks it rather
//  than this one — ``CommunityPublicationCheck`` looks for a listing published
//  from the submission and remembers a yes. That is the single thing the app
//  can observe: a reviewer who has not looked and one who declined leave the
//  same absence behind. See ``CommunityPublicationState``.
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

    /// The name this share is published under.
    ///
    /// Bounded and not merely trimmed, which is ``HikeTitle``'s rule applied
    /// to the other piece of free text a person types into this app — and the
    /// one that goes furthest, since it is written to a record in the public
    /// database and drawn in every other hiker's list. See ``TextBound/credit``.
    private var boundedAuthorName: String {
        BoundedText.boundedOrEmpty(authorName, to: .credit)
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

    /// What the hike is credited to, asked for as the display name it is.
    ///
    /// It used to be labelled "Name", which left the hiker to decide whether
    /// they were being asked for the name on their Apple Account. Nothing in
    /// this app ever wanted that — ``CommunityListing/authorName`` has said
    /// "a credit and not an identity" since it was written, blank has always
    /// been allowed, and what it sits beside is a walk rather than a profile.
    /// The field now says so, which is also what settles how it is declared:
    /// Apple's definitions put a handle under `NSPrivacyCollectedDataTypeUserID`
    /// and a person's name under Contact Info. See `PrivacyInfo.xcprivacy`.
    ///
    /// Still capitalised by word. A display name is far more often "Anna" or
    /// "Ridge Walker" than a lowercase handle, and a keyboard can be overruled
    /// where a wrong guess about what is being asked for cannot be.
    var nameSection: some View {
        Section {
            TextField("Display name", text: $authorName)
                .accessibilityIdentifier("community-author-field")
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .disabled(phase == .sending)
        } header: {
            Text("Shared as")
        } footer: {
            Text("""
            Shown publicly next to your hike. It doesn't have to be your real \
            name, and you can leave it blank to share without one.
            """)
        }
    }

    /// The two things a hiker should know before the Share button, in the
    /// order they matter: that a person looks at this first, and what they are
    /// agreeing to by sending it.
    ///
    /// The terms were published from the day Community shipped and linked from
    /// nowhere in the app. That is the gap this closes. They are not boilerplate
    /// about a subscription — they are the rules this screen is the entry point
    /// to: that a hiker may publish only what is theirs to publish, that
    /// publishing grants a licence to show it inside the app, that a route
    /// starting at their front door says where they live, and how to have a
    /// hike taken down afterwards. A page nobody can reach from the screen it
    /// governs is a page nobody has agreed to.
    ///
    /// Stated beside Share rather than gated behind a checkbox. Apple mandates
    /// no particular control here, an unticked box on a form with one action is
    /// a tap spent on a sentence the hiker has already read, and what makes
    /// consent mean anything is that the rules were in front of them and
    /// reachable — which a `Link` is and a modal they have to dismiss is not.
    var reviewSection: some View {
        Section {
            Label {
                Text("Every community hike is checked by a person before anyone else can see it.")
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                Share only a route, photos and notes that are yours to publish. A hike that \
                starts at your front door shows where you live.
                """)
                Link(destination: MapPurchaseLinks.termsAndConditions) {
                    Text("By sharing, you agree to the Terms & Conditions.")
                }
                .accessibilityIdentifier("community-terms-link")
            }
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
                    // The same floor ``CommunityPublisher/share`` refuses
                    // below, so a hike with no route cannot start an upload
                    // that was always going to come back as a failure.
                    .disabled(hike.pointCount < 2)
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
                authorName: boundedAuthorName,
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
            // The time as well as the place, because a pin is both. The
            // sentence used to name only the coordinate while
            // ``CommunityPhotoPin`` carried `capturedAt` too — uploaded in the
            // pins asset, where the re-encode that strips EXIF never reaches
            // it — so the reassurance that followed read as a promise in the
            // other direction. *Taken* is the word the rest of the app already
            // uses for that timestamp: see `PhotoDiscoverySheet` and
            // ``HikePhotoViewer``.
            //
            // Number-neutral after the count, so one photograph reads as
            // written English rather than as a template with a 1 in it.
            let photos = photoCount == 1
                ? "One photo goes with it, with the spot on the trail and the time it was taken at"
                : """
                \(photoCount) photos go with it, each with the spot on the trail \
                and the time it was taken at
                """
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
