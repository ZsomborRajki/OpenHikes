//
//  WaymarkShapes.swift
//  OpenHikes
//
//  The marks an `osmc:symbol` foreground names, drawn into a sign's frame,
//  and the colours they are painted in.
//
//  Laid out on the sign's height, in thirds, quarters, sixths and eighths,
//  after the drawings on the OpenStreetMap wiki's *Key:osmc:symbol* page. A
//  band or a stripe spans the sign however wide its text made it; a shape —
//  a dot, a diamond, a triangle — keeps to the square in its middle, so a
//  wide sign does not stretch it.
//

import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum WaymarkShapes {
    /// The square in the middle of `frame`, as tall as it.
    static func square(in frame: CGRect) -> CGRect {
        CGRect(x: frame.midX - frame.height / 2, y: frame.minY, width: frame.height, height: frame.height)
    }

    static func draw(_ shape: OSMCSymbol.Shape, paint: OSMCSymbol.Paint, in frame: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: frame)
        context.setFillColor(color(of: paint))
        context.setStrokeColor(color(of: paint))
        context.setLineJoin(.miter)
        context.setLineCap(.butt)
        let side = frame.height
        let box = square(in: frame)
        switch shape {
        case .bar, .stripe, .cross, .lower, .right:
            fillBands(shape, in: frame, context: context)
        case .slash, .backslash, .xShape:
            strokeDiagonals(shape, in: frame, width: side / 4, context: context)
        case .dot:
            context.fillEllipse(in: box.insetBy(dx: side / 4, dy: side / 4))
        case .circle:
            context.setLineWidth(side / 8)
            context.strokeEllipse(in: box.insetBy(dx: side / 4, dy: side / 4))
        case .diamond, .diamondLine, .diamondLeft, .diamondRight:
            drawDiamond(shape, in: box, context: context)
        case .rectangle:
            context.fill(box.insetBy(dx: side / 4, dy: side / 4))
        case .rectangleLine:
            context.setLineWidth(side / 8)
            context.stroke(box.insetBy(dx: side / 4, dy: side / 4))
        case .triangle, .triangleLine, .triangleTurned, .pointer, .corner:
            drawTriangle(shape, in: box, context: context)
        case .lShape, .turnedT, .fork, .arch:
            strokeFigure(shape, in: box, context: context)
        }
        context.restoreGState()
    }

    /// The colour a paint is drawn in.
    static func color(of paint: OSMCSymbol.Paint) -> CGColor {
        switch paint {
        case .black: black
        case .blue: blue
        case .brown: brown
        case .gray: gray
        case .green: green
        case .orange: orange
        case .purple: purple
        case .red: red
        case .white: white
        case .yellow: yellow
        }
    }

    private static let black = cgColor(Color(hex: "#000000") ?? .black)
    private static let blue = cgColor(Color(hex: "#1F4FD8") ?? .blue)
    private static let brown = cgColor(Color(hex: "#8B5A2B") ?? .brown)
    private static let gray = cgColor(Color(hex: "#8E8E93") ?? .gray)
    private static let green = cgColor(Color(hex: "#1E9E3A") ?? .green)
    private static let orange = cgColor(Color(hex: "#F28C00") ?? .orange)
    private static let purple = cgColor(Color(hex: "#7D31C6") ?? .purple)
    private static let red = cgColor(Color(hex: "#E0260D") ?? .red)
    private static let white = cgColor(Color(hex: "#FFFFFF") ?? .white)
    private static let yellow = cgColor(Color(hex: "#FFD200") ?? .yellow)

    private static func cgColor(_ color: Color) -> CGColor {
        #if canImport(UIKit)
        UIColor(color).cgColor
        #else
        NSColor(color).cgColor
        #endif
    }
}

// MARK: - The shapes

