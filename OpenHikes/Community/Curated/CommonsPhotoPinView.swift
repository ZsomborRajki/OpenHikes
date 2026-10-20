//
//  CommonsPhotoPinView.swift
//  OpenHikes
//
//  A Wikimedia Commons photograph on the map, drawn as the photograph.
//
//  **The picture is the pin.** A camera glyph in a marker says *there is a
//  photograph here* and makes the hiker open each one to find out whether it
//  is the lake or the car park; a thumbnail answers that from the map, which
//  is the whole of what a planning map is for. So each is a small rounded
//  photograph with a white edge, the way Photos draws its places map.
//
//  **And it gives way.** A search can find sixteen in a valley, and the map
//  has pins that matter more: the photographs are below them, so MapKit hides
//  one a more important pin overlaps and a zoom brings it back.
//
//  **Or it stands for several.** The *Community* tab draws photographs too
//  close together to tell apart as one thumbnail with a count in its corner,
//  as Photos draws a group on its map — see `MapCommunityCommonsPhotos.swift`.
//  Same view, so a group looks like the photographs it stands for.
//
//  Shared by the trail maker's photographs (`MapTrailDraftPhotos.swift`) and
//  the *Community* tab's. Each sets its own accessibility identifier, because
//  a tap on one does something different from a tap on the other.
//

import MapKit
import OpenHikesData
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
/// A thumbnail standing on the spot it was taken.
final class CommonsPhotoPinView: MKAnnotationView {
    /// The thumbnail's side, in points: a fingertip, and a picture big
    /// enough to tell a lake from a road.
    static let side: CGFloat = 44
    private static let cornerRadius: CGFloat = 8
    private static let edge: CGFloat = 2
    /// Below the maker's stops and places and the community's hike markers,
    /// which are `.defaultHigh` and above, and above MapKit's own labels.
    private static let priority = MKFeatureDisplayPriority(rawValue: 500)
    private static let shadowOpacity: Float = 0.3
    private static let shadowRadius: CGFloat = 3
    private static let shadowDrop: CGFloat = 1
    /// Decoded at the screen's scale and no more.
    private static let pixelsPerPoint: CGFloat = 3
    /// The count a group carries: dark under white figures, edged in the
    /// thumbnail's white, so it reads over a bright sky and a dark map alike.
    private static let countHeight: CGFloat = 18
    private static let countPadding: CGFloat = 5
    private static let countInset: CGFloat = 3
    private static let countFontSize: CGFloat = 12
    private static let countEdge: CGFloat = 1.5
    private static let countOpacity: CGFloat = 0.75

    private let imageView = UIImageView()
    /// How many photographs a group stands for, hidden on a single one.
    private let countLabel = UILabel()
    /// Which photograph is on screen, so a decode that lands after the view
    /// has been recycled onto another pin is dropped rather than drawn.
    private var shown: CommonsPhoto?
    private var loadTask: Task<Void, Never>?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        // Standing on the spot rather than centred on it, like a pin.
        centerOffset = CGPoint(x: 0, y: -Self.side / 2)
        canShowCallout = false
        // Below the pins that matter more, and hidden by them — see the file
        // header.
        displayPriority = Self.priority
        collisionMode = .rectangle
        backgroundColor = .white
        layer.cornerRadius = Self.cornerRadius
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = Self.shadowOpacity
        layer.shadowRadius = Self.shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: Self.shadowDrop)
        imageView.frame = bounds.insetBy(dx: Self.edge, dy: Self.edge)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = Self.cornerRadius - Self.edge
        imageView.backgroundColor = .secondarySystemFill
        addSubview(imageView)
        countLabel.font = .monospacedDigitSystemFont(ofSize: Self.countFontSize, weight: .bold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.backgroundColor = UIColor.black.withAlphaComponent(Self.countOpacity)
        countLabel.layer.borderColor = UIColor.white.cgColor
        countLabel.layer.borderWidth = Self.countEdge
        countLabel.layer.cornerRadius = Self.countHeight / 2
        countLabel.clipsToBounds = true
        countLabel.isHidden = true
        addSubview(countLabel)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        shown = nil
        imageView.image = nil
    }

    /// Points the view at a photograph, or at the one drawn for a group of
    /// `count`. Cheap to call again with the same one.
    func show(_ photo: CommonsPhoto, standingFor count: Int = 1) {
        // A group is named by its size: the credit belongs to one picture of
        // several, and each is credited on the screen a tap opens.
        accessibilityLabel = count > 1
            ? String(localized: "\(count) photos")
            : PhotoLicenseCredit.line(author: photo.credit.author, license: photo.credit.license)
        showCount(count)
        guard shown != photo else { return }
        shown = photo
        imageView.image = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // The decode the community strip owns, at this box's size.
            let decoded = await CommunityPhotoTile.decodeUIImage(
                photo.fileURL,
                maxPixelSize: Int(Self.side * Self.pixelsPerPoint)
            )
            guard let self, shown == photo else { return }
            imageView.image = decoded
        }
    }

    /// The count in the top trailing corner, inside the thumbnail so a tap
    /// on it lands on the pin, or nothing for a single photograph.
    private func showCount(_ count: Int) {
        countLabel.isHidden = count < 2
        guard count > 1 else { return }
        countLabel.text = count.formatted()
        let width = max(Self.countHeight, countLabel.intrinsicContentSize.width + 2 * Self.countPadding)
        countLabel.frame = CGRect(
            x: Self.side - Self.countInset - width,
            y: Self.countInset,
            width: width,
            height: Self.countHeight
        )
    }
}
#endif
