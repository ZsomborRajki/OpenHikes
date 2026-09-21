//
//  TrailPlaceEditor.swift
//  OpenHikes
//
//  What a marked place is called, what kind of place it is, and anything else
//  worth saying about it.
//
//  ## A sheet, and it has to be
//
//  Not a pushed screen, and that is a constraint rather than a preference.
//  ``MapSheet`` drives ``TrailDraftController/setEditing(_:)`` off
//  ``SheetPresentation/isTrailDraftPresented``, which is true only while the
//  maker is the screen on top — so pushing an editor over it would take the
//  canvas down mid-edit, cancel any drag and disown every leg still being
//  routed. A sheet leaves the maker on top of its own stack.
//
//  It is presented from inside the maker's screen, which is itself inside the
//  sheet's contents, which is the rule the repository instructions state under
//  *Present modals from inside the sheet's contents* — see
//  [[root-alerts-cannot-open]] and ``TrailDraftView``'s own dialogs.
//
//  ## It edits a copy and writes it on the way out
//
//  Every other mutation in this feature lands on the controller as it happens,
//  because every other mutation is one gesture. A name is not: it is a
//  keystroke at a time, and a store write per character is a disk write per
//  character — the cost ``TrailDraftName`` is a reference type to avoid one
//  screen up. So this holds a working copy, and commits it when the sheet
//  goes.
//
//  **Dismissing is committing.** There is no Cancel, and the absence is the
//  decision: the place is already on the map before this opens — marking it
//  and naming it are one gesture from the hiker's side — so a Cancel could
//  only mean *keep the pin and forget what I typed*, which is not a thing
//  anybody wants twice. What removes a place is Remove, which is in here and
//  in its callout.
//

import SwiftUI

/// What is being typed into the editor, for as long as it is up.
///
/// A reference type rather than the sheet's `@State`, for the reason
/// ``TrailDraftName`` is one: a `@State` mutation invalidates the view holding
/// it whether or not its body reads the value, and this sheet is presented
/// from a screen whose body draws every waypoint and every place.
@Observable
final class TrailPlaceEdit {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var place: TrailPlace?

    var name = ""
    var note = ""
    var symbol: TrailPlaceSymbol?

    /// Points the editor at a place, or at nothing.
    func begin(_ place: TrailPlace?) {
        self.place = place
        name = place?.name ?? ""
        note = place?.note ?? ""
        symbol = place?.symbol
    }

    /// The place as edited, or `nil` when there is nothing to write.
    ///
    /// Bounded here, where the text leaves the field, for the reason
    /// ``HikeTitle`` bounds a hike's name where it is entered: both of these
    /// reach a mirrored column and a `CKRecord`, and a note pasted from a web
    /// page is exactly the unattended input that argument is about.
    var edited: TrailPlace? {
        guard var place else { return nil }
        place.name = BoundedText.boundedOrEmpty(name, to: .title)
        place.note = BoundedText.boundedOrEmpty(note, to: .notes)
        place.symbol = symbol
        return place
    }
}

struct TrailPlaceEditor: View {
    let maker: TrailDraftController
    /// What is being typed. Held by the screen that presents this, so it
    /// survives the sheet being torn down while the write is going through.
    let edit: TrailPlaceEdit
    var onClose: () -> Void

    /// Three across at the default text size, and the grid reflows rather than
    /// scrolling at larger ones — eight symbols is a thing to be seen at once.
    private static let symbolTileWidth: CGFloat = 88
    private static let symbolGridSpacing: CGFloat = 12
    private static let symbolTileRadius: CGFloat = 10
    private static let symbolTileBorder: CGFloat = 2
    private static let symbolTilePadding: CGFloat = 10
    private static let chosenTileOpacity: Double = 0.18
    private static let symbolColumns = [
        GridItem(.adaptive(minimum: symbolTileWidth), spacing: symbolGridSpacing),
    ]

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                symbolSection
                noteSection
                removeSection
            }
            .navigationTitle("Place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("trail-place-done")
                }
            }
        }
    }

    @ViewBuilder private var nameSection: some View {
        Section("Name") {
            TextField(placeholder, text: Binding(
                get: { edit.name },
                set: { edit.name = $0 }
            ))
            .accessibilityIdentifier("trail-place-name")
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
        }
    }

    @ViewBuilder private var noteSection: some View {
        Section("Note") {
            TextField(
                "Anything worth remembering",
                text: Binding(get: { edit.note }, set: { edit.note = $0 }),
                axis: .vertical
            )
            .lineLimit(2...5)
            .accessibilityIdentifier("trail-place-note")
        }
    }

    /// The way out that is not *Done*, and the only one — see the file header
    /// for why there is no Cancel.
    @ViewBuilder private var removeSection: some View {
        Section {
            Button("Remove This Place", systemImage: "trash", role: .destructive) {
                guard let place = edit.place else { return }
                maker.removePlace(id: place.id)
                // Closed without committing: the place it was about is gone,
                // and ``TrailDraft/updatePlace(_:)`` would find nothing to
                // write anyway. Told explicitly rather than relied on, because
                // "the write is a no-op" is a fact about another file.
                edit.begin(nil)
                onClose()
            }
            .accessibilityIdentifier("trail-place-delete")
        }
    }

    /// What a blank name writes, which is what makes leaving it blank a choice
    /// rather than an omission — the same promise the maker's own save alert
    /// makes. It follows the symbol, so picking *Spring* immediately shows
    /// what the place will be called.
    private var placeholder: String {
        edit.symbol?.label ?? String(localized: "Place")
    }

    /// The eight, and the ninth choice that is none of them.
    ///
    /// *No Symbol* is offered rather than hidden, because an unstated kind is
    /// a real answer — see ``TrailPlace``. A place marked in a hurry, or one
    /// imported from somebody else's GPX carrying a symbol this app has no
    /// glyph for, is a place and nothing more, and the picker should be able
    /// to say so.
    @ViewBuilder private var symbolSection: some View {
        Section("Symbol") {
            LazyVGrid(columns: Self.symbolColumns, spacing: Self.symbolGridSpacing) {
                symbolButton(nil)
                ForEach(TrailPlaceSymbol.allCases, id: \.self) { candidate in
                    symbolButton(candidate)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func symbolButton(_ candidate: TrailPlaceSymbol?) -> some View {
        let isChosen = edit.symbol == candidate
        let radius = Self.symbolTileRadius
        return Button {
            edit.symbol = candidate
        } label: {
            VStack(spacing: 6) {
                Image(systemName: candidate?.systemImageName ?? "mappin")
                    .font(.title3)
                    // The word underneath says it, and a glyph that said it
                    // again would make every tile speak twice.
                    .accessibilityHidden(true)
                Text(candidate?.label ?? String(localized: "None"))
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Self.symbolTilePadding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        isChosen
                            ? AnyShapeStyle(.tint.opacity(Self.chosenTileOpacity))
                            : AnyShapeStyle(.quaternary)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        lineWidth: Self.symbolTileBorder
                    )
            )
            .foregroundStyle(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("trail-place-symbol-\(candidate?.rawValue ?? "none")")
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }
}
