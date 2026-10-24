//
//  fit-screenshot.swift
//  Scripts/lib
//
//  Brings an exported App Store frame to what App Store Connect accepts: its
//  pixels the right way up, at the size of a display it takes. Run by
//  `Scripts/lib/screenshots.sh` on every frame it exports:
//
//      swift Scripts/lib/fit-screenshot.swift <width>x<height>... -- <frame.png>...
//
//  **The pixel XCTest leaves off.** The iPhone Duo's inner display is
//  2007 × 2853 pixels, and App Store Connect takes exactly that — or exactly
//  2853 × 2007 — for it. XCTest captures it at 2006 × 2852: a screen of
//  669 × 951 points at three pixels a point reaches `XCUIScreenshot` as
//  668.67 × 950.67, and the image comes out a pixel short each way.
//  `app.screenshot()` is no different. App Store Connect refuses a frame a
//  pixel off, so a set shot on the open Duo could not be uploaded at all.
//
//  The missing row and column are put back by repeating the last ones, which
//  leaves every pixel the frame had where it was. Scaling the frame up to size
//  would have filled the gap too, at the cost of resampling everything in it —
//  every line of text, every route — by a factor of 1.0005.
//
//  **A frame on its side.** A display captured in landscape — the open Duo's
//  inner display, the way up it opens — is stored as that display's own
//  portrait pixels, with an EXIF orientation that tells a viewer to give them
//  a quarter turn. Preview honours the tag and shows a landscape frame;
//  anything that reads only the pixels sees a portrait one lying on its side.
//  So a frame stored any way but upright is turned in its pixels first and
//  written without the tag, rather than leaving to chance whether an upload
//  reads it. A quarter turn moves pixels and resamples none.
//
//  A frame is resized only when, upright, it is within a pixel of one of the
//  sizes it is given, each way, and short rather than over. Anything else
//  keeps its size — the script lists every frame's — because a frame two
//  pixels out is from a device nobody listed, and is the script's problem to
//  report, not this file's to hide.
//

import AppKit
import Foundation
import ImageIO

struct PixelSize: Equatable {
    let width: Int
    let height: Int

    init?(_ text: Substring) {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        self.width = width
        self.height = height
    }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(of image: CGImage) {
        self.init(width: image.width, height: image.height)
    }

    var description: String { "\(width) × \(height)" }

    /// Whether `self` is at most one pixel short of `target` each way, and
    /// short in at least one of them.
    func isOnePixelShort(of target: PixelSize) -> Bool {
        let wide = target.width - width
        let tall = target.height - height
        return (0...1).contains(wide) && (0...1).contains(tall) && wide + tall > 0
    }
}

let canvasSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fit-screenshot: \(message)\n".utf8))
    exit(1)
}

/// A blank canvas of `size` in `image`'s color space, drawn on without
/// interpolation: every pixel this file moves lands on a whole pixel.
func canvas(_ size: PixelSize, for image: CGImage, path: String) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: size.width,
        height: size.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: image.colorSpace ?? canvasSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fail("cannot make a \(size.description) canvas for \(path)")
    }
    context.interpolationQuality = CGInterpolationQuality.none
    return context
}

/// `image` turned the way an EXIF `orientation` says to show it. A screen is
/// captured upright (1), upside down (3) or on either side (6, 8), and never
/// mirrored, so a mirrored orientation is refused rather than guessed at.
func upright(_ image: CGImage, orientation: Int, path: String) -> CGImage {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    // Where each stored pixel lands, written out, because `rotated(by:)`
    // builds a quarter turn from a cosine that is not quite zero.
    let turn: CGAffineTransform
    let size: PixelSize
    switch orientation {
    case 1:
        return image
    case 3:
        turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        size = PixelSize(width: image.width, height: image.height)
    case 6:
        turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        size = PixelSize(width: image.height, height: image.width)
    case 8:
        turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        size = PixelSize(width: image.height, height: image.width)
    default:
        fail("\(path) is stored mirrored (EXIF orientation \(orientation)), which no screen capture is")
    }
    let context = canvas(size, for: image, path: path)
    context.concatenate(turn)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let turned = context.makeImage() else { fail("cannot turn \(path) upright") }
    return turned
}

/// `image` on a canvas of `target`, with its last row and column repeated
/// into the pixel it is short of.
func padded(_ image: CGImage, to target: PixelSize, path: String) -> CGImage {
    let size = PixelSize(of: image)
    let context = canvas(target, for: image, path: path)
    // Core Graphics counts rows from the bottom, so the frame is drawn at the
    // top of the canvas, and its last row — the bottom one — is stretched over
    // the row below it.
    let extraRows = target.height - size.height
    let extraColumns = target.width - size.width
    context.draw(image, in: CGRect(x: 0, y: extraRows, width: size.width, height: size.height))
    if extraColumns > 0, let column = image.cropping(to: CGRect(x: size.width - 1, y: 0, width: 1, height: size.height)) {
        context.draw(column, in: CGRect(x: size.width, y: extraRows, width: extraColumns, height: size.height))
    }
    if extraRows > 0, let row = image.cropping(to: CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)) {
        context.draw(row, in: CGRect(x: 0, y: 0, width: size.width, height: extraRows))
    }
    if extraRows > 0, extraColumns > 0,
       let corner = image.cropping(to: CGRect(x: size.width - 1, y: size.height - 1, width: 1, height: 1)) {
        context.draw(corner, in: CGRect(x: size.width, y: 0, width: extraColumns, height: extraRows))
    }
    guard let fitted = context.makeImage() else { fail("cannot fit \(path) to \(target.description)") }
    return fitted
}

let arguments = CommandLine.arguments.dropFirst()
guard let separator = arguments.firstIndex(of: "--") else {
    fail("usage: fit-screenshot.swift <width>x<height>... -- <frame.png>...")
}
let sizes: [PixelSize] = arguments[..<separator].map { text in
    guard let size = PixelSize(Substring(text)) else { fail("not a size: \(text)") }
    return size
}
let frames = arguments[arguments.index(after: separator)...]

for path in frames {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let stored = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("cannot read \(path)")
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    let orientation = properties?[kCGImagePropertyOrientation as String] as? Int ?? 1
    let image = upright(stored, orientation: orientation, path: path)
    let target = sizes.first { PixelSize(of: image).isOnePixelShort(of: $0) }
    if target == nil && orientation == 1 { continue }
    let fitted = target.map { padded(image, to: $0, path: path) } ?? image

    // Written without properties, so the orientation the capture carried is
    // not written back over pixels that are already upright.
    guard let data = NSBitmapImageRep(cgImage: fitted).representation(using: .png, properties: [:]) else {
        fail("cannot encode \(path)")
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fail("cannot write \(path): \(error.localizedDescription)")
    }
    let turned = orientation == 1 ? "" : ", turned upright"
    print("\(url.lastPathComponent): \(PixelSize(of: stored).description) → \(PixelSize(of: fitted).description)\(turned)")
}
