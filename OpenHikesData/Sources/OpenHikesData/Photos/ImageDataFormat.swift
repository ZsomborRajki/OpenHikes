//
//  ImageDataFormat.swift
//  OpenHikesData
//
//  The extension a photograph's bytes are stored under. Here beside
//  ``HikePhoto``, whose file names are built from it; the store that writes
//  the bytes is `HikePhotoStore`, in the app.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The stored form of an image's bytes: the extension they should be written
/// under, resolved from the bytes themselves rather than from whatever handed
/// them over.
///
/// A picker reports the *asset's* content types, which is not always what the
/// transferred representation turns out to be, and a file named `.jpg`
/// containing HEIC bytes is a bug that only shows up in someone else's photo
/// library. ImageIO is the authority because it is also what reads the file
/// back.
nonisolated public struct ImageDataFormat: Equatable, Sendable {
    /// What the camera path always produces — see
    /// ``HikePhotoStore/encode(_:)``.
    ///
    /// `jpeg` rather than `jpg` because that is what ``detect(in:)`` returns
    /// for JPEG bytes: the extension comes from
    /// `UTType.jpeg.preferredFilenameExtension`, and a constant that disagreed
    /// with the one path that writes files would describe nothing that is
    /// actually on disk.
    public static let jpeg = Self(pathExtension: "jpeg")

    public let pathExtension: String

    /// `nil` when the data is not a decodable image at all, which is the one
    /// answer an import has to be able to give.
    public static func detect(in data: Data) -> Self? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              type.conforms(to: .image),
              let detected = type.preferredFilenameExtension
        else { return nil }
        return Self(pathExtension: detected)
    }

    public init(pathExtension: String) {
        self.pathExtension = pathExtension
    }
}
