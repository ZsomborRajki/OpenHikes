//
//  MapGlass.swift
//  OpenHikes
//
//  What the map's UIKit controls stand on, on every release the app supports.
//
//  The glyph capsules, the tracking button, the attribution line and the
//  *Search this area* pill are UIKit views over the `MKMapView`, drawn with
//  iOS 26's `UIGlassEffect` and shaped by its `cornerConfiguration`. Below 26
//  neither exists, so each piece is the thin material iOS 18's own map
//  controls sit on, clipped to the same shape — ``EarlierMapGlassView``. Its
//  capsule recomputes its corners from its height on every layout, because a
//  layer radius is a number where a corner configuration is a shape. A tint
//  is a fill under the content rather than colour in the glass. The container
//  that merges neighbouring capsules into one pill is a plain view there, so
//  they stand as the separate circles iOS 18's map controls are.
//
//  The branches live here and nowhere else, so the controls ask for a shape
//  and never for a release.
//

#if os(iOS)
import UIKit

enum MapGlass {
    /// The outline a piece of glass is cut to.
    enum Shape: Equatable {
        /// Fully rounded ends, whatever the height.
        case capsule
        /// Corners of a fixed radius.
        case rounded(CGFloat)
    }

    /// A piece of untinted glass cut to `shape`, laid out by constraints.
    static func view(_ shape: Shape) -> UIVisualEffectView {
        let glass: UIVisualEffectView
        if #available(iOS 26.0, *) {
            glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            switch shape {
            case .capsule:
                glass.cornerConfiguration = .capsule()
            case .rounded(let radius):
                glass.cornerConfiguration = .corners(radius: .fixed(radius))
            }
        } else {
            glass = EarlierMapGlassView(shape: shape)
        }
        glass.translatesAutoresizingMaskIntoConstraints = false
        return glass
    }

    /// Colours `glass` with `tint`, or clears it — the recording red of the
    /// maker's record button.
    ///
    /// The tint is a fill below 26, under the glyph, so a white glyph keeps
    /// the contrast it has on the tinted glass above it.
    static func tint(_ glass: UIVisualEffectView, with tint: UIColor?) {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = tint
            glass.effect = effect
        } else {
            glass.contentView.backgroundColor = tint
        }
    }

    /// The view that merges the glass shapes inside it as they come within
    /// `spacing` of each other, rendering them in one pass.
    static func container(spacing: CGFloat) -> UIVisualEffectView {
        let container: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let effect = UIGlassContainerEffect()
            effect.spacing = spacing
            container = UIVisualEffectView(effect: effect)
        } else {
            container = UIVisualEffectView(effect: nil)
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        return container
    }
}

/// The thin material, clipped to a ``MapGlass/Shape`` by its layer: what a
/// piece of map glass is below iOS 26.
final class EarlierMapGlassView: UIVisualEffectView {
    let shape: MapGlass.Shape

    init(shape: MapGlass.Shape) {
        self.shape = shape
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        clipsToBounds = true
        layer.cornerCurve = .continuous
        if case .rounded(let radius) = shape {
            layer.cornerRadius = radius
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("A piece of map glass is created in code only")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if shape == .capsule {
            layer.cornerRadius = bounds.height / 2
        }
    }
}
#endif
