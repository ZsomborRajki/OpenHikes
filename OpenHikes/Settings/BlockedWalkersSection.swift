//
//  BlockedWalkersSection.swift
//  OpenHikes
//
//  The settings section for people this device has blocked: who they are, and
//  how to stop.
//
//  Its own file for the reason ``CloudSyncSection`` is: it holds live state
//  that changes while the sheet is open — an unblock is an edit to a list the
//  same screen is drawing — and ``SettingsView`` is an eight-section `Form` in
//  one body that must not be rebuilt by it.
//
//  **A block a walker cannot see or undo is its own problem.** Blocking is
//  reached from a menu on somebody else's hike, which is a screen they may
//  never open again; without somewhere like this, a tap taken once would be
//  permanent and invisible, and a walker who blocked the wrong person would
//  have no way back. So the entries are named, dated and individually
//  reversible, and the section is absent rather than empty when there is
//  nothing in it — an empty *Blocked* heading in a settings screen invites the
//  question of what it is for from everybody who never used the community
//  feature at all.
//
//  What it shows is the name the hike was published under at the moment of
//  blocking, which is a label rather than the key — see ``CommunityBlockList``
//  for why a block is keyed on something the walker did not type.
//

import SwiftUI

struct BlockedWalkersSection: View {
    let blocks: CommunityBlockList

    @State private var isConfirmingUnblockAll = false

    var body: some View {
        // Nothing to say to somebody who has never blocked anybody, and the
        // section is not a switch they might want to find.
        if !blocks.isEmpty {
            Section {
                ForEach(blocks.authors) { author in
                    row(author)
                }
                Button("Unblock Everyone", role: .destructive) {
                    isConfirmingUnblockAll = true
                }
                .accessibilityIdentifier("unblock-everyone")
            } header: {
                Text("Blocked")
            } footer: {
                Text("""
                Their shared hikes don't appear on this device. Blocking is kept \
                on this device only, and doesn't remove anything for anyone else — \
                to have a hike taken down, report it from the hike's own screen.
                """)
            }
            .confirmationDialog(
                "Unblock everyone?",
                isPresented: $isConfirmingUnblockAll,
                titleVisibility: .visible
            ) {
                Button("Unblock Everyone", role: .destructive) { blocks.unblockAll() }
                Button("Cancel", role: .cancel) { /* intentionally empty */ }
            } message: {
                Text("Hikes from everyone on this list will appear again.")
            }
        }
    }

    private func row(_ author: CommunityBlockList.BlockedAuthor) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name(of: author))
                    .font(.body)
                Text("Blocked \(author.blockedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Who and when are one thing said about one person, the same
            // contract every composite row in the app keeps. The button is
            // deliberately left outside it: an action folded into a label is
            // one a screen reader cannot reach separately.
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Unblock") { blocks.unblock(author.id) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Unblock \(name(of: author))")
                .accessibilityIdentifier("unblock-walker")
        }
    }

    /// What the row calls them.
    ///
    /// A walker may publish without a name, and an entry with a blank line
    /// where the name goes is one nobody can decide whether to undo. There is
    /// nothing truer to put here — the key is an opaque record name — so the
    /// row says what it knows.
    private func name(of author: CommunityBlockList.BlockedAuthor) -> String {
        author.name.isEmpty
            ? String(localized: "Walker who shared without a name")
            : author.name
    }
}
