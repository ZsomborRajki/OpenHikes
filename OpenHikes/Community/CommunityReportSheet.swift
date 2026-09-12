//
//  CommunityReportSheet.swift
//  OpenHikes
//
//  The screen a walker reports somebody else's published hike from.
//
//  A form rather than an alert, for the same reason ``CommunityShareSheet`` is
//  one: a report that arrives saying only "reported" is a report a reviewer
//  cannot act on inside a day, and the two fields that make it actionable —
//  what is wrong, and anything the walker wants to add — need somewhere to be
//  typed. It also has to *name what is being reported*, which an alert over a
//  list could not: the walker sees the title and the author they are
//  complaining about before they send anything.
//
//  ## What this does not claim
//
//  It hands the report to the device's mail app and stops. It cannot watch the
//  message leave, so the confirmation says the report is *ready to send in
//  your mail app* rather than that it was sent — the same discipline that
//  keeps the share sheet saying "sent for review" instead of "published". See
//  ``CommunityReport`` for why this is mail at all rather than a record type;
//  the short version is that browsing works signed out and a public-database
//  write does not.
//
//  A phone with no mail account configured is a real case and not an error
//  state. `openURL`'s completion says so, and the fallback is the whole
//  message as copyable text with the address above it — which is worse than a
//  composed mail and is still a route the walker can take, unlike a button
//  that did nothing.
//

import SwiftUI

struct CommunityReportSheet: View {
    /// Where the sheet is in the one-way trip from form to handoff.
    ///
    /// One value rather than two booleans, for the reason
    /// ``CommunityHikeView``'s `Phase` gives: a sheet that is both handed off
    /// and showing the fallback is a state nobody has to reason about if it
    /// cannot be spelled.
    private enum Phase: Equatable {
        /// Filling the form in.
        case editing
        /// The mail app took it. Nothing more happens in this app.
        case handedOff
        /// Nothing opened the `mailto:`. The message is shown to be copied.
        case noMailApp
    }

    let listing: CommunityListing

    @Environment(\.dismiss)
    private var dismiss
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
                case .noMailApp:
                    fallbackSection
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

// MARK: - Sections

private extension CommunityReportSheet {
    /// What is being reported, said before anything is sent.
    ///
    /// The first section rather than assumed context: this sheet can be opened
    /// from a preview whose contents are still loading, and a walker who
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
            // walker is looking for behind a tap.
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
            // Said because the walker is about to watch their mail app open,
            // which is surprising if nobody warned them, and because a report
            // needing no account is the part that is worth knowing.
            Text("""
            Your report opens in your mail app so you can send it. \
            You don't need an account to report a hike.
            """)
        }
    }

    var handedOffSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "envelope.badge")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Ready to send")
                    .font(.headline)
                // What is true: this app composed it and handed it over. It
                // reaches anybody when the walker presses send in Mail.
                Text("The report is waiting in your mail app. It reaches the reviewer once you send it.")
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

    /// No mail app took the link. The message is shown whole so it can be
    /// copied somewhere that will.
    var fallbackSection: some View {
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
            #endif
        } header: {
            Text("Send this to \(CommunityReport.recipient)")
        } footer: {
            Text("No mail app answered, so the report is here to copy and send yourself.")
        }
    }

    @ToolbarContentBuilder var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(phase == .editing ? "Cancel" : "Done") { dismiss() }
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
    /// Opens the composed mail, or falls back to showing it.
    ///
    /// A `mailto:` that cannot even be *formed* takes the same fallback as one
    /// nothing opened: both leave the walker holding a report with nowhere to
    /// put it, and there is nothing useful to say about the difference.
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
