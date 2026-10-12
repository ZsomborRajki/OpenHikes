//
//  HikePhotoLicence.swift
//  OpenHikes
//
//  The licence a photograph copied out of Wikimedia Commons was shared under,
//  kept with the copy.
//
//  A photograph a hiker took is theirs, and one another hiker shared is
//  credited by name — see ``HikePhoto/importedAuthorName``. A photograph from
//  Wikimedia Commons is a third thing: somebody's work that the app may show
//  and keep because its author chose an open licence, and only on that
//  licence's terms. Every licence Commons accepts asks the same three things
//  of anybody showing the picture — name who took it, name the licence and
//  link to it, link to where the picture came from — so the two links and the
//  licence's name travel with the copy for as long as the hiker keeps it.
//
//  The author is not here. ``HikePhoto/importedAuthorName`` already says who
//  took a photograph that somebody else did, and two fields for one name
//  would be two answers to one question.
//

import Foundation

/// The open licence a photograph was shared under, and the page that says so.
///
/// Present on exactly one kind of ``HikePhoto``: a copy of a Wikimedia Commons
/// photograph, saved with an OpenStreetMap trail. Its presence is also what
/// makes ``HikePhoto/isOwn`` false whatever else the row says — a picture under
/// somebody else's licence is never this hiker's to publish.
nonisolated public struct HikePhotoLicence: Codable, Hashable, Sendable {
    /// The licence's short name as Commons spells it — "CC BY-SA 4.0",
    /// "Public domain". Shown beside the credit.
    public var name: String
    /// The licence's own text, when Commons links one. A public-domain mark
    /// usually carries none, and the credit then links only the source.
    public var url: URL?
    /// The photograph's page on Commons: the full picture, who took it, its
    /// licence and its history — and where a problem with any of them is
    /// raised.
    public var sourceURL: URL

    public init(name: String, url: URL?, sourceURL: URL) {
        self.name = name
        self.url = url
        self.sourceURL = sourceURL
    }
}
