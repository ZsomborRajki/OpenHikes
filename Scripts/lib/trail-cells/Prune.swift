//
//  Prune.swift
//  trail-cells
//
//  Taking a set of squares out of the public database once no installed
//  build reads it there.
//
//  The app reads every set from the tile server (`SquareArchive.swift`).
//  The records stay in the public database for the builds from before that,
//  1.5 to 1.7, which ask for them by name, and go once those builds are
//  gone: `prune` deletes one set's squares and its manifest. A production
//  record type cannot be deleted, so the two types stay there, empty.
//
//  ## In this order, and again from where it stopped
//
//  1. The manifest is made to say the squares are not the whole world. A
//     build that reads it then asks Overpass, as it did before there were
//     squares, rather than reading a square deleted under it as ground with
//     nothing on it and keeping that for thirty days. Its hiking-routes
//     layer draws nothing from then on, which is what it would draw from no
//     squares at all.
//  2. Every square the manifest lists is deleted. The manifest is the only
//     list of them: the record type has no index, so nothing else can find
//     one (see `CommunitySchema`).
//  3. The manifest is deleted last, so a prune that stops part of the way
//     still has the list to carry on from. Run again, it finds the manifest
//     already saying the squares are not the whole world, deletes those
//     still there, and then the manifest.
//
//  A name the manifest lists that is not one of its own set's squares is
//  left alone, as `upload` leaves one. A set with no manifest has nothing
//  this tool can find, and nothing is changed.
//

import Foundation

enum Prune {
    /// What a prune will do.
    struct Plan: Equatable {
        /// Whether the manifest is first made to say the squares are not the
        /// whole world: it says they are.
        var endsTheWorld = false
        /// The squares that have a record, by name.
        var delete: [String] = []
        /// How many names the manifest lists that are not the set's squares.
        var foreign = 0
        /// Whether there is a manifest to delete last.
        var deletesManifest = false
    }

    /// The sets by the names the command takes: the tile server's list names
    /// for the three that have one, and the trail graph's.
    static let datasets: [String: Upload.Dataset] = [
        SquareArchive.trails.listName: .dayHikes,
        SquareArchive.routes.listName: .hikingRoutes,
        SquareArchive.places.listName: .places,
        TrailGraphSquareBuild.manifestKind: .trailGraph,
    ]

    static func plan(remote: Upload.Remote, dataset: Upload.Dataset) -> Plan {
        var plan = Plan()
        guard remote.manifestExists else { return plan }
        let present = Set(remote.digests.keys)
        plan.endsTheWorld = remote.complete
        plan.delete = present.filter(dataset.owns).sorted()
        plan.foreign = remote.listed.union(present).filter { !dataset.owns($0) }.count
        plan.deletesManifest = true
        return plan
    }

    static func run(_ options: inout Options) async throws {
        let isDryRun = options.flag("--dry-run")
        let isConfirmed = options.flag("--yes")
        let savedRemote = try options.value("--against")
        let target = try Upload.Target(&options)
        // A remote state read from a file is what the script tests plan
        // against, as `upload`'s do. It needs no key, because it sends
        // nothing.
        let database = savedRemote == nil ? try target.database(&options) : nil
        let setName = try options.positional("a set: \(datasets.keys.sorted().joined(separator: ", "))")
        try options.finish()
        guard let dataset = datasets[setName] else {
            throw UsageError(description: "'\(setName)' is not a set of squares: "
                + "\(datasets.keys.sorted().joined(separator: ", ")).")
        }
        let manifest = dataset.manifestRecordName

        let remote: Upload.Remote
        if let savedRemote {
            guard isDryRun else { throw UsageError(description: "--against only plans; pass --dry-run.") }
            remote = try JSONDecoder().decode(Upload.Remote.self, from: Data(contentsOf: URL(fileURLWithPath: savedRemote)))
        } else if let database {
            remote = try await Upload.remoteState(of: database, manifest: manifest, names: [])
        } else {
            return
        }

        let plan = plan(remote: remote, dataset: dataset)
        let place = "\(target.container), \(target.environment), \(manifest)"
        guard plan.deletesManifest else {
            print("\(place): there is no manifest, so no list of squares to delete. Nothing was changed.")
            return
        }
        print("\(place): \(plan.delete.count) squares to delete, then the manifest.")
        if plan.foreign > 0 {
            print("Leaving alone \(plan.foreign) records \(manifest) lists that are not its squares.")
        }
        print(plan.endsTheWorld
            ? "Before any square is deleted, the manifest is made to say the squares are no longer the whole "
                + "world, so the builds that read them \(dataset.withoutTheWorld)."
            : "The manifest already says the squares are not the whole world.")
        guard !isDryRun, let database else {
            print("Dry run: nothing was changed.")
            return
        }
        try Upload.confirm(changing: true, in: database.environment, isConfirmed: isConfirmed)
        try await apply(plan, manifest: manifest, to: database)
        print("Done: deleted \(plan.delete.count) squares and \(manifest).")
    }

    private static let squaresPerRequest = 1000

    private static func apply(_ plan: Plan, manifest: String, to database: PublicDatabase) async throws {
        if plan.endsTheWorld {
            // An update, so the list of names stays where the next run, if
            // this one stops, reads it.
            try check(try await database.modify([
                Operation(
                    operationType: "forceUpdate",
                    record: Operation.Record(
                        recordType: CommunitySchema.trailManifestType,
                        recordName: manifest,
                        fields: [CommunitySchema.TrailManifest.complete: .integer(0)]
                    )
                ),
            ]), while: "marking the manifest")
            print("marked \(manifest) as not the whole world")
        }
        var deleted = 0
        for batch in plan.delete.chunked(into: squaresPerRequest) {
            try check(try await database.modify(batch.map { name in
                Operation(operationType: "forceDelete", record: Operation.Record(recordName: name))
            }), while: "deleting squares")
            deleted += batch.count
            print("deleted \(deleted) of \(plan.delete.count)")
        }
        try check(try await database.modify([
            Operation(operationType: "forceDelete", record: Operation.Record(recordName: manifest)),
        ]), while: "deleting the manifest")
    }

    private static func check(_ refused: [String: String], while what: String) throws {
        guard let first = refused.sorted(by: { $0.key < $1.key }).first else { return }
        throw CloudKitError(description: "\(refused.count) records were refused while \(what); the first is "
            + "\(first.key) — \(first.value). What was deleted before this stays deleted, and running the "
            + "prune again carries on from there.")
    }
}
