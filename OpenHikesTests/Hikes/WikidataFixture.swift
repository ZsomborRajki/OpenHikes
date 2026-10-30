//
//  WikidataFixture.swift
//  OpenHikesTests
//
//  What Wikidata, Wikipedia and Commons answered about the Watzmann
//  (Q163919) and Hong Kong (Q8646) on 2026-10-30, cut down to the keys read
//  and a few beside them, for the suites that read those answers and the one
//  that asks for them.
//

import Foundation

nonisolated enum WikidataFixture {
    /// The item: a German and an English article, and one image. The
    /// coordinate statement is there to be skipped, as most of an item's
    /// statements are, because its value is an object rather than a name.
    static let watzmann = Data(#"""
    {"entities":{"Q163919":{"type":"item","id":"Q163919",
    "sitelinks":{"dewiki":{"site":"dewiki","title":"Watzmann","badges":["Q17437798"]},
    "enwiki":{"site":"enwiki","title":"Watzmann","badges":[]}},
    "claims":{"P625":[{"mainsnak":{"snaktype":"value","property":"P625","datavalue":{"value":
    {"latitude":47.5546,"longitude":12.9223,"precision":0.0001},"type":"globecoordinate"},
    "datatype":"globe-coordinate"},"type":"statement","rank":"normal"}],
    "P18":[{"mainsnak":{"snaktype":"value","property":"P18","datavalue":{"value":"Watzmann von Norden.jpg",
    "type":"string"},"datatype":"commonsMedia"},"type":"statement","rank":"normal"}]}}},"success":1}
    """#.utf8)

    /// The same item linked to the German article alone — the shape eight of
    /// the nine huts' items in the Berchtesgaden box had that day.
    static let watzmannInGermanOnly = Data(#"""
    {"entities":{"Q163919":{"type":"item","id":"Q163919",
    "sitelinks":{"dewiki":{"site":"dewiki","title":"Watzmann","badges":["Q17437798"]}},
    "claims":{"P18":[{"mainsnak":{"snaktype":"value","property":"P18","datavalue":{"value":"Watzmann von Norden.jpg",
    "type":"string"},"datatype":"commonsMedia"},"type":"statement","rank":"normal"}]}}},"success":1}
    """#.utf8)

    /// Hong Kong (Q8646), asked about Cantonese and English: Cantonese's
    /// Wikipedia is filed as `zh_yuewiki`, not under its language's code.
    static let hongKong = Data(#"""
    {"entities":{"Q8646":{"type":"item","id":"Q8646",
    "sitelinks":{"enwiki":{"site":"enwiki","title":"Hong Kong","badges":["Q17437798"]},
    "zh_yuewiki":{"site":"zh_yuewiki","title":"香港","badges":["Q17437796"]}},
    "claims":{"P18":[{"mainsnak":{"snaktype":"value","property":"P18","datavalue":{"value":
    "Hong Kong from Victoria Peak1.jpg","type":"string"},"datatype":"commonsMedia"},"type":"statement",
    "rank":"normal"}]}}},"success":1}
    """#.utf8)

    /// The Cantonese article's summary, from zh-yue.wikipedia.org — whose
    /// own `lang` is `yue`, which is not its host name.
    static let hongKongInCantonese = Data(#"""
    {"type":"standard","title":"香港",
    "titles":{"canonical":"香港","normalized":"香港","display":"香港"},
    "wikibase_item":"Q8646","lang":"yue","dir":"ltr",
    "extract":"香港，全名香港特別行政區 係中華人民共和國嘅一個特別行政區。",
    "content_urls":{"desktop":{"page":"https://zh-yue.wikipedia.org/wiki/%E9%A6%99%E6%B8%AF"},
    "mobile":{"page":"https://zh-yue.wikipedia.org/wiki/%E9%A6%99%E6%B8%AF"}}}
    """#.utf8)

    /// The German article's summary.
    static let summary = Data(#"""
    {"type":"standard","title":"Watzmann","displaytitle":"<span>Watzmann</span>",
    "titles":{"canonical":"Watzmann","normalized":"Watzmann","display":"Watzmann"},
    "wikibase_item":"Q163919","lang":"de","dir":"ltr",
    "extract":"Der Watzmann ist der zentrale Gebirgsstock der Berchtesgadener Alpen.",
    "content_urls":{"desktop":{"page":"https://de.wikipedia.org/wiki/Watzmann"},
    "mobile":{"page":"https://de.m.wikipedia.org/wiki/Watzmann"}}}
    """#.utf8)

    /// Where the image's thumbnail is, as Commons named it.
    static let thumbnail = "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d7/Watzmann_von_Norden.jpg/"
        + "960px-Watzmann_von_Norden.jpg"

    /// The image's details, asked of Commons by its name.
    static let fileInfo = fileInfo(mime: "image/jpeg")

    /// The same details for a file of type `mime`.
    static func fileInfo(mime: String) -> Data {
        Data(#"""
        {"batchcomplete":true,"query":{"pages":[{"pageid":117867472,"ns":6,
        "title":"File:Watzmann von Norden.jpg","imageinfo":[{"timestamp":"2022-04-28T10:15:42Z",
        "width":8883,"height":3866,"mime":"\#(mime)","thumburl":"\#(thumbnail)",
        "descriptionurl":"https://commons.wikimedia.org/wiki/File:Watzmann_von_Norden.jpg",
        "extmetadata":{"DateTimeOriginal":{"value":"2021-10-15 07:18:56"},
        "Artist":{"value":"<a href=\"//commons.wikimedia.org/wiki/User:Milseburg\">Jörg Braukmann</a>"},
        "LicenseShortName":{"value":"CC BY-SA 4.0"},
        "LicenseUrl":{"value":"https://creativecommons.org/licenses/by-sa/4.0"},
        "Restrictions":{"value":""}}}]}]}}
        """#.utf8)
    }
}
