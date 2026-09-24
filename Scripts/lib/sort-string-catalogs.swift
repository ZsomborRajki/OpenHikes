#!/usr/bin/env swift
//
//  sort-string-catalogs.swift
//  Scripts/lib
//
//  Puts the keys of each String Catalog in the order Xcode's IDE writes them,
//  so a catalog synced by `Scripts/sync-string-catalogs.sh` and one saved by
//  an Xcode build are the same file.
//
//  `xcstringstool sync` writes keys in byte order, every capital before every
//  lower-case letter ("Add More Photos" before "Add a photo…"), and the IDE
//  writes them the way Finder lists names: case-insensitive, with a curly and
//  a straight apostrophe side by side, and a lower-case key before its
//  capitalised twin ("Delete photo" before "Delete Photo"). With nothing
//  between the two, every IDE build re-sorted the app's catalog into a
//  four-hundred-line diff that the next script run sorted straight back.
//  `localizedStandardCompare` reproduces the IDE's order key for key; it is
//  spelled out below with a fixed locale, because that call otherwise takes
//  the order from whichever locale the machine running this is set to.
//
//  Only whole entries move, as text: every line of an entry, the IDE's
//  blank line inside an empty one included, is written back as it was read.
//  The result is parsed and compared with the input before anything is
//  written, so a catalog laid out in a way this does not expect is refused
//  rather than rewritten into something else.
//
//  Usage:
//    swift Scripts/lib/sort-string-catalogs.swift <catalog.xcstrings> [...]
//

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Finder's order, the IDE's order: `localizedStandardCompare` with the
/// locale pinned instead of taken from the machine.
func precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(
        rhs,
        options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering],
        range: nil,
        locale: Locale(identifier: "en")
    ) == .orderedAscending
}

struct Entry {
    let key: String
    var lines: [String]
}

func sorted(_ text: String, path: String) -> String {
    var lines = text.components(separatedBy: "\n")
    let entryIndent = "    \""
    guard let open = lines.firstIndex(of: "  \"strings\" : {") else {
        fail("\(path) has no \"strings\" object where one is expected")
    }
    guard let close = lines[(open + 1)...].firstIndex(where: { $0 == "  }" || $0 == "  }," }) else {
        fail("\(path) never closes its \"strings\" object")
    }

    var entries: [Entry] = []
    for line in lines[(open + 1)..<close] {
        if line.hasPrefix(entryIndent) {
            guard line.hasSuffix(" : {"),
                  let literal = line.dropFirst(4).dropLast(4).data(using: .utf8),
                  let key = try? JSONDecoder().decode(String.self, from: literal) else {
                fail("\(path) has an entry this cannot read: \(line)")
            }
            entries.append(Entry(key: key, lines: [line]))
        } else if entries.isEmpty {
            fail("\(path) has a line before its first entry: \(line)")
        } else {
            entries[entries.count - 1].lines.append(line)
        }
    }

    // The comma is the separator, not part of the entry: the entry that
    // moves last loses it and the one that moves off the end gains it.
    for index in entries.indices {
        let last = entries[index].lines.count - 1
        if entries[index].lines[last].hasSuffix(",") {
            entries[index].lines[last].removeLast()
        }
    }
    entries.sort { precedes($0.key, $1.key) }
    for index in entries.indices.dropLast() {
        entries[index].lines[entries[index].lines.count - 1] += ","
    }

    lines.replaceSubrange((open + 1)..<close, with: entries.flatMap(\.lines))
    return lines.joined(separator: "\n")
}

let paths = CommandLine.arguments.dropFirst()
if paths.isEmpty {
    fail("usage: sort-string-catalogs.swift <catalog.xcstrings> [...]")
}

for path in paths {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
        fail("cannot read \(path)")
    }
    let result = sorted(text, path: path)
    guard let before = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
          let after = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? NSDictionary,
          before.isEqual(after) else {
        fail("sorting \(path) would change what it says, not only its order; left as it was")
    }
    if result != text {
        do {
            try Data(result.utf8).write(to: url, options: .atomic)
        } catch {
            fail("cannot write \(path): \(error.localizedDescription)")
        }
    }
}
