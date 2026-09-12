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
            Text(
                photoCount == 0
                    ? "Your route and its name. Nothing else from this hike."
                    : """
                    Your route, its name, and \(photoCount == 1 ? "1 photo" : "\(photoCount) photos") \
                    with the spot on the trail each was taken at. \
                    Photos are resized before they're sent, and their camera details and original \
                    location data are removed.
                    """
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
