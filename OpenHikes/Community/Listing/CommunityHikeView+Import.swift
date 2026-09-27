//
//  CommunityHikeView+Import.swift
//  OpenHikes
//
//  The button that saves the hike, and what saving it came to.
//
//  Split from `CommunityHikeView.swift` for length alone, the way
//  `CommunityHikeView+Curated.swift` is, which is why the state these read is
//  `internal` rather than `private`: `private` is file-scoped in Swift, and
//  these files are one type.
//
//  A save can keep the route and miss some of its photographs — see
//  ``CommunityPhotoCopy`` — and this is where the hiker is told, and offered
//  the missing ones again. The screen stays up for it rather than opening the
//  saved hike, because the files a retry copies from are this screen's
//  downloads and go when it does.
//

import SwiftUI

// MARK: - The button

extension CommunityHikeView {
    @ViewBuilder
    func importButton(_ detail: CommunityHikeDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                performImport(detail)
            } label: {
                HStack {
                    if isImporting {
                        ProgressView()
                    } else {
                        Image(systemName: importGlyph)
                    }
                    Text(importButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .prominentGlassButtonStyle()
            .disabled(isImporting)
            .accessibilityIdentifier("community-import-button")

            if let importFailure {
                Text(importFailure.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let photoCopy {
                missingPhotos(photoCopy, of: detail)
            } else if existingHike != nil {
                Text("This hike is already in your list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    /// The hike is saved and some of its photographs are not, and the one
    /// thing that can be done about it from here.
    ///
    /// Said rather than swallowed, because the saved hike is otherwise the
    /// only place the hiker could find out — by counting, against a strip they
    /// have just left.
    func missingPhotos(_ copy: CommunityPhotoCopy, of detail: CommunityHikeDetail) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(copy.failed.count) photos couldn't be saved to this hike.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Try Again") {
                retryPhotos(of: detail)
            }
            .font(.footnote)
            .disabled(isImporting)
            .accessibilityIdentifier("community-import-retry-photos")
        }
    }

    /// One title for one action, wherever it is offered: the button under the
    /// page and the first item of the toolbar menu are the same tap, and two
    /// wordings for it would read as two different things to do.
    var importButtonTitle: String {
        if isImporting { return "Adding…" }
        return existingHike == nil ? "Add to My Hikes" : "Open in My Hikes"
    }

    /// The glyph beside that title, shared for the same reason.
    var importGlyph: String {
        existingHike == nil ? "square.and.arrow.down" : "checkmark"
    }
}

// MARK: - Saving

extension CommunityHikeView {
    /// Adds the hike, and holds the task that does it.
    ///
    /// Held because the hiker can leave — by backing out, or by blocking this
    /// author — while the photographs are still being copied, and an
    /// unstructured task keeps running when the screen goes. What that costs
    /// is covered in ``discardDownloads()`` and just below.
    func performImport(_ detail: CommunityHikeDetail) {
        // Already in the library: this is the "Open" case, and re-importing
        // would make a second copy of the same trail.
        if let existingHike {
            onImport(existingHike)
            return
        }
        isImporting = true
        importFailure = nil
        // Inherits the main actor from here, which is what every assignment
        // inside it needs and what ``CommunityImport/importHike(_:into:)``
        // requires anyway.
        importTask = Task {
            let outcome = await CommunityImport.importHike(
                await withContributedSets(detail),
                into: context
            )
            isImporting = false
            switch outcome {
            case let .imported(hike, photos) where !photos.isComplete:
                // Saved, and short of photographs: this screen stays, because
                // it is the only one holding the files a retry needs. The
                // button beneath already says *Open in My Hikes*.
                existingHike = hike
                photoCopy = photos
            case .imported(let hike, _), .alreadyImported(let hike):
                existingHike = hike
                // Blocked while this was running, which is the later of the
                // two things the hiker said. The hike stays in the library —
                // it committed before the photographs began copying, and
                // blocking is a control over what the *community* shows rather
                // than a retraction of a save — but nothing re-opens it. The
                // alternative is the screen they just hid reappearing on top
                // of the list they were sent back to.
                guard !wasAuthorBlocked else { return }
                onImport(hike)
            case .refused(let failure):
                importFailure = failure
            }
        }
    }

    /// Copies the photographs the import missed onto the hike it saved.
    ///
    /// Held in ``importTask`` for the reason the import is: it reads out of
    /// the downloads ``discardDownloads()`` removes. Reads the same detail the
    /// import did — the screen's, contributed sets included — so every
    /// photograph is found at the position ``CommunityPhotoCopy`` recorded it
    /// under.
    func retryPhotos(of detail: CommunityHikeDetail) {
        guard let existingHike, let previous = photoCopy else { return }
        isImporting = true
        importTask = Task {
            let copy = await CommunityImport.copyPhotos(
                of: await withContributedSets(detail),
                onto: existingHike,
                after: previous
            )
            isImporting = false
            photoCopy = copy.isComplete ? nil : copy
        }
    }

    /// `detail` once the contributed sets have had their chance to land.
    ///
    /// The trail is two requests, and the second is deliberately not awaited
    /// by the first — see ``loadContributions()`` — so this screen is
    /// tappable while the contributed photographs are still in flight.
    /// Importing on that tap used to be harmless, because the import ignored
    /// those sets entirely. Now that it copies them, a hiker quick on the
    /// button would get a hike missing exactly the photographs that copy
    /// exists for, *some* of the time, with nothing to tell the fast tap from
    /// the slow one — which is the worst shape a bug of this kind can take.
    ///
    /// So it waits, and then reads the detail the **screen** ended up with
    /// rather than the one captured at the tap: the fetch hangs its answer on
    /// ``phase``, where a value copied out before it landed cannot see it.
    /// Filtered on the way out for the reason everything drawn from `phase` is
    /// — see ``visible(_:)``.
    ///
    /// A fetch that fails, finds nothing or is cancelled changes nothing: the
    /// wait ends and what comes back is the detail already on screen, which is
    /// what makes this safe to wait on unconditionally rather than only when
    /// something is known to be coming. The button is showing a spinner by the
    /// time this runs, so the wait reads as part of the import it is part of.
    func withContributedSets(_ detail: CommunityHikeDetail) async -> CommunityHikeDetail {
        await contributionsTask?.value
        guard case .loaded(let latest) = phase else { return detail }
        return visible(latest)
    }
}
