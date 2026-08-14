//
//  GPXDocumentTypeTests.swift
//  OpenHikesTests
//
//  Guards the Info.plist half of GPX import. None of this is Swift the
//  compiler can check: the app appears in the Files app's "Open With" list
//  only because of declarations in a property list, and a rename or a merge
//  that drops one of them breaks opening a downloaded .gpx without breaking a
//  build. The type declaration also has a second job — it's what makes
//  `UTType(filenameExtension: "gpx")` resolve at all, which the document
//  picker's allowed content types depend on.
//

import Foundation
@testable import OpenHikes
import Testing
import UniformTypeIdentifiers

@Suite("GPX document type")
struct GPXDocumentTypeTests {
    private static let gpxIdentifier = "com.topografix.gpx"

    private var documentTypes: [[String: Any]] {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
            as? [[String: Any]] ?? []
    }

    @Test("The app declares itself a viewer of GPX documents")
    func declaresDocumentType() throws {
        let gpx = try #require(
            documentTypes.first { type in
                let contentTypes = type["LSItemContentTypes"] as? [String] ?? []
                return contentTypes.contains(Self.gpxIdentifier)
            },
            "Without a CFBundleDocumentTypes entry the app never appears in Files"
        )

        #expect(gpx["CFBundleTypeRole"] as? String == "Viewer")
        // Owner would make OpenHikes the default handler for a format it only
        // reads, displacing whatever mapping app the user actually prefers.
        #expect(gpx["LSHandlerRank"] as? String == "Alternate")
    }

    /// Without this the system copies every opened file into `Documents/Inbox`
    /// instead of lending the original — which still imports, but leaves the
    /// cleanup in ``GPXInbox`` doing all the work.
    @Test("The app opens documents in place")
    func opensInPlace() {
        #expect(
            Bundle.main.object(
                forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace"
            ) as? Bool == true
        )
    }

    /// GPX has no system-declared type, so this resolves only because the app
    /// imports topografix's. A dynamic `dyn.…` identifier here means the
    /// declaration went missing and the document picker is back to matching
    /// every XML file.
    @Test("A .gpx extension resolves to the declared type")
    func resolvesExtension() throws {
        let type = try #require(UTType(filenameExtension: "gpx"))

        #expect(type.identifier == Self.gpxIdentifier)
        #expect(!type.isDynamic)
        // Conformance is what lets the picker and the share sheet treat a GPX
        // file as the text it is rather than an opaque blob.
        #expect(type.conforms(to: .xml))
    }

    @Test("The declared type carries the GPX MIME type")
    func declaresMIMEType() throws {
        let type = try #require(UTType(Self.gpxIdentifier))

        #expect(type.tags[.mimeType]?.contains("application/gpx+xml") == true)
        #expect(type.tags[.filenameExtension]?.contains("gpx") == true)
    }
}
