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
//  has pins that matter more: the photographs are below them and collide with
//  each other, so MapKit hides what overlaps and a zoom brings it back.
//
//  Shared by the trail maker's photographs (`MapTrailDraftPhotos.swift`) and
//  the *Community* tab's (`MapCommunityCommonsPhotos.swift`). Each sets its
//  own accessibility identifier, because a tap on one does something
//  different from a tap on the other.
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

    private let imageView = UIImageView()
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
        // Below the pins that matter more, and hidden by its neighbours — see
        // the file header.
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

    /// Points the view at a photograph. Cheap to call again with the same one.
    func show(_ photo: CommonsPhoto) {
        accessibilityLabel = PhotoLicenceCredit.line(author: photo.credit.author, licence: photo.credit.licence)
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
}
#endif
