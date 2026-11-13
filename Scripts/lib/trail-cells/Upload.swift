//
//  Upload.swift
//  trail-cells
//
//  Making the public database hold exactly what a build's directory does.
//
//  One record a square, named for the square, and one manifest beside them.
//  An upload sends the squares whose digest differs from the record's, deletes
//  the records of squares the build no longer has, and writes the manifest
//  last — so most of a monthly refresh is squares that are skipped.
//
//  ## The manifest is written twice, and the first time is the one that matters
//
//  The manifest lists every square's record name, and that list is the only
//  way to learn which records exist: the record type carries no index, so
//  nothing can enumerate it (see `CommunitySchema`). An upload that was
//  interrupted after creating a record the list did not name would leave a
//  square no later run could find, and so could never delete — a hiker would
//  go on being offered whatever routes it held.
//
//  So before any square is touched, the list is rewritten as the union of
//  what it named and what this build names. Whatever happens after that, the
//  next run knows every name that can exist. The second write, at the end,
//  replaces it with the build's own list and says whether the squares are the
//  whole world.
//
//  ## What is refused
//
//  A build that is not the whole world over a database that says it holds the
//  whole world. That is somebody refreshing a region against the wrong
//  environment, and what it would do is delete every other region — the app
//  would then read the gaps as *no routes here*, because the manifest it found
//  still said the squares were complete until the last step. `--replace-world`
//  is for the day that is really meant.
//

import Foundation

enum Upload {
    /// What the database holds now, as far as an upload needs to know.
    struct Remote: Decodable {
        var manifestExists = false
        /// Whether the manifest there says the squares are the whole world.
        var complete = false
        /// The record names the manifest there lists.
        var listed: Set<String> = []
        /// The digest of every square that has a record, by record name.
        var digests: [String: String] = [:]
    }

    /// What an upload will do.
    struct Plan {
        var upload: [BuildManifest.Cell] = []
        var delete: [String] = []
        var unchanged = 0

        var isEmpty: Bool { upload.isEmpty && delete.isEmpty }
    }

    /// How many squares go up between one request for upload URLs and the
    /// save that uses them. The URLs are good for fifteen minutes; a hundred
    /// small files are seconds.
    private static let squaresPerBatch = 100
    private static let simultaneousUploads = 8

    static func plan(local: BuildManifest, remote: Remote) -> Plan {
        var plan = Plan()
        let localNames = Set(local.cells.map(\.name))
        for cell in local.cells {
            if remote.digests[cell.name] == cell.digest {
                plan.unchanged += 1
            } else {
                plan.upload.append(cell)
            }
        }
        plan.delete = remote.digests.keys.filter { !localNames.contains($0) }.sorted()
        return plan
    }
}

// MARK: - The command

extension Upload {
    static func run(_ options: inout Options) async throws {
        let isDryRun = options.flag("--dry-run")
        let isConfirmed = options.flag("--yes")
        let mayReplaceWorld = options.flag("--replace-world")
        let savedRemote = try options.value("--against")
        let target = try Target(&options)
        // A remote state read from a file is what the script tests plan
        // against, since nothing here may reach CloudKit from a test. It
        // needs no key, because it sends nothing.
        let database = savedRemote == nil ? try target.database(&options) : nil
        let directory = URL(fileURLWithPath: try options.positional("a build's directory"), isDirectory: true)
        try options.finish()

        let local = try BuildManifest.read(from: directory)
        guard local.generation == TrailCellGrid.generation else {
            throw CloudKitError(description: "\(directory.path) is generation \(local.generation); "
                + "this tool writes generation \(TrailCellGrid.generation).")
        }
        let remote: Remote
        if let savedRemote {
            guard isDryRun else { throw UsageError(description: "--against only plans; pass --dry-run.") }
            remote = try JSONDecoder().decode(Remote.self, from: Data(contentsOf: URL(fileURLWithPath: savedRemote)))
        } else if let database {
            remote = try await remoteState(of: database, names: local.cells.map(\.name))
        } else {
            return
        }

        let plan = Self.plan(local: local, remote: remote)
        print("\(target.container), \(target.environment): \(plan.upload.count) squares to upload, "
            + "\(plan.delete.count) to delete, \(plan.unchanged) unchanged.")
        if remote.complete, !local.complete, !mayReplaceWorld {
            throw CloudKitError(description: "the database says its squares are the whole world and this build "
                + "is not, so uploading it would delete \(plan.delete.count) squares of everywhere else. "
                + "Pass --replace-world if that is what is meant.")
        }
        guard !isDryRun, let database else {
            print("Dry run: nothing was changed.")
            return
        }
        try confirm(plan, in: database.environment, isConfirmed: isConfirmed)
        try await apply(plan, of: local, from: directory, to: database, remote: remote)
        print("Done: \(local.cells.count) squares, \(local.routeCount) routes, "
            + (local.complete ? "marked as the whole world." : "not marked as the whole world."))
    }

