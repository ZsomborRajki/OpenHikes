//
//  watch-map-readiness.swift
//  Scripts/lib
//
//  A successful simctl screenshot can still be MapKit's gray loading grid.
//  Check the map's middle, away from the title and controls: its loaded dark
//  terrain has a color tint, while the grid is nearly neutral. The green route
//  alone covers too little of this region to count as a loaded basemap.
//

import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("watch-map-readiness: expected a readable screenshot\n".utf8))
    exit(2)
}

let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
    guard let context = CGContext(
        data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    // Give the pixel rows the same top-left origin as the screenshot.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard rendered else { exit(2) }

var samples = 0
var terrain = 0
var placeholder = 0
for row in stride(from: height * 28 / 100, to: height * 65 / 100, by: 4) {
    for column in stride(from: width / 10, to: width * 9 / 10, by: 4) {
        let offset = (row * width + column) * 4
        let channels = pixels[offset..<(offset + 3)]
        let high = Int(channels.max() ?? 0)
        let low = Int(channels.min() ?? 0)
        if high - low >= 18 { terrain += 1 }
        if high < 90, high - low <= 12 { placeholder += 1 }
        samples += 1
    }
}
let terrainFraction = Double(terrain) / Double(max(samples, 1))
let placeholderFraction = Double(placeholder) / Double(max(samples, 1))
let ready = samples > 0 && terrainFraction >= 0.25 && placeholderFraction < 0.1
print(String(format: "watch map: %.1f%% terrain, %.1f%% loading grid", terrainFraction * 100, placeholderFraction * 100))
exit(ready ? 0 : 1)
