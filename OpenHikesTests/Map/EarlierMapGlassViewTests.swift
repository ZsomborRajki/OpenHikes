//
//  EarlierMapGlassViewTests.swift
//  OpenHikesTests
//
//  What the map's UIKit controls stand on below iOS 26, held on a release
//  that would otherwise never draw it. A layer radius is a number where iOS
//  26's corner configuration is a shape, so a capsule has to recompute its
//  corners from its height on every layout — the *Search this area* pill grows
//  with Dynamic Type, and a radius fixed at its first height would leave it a
//  lozenge. See `MapGlass.swift`.
//

#if os(iOS)
@testable import OpenHikes
import RealModule
import Testing
import UIKit

@MainActor
@Suite("Map glass below iOS 26")
struct EarlierMapGlassViewTests {
    private static func laidOut(_ glass: UIView, height: CGFloat) {
        glass.frame = CGRect(x: 0, y: 0, width: 160, height: height)
        glass.setNeedsLayout()
        glass.layoutIfNeeded()
    }

    @Test("a capsule's corners follow its height")
    func aCapsuleFollowsItsHeight() {
        let glass = EarlierMapGlassView(shape: .capsule)

        Self.laidOut(glass, height: 44)
        #expect(glass.layer.cornerRadius.isApproximatelyEqual(to: 22, absoluteTolerance: 0.001))

        Self.laidOut(glass, height: 60)
        #expect(glass.layer.cornerRadius.isApproximatelyEqual(to: 30, absoluteTolerance: 0.001))
    }

    @Test("fixed corners keep their radius whatever the height")
    func fixedCornersStayFixed() {
        let glass = EarlierMapGlassView(shape: .rounded(12))

        Self.laidOut(glass, height: 80)
        #expect(glass.layer.cornerRadius.isApproximatelyEqual(to: 12, absoluteTolerance: 0.001))
    }

    @Test("the material is clipped to the shape, with continuous corners")
    func theMaterialIsClipped() {
        let glass = EarlierMapGlassView(shape: .capsule)

        #expect(glass.clipsToBounds)
        #expect(glass.layer.cornerCurve == .continuous)
        #expect(glass.effect is UIBlurEffect)
    }
}
#endif
