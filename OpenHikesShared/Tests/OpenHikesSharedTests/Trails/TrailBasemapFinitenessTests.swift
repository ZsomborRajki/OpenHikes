//
//  TrailBasemapFinitenessTests.swift
//  OpenHikesSharedTests
//
//  What `UnitMercatorRect`'s two failable initializers do with a number that
//  isn't one.
//
//  Separate from `TrailBasemapTests` because it's a different question: that
//  suite asks whether the geometry is *right*, this one asks whether a rect
//  describing no region can be built at all. It could be, until recently.
//  `.nan` survives every step of the bounding arithmetic — Swift's `min` and
//  `max` return their first argument when the comparison is false, so the
//  latitude clamp in `Mercator` doesn't catch it either — and the rect that
//  came out compared unequal to itself, which made every staleness and
//  de-duplication test downstream answer "no" forever, with nothing logged.
//
//  Nothing crashed, because a *different* layer happened to reject the value:
//  MapKit refuses a snapshot region it can't place. That is the shape of a
//  latent bug rather than a reason not to fix one, and it's why the boundary
//  case below matters as much as the refusals — the guard has to be exactly
//  `isFinite` and not one notch tighter, or trails at high latitude and
//  trails past the antimeridian lose their basemap for being unusual rather
//  than for being impossible.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Trail basemap finiteness")
struct TrailBasemapFinitenessTests {
    /// A short ordinary trail, used as the thing to break.
    static let trail: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: 47.6205, longitude: 12.8492),
        .init(latitude: 47.6231, longitude: 12.8544),
        .init(latitude: 47.6198, longitude: 12.8601),
        .init(latitude: 47.6250, longitude: 12.8628),
    ]

    /// The four ways a `Double` can fail to name a point. `signalingNaN` is
    /// in here because it isn't `== .nan`, so a guard written as an equality
    /// comparison would miss it.
    static let nonFinite: [(name: String, value: Double)] = [
        ("nan", .nan),
        ("signalingNaN", .signalingNaN),
        ("+infinity", .infinity),
        ("-infinity", -.infinity),
    ]

    /// Coordinates that are strange but real, or at least arithmetically
    /// answerable. Every one of these has to keep working.
    static let extremeShapes: [(name: String, coordinates: [SharedTrailSnapshot.CodableCoordinate])] = [
        ("the north pole", [
            .init(latitude: 90, longitude: 0),
            .init(latitude: 89.5, longitude: 10),
        ]),
        ("past both poles", [
            .init(latitude: 91, longitude: 0),
            .init(latitude: -91, longitude: 0),
        ]),
        ("across the antimeridian", [
            .init(latitude: 66, longitude: 179.9),
            .init(latitude: 66, longitude: -179.9),
        ]),
        ("past the antimeridian", [
            .init(latitude: 47.6, longitude: 181),
            .init(latitude: 47.6, longitude: -181),
        ]),
        ("huge but finite", [
            .init(latitude: 1e300, longitude: 1e300),
            .init(latitude: -1e300, longitude: -1e300),
        ]),
        ("signed zero", [
            .init(latitude: -0.0, longitude: -0.0),
            .init(latitude: 0.0, longitude: 0.0),
        ]),
        ("every point identical", [
            .init(latitude: 47.62, longitude: 12.85),
            .init(latitude: 47.62, longitude: 12.85),
        ]),
    ]

    /// The image side length the measuring tests work in — an ordinary
    /// snapshot size, so the only unusual thing in any of them is the value
    /// under test.
    static let imageSide = 320.0

    enum Axis: String, CaseIterable {
        case latitude = "latitude"
        case longitude = "longitude"

        func poisoning(
            _ coordinate: SharedTrailSnapshot.CodableCoordinate,
            with value: Double
        ) -> SharedTrailSnapshot.CodableCoordinate {
            switch self {
            case .latitude: .init(latitude: value, longitude: coordinate.longitude)
            case .longitude: .init(latitude: coordinate.latitude, longitude: value)
            }
        }
    }

    enum Field: String, CaseIterable {
        case latitude = "latitude"
        case longitude = "longitude"
        case x = "x"
        case y = "y"

        func poisoning(
            _ point: UnitMercatorRect.ImageReferencePoint,
            with value: Double
        ) -> UnitMercatorRect.ImageReferencePoint {
            var poisoned = point
            switch self {
            case .latitude: poisoned.latitude = value
            case .longitude: poisoned.longitude = value
            case .x: poisoned.x = value
            case .y: poisoned.y = value
            }
            return poisoned
        }
    }

    enum Dimension: String, CaseIterable {
        case width = "width"
        case height = "height"
    }

    /// The two ordinary reference points the measuring tests break one field
    /// of at a time: opposite corners of a square snapshot.
    static func referencePoints() -> [UnitMercatorRect.ImageReferencePoint] {
        [
            .init(latitude: 47.63, longitude: 12.84, x: 0, y: 0),
            .init(latitude: 47.61, longitude: 12.87, x: imageSide, y: imageSide),
        ]
    }

    // MARK: Why a refusal and not a rect

    /// The premise the refusals rest on, pinned so it can't quietly stop
    /// being true: a rect carrying a non-finite field is not recognizable,
    /// including by itself. Both comparisons here are ones the render
    /// pipeline makes — `==` to spot the request already in flight,
    /// `isEquivalent(to:)` to decide whether the images on disk still frame
    /// the trail — so an unrecognizable rect means a pass that can never
    /// short-circuit and never settle.
    ///
    /// Handing the value straight to the memberwise initializer is the only
    /// way left to build one, which is itself the point.
    @Test("a rect that isn't finite can't even recognize itself")
    func aNonFiniteRectIsUnrecognizable() {
        let broken = UnitMercatorRect(originX: .nan, originY: 0, width: 1, height: 1)

        #expect(!broken.isFinite)
        // Comparing a value with itself is the assertion, not a slip: this is
        // the property that makes a NaN-bearing rect invisible to every
        // bookkeeping check in the render pass.
        // swiftlint:disable:next identical_operands
        #expect(broken != broken)
        #expect(!broken.isEquivalent(to: broken))
    }

    /// The control for every refusal below. Without it, an initializer that
    /// returned `nil` unconditionally would satisfy the whole suite.
    @Test("ordinary input still produces a rect, and a finite one")
    func ordinaryInputIsUntouched() throws {
        let bounded = try #require(UnitMercatorRect(bounding: Self.trail))
        #expect(bounded.isFinite)
        #expect(bounded.width > 0)
        #expect(bounded.height > 0)

        let points = Self.referencePoints()
        let measured = try #require(UnitMercatorRect(
            imageWidth: Self.imageSide,
            imageHeight: Self.imageSide,
            points[0],
            points[1]
        ))
        #expect(measured.isFinite)
        #expect(measured.width > 0)
        #expect(measured.height > 0)
    }
}

