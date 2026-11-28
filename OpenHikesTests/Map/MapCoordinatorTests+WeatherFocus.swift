//
//  MapCoordinatorTests+WeatherFocus.swift
//  OpenHikesTests
//
//  The "my location" button, as the weather badge hears it. MapKit's button
//  is not a control and its tap goes straight to the map, so what the
//  coordinator hears is the map turning to follow the hiker — and that turn
//  makes the hiker what the badge is about, as a search makes it about the
//  place the map went to.
//
//  A test host has no location, so the position is handed to the two calls
//  the delegate makes. The delegate itself is driven once, for the wiring,
//  and finds what a launch's first seconds find: a map with no position yet.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    private static let hikerLatitude = 47.4979
    private static let hikerLongitude = 19.0402
    private static let searchedLatitude = 48.2082
    private static let searchedLongitude = 16.3738

    /// Where the hiker stands.
    private static var budapest: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: hikerLatitude, longitude: hikerLongitude)
    }

    /// A place the map was sent to by a search, which is what the badge is
    /// about until the map turns back to the hiker.
    private static var vienna: WeatherSubject {
        .place(CLLocationCoordinate2D(latitude: searchedLatitude, longitude: searchedLongitude), name: "Vienna")
    }

    /// A coordinator told about `focus`, as `makeMapView` tells it.
    private func coordinator(pointing focus: WeatherFocus) -> MapView.Coordinator {
        let coordinator = MapView.Coordinator()
        coordinator.weatherFocus = focus
        return coordinator
    }

    @Test("a map that turns to follow the hiker makes them what the weather is about")
    func followingPointsTheWeatherAtTheHiker() {
        let focus = WeatherFocus()
        focus.focus(on: Self.vienna)
        let coordinator = coordinator(pointing: focus)

        coordinator.focusWeather(following: .follow, hikerAt: Self.budapest)

        #expect(focus.subject == .me(Self.budapest))
    }

    @Test("a pan that ends the follow leaves the weather where it is")
    func leavingTheFollowChangesNothing() {
        let focus = WeatherFocus()
        focus.focus(on: Self.vienna)
        let coordinator = coordinator(pointing: focus)

        coordinator.focusWeather(following: .none, hikerAt: Self.budapest)

        #expect(focus.subject == Self.vienna)
    }

    /// A press in the first seconds of a launch, which is the launch whose
    /// badge has nothing current to draw.
    @Test("a map that turned before it knew where the hiker is pays the weather at its first position")
    func aTurnWithNoPositionIsOwed() {
        let focus = WeatherFocus()
        focus.focus(on: Self.vienna)
        let coordinator = coordinator(pointing: focus)

        coordinator.focusWeather(following: .follow, hikerAt: nil)
        #expect(focus.subject == Self.vienna, "nothing to point at yet")

        coordinator.settleWeatherFocus(hikerAt: Self.budapest)
        #expect(focus.subject == .me(Self.budapest))
    }

    @Test("a position that arrives after a pan ended the follow is owed nothing")
    func aPanCancelsWhatWasOwed() {
        let focus = WeatherFocus()
        focus.focus(on: Self.vienna)
        let coordinator = coordinator(pointing: focus)
        coordinator.focusWeather(following: .follow, hikerAt: nil)

        coordinator.focusWeather(following: .none, hikerAt: nil)
        coordinator.settleWeatherFocus(hikerAt: Self.budapest)

        #expect(focus.subject == Self.vienna)
    }

    /// Every position MapKit reports goes through the same call, and all but
    /// the first after a turn must leave a later search alone.
    @Test("a position with nothing owed leaves the weather where it is")
    func anOrdinaryPositionChangesNothing() {
        let focus = WeatherFocus()
        let coordinator = coordinator(pointing: focus)
        coordinator.focusWeather(following: .follow, hikerAt: Self.budapest)
        focus.focus(on: Self.vienna)

        coordinator.settleWeatherFocus(hikerAt: Self.budapest)

        #expect(focus.subject == Self.vienna)
    }

    @Test("the map hands its weather focus to the delegate MapKit reports the turn to")
    func theDelegateHearsTheTurn() {
        let focus = WeatherFocus()
        focus.focus(on: Self.vienna)
        var view = mapView()
        view.weatherFocus = focus
        let coordinator = MapView.Coordinator()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        #expect(map.userLocation.location == nil, "precondition: a test host's map has no position")

        coordinator.mapView(map, didChange: .follow, animated: false)
        #expect(focus.subject == Self.vienna, "nothing to point at yet")

        coordinator.settleWeatherFocus(hikerAt: Self.budapest)
        #expect(focus.subject == .me(Self.budapest))
    }
}
