//
//  WikidataPlaceSection.swift
//  OpenHikes
//
//  The part of a place card that reads from Wikimedia: the item's
//  photograph, the article's opening, and the way to the rest of it.
//
//  Headed by where it comes from, the way the card's subtitle says *From
//  OpenStreetMap*: *From Wikipedia* over an article, and *From Wikimedia
//  Commons* over a photograph that has no article beside it — the photograph
//  is Commons', and a heading that named Wikipedia would be claiming words the
//  section does not have. See ``WikidataPlace`` for why a photograph alone is
//  still a section.
//
//  The credits are the ones the licences ask for, each where its work is: the
//  photograph carries its own capsule, as every Commons photograph in the app
//  does, and the article's words are followed by the way to the article and a
//  row naming their licence. The opening is cut after a few lines rather than
//  given a *More*, because the link is the more — the whole article, on
//  Wikipedia.
//

import OpenHikesData
import SwiftUI

/// What Wikipedia and Commons have about a place, as a section of its card.
struct WikidataPlaceSection: View {
    let place: WikidataPlace

    /// The licence Wikipedia's words are shared under, in every language this
    /// app reads them in: every Wikipedia moved to version 4.0 in June 2023.
    static let textLicenseName = "CC BY-SA 4.0"
    // swiftlint:disable:next force_unwrapping
    static let textLicenseURL = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!

    /// How many lines of the opening are shown before the link takes over.
    static let extractLineLimit = 10

    var body: some View {
        PlaceCardList(title: place.heading) {
            if let photo = place.photo {
                WikidataPlacePhotoView(photo: photo, subject: place.article?.title)
            }
            if let article = place.article {
                Text(article.extract)
                    .font(.body)
                    .lineLimit(Self.extractLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("wikidata-place-extract")
                // The row's height and hit shape inside the label, as the
                // card's *View on OpenStreetMap* has them, for the audit's
                // reason given there.
                Link(destination: article.url) {
                    Label("Read on Wikipedia", systemImage: "arrow.up.right.square")
                        .trailPlaceRow()
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("wikidata-place-article-link")
                TrailPlaceLinkRow(
                    label: String(localized: "Text License"),
                    title: Self.textLicenseName,
                    destination: Self.textLicenseURL
                )
                .accessibilityIdentifier("wikidata-place-text-license")
            }
        }
    }
}

/// The item's photograph across the card, with its credit over it.
///
/// Its own view so the decode, and the pass that draws it once decoded,
/// belong to it rather than to the card — the shape ``CommunityPhotoTile``
/// takes, for its reasons.
struct WikidataPlacePhotoView: View {
    let photo: WikidataPhoto
    /// What the photograph is of — the article's title — or `nil` when there
    /// is no article to name it by.
    let subject: String?

    /// The height the photograph is drawn at, whatever its shape: a card's
    /// worth of picture, and the same space whether it has decoded yet or not.
    static let height: CGFloat = 180
    private static let cornerRadius: CGFloat = 10
    private static let creditInset: CGFloat = 8

    @State private var image: Image?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("wikidata-place-photo")
            // After the picture's own element, so the credit is an element of
            // its own: the menu that leads to the file page and the licence.
            .overlay(alignment: .bottomLeading) {
                PhotoLicenseCredit(author: photo.credit.author, license: photo.credit.license)
                    .padding(Self.creditInset)
            }
            .padding(.vertical, 12)
            // Keyed by the file, so a card handed another place's photograph
            // never shows the last one's while the new one decodes.
            .task(id: photo.credit.license.sourceURL) {
                image = nil
                image = await WikidataPlaceLookup.image(from: photo.imageData)
            }
    }

    private var label: Text {
        subject.map { Text("Photo of \($0)") } ?? Text("Photo")
    }
}
