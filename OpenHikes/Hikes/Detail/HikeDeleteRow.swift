//
//  HikeDeleteRow.swift
//  OpenHikes
//
//  *Delete Hike*, at the foot of a saved hike's own screen.
//
//  A saved hike could be deleted only by a swipe on its row in the list,
//  which a hiker looking at the hike had to know to go back for. The owner
//  asked for it here too (2026-11-20), as Apple Maps closes a place's card:
//  a row of its own, under the card's actions, in red.
//
//  It asks what the swipe asks, in the same words — see
//  ``HikeDeletionPrompt`` — and the deletion is the list's, so the store's
//  order, the tiles no other hike claims and a refusal's alert are one
//  answer wherever it was asked — see `MapSheet`'s `delete(_:among:)`.
//

import OpenHikesData
import SwiftUI

struct HikeDeleteRow: View {
    let hike: Hike
    /// Deletes the hike, once the hiker has said yes.
    let onDelete: (Hike) -> Void
    /// Asks for a sent hike's shared copy to be taken down, the way out of
    /// the question that keeps the hike.
    let onWithdraw: (Hike) -> Void

    @State private var isConfirming = false
    /// The question's words, built at the tap from the hike as it stands
    /// then: the wording counts its photographs and walks, and a body that
    /// read them on every pass would run again on every one added. Kept after
    /// the question closes, so the dialog does not go blank as it animates
    /// away, and built again by the next tap.
    @State private var prompt: HikeDeletionPrompt?

    var body: some View {
        PlaceCardList {
            Button(role: .destructive) {
                prompt = HikeDeletionPrompt(hike: hike)
                isConfirming = true
            } label: {
                Label(String(localized: "Delete Hike"), systemImage: "trash")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: StatCardMetrics.rowMinimumHeight, alignment: .leading)
                    // The whole row is the target — see ``StatRow``.
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hike-delete")
        }
        .confirmationDialog(
            prompt?.title ?? "",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(prompt?.confirmTitle ?? "", role: .destructive) { onDelete(hike) }
            // Only for a hike that has been sent, and above Cancel, as the
            // list's question offers it.
            if hike.communitySubmissionID != nil {
                Button("Ask for Removal First") { onWithdraw(hike) }
            }
            Button("Cancel", role: .cancel) { /* intentionally empty */ }
        } message: {
            Text(prompt?.message ?? "")
        }
    }
}
