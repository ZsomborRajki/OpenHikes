//
//  Tool.swift
//  trail-cells
//
//  The command-line tool behind `Scripts/trail-cells.sh`: it files an
//  OpenStreetMap extract's hiking routes into squares, and puts the squares in
//  the public database.
//
//  It is compiled by that script, from the files in this directory and from
//  three of the app's own — `TrailCellGrid.swift`, `TrailCellFile.swift` and
//  `CommunitySchema.swift` — so what the tool writes and what the app reads
//  are one source. The script is the front door: it finds osmium, the
//  container's name and the key; this takes them as options and decides
//  nothing about the machine it is on.
//

import Foundation

struct UsageError: Error, CustomStringConvertible {
    var description: String
}

@main
enum TrailCellsTool {
    static let usage = """
    Usage: trail-cells <command> [options]

      build    --relations <opl> --ways <opl> --out <dir> [--world] [--osm-timestamp <ISO 8601>]
               File the relations of an extract into squares under <dir>.
      upload   <dir> --container <id> --environment development|production
               --key-id <id> --key-file <pem> [--dry-run] [--yes] [--replace-world]
               Make the public database hold what <dir> does.
      whoami   --container <id> --environment development|production --key-id <id> --key-file <pem>
               Print the account the key acts as.
      sign     --key-id <id> --key-file <pem> --subpath <path> --date <ISO 8601> [--body-file <file>]
               Print the headers a request would carry, and send nothing.
      inspect  <file.cell> [--json]
               Print what a square holds.
      cell     <latitude> <longitude>
               Print the record name of the square a point is in.
    """

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as UsageError {
            printError("error: \(error.description)\n\n\(usage)")
            exit(2)
        } catch {
            printError("error: \(error)")
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { throw UsageError(description: "no command given.") }
        var options = Options(Array(arguments.dropFirst()))
        switch command {
        case "build":
            try build(&options)
        case "upload":
            try await Upload.run(&options)
        case "whoami":
            try await Upload.whoAmI(&options)
        case "sign":
            try Upload.sign(&options)
        case "inspect":
            try inspect(&options)
        case "cell":
            try cell(&options)
        case "-h", "--help", "help":
            print(usage)
        default:
            throw UsageError(description: "unknown command '\(command)'.")
        }
    }

    static func printError(_ message: String) {
        // What was printed before the error, before the error: standard
        // output is held back when it is a pipe, and standard error is not.
        fflush(stdout)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: - Commands

private extension TrailCellsTool {
    static func build(_ options: inout Options) throws {
        let timestamp = try options.value("--osm-timestamp").map { text -> Date in
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw UsageError(description: "--osm-timestamp '\(text)' is not an ISO 8601 date.")
            }
            return date
        }
        let build = BuildOptions(
            relationsPath: try options.required("--relations"),
            waysPath: try options.required("--ways"),
            outputDirectory: URL(fileURLWithPath: try options.required("--out"), isDirectory: true),
            coversTheWorld: options.flag("--world"),
            osmTimestamp: timestamp
        )
        try options.finish()

        let summary = try TrailCellBuild.run(build)
        print("Read \(summary.relationsRead) relations.")
        for reason in TrailCellBuild.Dropped.allCases {
            guard let count = summary.dropped[reason] else { continue }
            print("  left out \(count) \(reason.rawValue)")
        }
        print("Filed \(summary.routes) routes (\(summary.points) points) in \(summary.cells) squares, "
            + "\(summary.bytes) bytes in all.")
        if let largest = summary.largest {
            print("The largest square is \(largest.name), \(largest.bytes) bytes.")
        }
        print(build.coversTheWorld
            ? "Marked complete: a square with no file is a square with no routes."
            : "Not marked complete: the app reads only squares that are the whole world, and keeps asking "
                + "Overpass. Pass --world for a build of the whole planet.")
    }

    static func inspect(_ options: inout Options) throws {
        let asJSON = options.flag("--json")
        let path = try options.positional("a square's file")
        try options.finish()
        let file = try TrailCellFile(decoding: Data(contentsOf: URL(fileURLWithPath: path)))
        if asJSON {
            print(try Inspection.json(of: file))
            return
        }
        print("scale \(file.coordinateScale), \(file.relations.count) relations")
        for relation in file.relations {
            let points = relation.ways.reduce(0) { $0 + $1.points.count }
            print("\(relation.id)\t\(relation.ways.count) ways\t\(points) points\t\(relation.tags["name"] ?? "")")
        }
    }

    static func cell(_ options: inout Options) throws {
        let latitudeText = try options.positional("a latitude")
        let longitudeText = try options.positional("a longitude")
        try options.finish()
        guard let latitude = Double(latitudeText), let longitude = Double(longitudeText),
              (-90...90).contains(latitude), longitude.isFinite
        else { throw UsageError(description: "'\(latitudeText) \(longitudeText)' is not a latitude and a longitude.") }
        print(TrailCellGrid.recordName(
            for: TrailCellGrid.cell(containingLatitude: latitude, longitude: longitude)
        ))
    }
}

/// A square written out as JSON, for comparing against a fixture.
enum Inspection {
    static func json(of file: TrailCellFile) throws -> String {
        let relations: [[String: Any]] = file.relations.map { relation in
            [
                "id": relation.id,
                "tags": relation.tags,
                "ways": relation.ways.map { way -> [String: Any] in
                    ["role": way.role, "points": way.points.map { [$0.latitude, $0.longitude] }]
                },
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["scale": file.coordinateScale, "relations": relations],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Options

/// The command line after the command: named values, flags and what is left.
///
/// Every option a command does not take is an error rather than something
/// skipped — `finish()` is what says so, once the command has taken its own.
struct Options {
    private var remaining: [String]

    init(_ arguments: [String]) {
        remaining = arguments
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = remaining.firstIndex(of: name) else { return false }
        remaining.remove(at: index)
        return true
    }

    mutating func value(_ name: String) throws -> String? {
        guard let index = remaining.firstIndex(of: name) else { return nil }
        guard index + 1 < remaining.count, !remaining[index + 1].hasPrefix("--") else {
            throw UsageError(description: "missing value for \(name).")
        }
        let value = remaining[index + 1]
        remaining.removeSubrange(index...index + 1)
        return value
    }

    mutating func required(_ name: String) throws -> String {
        guard let value = try value(name) else { throw UsageError(description: "\(name) is required.") }
        return value
    }

    /// The next argument that is not an option. A negative number is one:
    /// `cell -33.9 151.2` names a place.
    mutating func positional(_ what: String) throws -> String {
        guard let index = remaining.firstIndex(where: { !$0.hasPrefix("--") }) else {
            throw UsageError(description: "expected \(what).")
        }
        return remaining.remove(at: index)
    }

    func finish() throws {
        guard let stray = remaining.first else { return }
        throw UsageError(description: stray.hasPrefix("--")
            ? "unknown option '\(stray)'."
            : "unexpected argument '\(stray)'.")
    }
}
