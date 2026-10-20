//
//  PhotoLicenceCredit.swift
//  OpenHikes
//
//  The credit a Wikimedia Commons photograph is owed, over the photograph.
//
//  Every licence Commons accepts asks the same three things of anybody showing
//  the picture: name who took it, name the licence and link to it, and link to
//  where it came from. So this is a capsule rather than a caption — the first
//  two in words, and both links one tap away in a menu — drawn by the gallery
//  of a curated route's preview and by the saved hike's own gallery alike,
//  because the copy a hiker keeps is owed the same credit as the one they
//  were shown. See ``HikePhotoLicence``.
//

import OpenHikesData
import SwiftUI

/// Who took a Commons photograph and what they shared it under, with the way
/// to the photograph's page and to the licence.
struct PhotoLicenceCredit: View {
    /// The author as the file page names them, or `nil` when it names nobody
    /// — the capsule then says the licence alone and the page says the rest.
    let author: String?
    let licence: HikePhotoLicence

    var body: some View {
        Menu {
            Link(destination: licence.sourceURL) {
                Label("View on Wikimedia Commons", systemImage: "photo.on.rectangle")
            }
            if let url = licence.url {
                Link(destination: url) {
                    Label("About the \(licence.name) Licence", systemImage: "doc.text")
                }
            }
        } label: {
            Text(line)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassSurface(.regular, in: Capsule())
                // A capsule of footnote text is shorter than a finger: the
                // target grows to the minimum and the glass keeps its size.
                .minimumTapTarget()
        }
        // The backdrop is black whatever the device is set to, the reason the
        // credit beside it in the hiker's own gallery is told the same.
        .environment(\.colorScheme, .dark)
        .accessibilityLabel(line)
        .accessibilityHint("Shows where this photo comes from and its licence")
        .accessibilityIdentifier("photo-licence-credit")
    }

    private var line: String { Self.line(author: author, licence: licence) }

    /// The credit in words — also what the maker's photo pins are called to
    /// VoiceOver, since it is the one thing about the picture this app knows.
    ///
    /// `nonisolated` because the exports that carry a copy out of the app
    /// write it off the main actor — see ``CommonsPhotoCredit/notice``.
    nonisolated static func line(author: String?, licence: HikePhotoLicence) -> String {
        guard let author else { return String(localized: "Photo · \(licence.name)") }
        return String(localized: "Photo by \(author) · \(licence.name)")
    }
}
