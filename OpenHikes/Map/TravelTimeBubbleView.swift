//
//  TravelTimeBubbleView.swift
//  OpenHikes
//
//  A time in a capsule, standing on a line: the trail maker's route times,
//  and the time left on a walk.
//
//  One look for both, so the bubble a hiker learned while drawing a trail
//  reads the same way on the trail they are walking. What a bubble says, how
//  it gives way to its neighbours and how VoiceOver speaks it are each
//  owner's own — see `MapTrailDraftRouteChoices.swift` and
//  `MapCoordinator+WalkTimeLeft.swift`.
//

import MapKit
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
class TravelTimeBubbleView: MKAnnotationView {
    private static let padding = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    private static let shadowOpacity: Float = 0.2

    private let label = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .rectangle
        label.font = .preferredFont(forTextStyle: .caption1).bold
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        addSubview(label)
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Self.shadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("A travel time bubble is created in code only")
    }

    /// Draws `time` in white on `fill`, or in the label colour on the system
    /// background when there is no fill, and sizes the capsule to it.
    func showTime(_ time: String?, fill: UIColor?) {
        label.text = time
        label.textColor = fill == nil ? .label : .white
        backgroundColor = fill ?? .systemBackground
        let size = label.intrinsicContentSize
        bounds = CGRect(
            x: 0,
            y: 0,
            width: size.width + Self.padding.left + Self.padding.right,
            height: size.height + Self.padding.top + Self.padding.bottom
        )
        label.frame = bounds.inset(by: Self.padding)
        layer.cornerRadius = bounds.height / 2
    }
}

private extension UIFont {
    var bold: UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
#endif
