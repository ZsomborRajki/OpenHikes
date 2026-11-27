//
//  TrailingBarColumnTests.swift
//  OpenHikesTests
//
//  Which windows have a column for the map's pill beyond the safe area: a
//  closed iPhone Duo's, held upright, and none of the others the app was
//  measured in.
//
//  No gate runs on a Duo, so the rule is held to what its display answered.
//  The figures are the table in `MapTrailingBarColumn.swift`: where UIKit put
//  a bar as wide as the pill on the trailing edge, on iOS 27.2.
//

@testable import OpenHikes
import Testing
import UIKit

@Suite("Trailing bar column")
struct TrailingBarColumnTests {
    /// The pill's width, which every window was measured for.
    nonisolated static let extent: CGFloat = 44

    /// One window as it was measured: where its safe area ends on the
    /// trailing edge, and where the system would stand a bar there.
    nonisolated struct Window: CustomTestStringConvertible, Sendable {
        let name: String
        let safeAreaTrailing: CGFloat
        let barTrailing: CGFloat
        let barTop: CGFloat

        var testDescription: String { name }

        var column: TrailingBarColumn? {
            TrailingBarColumn(
                bar: NSDirectionalEdgeInsets(top: barTop, leading: 0, bottom: 0, trailing: barTrailing),
                safeArea: NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: safeAreaTrailing),
                extent: TrailingBarColumnTests.extent
            )
        }
    }

    nonisolated static let closedDuo = Window(
        name: "closed Duo, upright",
        safeAreaTrailing: 84,
        barTrailing: 26,
        barTop: 174
    )

    /// Every other window: the bar stands inside the safe area, where the
    /// map's controls already are.
    nonisolated static let withoutAColumn = [
        Window(name: "closed Duo, turned", safeAreaTrailing: 0, barTrailing: 26, barTop: 17),
        Window(name: "open Duo, upright", safeAreaTrailing: 0, barTrailing: 26, barTop: 82),
        Window(name: "iPhone 18 Pro, upright", safeAreaTrailing: 0, barTrailing: 0, barTop: 62),
        Window(name: "iPhone 18 Pro, turned", safeAreaTrailing: 62, barTrailing: 62, barTop: 18),
    ]

    @Test("the windows were measured for a bar as wide as the pill")
    func extentIsThePills() {
        #expect(Self.extent == MapGlassPill.controlSize)
    }

    @Test("a closed iPhone Duo held upright has the column, under its status items")
    func closedDuoHasTheColumn() throws {
        let column = try #require(Self.closedDuo.column)
        #expect(column.trailingInset == 26)
        #expect(column.topInset == 174)
    }

    @Test("a bar inside the safe area is no column", arguments: withoutAColumn)
    func barInsideTheSafeAreaIsNoColumn(window: Window) {
        #expect(window.column == nil)
    }

    /// A bar the safe area's edge runs through is half under whatever the
    /// inset is there for, and the pill stays clear of that.
    @Test("a bar across the safe area's edge is no column")
    func barAcrossTheEdgeIsNoColumn() {
        let across = Window(name: "across", safeAreaTrailing: 60, barTrailing: 26, barTop: 0)
        #expect(across.column == nil)
        let justBeyond = Window(name: "beyond", safeAreaTrailing: 70, barTrailing: 26, barTop: 0)
        #expect(justBeyond.column != nil, "a bar ending where the safe area does stands wholly beyond it")
    }

    /// The live question, asked of a view no window holds: what every map in
    /// `MapCoordinatorTests` is. It has no column, whatever the system makes
    /// of a region with no window to measure.
    @Test("a view with no window has no column")
    func viewWithoutAWindowHasNoColumn() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        #expect(TrailingBarColumn.current(in: view, extent: Self.extent) == nil)
    }
}
