//
//  OverpassDecodable.swift
//  OpenTrails
//
//  Decodable value types for the Overpass API JSON response.
//

import Foundation

extension OverpassTrailGraphProvider {
    struct OverpassMember: Decodable {
        let type: String
        let ref: Int64
    }

    struct OverpassElement: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let nodes: [Int64]
        let tags: [String: String]
        let members: [OverpassMember]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            id = try container.decode(Int64.self, forKey: .id)
            lat = try container.decodeIfPresent(Double.self, forKey: .lat)
            lon = try container.decodeIfPresent(Double.self, forKey: .lon)
            nodes = (try container.decodeIfPresent([Int64].self, forKey: .nodes)) ?? []
            tags = (try container.decodeIfPresent([String: String].self, forKey: .tags)) ?? [:]
            members = (try container.decodeIfPresent([OverpassMember].self, forKey: .members)) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case type = "type"
            case id = "id"
            case lat = "lat"
            case lon = "lon"
            case nodes = "nodes"
            case tags = "tags"
            case members = "members"
        }
    }

    struct OverpassResponse: Decodable {
        let elements: [OverpassElement]
    }
}
