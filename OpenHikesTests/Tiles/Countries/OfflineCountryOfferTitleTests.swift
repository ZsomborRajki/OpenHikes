//
//  OfflineCountryOfferTitleTests.swift
//  OpenHikesTests
//
//  The words of an offer on a downloaded area's row: each names the switch
//  it is for, both where it is for both, and the size its files come to.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: an offer's words")
struct OfflineCountryOfferTitleTests {
    private static let megabyte = Data(count: 1_000_000)

    /// An offer of `extras`, a megabyte a file.
    private func offer(_ extras: OfflineCountryExtras, files count: Int = 1) -> OfflineCountryOffer {
        let files = (0..<count).map { number in
            OfflineCountryFixture.file(.detail, name: "SI-\(number).pmtiles", bytes: Self.megabyte)
        }
        return OfflineCountryOffer(extras: extras, files: files)
    }

    @Test("an offer to add names what it adds, and the size of all its files")
    func adding() {
        let size = OfflineCountryRow.bytes(2_000_000)

        #expect(offer(.detail, files: 2).additionTitle == "Add Extra Detail · \(size)")
        #expect(offer(.elevation, files: 2).additionTitle == "Add Elevation Data · \(size)")
        #expect(offer([.detail, .elevation], files: 2).additionTitle == "Add Extra Detail and Elevation Data · \(size)")
    }

    @Test("an offer to delete names what it deletes, and what that frees")
    func deleting() {
        let size = OfflineCountryRow.bytes(1_000_000)

        #expect(offer(.detail).removalTitle == "Remove Extra Detail · \(size)")
        #expect(offer(.elevation).removalTitle == "Remove Elevation Data · \(size)")
        #expect(offer([.detail, .elevation]).removalTitle == "Remove Extra Detail and Elevation Data · \(size)")
    }

    @Test("a file every download takes is no switch's part, and zoom 15 and the heights each are one")
    func parts() {
        #expect(OfflineCountryExtras.part(of: .basemap).isEmpty)
        #expect(OfflineCountryExtras.part(of: .extras).isEmpty)
        #expect(OfflineCountryExtras.part(of: .trails).isEmpty)
        #expect(OfflineCountryExtras.part(of: .detail) == .detail)
        #expect(OfflineCountryExtras.part(of: .detailExtras) == .detail)
        #expect(OfflineCountryExtras.part(of: .elevation) == .elevation)
        for role in OfflineCountryManifest.Role.allCases {
            #expect(role.isOptional == !OfflineCountryExtras.part(of: role).isEmpty, "\(role.rawValue)")
        }
    }
}
