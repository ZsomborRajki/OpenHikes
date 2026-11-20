//
//  RouteTrimChart.swift
//  OpenHikes
//
//  *Edit Route*'s trimmer: the line's heights from start to finish, with a
//  handle on each end of the part a save would keep, as Photos trims a video.
//
//  The chart is the line laid out straight, which is what makes it the place
//  to trim an out-and-back or a loop with a shared stem: on the map those
//  passes lie on top of each other, and here each has its own stretch.
//
//  ## Two views, so a drag redraws one
//
//  ``RouteTrimChart`` draws the heights and reads only which line is loaded.
//  ``RouteTrimRange`` over it reads the two cuts, so a handle moving redraws
//  the handles and the dimming and not the shape of twenty thousand points
//  under them — see *Render isolation, in practice* in `AGENTS.md`.
//

import OpenHikesData
import SwiftUI

struct RouteTrimChart: View {
    let session: RouteTrimSession
    let tint: Color

    static let height: CGFloat = 96

    var body: some View {
        // The one read: a new line is a new shape.
        _ = session.lineRevision
        return ZStack {
            if let profile = session.line?.profile {
                RouteTrimSilhouette(
                    samples: profile.samples,
                    totalMeters: profile.totalDistanceMeters,
                    range: profile.elevationRange
                )
                .fill(tint.opacity(Self.fillOpacity))
                .padding(.horizontal, RouteTrimRange.handleWidth)
                RouteTrimRange(session: session, tint: tint)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
    }

    private static let fillOpacity = 0.35
}

/// The line's heights as one filled shape, or a level band for a line that
/// has none: an import without elevation is still a line to trim.
nonisolated struct RouteTrimSilhouette: Shape {
    let samples: [ElevationSample]
    let totalMeters: Double
    let range: ClosedRange<Double>?

    /// How much of the height the lowest point still stands, so the shape
    /// has a body where the trail is at its lowest.
    private static let floorShare = 0.25

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard totalMeters > 0, let range, range.upperBound > range.lowerBound, samples.count > 1 else {
            path.addRect(rect.insetBy(dx: 0, dy: rect.height * Self.floorShare))
            return path
        }
        let span = range.upperBound - range.lowerBound
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for sample in samples {
            let across = sample.distanceMeters / totalMeters
            let up = Self.floorShare + (1 - Self.floorShare) * (sample.elevation - range.lowerBound) / span
            path.addLine(to: CGPoint(x: rect.minX + rect.width * across, y: rect.maxY - rect.height * up))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The two handles, the frame between them and the dimming outside it.
struct RouteTrimRange: View {
    let session: RouteTrimSession
    let tint: Color

    /// Where each handle's cut stood when a finger took it, so a drag moves
    /// the cut by as far as the finger travels and never jumps to it.
    @State private var startOrigin: Double?
    @State private var endOrigin: Double?

    static let handleWidth: CGFloat = 18
    private static let frameWidth: CGFloat = 3
    private static let cornerRadius: CGFloat = 6
    /// How far past its own edge a handle can be taken hold of.
    private static let reach: CGFloat = 13
    private static let dimOpacity = 0.6
    /// What one step of VoiceOver's adjust moves a cut by, as a share of the
    /// line.
    private static let stepFraction = 0.02

    var body: some View {
        GeometryReader { proxy in
            let plot = max(proxy.size.width - 2 * Self.handleWidth, 1)
            let total = max(session.totalMeters, 1)
            let startX = Self.handleWidth + plot * session.startMeters / total
            let endX = Self.handleWidth + plot * session.endMeters / total
            ZStack(alignment: .topLeading) {
                dim(from: 0, to: startX)
                dim(from: endX, to: proxy.size.width)
                frame(from: startX, to: endX, height: proxy.size.height)
                handle(.start, at: startX - Self.handleWidth, height: proxy.size.height, metersPerPoint: total / plot)
                handle(.end, at: endX, height: proxy.size.height, metersPerPoint: total / plot)
            }
        }
    }

    private func dim(from start: CGFloat, to end: CGFloat) -> some View {
        Rectangle()
            .fill(.background.opacity(Self.dimOpacity))
            .frame(width: max(end - start, 0))
            .offset(x: start)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The rails along the top and the bottom of the kept part.
    private func frame(from start: CGFloat, to end: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(tint).frame(height: Self.frameWidth)
            Spacer(minLength: 0)
            Rectangle().fill(tint).frame(height: Self.frameWidth)
        }
        .frame(width: max(end - start, 0), height: height)
        .offset(x: start)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func handle(
        _ handle: RouteTrimHandle,
        at leading: CGFloat,
        height: CGFloat,
        metersPerPoint: Double
    ) -> some View {
        let isStart = handle == .start
        return UnevenRoundedRectangle(
            topLeadingRadius: isStart ? Self.cornerRadius : 0,
            bottomLeadingRadius: isStart ? Self.cornerRadius : 0,
            bottomTrailingRadius: isStart ? 0 : Self.cornerRadius,
            topTrailingRadius: isStart ? 0 : Self.cornerRadius
        )
        .fill(tint)
        .overlay {
            Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
        .frame(width: Self.handleWidth, height: height)
        .padding(.horizontal, Self.reach)
        .contentShape(.rect)
        .offset(x: leading - Self.reach)
        .gesture(drag(handle, metersPerPoint: metersPerPoint))
        .accessibilityElement()
        .accessibilityLabel(isStart ? Text("Start of route") : Text("End of route"))
        .accessibilityValue(RouteTrimFormat.length(session.position(of: handle)))
        .accessibilityAdjustableAction { direction in
            let step = session.totalMeters * Self.stepFraction
            switch direction {
            case .increment: session.move(handle, to: session.position(of: handle) + step)
            case .decrement: session.move(handle, to: session.position(of: handle) - step)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(isStart ? "route-trim-start" : "route-trim-end")
    }

    private func drag(_ handle: RouteTrimHandle, metersPerPoint: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = origin(of: handle) ?? session.position(of: handle)
                setOrigin(origin, of: handle)
                session.move(handle, to: origin + Double(value.translation.width) * metersPerPoint)
            }
            .onEnded { _ in setOrigin(nil, of: handle) }
    }

    private func origin(of handle: RouteTrimHandle) -> Double? {
        switch handle {
        case .start: startOrigin
        case .end: endOrigin
        }
    }

    private func setOrigin(_ origin: Double?, of handle: RouteTrimHandle) {
        switch handle {
        case .start: if startOrigin != origin { startOrigin = origin }
        case .end: if endOrigin != origin { endOrigin = origin }
        }
    }
}

/// How *Edit Route* writes a length, as the screens around it do.
nonisolated enum RouteTrimFormat {
    static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
