//
//  ElevationCredit.swift
//  OpenHikes
//
//  What the licence of the heights asks to be said, word for word.
//
//  The heights are the Copernicus DEM's GLO-30, under the licence its tiles
//  ship with (`INFO/eula_F.pdf`, "Licence for Copernicus DEM instance
//  COP-DEM-GLO-30-F"). Article 6 asks three things of anybody who gives the
//  data on, and the squares are given on twice: by the tile server to anyone
//  who asks, and by the app as a profile.
//
//  - (b) Data that has been adapted, as a square in whole metres is, carries
//    ``notice``. The archive's metadata carries it, and *About* in Settings
//    shows it, linked to the product's page.
//  - (c) A licence or legal notice covering it carries ``liability``, "or its
//    translation in any language": the terms, in every language they are
//    published in.
//  - (d) Nothing may suggest that Copernicus or Airbus endorses the app,
//    which a credit worded as theirs does not.
//
//  Neither sentence is localized, as no data credit in the app is (see
//  ``TileAttribution``): it is the licensor's wording, not ours to translate.
//  The terms translate ``liability``, which the licence allows.
//
//  Compiled by the tool too, which writes ``notice`` into the archive.
//

import Foundation

nonisolated enum ElevationCredit {
    /// Article 6(b)'s notice, for data adapted from the Copernicus DEM.
    static let notice = """
        produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH \
        2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved
        """

    /// Article 6(c)'s sentence, for the terms.
    static let liability = """
        The organisations in charge of the Copernicus programme by law or by delegation do not incur any \
        liability for any use of the Copernicus WorldDEM-30
        """

    /// The source's short name, for a caption under a chart drawn from it:
    /// "Elevation from Copernicus DEM."
    static let sourceName = "Copernicus DEM"

    /// The product's page, which the credit links to.
    static let productPage = URL(
        string: "https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM"
    )!
}
