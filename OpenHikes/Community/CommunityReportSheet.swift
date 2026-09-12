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
    private enum Phase: Equatable {
        /// Filling the form in.
        case editing
        /// Something opened the `mailto:`. Whether it composed anything is not
        /// knowable from here — see this file's header.
        case handedOff
        /// Nothing opened the `mailto:` at all.
        case noMailApp
    }

    let listing: CommunityListing

    @Environment(\.openURL)
    private var openURL
    @State private var reason: CommunityReportReason = .objectionable
    @State private var note = ""
    @State private var phase: Phase = .editing

    private var report: CommunityReport {
        CommunityReport(listing: listing, reason: reason, note: note)
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
                    handedOffSection
                    messageSection
                    editAgainSection
                case .noMailApp:
                    noMailAppSection
                    messageSection
                    editAgainSection
                }
            }
            .navigationTitle("Report Hike")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
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
            LabeledContent("Hike", value: listing.title)
            if !listing.authorName.isEmpty {
                LabeledContent("Shared by", value: listing.authorName)
            }
        } header: {
            Text("What you're reporting")
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
    /// Something took the URL. Deliberately worded as *opened in* rather than
    /// *waiting in*: see this file's header for why the Boolean behind this
    /// does not support the stronger claim.
    var handedOffSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Opened in your mail app")
                    .font(.headline)
                Text("The report reaches the reviewer only once you send it there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-report-handed-off")
        }
    }

    var noMailAppSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No mail app answered")
                    .font(.headline)
                Text("Nothing on this device offered to write the message.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-report-no-mail-app")
        }
    }

    /// The report itself, kept reachable after *either* outcome.
    ///
    /// Shown after a successful handoff too, and that is the point rather than
    /// clutter: no message may have been composed at all, and a hiker who
    /// finds their mail app asking them to set up an account has otherwise
    /// lost everything they typed.
    var messageSection: some View {
        Section {
            Text(report.plainText)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("community-report-fallback-text")
            #if canImport(UIKit)
            Button {
                UIPasteboard.general.string = report.plainText
            } label: {
                Label("Copy Report", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("community-report-copy")
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

    /// The way back to the form, so a second attempt does not mean typing the
    /// complaint again.
    ///
    /// The reason and the note are `@State` on this sheet and survive the
    /// round trip, so this really is the report the hiker already wrote.
    var editAgainSection: some View {
        Section {
            Button("Back to the Report") { phase = .editing }
                .accessibilityIdentifier("community-report-edit-again")
        }
    }
}

// MARK: - Toolbar

private extension CommunityReportSheet {
    /// ``DismissButton`` rather than `Button("Done") { dismiss() }`, because a
    /// `.toolbar` closure is inlined into the body that declares it — so
    /// `@Environment(\.dismiss)` here would belong to this whole form and
    /// rebuild it on every scene-phase transition. The mail handoff *is* a
    /// scene-phase transition, which makes this screen the shape the rule was
    /// measured on. See ``DismissButton``.
    @ToolbarContentBuilder var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            DismissButton(phase == .editing ? "Cancel" : "Done")
        }
        ToolbarItem(placement: .confirmationAction) {
            if phase == .editing {
                Button("Send") { send() }
                    .accessibilityIdentifier("community-report-send")
            }
        }
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
