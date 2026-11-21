//
//  CatalogIconsTests.swift
//  OpenHikesVectorTilesTests
//
//  The icons a drawn tile's points carry: however many tiles ask at once,
//  one icon is drawn at a time, because the asset catalog crashes the app
//  when two threads read it together — see `CatalogIcons`.
//

import CoreGraphics
@testable import OpenHikesVectorTiles
import Synchronization
import Testing

@Suite("Catalog icons")
struct CatalogIconsTests {
    @Test("icons asked for from many threads at once are drawn one at a time, and each once")
    func drawsOneAtATime() async {
        let probe = RenderProbe()
        let icons = CatalogIcons { _, _, size in probe.draw(size) }
        let iconCount = 40
        let stagger = 5

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask { @concurrent in
                    // Every worker asks for every icon, each from a different
                    // one, so most requests are for an icon not kept yet.
                    for index in 0..<iconCount {
                        let side = CGFloat((index + worker * stagger) % iconCount + 1)
                        _ = icons.image(asset: "icon", fill: nil, size: CGSize(width: side, height: side))
                    }
                }
            }
        }

        #expect(probe.mostAtOnce == 1)
        #expect(probe.drawn == iconCount)
    }
}

/// A stand-in for the catalog's renderer that counts how many draw at once.
/// It draws a real picture, so a second thread has time to arrive while one
/// is inside.
private final class RenderProbe: Sendable {
    private struct State {
        var inside = 0
        var mostAtOnce = 0
        var drawn = 0
    }

    private let state = Mutex(State())
    private static let side = 256

    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }
    var drawn: Int { state.withLock { $0.drawn } }

    func draw(_ size: CGSize) -> CGImage? {
        state.withLock { state in
            state.inside += 1
            state.mostAtOnce = max(state.mostAtOnce, state.inside)
            state.drawn += 1
        }
        defer { state.withLock { $0.inside -= 1 } }
        guard let context = CGContext(
            data: nil,
            width: Self.side,
            height: Self.side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