// MARK: - Bounding a trail

extension TrailBasemapFinitenessTests {
    /// Swept across every index because position changed the answer, and
    /// changed it two different ways. `min`/`max` return their first argument
    /// when the comparison is false, so a `.nan` past index 0 lost every
    /// comparison and was silently *dropped* — the box came out plausible and
    /// finite, framing a trail whose drawn line still had a hole in it. Only
    /// at index 0, where it seeds the running extremes directly, did it
    /// poison the rect visibly. A fix checked at one index would have looked
    /// complete.
    @Test(
        "a coordinate that isn't a number has no bounding box",
        arguments: nonFinite, Axis.allCases
    )
    func nonFiniteCoordinateIsRefused(spelling: (name: String, value: Double), axis: Axis) {
        for index in Self.trail.indices {
            var trail = Self.trail
            trail[index] = axis.poisoning(trail[index], with: spelling.value)

            #expect(
                UnitMercatorRect(bounding: trail) == nil,
                "\(spelling.name) \(axis.rawValue) at index \(index) still produced a box"
            )
        }
    }

    /// A trail of nothing but unnumbered points, so the non-finite path and
    /// the long-standing empty-input path are known to agree rather than
    /// assumed to.
    @Test("a trail with no usable coordinate at all has no bounding box")
    func entirelyNonFiniteTrailIsRefused() {
        let nowhere = Array(
            repeating: SharedTrailSnapshot.CodableCoordinate(latitude: .nan, longitude: .nan),
            count: Self.trail.count
        )
        #expect(UnitMercatorRect(bounding: nowhere) == nil)
        #expect(UnitMercatorRect(bounding: []) == nil)
    }

    /// The other half of the guard, and the half that's easy to lose: only
    /// non-finite is refused. A latitude past Mercator's limit is a real
    /// place and gets clamped; a longitude past ±180 is cyclic and is left
    /// unclamped on purpose. Tightening the check to
    /// `Mercator.isRepresentable` would turn every one of these into a widget
    /// with no basemap, which is why they're asserted rather than assumed.
    @Test("extreme but finite coordinates still get a box", arguments: extremeShapes)
    func extremeFiniteCoordinatesAreAccepted(
        shape: (name: String, coordinates: [SharedTrailSnapshot.CodableCoordinate])
    ) throws {
        let rect = try #require(
            UnitMercatorRect(bounding: shape.coordinates),
            Comment(rawValue: "\(shape.name) was refused a bounding box")
        )
        #expect(rect.isFinite, Comment(rawValue: "\(shape.name) produced a rect that isn't finite"))
    }
}

