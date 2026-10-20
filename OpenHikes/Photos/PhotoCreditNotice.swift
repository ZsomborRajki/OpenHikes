//
//  PhotoCreditNotice.swift
//  OpenHikes
//
//  The credit a Wikimedia Commons copy is owed, in the form that leaves the
//  app with it.
//
//  Inside the app the credit is drawn — ``PhotoLicenseCredit`` over the
//  picture, with its two links in a menu. Outside it there is nothing to draw
//  on: a shared photograph is a file, an archive is a folder of files, and the
//  author, the licence and the source page were stored beside the picture on
//  its ``HikePhoto`` row rather than in its bytes. Every export that carries a
//  licensed copy away has to carry those three with it, and this is the one
//  wording they all use: the share sheet's message, the bytes the file itself
//  is rewritten with (see ``PhotoMetadataStamp/credited(_:with:)``), and the
//  credits file an archive lays beside its photographs.
//
//  The two links go unlabelled. They are what a reader follows rather than
//  reads, and a URL needs no translation.
//

import Algorithms
import Foundation
import OpenHikesData

nonisolated extension CommonsPhotoCredit {
    /// The credit a saved copy carries, or `nil` for a photograph that is not
    /// one — anything but a licensed copy goes out exactly as it was.
    ///
    /// The author is ``HikePhoto/importedAuthorName``, as it is for any
    /// photograph somebody else took; see ``HikePhotoLicense`` for why the
    /// licence does not hold it too.
    init?(_ photo: HikePhoto) {
        guard let license = photo.license else { return nil }
        self.init(author: photo.importedAuthorName, license: license)
    }

    /// The credit in words, as the viewer draws it over the picture.
    var line: String { PhotoLicenseCredit.line(author: author, license: license) }

    /// The credit, then the photograph's page on Commons, then the licence's
    /// own text when Commons links one — each on its own line.
    var notice: String {
        [line, license.sourceURL.absoluteString, license.url?.absoluteString]
            .compacted()
            .joined(separator: "\n")
    }
}