    static func whoAmI(_ options: inout Options) async throws {
        let database = try Target(&options).database(&options)
        try options.finish()
        print(try await database.caller())
    }

    /// The headers a request would carry, for checking a key against the
    /// Console without sending anything — and for the script tests, which
    /// verify the signature with openssl.
    static func sign(_ options: inout Options) throws {
        let key = try ServerKey(id: try options.required("--key-id"), pemFile: try options.required("--key-file"))
        let subpath = try options.required("--subpath")
        let bodyFile = try options.value("--body-file")
        let stamp = try options.required("--date")
        try options.finish()
        guard let date = ISO8601DateFormatter().date(from: stamp) else {
            throw UsageError(description: "--date '\(stamp)' is not an ISO 8601 date.")
        }
        let body = try bodyFile.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } ?? Data()
        for (name, value) in try key.headers(forBody: body, subpath: subpath, at: date).sorted(by: { $0.key < $1.key }) {
            print("\(name): \(value)")
        }
    }

    /// Which database a command is about.
    private struct Target {
        var container: String
        var environment: String
        var endpoint: String

        init(_ options: inout Options) throws {
            environment = try options.required("--environment")
            guard ["development", "production"].contains(environment) else {
                throw UsageError(description: "--environment is development or production, not '\(environment)'.")
            }
            container = try options.required("--container")
            endpoint = try options.value("--endpoint") ?? PublicDatabase.defaultEndpoint
        }

        func database(_ options: inout Options) throws -> PublicDatabase {
            PublicDatabase(
                endpoint: endpoint,
                container: container,
                environment: environment,
                key: try ServerKey(id: try options.required("--key-id"), pemFile: try options.required("--key-file"))
            )
        }
    }

    /// Production is changed only by somebody who said so: with `--yes`, or
    /// by typing the word at a terminal.
    private static func confirm(_ plan: Plan, in environment: String, isConfirmed: Bool) throws {
        guard environment == "production", !isConfirmed, !plan.isEmpty else { return }
        guard isatty(STDIN_FILENO) != 0 else {
            throw UsageError(description: "changing production needs --yes when nobody is at the terminal.")
        }
        print("This changes PRODUCTION, which every installed copy of the app reads. "
            + "Type production to go on: ", terminator: "")
        guard readLine() == "production" else {
            throw CloudKitError(description: "not confirmed; nothing was changed.")
        }
    }
}

// MARK: - Reading what is there

private extension Upload {
    static func remoteState(of database: PublicDatabase, names: [String]) async throws -> Remote {
        var remote = Remote()
        let manifestName = TrailCellGrid.manifestRecordName
        let manifestAnswer = try await database.lookup(
            [manifestName],
            desiredKeys: [CommunitySchema.TrailManifest.complete, CommunitySchema.TrailManifest.cells]
        )[manifestName]
        switch manifestAnswer {
        case .found(let fields):
            remote.manifestExists = true
            if case .number(let complete) = fields[CommunitySchema.TrailManifest.complete] {
                remote.complete = complete == 1
            }
            if case .asset(let list) = fields[CommunitySchema.TrailManifest.cells] {
                let text = String(decoding: try await database.download(list), as: UTF8.self)
                remote.listed = Set(text.split(separator: "\n").map(String.init))
            }
        case .failed(let reason):
            throw CloudKitError(description: "reading the manifest failed — \(reason)")
        case .missing, nil:
            break
        }

        let candidates = Array(remote.listed.union(names)).sorted()
        let answers = try await database.lookup(candidates, desiredKeys: [CommunitySchema.TrailCell.digest])
        for (name, answer) in answers {
            switch answer {
            case .found(let fields):
                if case .text(let digest) = fields[CommunitySchema.TrailCell.digest] {
                    remote.digests[name] = digest
                } else {
                    // A record with no digest is one this tool did not finish
                    // writing; it is there, and it is not what the build has.
                    remote.digests[name] = ""
                }
            case .failed(let reason):
                throw CloudKitError(description: "reading \(name) failed — \(reason)")
            case .missing:
                continue
            }
        }
        return remote
    }
}

// MARK: - Changing it

