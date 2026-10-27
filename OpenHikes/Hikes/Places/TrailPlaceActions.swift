//
//  TrailPlaceActions.swift
//  OpenHikes
//
//  Every place card measures its actual buttons at the available column
//  width. Two caption lines are ordinary on a phone; taller captions move
//  whole buttons to another row. A fixed width or an unconstrained ideal
//  width would reject even short English captions on a standard-size phone.
//

import SwiftUI

struct TrailPlaceActions<Content: View>: View {
    @ScaledMetric(relativeTo: .caption) private var captionLineHeight: CGFloat = 15
    @ViewBuilder let content: Content

    var body: some View {
        TrailPlaceActionLayout(captionLineHeight: captionLineHeight) { content }
            .buttonBorderShape(.roundedRectangle(radius: TrailPlaceActionLabelStyle.cornerRadius))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TrailPlaceActionLayout: Layout {
    let captionLineHeight: CGFloat
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(width proposed: CGFloat?, subviews: Subviews) -> [CGRect] {
        guard !subviews.isEmpty else { return [] }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let available = proposed.flatMap { $0.isFinite ? $0 : nil }
        let width = max(0, available ?? (ideal.map(\.width).reduce(0, +) + spacing * CGFloat(subviews.count - 1)))
        var columns = subviews.count
        var sizes: [CGSize] = []
        while true {
            let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)) }
            if columns == 1 || zip(sizes, ideal).allSatisfy({ $0.height <= $1.height + captionLineHeight + 1 }) {
                break
            }
            columns = (columns + 1) / 2
        }
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var result: [CGRect] = []
        var top: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let end = min(start + columns, subviews.count)
            let height = sizes[start..<end].map(\.height).max() ?? 0
            for index in start..<end {
                result.append(CGRect(
                    x: CGFloat(index - start) * (columnWidth + spacing), y: top, width: columnWidth, height: height
                ))
            }
            top += height + spacing
        }
        return result
    }
}
