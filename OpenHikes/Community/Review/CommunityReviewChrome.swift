//
//  CommunityReviewChrome.swift
//  OpenHikes
//
//  What is around a review, as opposed to what is in one.
//
//  ``CommunityReviewDecisions`` already holds the machinery both review
//  screens run on. This is the other half of what they had in common and it is
//  all view: the title bar, the pair of buttons at the foot, the confirmation
//  a decline goes through, the alert a failed decision comes back as, and the
//  two lines that tell the map behind the sheet what is on screen.
//
//  Those are rules about *reviewing* rather than about either subject. A
//  decline is destructive and irreversible whichever it is, so it asks twice;
//  a decision that fails leaves everything as it was, so it says so and
//  changes nothing; and the map behind the sheet has to be told when a preview
//  opens and when it goes, or a line stays drawn over a screen that has
//  finished with it.
//
//  What stays on the screens is everything a reviewer reads: the question the
//  decline asks, the warning under it, what the footer says about why
//  publishing is unavailable, and the title bar. Those are about the thing
//  being judged.
//
//  ## The browser is called and never read
//
//  ``CommunityBrowser`` is held here to be *told* things — three one-way calls
//  and no property access anywhere in this file. That is what keeps a screen
//  presented over the map out of the map's own redraw path, and it is the same
//  rule the review screens state for themselves. See
//  ``CommunityBrowser/previewOpened(_:)``.
//

import SwiftUI

/// The title bar, lifecycle, decline confirmation and failure alert every
/// review screen wears.
///
/// Applied with `.modifier(...)` rather than through a `View` extension: the
/// convenience method would need every one of these as a parameter, which is
/// four more than the linter allows a function and four more than a reader
/// wants in a signature. A modifier's memberwise init labels them all anyway.
struct CommunityReviewChrome: ViewModifier {
    let title: LocalizedStringKey
    /// What the map should draw behind the sheet while this is open.
    let listing: CommunityListing
    let browser: CommunityBrowser
    /// The question the confirmation asks, which names what is being declined.
    let declineQuestion: LocalizedStringKey
    /// What a decline costs, spelled out. Each screen's is about its own
    /// subject: one takes a route and its photographs, the other takes
    /// photographs off a trail that stays.
    let declineWarning: LocalizedStringKey
    @Binding var isConfirmingDecline: Bool
    @Binding var decisionFailure: CommunityFailure?
    /// Downloads the subject and shows it. Built on the screen rather than
    /// here because it closes over that screen's current state — see
    /// *Why the operations are passed per call* in
    /// ``CommunityReviewDecisions``.
    let begin: () async -> Void
    let end: () -> Void
    let decline: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                browser.previewOpened(listing)
                await begin()
            }
            .onDisappear {
                browser.previewClosed(listing)
                end()
            }
            .confirmationDialog(
                declineQuestion,
                isPresented: $isConfirmingDecline,
                titleVisibility: .visible
            ) {
                Button("Decline and Delete", role: .destructive, action: decline)
                Button("Cancel", role: .cancel) { /* the dialog closing is the whole action */ }
            } message: {
                Text(declineWarning)
            }
            .communityFailureAlert("Couldn't finish", failure: $decisionFailure)
    }
}

/// The two buttons a review ends at, and what they are allowed to do.
///
/// *Publish* is the one that can be unavailable and the footer is where that
/// is explained — a disabled button with no sentence beside it is the dead end
/// this app fixes wherever it finds one. *Decline* stays available almost
/// always, because a subject that will not load is a perfectly good reason to
/// decline it.
struct CommunityReviewDecisionSection<Footer: View>: View {
    let isDeciding: Bool
    let canPublish: Bool
    let publishIdentifier: String
    let declineIdentifier: String
    let publish: () -> Void
    let decline: () -> Void
    @ViewBuilder let footer: Footer

    var body: some View {
        Section {
            Button(action: publish) {
                if isDeciding {
                    ProgressView()
                } else {
                    Text("Publish")
                }
            }
            .disabled(!canPublish)
            .accessibilityIdentifier(publishIdentifier)

            Button("Decline", role: .destructive, action: decline)
                .disabled(isDeciding)
                .accessibilityIdentifier(declineIdentifier)
        } footer: {
            footer
        }
    }
}