private extension Upload {
    static func apply(
        _ plan: Plan,
        of local: BuildManifest,
        from directory: URL,
        to database: PublicDatabase,
        remote: Remote
    ) async throws {
        let localNames = Set(local.cells.map(\.name))
        if !plan.isEmpty, !remote.listed.isSuperset(of: localNames) || !remote.manifestExists {
            // The first write of the two — see this file's header.
            try await writeManifest(
                listing: remote.listed.union(localNames).union(remote.digests.keys),
                fields: remote.manifestExists ? [:] : [CommunitySchema.TrailManifest.complete: .integer(0)],
                operation: "forceUpdate",
                to: database
            )
        }

        var uploaded = 0
        for batch in plan.upload.chunked(into: squaresPerBatch) {
            try await upload(batch, from: directory, to: database)
            uploaded += batch.count
            print("uploaded \(uploaded) of \(plan.upload.count)")
        }
        if !plan.delete.isEmpty {
            let refused = try await database.modify(plan.delete.map { name in
                Operation(operationType: "forceDelete", record: Operation.Record(recordName: name))
            })
            try check(refused, while: "deleting squares")
            print("deleted \(plan.delete.count)")
        }

        var fields: [String: Operation.Field] = [
            CommunitySchema.TrailManifest.complete: .integer(local.complete ? 1 : 0),
            CommunitySchema.TrailManifest.builtAt: .timestamp(local.builtAt),
            CommunitySchema.TrailManifest.routeCount: .integer(Int64(local.routeCount)),
            CommunitySchema.TrailManifest.cellCount: .integer(Int64(local.cells.count)),
        ]
        if let osmTimestamp = local.osmTimestamp {
            fields[CommunitySchema.TrailManifest.osmTimestamp] = .timestamp(osmTimestamp)
        }
        try await writeManifest(listing: localNames, fields: fields, operation: "forceReplace", to: database)
    }

    static func upload(_ cells: [BuildManifest.Cell], from directory: URL, to database: PublicDatabase) async throws {
        let urls = try await database.uploadURLs(for: cells.map { cell in
            TokenRequest.Token(
                recordType: CommunitySchema.trailCellType,
                recordName: cell.name,
                fieldName: CommunitySchema.TrailCell.routes
            )
        })
        var receipts: [String: AssetReceipt] = [:]
        try await withThrowingTaskGroup(of: (String, AssetReceipt).self) { group in
            var waiting = cells.makeIterator()
            func addNext() throws {
                guard let cell = waiting.next() else { return }
                guard let url = urls[cell.name] else {
                    throw CloudKitError(description: "CloudKit gave no upload URL for \(cell.name).")
                }
                let file = BuildManifest.cellFile(named: cell.name, in: directory)
                group.addTask {
                    (cell.name, try await database.uploadAsset(try Data(contentsOf: file), to: url))
                }
            }
            for _ in 0..<simultaneousUploads { try addNext() }
            while let (name, receipt) = try await group.next() {
                receipts[name] = receipt
                try addNext()
            }
        }
        let refused = try await database.modify(try cells.map { cell in
            guard let receipt = receipts[cell.name] else {
                throw CloudKitError(description: "\(cell.name) was not uploaded.")
            }
            return Operation(
                operationType: "forceReplace",
                record: Operation.Record(
                    recordType: CommunitySchema.trailCellType,
                    recordName: cell.name,
                    fields: [
                        CommunitySchema.TrailCell.routes: .asset(receipt),
                        CommunitySchema.TrailCell.digest: .text(cell.digest),
                    ]
                )
            )
        })
        try check(refused, while: "saving squares")
    }

    static func writeManifest(
        listing names: Set<String>,
        fields: [String: Operation.Field],
        operation: String,
        to database: PublicDatabase
    ) async throws {
        let manifestName = TrailCellGrid.manifestRecordName
        let list = Data(names.sorted().joined(separator: "\n").utf8)
        let urls = try await database.uploadURLs(for: [
            TokenRequest.Token(
                recordType: CommunitySchema.trailManifestType,
                recordName: manifestName,
                fieldName: CommunitySchema.TrailManifest.cells
            ),
        ])
        guard let url = urls[manifestName] else {
            throw CloudKitError(description: "CloudKit gave no upload URL for the manifest.")
        }
        var fields = fields
        fields[CommunitySchema.TrailManifest.cells] = .asset(try await database.uploadAsset(list, to: url))
        let refused = try await database.modify([
            Operation(
                operationType: operation,
                record: Operation.Record(
                    recordType: CommunitySchema.trailManifestType,
                    recordName: manifestName,
                    fields: fields
                )
            ),
        ])
        try check(refused, while: "saving the manifest")
    }

    static func check(_ refused: [String: String], while what: String) throws {
        guard let first = refused.sorted(by: { $0.key < $1.key }).first else { return }
        throw CloudKitError(description: "\(refused.count) records were refused while \(what); the first is "
            + "\(first.key) — \(first.value). What was saved before this stays saved, and running the "
            + "upload again carries on from there.")
    }
}
