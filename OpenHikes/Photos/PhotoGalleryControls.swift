//
//  PhotoGalleryControls.swift
//  OpenHikes
//
//  What stands over a full-size photograph — who took it, and the way to the
//  next one — laid out by the shape of the screen the photograph is on.
//
//  The pages letterbox rather than crop, so whatever a picture does not fill
//  is black, and where that black is depends on the screen. Upright, an
//  ordinary photograph is wider than the screen's shape and the black is above
//  and below it: the credit goes across under the picture, above the step
//  pill, and lands on black. Turned on its side the screen is wider than any
//  ordinary photograph and the black is at its two sides — so the same credit
//  sat on the picture itself, a fifth of the way up a landscape screen. There
//  it goes in a narrow column at the leading edge instead, where a 4:3 or 3:2
//  photograph leaves black.
//
//  Decided by the frame rather than by the size class, because the hiker's own
//  gallery is also drawn in landscape as the side panel's 320-point column
//  beside the map — a portrait shape on a phone turned on its side, where the
//  black is under the picture again and a column beside the pill would run
//  into it. See ``SheetRoute/revealsMapBeside``.
//
//  A view of its own, measuring its own frame, so a rotation re-runs this and
//  not the gallery that holds it — see *Render isolation, in practice* in the
//  repository instructions.
//

import SwiftUI

/// Where a full-size photograph's credit stands — see ``PhotoGalleryControls``.
///
/// `nonisolated` because it is worked out in a geometry reader's transform.
nonisolated enum PhotoCreditPlacement {
    /// In a narrow column at the leading edge, beside the picture.
    case beside
    /// Across under the picture, above the step pill.
    case underneath

    /// The widest an ordinary photograph is: a camera's 3:2. A frame wider
    /// than that leaves black either side of one, and either side of a
    /// phone's 4:3 by more.
    static let ordinaryAspectRatio: CGFloat = 3 / 2

    /// How wide the column beside the picture may grow. Room for a
    /// licence's name on a line of its own — *CC BY-SA 4.0* is the usual
    /// longest — and no more: a 3:2 photograph on an iPhone turned on its
    /// side leaves about a hundred points of black inside the safe area, and
    /// a 4:3 one about 130.
    static let columnWidth: CGFloat = 110
    /// The column's distance from the safe area's leading edge, which in
    /// landscape is already clear of the Dynamic Island and the screen's
    /// rounded corners.
    static let columnInset: CGFloat = 8

    /// Where the credit goes over pages of `size`.
    init(for size: CGSize) {
        self = size.width > size.height * Self.ordinaryAspectRatio ? .beside : .underneath
    }
}

struct PhotoGalleryControls<Credit: View, Steps: View>: View {
    /// Told where it stands, because a credit in the column is set on two
    /// lines rather than one — see ``PhotoLicenseCredit``.
    private let credit: (PhotoCreditPlacement) -> Credit
    private let steps: Steps

    @State private var placement = PhotoCreditPlacement.underneath

    init(
        @ViewBuilder credit: @escaping (PhotoCreditPlacement) -> Credit,
        @ViewBuilder steps: () -> Steps
    ) {
        self.credit = credit
        self.steps = steps()
    }

    /// One ``GlassStack`` around both, which is the rule this app follows
    /// wherever two pieces of glass sit near each other — separate containers
    /// each sample the backdrop for themselves, and two that nearly touch
    /// render as two panes rather than merging as they approach. See that
    /// type, where the cost is the argument.
    var body: some View {
        GlassStack(spacing: 6) {
            switch placement {
            case .underneath:
                VStack(spacing: 10) {
                    credit(.underneath)
                    steps
                }
            case .beside:
                // The credit first, so it is read before the steps, as it is
                // when it stands above them.
                ZStack(alignment: .bottomLeading) {
                    credit(.beside)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: PhotoCreditPlacement.columnWidth, alignment: .leading)
                        .padding(.leading, PhotoCreditPlacement.columnInset)
                    steps
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onGeometryChange(for: PhotoCreditPlacement.self) { proxy in
            PhotoCreditPlacement(for: proxy.size)
        } action: { placement in
            self.placement = placement
        }
    }
}

extension View {
    /// The type and the glass a photograph's credit is drawn with, wherever
    /// it stands: a capsule for a line across, and a rounded box for a credit
    /// that wraps in the column beside the picture.
    func photoCreditSurface(_ placement: PhotoCreditPlacement) -> some View {
        font(.footnote)
            .padding(.horizontal, placement == .beside ? 10 : 14)
            .padding(.vertical, 8)
            .glassSurface(.regular, in: placement == .beside ? AnyShape(.rect(cornerRadius: 12)) : AnyShape(Capsule()))
    }
}
