//
//  CommunityShareSheet.swift
//  OpenHikes
//
//  What the share button opens: the one screen where a walker decides to make
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

    @Environment(\.dismiss)
    private var dismiss
    @AppStorage(SettingsKey.communityAuthorName)
    private var authorName = ""
    @State private var phase: Phase = .editing

    /// The photographs this share would actually carry, worked out once here
    /// rather than described twice — the cap is ``CommunityPublisher``'s, and
    /// a screen that quoted its own number would eventually quote a stale one.
    private var photoCount: Int {
        min(hike.photos.count, CommunityPublisher.maximumPhotos)
    }

    private var trimmedAuthorName: String {
        authorName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The hike's description, if it has one worth showing.
    ///
    /// Shown rather than merely mentioned, because this is the field a walker
    /// is least likely to remember the contents of: a hike imported from a GPX
    /// file carries whatever its author wrote in it, which can be personal
    /// notes nothing in this app has displayed since the import. It goes to
    /// the public database either way — see ``CommunityPublisher/share``, which
    /// copies `trackDescription` into the draft — so the only question is
    /// whether the walker sees it before or after it is published.
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
                // it is that the walker can read what is about to be published
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
        } header: {
            Text("What gets shared")
        } footer: {
            // Said plainly because it is the one surprise in the feature: a
            // walker who has not thought about it assumes a shared trail is a
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
                Text("Every shared hike is checked by a person before anyone else can see it.")
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
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
                Text("It'll appear for other walkers once it's been checked.")
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
                authorName: trimmedAuthorName,
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
