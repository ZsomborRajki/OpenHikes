//
//  WeatherManager.swift
//  OpenTrails
//
//  Fetches current conditions for a coordinate via WeatherKit.
//

import Foundation
import CoreLocation
import WeatherKit
import Observation

@MainActor
@Observable
final class WeatherManager {
    private(set) var current: CurrentWeather?

    private let service = WeatherService.shared

    /// Fetches current weather for the given coordinate.
    func update(for coordinate: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            current = try await service.weather(for: location, including: .current)
        } catch {
            // Leave the previous reading in place on failure.
        }
    }
}
