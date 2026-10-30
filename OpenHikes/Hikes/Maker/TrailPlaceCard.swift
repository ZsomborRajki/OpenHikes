//
//  TrailPlaceCard.swift
//  OpenHikes
//
//  What the maker's place card says, apart from how it is drawn: the card's
//  title, subtitle and verb for a selection, OpenStreetMap's facts in the
//  hiker's words, and a coordinate as Apple Maps writes and links it.
//  `TrailPlaceSheet.swift` is the card itself, and its header is the argument
//  for it.
//
//  A file of its own so the coverage floor keeps measuring this while the
//  sheet, which is view bodies only CI's unmeasured UI suite evaluates, is on
//  `Scripts/coverage-exclusions.txt`.
//

import Algorithms
import CoreLocation
import OpenHikesData
import OpenHikesShared
import SwiftUI

/// What the card says about the selection, resolved against the drawing as it
/// is now — `nil` for something that has gone, which closes the card.
struct TrailPlaceCard: Equatable {
    enum Primary: Equatable {
        case addStop(name: String, preferredLeg: TrailLegEnds?)
        case removeStop(UUID)
    }

    var title: String
    var subtitle: String?
    var systemImage: String
    var tint: Color
    var latitude: Double
    var longitude: Double
    var facts: [TrailPlaceFact] = []
    var openStreetMapURL: URL?
    /// The Wikidata item the place links to — see ``WikidataPlaceSection``.
    var wikidataItem: String?
    var primary: Primary
    /// The place's id when *Remove* takes it off the trail; `nil` for the
    /// dropped pin, whose *Remove Pin* takes the pin off the map.
    var removablePlace: UUID?
    /// Whether this is the dropped pin's card — the one whose *Add Stop* also
    /// takes the pin away, since it has become the stop.
    var isDroppedPin = false
    /// The Commons photograph this card is about, drawn at its head with its
    /// credit, or `nil` for every other card.
    var photo: CommonsPhoto?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// - Parameter photos: What *Search this area* has found, which a
    ///   photograph's card is resolved against — see ``TrailDraftPhotos``.
    @MainActor
    init?(
        _ selection: TrailDraftSelection,
        in draft: TrailDraft,
        droppedPin: TrailDraftDroppedPinSpot?,
        photos: [CommonsPhoto] = []
    ) {
        switch selection {
        case .droppedPin:
            guard let spot = droppedPin else { return nil }
            isDroppedPin = true
            // A label's own name when the pin went down on one — see
            // `MapTrailDraftFeatures.swift` — and Apple Maps' heading otherwise.
            title = spot.name.isEmpty ? String(localized: "Dropped Pin") : spot.name
            systemImage = "mappin"
            tint = .red
            latitude = spot.latitude
            longitude = spot.longitude
            // A named pin's stop keeps that name. An unnamed one is named by
            // its address when it becomes a stop, as a tapped stop is.
            primary = .addStop(name: spot.name, preferredLeg: spot.leg)
        case .place(let id):
            guard let row = draft.placeRows.first(where: { $0.id == id }) else { return nil }
            let place = row.place
            title = place.displayName
            subtitle = Self.subtitle(
                kind: place.name.isEmpty ? nil : place.symbol?.label,
                distance: row.anchor?.distanceAlongRouteMeters
            )
            systemImage = place.systemImageName
            tint = place.tint
            latitude = place.latitude
            longitude = place.longitude
            facts = place.osm?.facts ?? []
            openStreetMapURL = place.osm?.url
            wikidataItem = place.osm?.wikidata
            primary = .addStop(name: place.displayName, preferredLeg: nil)
            removablePlace = id
        case .stop(let id):
            guard let index = draft.waypoints.firstIndex(where: { $0.id == id }) else { return nil }
            let waypoint = draft.waypoints[index]
            let role = draft.role(ofWaypointAt: index)
            title = waypoint.name.isEmpty ? role.title : waypoint.name
            // What its row says under the same heading.
            subtitle = role.detail(
                isNamed: !waypoint.name.isEmpty,
                along: draft.distanceAlongLine(toWaypointAt: index)
            )
            systemImage = role.systemImageName
            tint = .accentColor
            latitude = waypoint.latitude
            longitude = waypoint.longitude
            primary = .removeStop(id)
        case .photo(let url):
            guard let found = photos.first(where: { $0.fileURL == url }),
                  let camera = found.pin.coordinate
            else { return nil }
            photo = found
            title = String(localized: "Photo")
            subtitle = [
                String(localized: "Taken \(found.pin.capturedAt.formatted(date: .abbreviated, time: .omitted))"),
                String(localized: "Wikimedia Commons"),
            ].joined(separator: " · ")
            systemImage = "photo"
            tint = .purple
            // Where the camera stood, which is the spot the picture is of the
            // view *from* — the one a hiker walks to.
            latitude = camera.latitude
            longitude = camera.longitude
            // Named by its address once it is a stop, as a dropped pin is: a
            // Commons file name is a camera's `IMG_2041` as often as a place.
            primary = .addStop(name: "", preferredLeg: nil)
        }
    }

    /// `nonisolated`, because ``TrailStopRole/detail(isNamed:along:)`` says
    /// its distance in these words and the role is not main-actor.
    nonisolated static func subtitle(kind: String?, distance: Double?) -> String? {
        let along = distance.map { meters in
            let length = Measurement(value: meters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
            return String(localized: "\(length) along the route")
        }
        let parts = [kind, along].compacted()
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension TrailPlaceFact.Kind {
    var label: String {
        switch self {
        case .access: String(localized: "Access")
        case .capacity: String(localized: "Capacity")
        case .description: String(localized: "Description")
        case .drinkingWater: String(localized: "Drinking Water")
        case .elevation: String(localized: "Elevation")
        case .fee: String(localized: "Fee")
        case .openingHours: String(localized: "Hours")
        case .operatorName: String(localized: "Operator")
        case .phone: String(localized: "Phone")
        case .website: String(localized: "Website")
        }
    }
}

extension TrailPlaceFact {
    /// The value in the hiker's words and units: an elevation in their unit,
    /// OpenStreetMap's `yes` and `no` as words, anything else as written.
    var displayValue: String {
        switch kind {
        case .elevation:
            guard let meters = Double(value.replacingOccurrences(of: " m", with: "")) else { return value }
            return HikeFormat.elevation(Measurement(value: meters, unit: UnitLength.meters))
        case .drinkingWater, .fee:
            switch value.lowercased() {
            case "yes": return String(localized: "Yes")
            case "no": return String(localized: "No")
            default: return value
            }
        default:
            return value
        }
    }
}

/// How a coordinate is written on the card and in what is shared.
enum TrailPlaceCoordinates {
    /// "47.55412° N, 12.97310° E" — Apple Maps' own spelling.
    static func text(_ coordinate: CLLocationCoordinate2D) -> String {
        let latitude = abs(coordinate.latitude).formatted(.number.precision(.fractionLength(5)))
        let longitude = abs(coordinate.longitude).formatted(.number.precision(.fractionLength(5)))
        let north = coordinate.latitude >= 0 ? String(localized: "N") : String(localized: "S")
        let east = coordinate.longitude >= 0 ? String(localized: "E") : String(localized: "W")
        return "\(latitude)° \(north), \(longitude)° \(east)"
    }

    /// An Apple Maps link to the spot, which opens in Maps on any Apple device
    /// and in a browser anywhere else.
    static func mapsURL(_ coordinate: CLLocationCoordinate2D, named name: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: name),
        ]
        return components.url ?? URL(filePath: "/")
    }
}
