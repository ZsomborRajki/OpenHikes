//
//  ModelConfiguration+OpenHikes.swift
//  OpenHikes
//
//  Every SwiftData store this app opens, and the one thing they all have to
//  say.
//
//  The moment the iCloud entitlement was added, SwiftData started mirroring
//  the store to CloudKit on its own — `cloudKitDatabase` defaults to
//  `.automatic`, which means "on if the entitlement is there". It announced
//  itself by refusing to open the store at all, because mirroring requires
//  every non-optional attribute to carry a default.
//
//  Turning it off is not a workaround for that error; it is the whole design.
//  Mirroring syncs a *row*, and half of ``Hike`` describes files in this
//  device's Application Support — see ``HikeSyncPayload`` for what a second
//  device would then believe about offline maps it never downloaded. Sync goes
//  through ``HikeSyncEngine``, which sends the fields the app chooses and no
//  others.
//
//  Collected into one place because the failure mode of forgetting it
//  somewhere is not a compile error: it is a second, silent, whole-row sync of
//  whichever store was opened without it.
//

import Foundation
import SwiftData

extension ModelConfiguration {
    /// The app's own store, in the App Group container it shares with the
    /// widget.
    static func openHikes(isStoredInMemoryOnly: Bool = false) -> ModelConfiguration {
        ModelConfiguration(
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: .none
        )
    }

    /// A store at a chosen location, for the suites that assert on what
    /// survives a reopen.
    static func openHikes(url: URL) -> ModelConfiguration {
        ModelConfiguration(url: url, cloudKitDatabase: .none)
    }
}
