//
//  HikeDetailView+Archive.swift
//  OpenHikes
//
//  The second share control on the hike detail screen: the one that sends the
//  pictures too.
//
//  Split out for the reason `HikeDetailView+Community.swift` is — the detail
//  view is the largest screen in the app and the linter holds it to a file
//  length, so a subject that can stand on its own does.
//
//  The subject is why there are two share buttons rather than one clever one.
//  A share sheet fills its "Copy to <App>" row by matching the *file* against
//  what each installed app declares it opens, so a `.gpx` reaches every GPX
//  reader on the phone and a `.zip` reaches none of them. The hiker sending a
//  route to their mapping app and the hiker getting their photographs out of
//  a single-copy store want different files, and a button that silently
//  switched from the first to the second the day they took a picture would
//  take a working destination away without saying so. See ``HikeArchive`` for
//  what is in the archive and why the originals travel.
//

import SwiftUI

extension HikeDetailView {
    /// Hands the route *and its photographs* to the share sheet as a `.zip`.
    ///
    /// A second control rather than a smarter first one. ``shareButton`` keeps
    /// producing a bare `.gpx` because that is the file a GPX reader can match
    /// and open, and a zip is not — so switching the one button's output based
    /// on whether the hike happens to have a photograph would take that
    /// destination away from a hiker the day they took their first picture,
    /// silently. Two buttons, each honest about what it sends.
    ///
    /// Shown only for a hike that has photographs, because for one that does
    /// not the archive is the `.gpx` with a folder around it — a second button
    /// offering the same bytes in a worse container.
    ///
    /// The payload is a `Sendable` ``HikeArchive`` snapshot for the reason
    /// ``shareButton``'s is: `ShareLink` passes the exporter to the system,
    /// which calls it off the main actor, where a `@Model` must not be read.
    /// Nothing is copied or zipped until a destination is picked.
    @ViewBuilder var archiveButton: some View {
        if hike.hasPhotos {
            ShareLink(
                item: HikeArchiveFile(archive: HikeArchive(hike: hike)),
                preview: SharePreview(
                    hike.displayTitle,
                    icon: Image(systemName: "photo.on.rectangle.angled")
                )
            ) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share hike with photos")
            .disabled(hike.pointCount < 2)
        }
    }
}
