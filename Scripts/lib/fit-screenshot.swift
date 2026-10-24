//
//  fit-screenshot.swift
//  Scripts/lib
//
//  Brings an exported App Store frame up to the size App Store Connect
//  accepts when XCTest has captured it one pixel short. Run by
//  `Scripts/lib/screenshots.sh` on every frame it exports:
//
//      swift Scripts/lib/fit-screenshot.swift <width>x<height>... -- <frame.png>...
//
//  The iPhone Duo's inner display is 2007 × 2853 pixels, and App Store Connect
//  takes exactly that — or exactly 2853 × 2007 — for it. XCTest captures it at
//  2006 × 2852: a screen of 669 × 951 points at three pixels a point reaches
//  `XCUIScreenshot` as 668.67 × 950.67, and the image comes out a pixel short
//  each way. `app.screenshot()` is no different. App Store Connect refuses a
//  frame a pixel off, so a set shot on the open Duo could not be uploaded at
//  all.
//
//  The missing row and column are put back by repeating the last ones, which
//  leaves every pixel the frame had where it was. Scaling the frame up to size
//  would have filled the gap too, at the cost of resampling everything in it —
//  every line of text, every route — by a factor of 1.0005.
//
//  A frame is touched only when it is within a pixel of one of the sizes it is
//  given, each way, and short rather than over; anything else is left as it is
//  and said to be, because a frame two pixels out is from a device nobody
//  listed and is the script's problem to report, not this file's to hide.
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

    var description: String { "\(width) × \(height)" }

    /// Whether `self` is at most one pixel short of `target` each way, and
    /// short in at least one of them.
    func isOnePixelShort(of target: PixelSize) -> Bool {
        let wide = target.width - width
        let tall = target.height - height
        return (0...1).contains(wide) && (0...1).contains(tall) && wide + tall > 0
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fit-screenshot: \(message)\n".utf8))
    exit(1)
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
let canvasSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

for path in frames {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("cannot read \(path)")
    }
    let size = PixelSize(width: image.width, height: image.height)
    guard let target = sizes.first(where: { size.isOnePixelShort(of: $0) }) else { continue }

    guard let context = CGContext(
        data: nil,
        width: target.width,
        height: target.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: image.colorSpace ?? canvasSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fail("cannot make a \(target.description) canvas for \(path)")
    }
    // Core Graphics counts rows from the bottom, so the frame is drawn at the
    // top of the canvas, and its last row — the bottom one — is stretched over
    // the row below it.
    let extraRows = target.height - size.height
    let extraColumns = target.width - size.width
    context.interpolationQuality = CGInterpolationQuality.none
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

    guard let fitted = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: fitted).representation(using: .png, properties: [:]) else {
        fail("cannot encode \(path)")
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fail("cannot write \(path): \(error.localizedDescription)")
    }
    print("\(url.lastPathComponent): \(size.description) → \(target.description)")
}
