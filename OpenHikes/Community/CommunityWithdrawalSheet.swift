//
//  CommunityWithdrawalSheet.swift
//  OpenHikes
//
//  The screen a hiker asks for their own shared hike to be taken down from.
//
//  ``CommunityReportSheet``'s mirror, and deliberately the same screen in the
//  other direction: a form that names what is being asked about, a place to
//  say why, a handoff to the device's mail app, and a copyable fallback that
//  neither outcome can take away. Every argument in that file's header applies
//  here unchanged, including the one that matters most — `openURL`'s `accepted`
//  says something opened the `mailto:`, not that a message exists — so this
//  screen says *opened in* rather than *waiting in* too, and never becomes a
//  dead end.
//
//  ## What this does not claim
//
//  Nothing here says the hike has been taken down, and nothing changes on the
//  hike: the app cannot delete a public record, and a screen that said
//  "Withdrawn" would be a lie told at the one moment a hiker most needs the
//  truth. What it does is compose the message `docs/privacy` and `docs/terms`
//  already ask for, with the two record names a reviewer needs — the names
//  that live only on the `Hike` row and go when it does.
//
//  ## Why the reason is a free-text note and not a picker
//
//  ``CommunityReportSheet`` has a picker because a reviewer judging somebody
//  else's hike needs to know which of five different things to look at. A
//  hiker asking for their own hike back needs no grounds at all — it is their
//  route and their photographs — so there is nothing to pick from, and a
//  picker would read as a bar to clear.
//

import SwiftUI

struct CommunityWithdrawalSheet: View {
    /// Where the sheet is in the trip from form to handoff. Spelled the same
    /// way ``CommunityReportSheet``'s is, and for the same reason.
    let withdrawal: CommunityWithdrawal

    @Environment(\.openURL)
    private var openURL
    @State private var note = ""
    @State private var phase: CommunityMailPhase = .editing

    private var composed: CommunityWithdrawal {
        var request = withdrawal
        request.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return request
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .editing:
                    hikeSection
                    noteSection
                    whatHappensSection
                case .handedOff:
                    outcomeSections(.handedOff)
                case .noMailApp:
                    outcomeSections(.noMailApp)
                }
            }
            .navigationTitle("Ask for Removal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                CommunityMailRequestToolbar(
                    phase: phase,
                    sendIdentifier: "community-withdrawal-send",
                    send: send
                )
            }
        }
    }
}

// MARK: - Filling it in

private extension CommunityWithdrawalSheet {
    /// Which hike, said before anything is sent — the same first section the
    /// report sheet opens with, and for the same reason: a hiker who reached
    /// this from the wrong row should find that out here.
    var hikeSection: some View {
        Section {
            LabeledContent("Hike", value: withdrawal.title)
            LabeledContent(
                "Status",
                value: withdrawal.isPublished
                    ? String(localized: "Published")
                    : String(localized: "Waiting for review")
            )
        } header: {
            Text("What you're asking about")
        } footer: {
            Text(
                withdrawal.isPublished
                    ? "Other hikers can find this hike now."
                    : "This was sent and has not been published yet."
            )
        }
    }

    var noteSection: some View {
        Section {
            TextField("Optional", text: $note, axis: .vertical)
                .lineLimit(3...6)
                .accessibilityIdentifier("community-withdrawal-note")
        } header: {
            Text("Anything else")
        } footer: {
            // No reason is required and the footer says so outright: this is
            // the hiker's own route and their own photographs.
            Text("You don't have to give a reason. It's your hike.")
        }
    }

    /// What happens next, in the words the published pages use — and what does
    /// *not* happen, which is the half a hiker cannot see.
    var whatHappensSection: some View {
        Section {
            Label {
                Text("Removal requests are read and acted on within 24 hours.")
            } icon: {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
        } footer: {
            Text("""
            Your request opens in your mail app so you can send it. It carries \
            the record names a reviewer needs, which this hike is the only \
            place holding. The hike stays on this device either way — deleting \
            it here would not take the shared copy down.
            """)
        }
    }
}

// MARK: - After the handoff

private extension CommunityWithdrawalSheet {
    /// Shared with ``CommunityReportSheet`` — see
    /// ``CommunityMailOutcomeSections``.
    func outcomeSections(_ outcome: CommunityMailOutcome) -> some View {
        CommunityMailOutcomeSections(
            outcome: outcome,
            noun: "Request",
            plainText: composed.plainText,
            identifiers: .init(
                handedOff: "community-withdrawal-handed-off",
                noMailApp: "community-withdrawal-no-mail-app",
                fallbackText: "community-withdrawal-fallback-text",
                copy: "community-withdrawal-copy",
                editAgain: "community-withdrawal-edit-again"
            ),
            editAgain: { phase = .editing }
        )
    }
}

// MARK: - Handing it over

private extension CommunityWithdrawalSheet {
    /// Opens the composed mail, or says nothing would — the same two outcomes
    /// ``CommunityReportSheet/send()`` has, including a `mailto:` that could
    /// not be formed landing in the copyable one.
    func send() {
        guard let url = composed.mailURL else {
            phase = .noMailApp
            return
        }
        openURL(url) { accepted in
            phase = accepted ? .handedOff : .noMailApp
        }
    }
}
