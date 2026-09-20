//
//  CommunityMailOutcomeSections.swift
//  OpenHikes
//
//  What a sheet shows after it has handed a message to the mail app, or found
//  that nothing would take it.
//
//  Both sheets that mail the reviewer — ``CommunityReportSheet`` and
//  ``CommunityWithdrawalSheet`` — end the same way, and they ended it twice.
//  Same envelope, same wording, same *"Nothing on this device offered to write
//  the message"*, same monospaced copy of the text with the same footer under
//  it, same way back to the form. What genuinely differed between the two
//  copies was one noun and five accessibility identifiers.
//
//  The noun is a parameter. The identifiers are passed in one by one rather
//  than built from a prefix, deliberately: `community-withdrawal-fallback-text`
//  is what two UI test files look for, and a `"\(prefix)-fallback-text"` here
//  would mean the string they search for exists nowhere in the app.
//
//  The two other things a mailed request has and both sheets had written out
//  are here too: ``CommunityMailPhase``, the three states the trip from form
//  to handoff passes through, and ``CommunityMailRequestToolbar``, which is
//  Cancel-or-Done on one side and Send on the other.
//

import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Where a mailed request is on the one-way trip from form to handoff.
///
/// Both sheets declared this, with the same three cases and the same reason
/// for two of them. There is no *sent*: what the app can observe is whether
/// something opened the `mailto:`, and that is `handedOff` — see
/// ``CommunityReportSheet``'s header for why the Boolean behind it does not
/// support the stronger claim.
enum CommunityMailPhase: Equatable {
    /// Filling the form in.
    case editing
    /// Something opened the `mailto:`. Whether it composed anything is not
    /// knowable from here.
    case handedOff
    /// Nothing opened the `mailto:` at all.
    case noMailApp
}

/// What became of the handoff. Both answers leave the hiker holding the
/// message, which is why they share everything below the first section.
enum CommunityMailOutcome {
    /// Something took the URL. Deliberately *opened in* rather than *waiting
    /// in*: see ``CommunityReportSheet``'s header for why the Boolean behind
    /// this does not support the stronger claim.
    case handedOff
    case noMailApp
}

struct CommunityMailOutcomeSections: View {
    /// Spelled out per screen so every one of them is greppable from the
    /// automation that looks for it.
    struct Identifiers {
        let handedOff: String
        let noMailApp: String
        let fallbackText: String
        let copy: String
        let editAgain: String
    }

    let outcome: CommunityMailOutcome
    /// What this sheet calls the thing it is sending, capitalised: "Report",
    /// "Request". Used in a sentence and on two buttons.
    let noun: String
    let plainText: String
    let identifiers: Identifiers
    /// Back to the form, with what the hiker typed still in it.
    let editAgain: () -> Void

    var body: some View {
        switch outcome {
        case .handedOff: handedOffSection
        case .noMailApp: noMailAppSection
        }
        messageSection
        editAgainSection
    }

    private var handedOffSection: some View {
        CommunityOutcomeSection(
            symbol: "envelope",
            tint: AnyShapeStyle(.tint),
            headline: Text("Opened in your mail app"),
            detail: Text("The \(noun.lowercased()) reaches the reviewer only once you send it there."),
            identifier: identifiers.handedOff,
            moment: .outcomeSucceeded
        )
    }

    private var noMailAppSection: some View {
        CommunityOutcomeSection(
            symbol: "envelope.badge.shield.half.filled",
            tint: AnyShapeStyle(.secondary),
            headline: Text("No mail app answered"),
            detail: Text("Nothing on this device offered to write the message."),
            identifier: identifiers.noMailApp,
            // The one ending in this family that is not good news: nothing on
            // the device would write the message, so the report has not gone
            // anywhere.
            moment: .outcomeFailed
        )
    }

    /// The message itself, kept reachable after *either* outcome.
    ///
    /// Shown after a successful handoff too, and that is the point rather than
    /// clutter: no message may have been composed at all, and a hiker who
    /// finds their mail app asking them to set up an account has otherwise
    /// lost everything they typed. On the withdrawal sheet it also carries the
    /// two record names, which is the one thing there a hiker cannot
    /// reconstruct from memory.
    private var messageSection: some View {
        Section {
            Text(plainText)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier(identifiers.fallbackText)
            #if canImport(UIKit)
            Button {
                UIPasteboard.general.string = plainText
            } label: {
                Label("Copy \(noun)", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier(identifiers.copy)
            #endif
        } header: {
            Text("Send this to \(CommunityReport.recipient)")
        } footer: {
            Text("""
            If no message opened — no mail account set up, or you closed the \
            draft — copy this and send it yourself.
            """)
        }
    }

    /// The way back to the form, so a second attempt does not mean typing it
    /// again. What the hiker wrote is `@State` on the sheet and survives the
    /// round trip, so this really is the message they already have.
    private var editAgainSection: some View {
        Section {
            Button("Back to the \(noun)", action: editAgain)
                .accessibilityIdentifier(identifiers.editAgain)
        }
    }
}

/// Cancel-or-Done on one side, Send on the other, for a sheet that mails the
/// reviewer.
///
/// ``DismissButton`` rather than `Button("Done") { dismiss() }`, because a
/// `.toolbar` closure is inlined into the body that declares it — so an
/// `@Environment(\.dismiss)` on the sheet would belong to its whole form and
/// rebuild it on every scene-phase transition. **The mail handoff *is* a
/// scene-phase transition**, which makes these two screens the shape that rule
/// was measured on. See ``DismissButton``.
///
/// Send disappears once the handoff has happened rather than being disabled:
/// there is nothing left to send from here, and what replaces the form is the
/// message itself with a way back to it.
struct CommunityMailRequestToolbar: ToolbarContent {
    let phase: CommunityMailPhase
    /// Spelled out per screen rather than built from a prefix, for the reason
    /// ``CommunityMailOutcomeSections/Identifiers`` gives.
    let sendIdentifier: String
    let send: () -> Void

    @ToolbarContentBuilder var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            DismissButton(phase == .editing ? "Cancel" : "Done")
        }
        ToolbarItem(placement: .confirmationAction) {
            if phase == .editing {
                Button("Send", action: send)
                    .accessibilityIdentifier(sendIdentifier)
            }
        }
    }
}
