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

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
        outcomeSection(
            symbol: "envelope",
            tint: AnyShapeStyle(.tint),
            headline: "Opened in your mail app",
            detail: "The \(noun.lowercased()) reaches the reviewer only once you send it there.",
            identifier: identifiers.handedOff
        )
    }

    private var noMailAppSection: some View {
        outcomeSection(
            symbol: "envelope.badge.shield.half.filled",
            tint: AnyShapeStyle(.secondary),
            headline: "No mail app answered",
            detail: "Nothing on this device offered to write the message.",
            identifier: identifiers.noMailApp
        )
    }

    private func outcomeSection(
        symbol: String,
        tint: AnyShapeStyle,
        headline: String,
        detail: String,
        identifier: String
    ) -> some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(headline)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        }
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
