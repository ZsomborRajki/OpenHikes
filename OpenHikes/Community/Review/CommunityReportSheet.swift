//
//  CommunityReportSheet.swift
//  OpenHikes
//
//  The screen a hiker reports somebody else's published hike from.
//
//  A form rather than an alert, for the same reason ``CommunityShareSheet`` is
//  one: a report that arrives saying only "reported" is a report a reviewer
//  cannot act on inside a day, and the two fields that make it actionable —
//  what is wrong, and anything the hiker wants to add — need somewhere to be
//  typed. It also has to *name what is being reported*, which an alert over a
//  list could not: the hiker sees the title and the author they are
//  complaining about before they send anything.
//
//  ## What this does not claim
//
//  It hands the report to the device's mail app and stops. See
//  ``CommunityReport`` for why this is mail at all rather than a record type;
//  the short version is that browsing works signed out and a public-database
//  write does not.
//
//  What `openURL`'s completion reports is **narrower than it looks**, and the
//  wording here is held to the narrow reading. `accepted` says the system
//  found something willing to open the `mailto:` — it does not say a draft was
//  composed, and it does not say the device has a mail account at all. Mail is
//  installed on every iPhone and registered for the scheme, so a phone with no
//  account configured takes the URL, opens, and offers account setup: accepted
//  is `true` and no message exists. A hiker who discards the composer lands in
//  the same place from the other direction.
//
//  So the handed-off screen says the report was *opened in* the mail app
//  rather than that one is waiting in it, and — the part that matters — it
//  never becomes a dead end. The message stays copyable and the form stays
//  reachable from **both** outcomes, because the two cases this app cannot
//  tell apart are exactly the ones where a hiker needs the text back. A
//  screen that offered only *Done* would have taken the complaint away from
//  the person who typed it.
//

import SwiftUI

struct CommunityReportSheet: View {
    /// Where the sheet is in the trip from form to handoff.
    ///
    /// One value rather than two booleans, for the reason
    /// ``CommunityHikeView``'s `Phase` gives: a sheet that is both handed off
    /// and reporting no mail app is a state nobody has to reason about if it
    /// cannot be spelled.
    ///
    /// Not a one-way trip, which is the correction a review made. Both
    /// outcomes below lead back to ``editing``, since neither of them is
    /// evidence that the report got anywhere.
    let listing: CommunityListing
    /// The contributed set, when what is being reported is one photograph on
    /// the hike rather than the hike itself. `nil` is the ordinary report.
    var contribution: CommunityPhotoAttribution?

    @Environment(\.openURL)
    private var openURL
    @State private var reason: CommunityReportReason = .objectionable
    @State private var note = ""
    @State private var phase: CommunityMailPhase = .editing

    private var report: CommunityReport {
        CommunityReport(
            listing: listing,
            reason: reason,
            contribution: contribution,
            note: note
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .editing:
                    reportedSection
                    reasonSection
                    noteSection
                    commitmentSection
                case .handedOff:
                    outcomeSections(.handedOff)
                case .noMailApp:
                    outcomeSections(.noMailApp)
                }
            }
            .navigationTitle(contribution == nil ? "Report Hike" : "Report Photo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                CommunityMailRequestToolbar(
                    phase: phase,
                    sendIdentifier: "community-report-send",
                    send: send
                )
            }
        }
    }
}

// MARK: - Filling it in

private extension CommunityReportSheet {
    /// What is being reported, said before anything is sent.
    ///
    /// The first section rather than assumed context: this sheet can be opened
    /// from a preview whose contents are still loading, and a hiker who
    /// reached it from the wrong row should find that out here.
    var reportedSection: some View {
        Section {
            if let contribution {
                // The photograph first, because it is what is being reported.
                // The hike is named underneath as the place it was found, and
                // the footer says plainly that it is not part of the request —
                // a hiker reporting a stranger's picture must not be left
                // wondering whether they have just asked for the trail to come
                // down as well.
                LabeledContent(
                    "Photo added by",
                    value: contribution.credit ?? String(localized: "Someone")
                )
                LabeledContent("On", value: listing.title)
            } else {
                LabeledContent("Hike", value: listing.title)
                if !listing.authorName.isEmpty {
                    LabeledContent("Shared by", value: listing.authorName)
                }
            }
        } header: {
            Text("What you're reporting")
        } footer: {
            if contribution != nil {
                Text("The hike itself isn't reported — only the photo somebody added to it.")
            }
        }
    }

    var reasonSection: some View {
        Section {
            // Inline rather than a menu: five short choices are quicker to
            // read down than to open, and a menu would hide the one the
            // hiker is looking for behind a tap.
            // ``pickerOrder`` rather than `allCases`: the cases are declared
            // alphabetically to satisfy the linter, and that is not the order
            // to read five choices in.
            Picker("Reason", selection: $reason) {
                ForEach(CommunityReportReason.pickerOrder) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("community-report-reason")
        } header: {
            Text("What's wrong")
        }
    }

    var noteSection: some View {
        Section {
            TextField("Optional", text: $note, axis: .vertical)
                .lineLimit(3...6)
                .accessibilityIdentifier("community-report-note")
        } header: {
            Text("Anything else")
        } footer: {
            Text("Anything that helps decide quickly — which photo, which part of the route.")
        }
    }

    /// The promise, made on the screen that asks for the report rather than
    /// only in the privacy policy.
    var commitmentSection: some View {
        Section {
            Label {
                Text("Reports are read and acted on within 24 hours.")
            } icon: {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
        } footer: {
            // Said because the hiker is about to watch their mail app open,
            // which is surprising if nobody warned them, and because a report
            // needing no account is the part that is worth knowing.
            Text("""
            Your report opens in your mail app so you can send it. \
            You don't need an account to report a hike.
            """)
        }
    }
}

// MARK: - After the handoff

private extension CommunityReportSheet {
    /// Shared with ``CommunityWithdrawalSheet`` — see
    /// ``CommunityMailOutcomeSections``, which the two of them had written
    /// twice.
    func outcomeSections(_ outcome: CommunityMailOutcome) -> some View {
        CommunityMailOutcomeSections(
            outcome: outcome,
            noun: "Report",
            plainText: report.plainText,
            identifiers: .init(
                handedOff: "community-report-handed-off",
                noMailApp: "community-report-no-mail-app",
                fallbackText: "community-report-fallback-text",
                copy: "community-report-copy",
                editAgain: "community-report-edit-again"
            ),
            editAgain: { phase = .editing }
        )
    }
}

// MARK: - Handing it over

private extension CommunityReportSheet {
    /// Opens the composed mail, or says nothing would.
    ///
    /// A `mailto:` that cannot even be *formed* takes the same outcome as one
    /// nothing opened: both leave the hiker holding a report with nowhere to
    /// put it, and the screen offers the same copyable text either way.
    func send() {
        guard let url = report.mailURL else {
            phase = .noMailApp
            return
        }
        openURL(url) { accepted in
            phase = accepted ? .handedOff : .noMailApp
        }
    }
}