// MARK: - Measuring a finished snapshot

extension TrailBasemapFinitenessTests {
    /// `MKMapSnapshotter` reports where a coordinate landed in the image it
    /// produced, and the region is derived from two of those reports. A
    /// non-finite value in any of the eight numbers involved makes the
    /// derivation meaningless — but only the two image-space spans were ever
    /// checked, because they're the ones the "too close together" guard
    /// happens to look at.
    ///
    /// Two of these are why the initializer now checks its arguments *and*
    /// its result rather than picking one. An infinite latitude gets clamped
    /// by `Mercator` and yields a rect that is entirely finite and entirely
    /// wrong; an infinite `x` divides out to a per-point scale of zero and
    /// yields a finite rect of zero width. Neither is visible in the result,
    /// so a result check on its own would pass both.
    @Test("a reference point that isn't a number is refused", arguments: nonFinite, Field.allCases)
    func nonFiniteReferencePointIsRefused(spelling: (name: String, value: Double), field: Field) {
        for whichPoint in Self.referencePoints().indices {
            var points = Self.referencePoints()
            points[whichPoint] = field.poisoning(points[whichPoint], with: spelling.value)

            #expect(
                UnitMercatorRect(
                    imageWidth: Self.imageSide,
                    imageHeight: Self.imageSide,
                    points[0],
                    points[1]
                ) == nil,
                "\(spelling.name) \(field.rawValue) on point \(whichPoint) still produced a rect"
            )
        }
    }

    @Test("an image size that isn't a number is refused", arguments: nonFinite, Dimension.allCases)
    func nonFiniteImageSizeIsRefused(spelling: (name: String, value: Double), dimension: Dimension) {
        let points = Self.referencePoints()

        #expect(
            UnitMercatorRect(
                imageWidth: dimension == .width ? spelling.value : Self.imageSide,
                imageHeight: dimension == .height ? spelling.value : Self.imageSide,
                points[0],
                points[1]
            ) == nil,
            "\(spelling.name) \(dimension.rawValue) still produced a rect"
        )
    }

    /// Why the *result* is checked and not only the arguments: the scale here
    /// is a ratio, so an image dimension multiplied by a steep enough
    /// per-point factor overflows to infinity with every input a perfectly
    /// ordinary finite number. The values below are absurd — no snapshotter
    /// reports them — and that's the point. They're the smallest
    /// demonstration that guarding the way in makes the promise likely rather
    /// than true.
    @Test("a scale that overflows on the way out is refused")
    func overflowingScaleIsRefused() {
        // Fifteen turns east of the antimeridian across two image points: a
        // per-point scale of 7.75 worlds, which the widest finite image width
        // multiplies straight past `Double`'s ceiling.
        let farEast = 5400.0
        #expect(UnitMercatorRect(
            imageWidth: .greatestFiniteMagnitude,
            imageHeight: Self.imageSide,
            .init(latitude: 47.63, longitude: -180, x: 0, y: 0),
            .init(latitude: 47.61, longitude: farEast, x: 2, y: 2)
        ) == nil)
    }
}
