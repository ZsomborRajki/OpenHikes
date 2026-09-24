//
//  GPXFileImporter.swift
//  OpenHikes
//
//  The document picker the sheet's *Import GPX* opens.
//

import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Several files at once, so a folder of walks is one trip through the
    /// picker rather than one per file; their failures come back as one alert
    /// — see ``HikeImportFailure/several(_:)``.
    ///
    /// - Parameter onFailed: the picker could not hand over a file at all.
    ///   Rare, but dropping it would be the same silent no-op the import path
    ///   itself was fixed for, and from the hiker's side it is the same story
    ///   as an unreadable file, so it is told the same way.
    func gpxFileImporter(
        isPresented: Binding<Bool>,
        onImport: @escaping ([URL]) -> Void,
        onFailed: @escaping () -> Void
    ) -> some View {
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: GPXContentTypes.importable,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls): onImport(urls)
            case .failure: onFailed()
            }
        }
    }
}

nonisolated enum GPXContentTypes {
    /// GPX has no system-declared UTType; the app imports topografix's, which
    /// is what makes the lookup below resolve. XML stays as a fallback for a
    /// track exported under a different extension.
    static var importable: [UTType] {
        var types: [UTType] = []
        if let gpx = UTType(filenameExtension: "gpx") { types.append(gpx) }
        types.append(.xml)
        return types
    }
}