nonisolated private extension WaymarkShapes {
    static func fillBands(_ shape: OSMCSymbol.Shape, in frame: CGRect, context: CGContext) {
        let side = frame.height
        switch shape {
        case .bar:
            context.fill(CGRect(x: frame.minX, y: frame.minY + side / 3, width: frame.width, height: side / 3))
        case .stripe:
            context.fill(CGRect(x: frame.midX - side / 6, y: frame.minY, width: side / 3, height: side))
        case .cross:
            context.fill(CGRect(x: frame.minX, y: frame.midY - side / 8, width: frame.width, height: side / 4))
            context.fill(CGRect(x: frame.midX - side / 8, y: frame.minY, width: side / 4, height: side))
        case .lower:
            context.fill(CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: side / 2))
        default:
            context.fill(CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: side))
        }
    }

    static func strokeDiagonals(_ shape: OSMCSymbol.Shape, in frame: CGRect, width: CGFloat, context: CGContext) {
        context.setLineWidth(width)
        if shape != .backslash {
            context.move(to: CGPoint(x: frame.minX, y: frame.maxY))
            context.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
        }
        if shape != .slash {
            context.move(to: CGPoint(x: frame.minX, y: frame.minY))
            context.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        }
        context.strokePath()
    }

    static func drawDiamond(_ shape: OSMCSymbol.Shape, in box: CGRect, context: CGContext) {
        let inset = box.height / 8
        let top = CGPoint(x: box.midX, y: box.minY + inset)
        let bottom = CGPoint(x: box.midX, y: box.maxY - inset)
        let left = CGPoint(x: box.minX + inset, y: box.midY)
        let right = CGPoint(x: box.maxX - inset, y: box.midY)
        switch shape {
        case .diamondLeft:
            context.addLines(between: [top, left, bottom])
        case .diamondRight:
            context.addLines(between: [top, right, bottom])
        default:
            context.addLines(between: [top, right, bottom, left])
        }
        context.closePath()
        if shape == .diamondLine {
            context.setLineWidth(box.height / 8)
            context.strokePath()
        } else {
            context.fillPath()
        }
    }

    static func drawTriangle(_ shape: OSMCSymbol.Shape, in box: CGRect, context: CGContext) {
        let inset = box.height / 6
        let inner = box.insetBy(dx: inset, dy: inset)
        let corners: [CGPoint] = switch shape {
        case .triangleTurned:
            [
                CGPoint(x: inner.minX, y: inner.minY),
                CGPoint(x: inner.maxX, y: inner.minY),
                CGPoint(x: inner.midX, y: inner.maxY),
            ]
        case .pointer:
            [
                CGPoint(x: inner.minX, y: inner.minY),
                CGPoint(x: inner.maxX, y: inner.midY),
                CGPoint(x: inner.minX, y: inner.maxY),
            ]
        case .corner:
            [
                CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.midX, y: box.minY),
                CGPoint(x: box.minX, y: box.midY),
            ]
        default:
            [
                CGPoint(x: inner.midX, y: inner.minY),
                CGPoint(x: inner.maxX, y: inner.maxY),
                CGPoint(x: inner.minX, y: inner.maxY),
            ]
        }
        context.addLines(between: corners)
        context.closePath()
        if shape == .triangleLine {
            context.setLineWidth(box.height / 8)
            context.strokePath()
        } else {
            context.fillPath()
        }
    }

    static func strokeFigure(_ shape: OSMCSymbol.Shape, in box: CGRect, context: CGContext) {
        let inner = box.insetBy(dx: box.height / 6, dy: box.height / 6)
        context.setLineWidth(box.height / 6)
        switch shape {
        case .lShape:
            context.addLines(between: [
                CGPoint(x: inner.minX + inner.width / 4, y: inner.minY),
                CGPoint(x: inner.minX + inner.width / 4, y: inner.maxY),
                CGPoint(x: inner.maxX, y: inner.maxY),
            ])
        case .turnedT:
            context.addLines(between: [CGPoint(x: inner.midX, y: inner.minY), CGPoint(x: inner.midX, y: inner.maxY)])
            context.addLines(between: [CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)])
        case .fork:
            context.addLines(between: [CGPoint(x: inner.midX, y: inner.maxY), CGPoint(x: inner.midX, y: inner.midY)])
            context.addLines(between: [
                CGPoint(x: inner.minX, y: inner.minY),
                CGPoint(x: inner.midX, y: inner.midY),
                CGPoint(x: inner.maxX, y: inner.minY),
            ])
        default:
            context.addArc(
                center: CGPoint(x: inner.midX, y: inner.maxY),
                radius: inner.width / 2,
                startAngle: .pi,
                endAngle: 0,
                clockwise: false
            )
        }
        context.strokePath()
    }
}
