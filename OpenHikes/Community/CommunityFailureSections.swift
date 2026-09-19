//
//  CommunityFailureSections.swift
//  OpenHikes
//
//  The two ways a community screen says a request failed, each of which was
//  written twice.
//
//  ``CommunityRetryableFailureSection`` is what a screen shows when the
//  failure is *all* there is — the load that would have filled it never
//  arrived, so the section is the content and it carries the way to try again.
//  ``CommunityFailureNotice`` is what a screen shows when the form is still
//  standing and one action on it failed: red, tight, and read out as one
//  element, because it sits under the rows it is about.
//
//  They are two views rather than one with a flag because the difference is
//  not decoration. One replaces a screen and the other annotates one, and
//  merging them would mean picking a spacing and a colour for both — which is
//  a choice about how a failure reads, not about how it is spelled.
//
//  What varies between the two uses of each is the accessibility identifier,
//  so that is what they take. The automation names every screen separately
//  and should keep doing so: "the review screen failed" and "the photo review
//  screen failed" are different facts about a build.
//

import SwiftUI

/// A failure that replaced the content, with the way back.
struct CommunityRetryableFailureSection: View {
    let failure: CommunityFailure
    let identifier: String
    /// Runs the load again. The caller owns the task and the phase it moves
    /// through, because it owns the state the retry is resetting.
    let retry: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.localizedDescription)
                if let suggestion = failure.recoverySuggestion {
                    Text(suggestion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Try Again", action: retry)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// A failure under a form that is still usable.
///
/// No retry: the button the hiker pressed is still there, and a second one
/// here would be the same action wearing a different name.
struct CommunityFailureNotice: View {
    let failure: CommunityFailure
    let identifier: String

    var body: some View {
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
            .accessibilityIdentifier(identifier)
        }
    }
}
