//
//  CommunitySendFormViews.swift
//  OpenHikes
//
//  The parts both send forms draw the same way.
//
//  ``CommunityShareSheet`` and ``CommunityPhotoShareSheet`` are deliberately
//  different screens — one hands over a route and the other adds pictures to
//  somebody else's — and most of what they contain is their own. Four things
//  are not, and all four are places where two spellings would be a bug rather
//  than an inconsistency:
//
//  **The credit.** Both publish under the same
//  ``SettingsKey/communityAuthorName``, on purpose: it is one person's one
//  credit, and two settings for it would let somebody be two people by
//  accident. A field that capitalised differently, or bounded differently, on
//  the two screens would be one setting behaving like two.
//
//  **The photo count.** It is the same question about the same files on the
//  same disk — see ``CommunitySharePhotoTally``, which both forms already
//  share — and the row that reports it carries an accessibility fix that has
//  to travel with it.
//
//  **The terms.** Both end on the same promise — a person checks what is sent
//  before anyone else sees it — and the same link to the rules sending it
//  agrees to, which carries an alignment fix of its own. What each form says
//  its rules are is its own.
//
//  **The toolbar.** *Cancel* becomes *Done* once a send has landed, the
//  confirmation is replaced by a spinner while one is in flight, and neither
//  is available afterwards. Those are rules about a send rather than about
//  either screen.
//
//  What stays with the forms is everything a hiker would notice the difference
//  in: the wording under each field, the identifiers, what the confirm button
//  is called, and when it is allowed to be pressed.
//

import SwiftUI

/// The display name a send is published under.
///
/// Bounded and not merely trimmed, which is ``HikeTitle``'s rule applied to the
/// other piece of free text a person types into this app — and the one that
/// goes furthest, since it is written to a record in the public database and
/// drawn in every other hiker's list. See ``TextBound/credit``.
///
/// Still capitalised by word. A display name is far more often "Anna" or
/// "Ridge Walker" than a lowercase handle, and a keyboard can be overruled
/// where a wrong guess about what is being asked for cannot be.
///
/// It used to be labelled "Name", which left the hiker to decide whether they
/// were being asked for the name on their Apple Account. Nothing in this app
/// ever wanted that — ``CommunityListing/authorName`` has said "a credit and
/// not an identity" since it was written, blank has always been allowed, and
/// what it sits beside is a walk rather than a profile. That is also what
/// settles how it is declared: Apple's definitions put a handle under
/// `NSPrivacyCollectedDataTypeUserID` and a person's name under Contact Info.
/// See `PrivacyInfo.xcprivacy`.
struct CommunityCreditSection: View {
    @Binding var authorName: String
    /// What this screen says the name will be shown beside, which is the one
    /// part of the section that is genuinely per-form.
    let footer: String
    let identifier: String
    let phase: CommunitySendPhase

    var body: some View {
        Section {
            TextField("Display name", text: $authorName)
                .accessibilityIdentifier(identifier)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .disabled(phase.isSending)
        } header: {
            Text("Shared as")
        } footer: {
            Text(footer)
        }
    }
}

/// How many photographs this send would carry.
struct CommunitySendPhotoCountRow: View {
    let count: Int
    let identifier: String

    var body: some View {
        LabeledContent("Photos", value: spoken)
            // One element with an explicit value, rather than the pair
            // `LabeledContent` composes on its own. An identifier on a
            // container is pushed down onto every descendant, so without this
            // the name matches the "Photos" caption first and a reader asking
            // for the row's value gets nothing — see ``CommunityPhotoViewer``
            // for where that lesson was learned.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photos")
            .accessibilityValue(spoken)
            .accessibilityIdentifier(identifier)
    }

    private var spoken: String { count == 0 ? "None" : "\(count)" }
}

/// The two toolbar items a send form has, in the states a send puts them in.
///
/// The cancel action is handed in rather than assumed to be `dismiss()`:
/// ``CommunityShareSheet`` commits the title and the notes on the way out, and
/// this is the one exit it can rely on — a sheet's content is not guaranteed
/// to be torn down when it is dismissed, so `onDisappear` is a hook that
/// sometimes runs rather than a commit point.
struct CommunitySendToolbar: ToolbarContent {
    let phase: CommunitySendPhase
    /// What the confirmation button is called — *Share* for a hike, *Add* for
    /// photographs.
    let confirmTitle: LocalizedStringKey
    let confirmIdentifier: String
    /// Whether the confirmation may be pressed at all. Each form has its own
    /// floor and its own window in which the answer is not yet known; see the
    /// call sites.
    let canConfirm: Bool
    /// Whether the confirmation is offered at all. A refusal takes it away
    /// outright rather than dimming it.
    let offersConfirmation: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(phase.hasFinished ? "Done" : "Cancel", action: cancel)
                .disabled(phase.isSending)
        }
        ToolbarItem(placement: .confirmationAction) {
            if phase.isSending {
                ProgressView()
                    .accessibilityLabel("Sending")
            } else if !phase.hasFinished, offersConfirmation {
                Button(confirmTitle, action: confirm)
                    .accessibilityIdentifier(confirmIdentifier)
                    .disabled(!canConfirm)
            }
        }
    }
}

/// That a person looks at what is sent before anyone else can see it, the
/// rules it is sent under, and the terms that make sending it an agreement.
///
/// Stated beside the send button rather than gated behind a checkbox — see
/// ``CommunityShareSheet``'s review section for the argument. The rules are
/// each form's own paragraphs; the promise above them and the link below them
/// are the same on both.
struct CommunityTermsSection<Rules: View>: View {
    /// "Every … is checked by a person before anyone else can see it."
    let reviewNotice: Text
    /// "By …, you agree to the Terms & Conditions."
    let agreement: Text
    let termsIdentifier: String
    @ViewBuilder var rules: Rules

    var body: some View {
        Section {
            CommunityFootnoteLabel(
                text: reviewNotice,
                systemImage: "checkmark.shield",
                tint: AnyShapeStyle(.tint)
            )
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                rules
                // The frame is what makes it line up. A `Link`'s label is
                // sized to its own text and centred inside whatever width it
                // is given, while the paragraphs above fill the footer — so
                // the one line that is shorter than the column sat in the
                // middle of it, out of step with everything around it (#389).
                // Filling the width and aligning leading puts it back on the
                // same edge as the sentences it belongs to.
                Link(destination: MapPurchaseLinks.termsAndConditions) {
                    agreement
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityIdentifier(termsIdentifier)
            }
        }
    }
}
