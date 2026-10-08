#!/usr/bin/env swift
//
//  render-trace-report.swift
//  Scripts/lib
//
//  Turns a recording made by `Scripts/render-trace.sh` into a report of which
//  of the app's SwiftUI bodies ran, how often, during which step of which UI
//  test, and what — where SwiftUI can name it — made each one run.
//
//  The two tables it reads are Instruments' own: *View Body* records every
//  body evaluation with its view type, module and duration, and *View
//  Properties* records every dynamic property (`@State`, `@Environment`,
//  `@Binding`, `@AppStorage`, …) that was created, updated or destroyed, with
//  the value before and after. Neither needs anything compiled into the app,
//  which is the point: the harness this replaces needed a signpost in every
//  body it measured, and a body nobody had instrumented was a body nobody
//  measured.
//
//  The steps come from the result bundle. Every XCUITest action — a launch, a
//  tap, a wait — is an activity with a wall-clock start, and the trace carries
//  the wall-clock instant it started recording, so a body evaluation is
//  attributed to the last step that had begun before it. That is what turns a
//  count into a question: "Tap Done" evaluating the map screen's root is a
//  finding, the same count during the launch is not.
//
//  Each body is given the dynamic properties of its view type that were
//  updated since that type's previous body. Two refinements make that worth
//  reading. A property's first value is reported as an update "from
//  <initialState>", which is the view being built rather than changed, so it
//  is dropped. And an update whose old and new values print identically is
//  marked *prints unchanged*, which is one of two things: a value SwiftUI
//  cannot compare, so that any new one is a change whatever it holds — a
//  `Binding` rebuilt around the same answer, a fresh `DismissAction` — or a
//  refresh the instrument records that changed nothing. `Self._logChanges()`
//  tells the two apart, and the first is the cheapest evaluation to remove.
//
//  A body with no update at all is *unexplained*. SwiftUI re-evaluates a body
//  for three reasons — a dynamic property changed, an `@Observable` it read
//  changed, or its parent handed it a new value — and only the first is in
//  the trace. So unexplained is not a verdict; it is where to put
//  `Self._logChanges()` next.
//
//  Usage:
//    swift Scripts/lib/render-trace-report.swift \
//      --trace <recording.trace> --result-bundle <run.xcresult> \
//      --output <directory> [--baseline <earlier bodies.tsv>] [--module <prefix>]
//      [--processes <file of the app's process ids>]
//

import Foundation

// MARK: - Command line

struct Options {
    var trace = ""
    var resultBundle = ""
    var output = ""
    var baseline: String?
    /// The app's own views, as opposed to SwiftUI's and UIKit's: a Debug
    /// build puts them in `OpenHikes.debug.dylib`.
    var modulePrefix = "OpenHikes"
    /// The app's process ids on the recorded simulator, one a line. Without
    /// it every process is counted — see ``ProcessFilter``.
    var processes: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst()
    func value(for flag: String) -> String {
        guard let next = arguments.popFirst(), !next.hasPrefix("--") else {
            fail("\(flag) needs a value")
        }
        return next
    }
    while let argument = arguments.popFirst() {
        switch argument {
        case "--trace": options.trace = value(for: argument)
        case "--result-bundle": options.resultBundle = value(for: argument)
        case "--output": options.output = value(for: argument)
        case "--baseline": options.baseline = value(for: argument)
        case "--module": options.modulePrefix = value(for: argument)
        case "--processes": options.processes = value(for: argument)
        default: fail("unknown argument \(argument)")
        }
    }
    if options.trace.isEmpty { fail("--trace is required") }
    if options.resultBundle.isEmpty { fail("--result-bundle is required") }
    if options.output.isEmpty { fail("--output is required") }
    return options
}

// MARK: - Running the two tools

/// Through `env` rather than at `/usr/bin/xcrun`, so the `xcrun` that runs is
/// the first on `PATH` — which is how Scripts/run-script-tests.sh hands this
/// fixture tables instead of a recording.
///
/// Returns what the tool printed, or nothing when `file` is given, in which
/// case that is where it went.
@discardableResult
func xcrun(_ arguments: [String], into file: FileHandle? = nil) -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["xcrun"] + arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = file ?? output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        fail("could not run xcrun \(arguments.joined(separator: " ")): \(error)")
    }
    // Read before waiting: an export larger than the pipe's buffer would
    // otherwise block the child on a write nobody is reading.
    let data = file == nil ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(decoding: message, as: UTF8.self)
        fail("xcrun \(arguments.prefix(3).joined(separator: " ")) failed: \(detail)")
    }
    return data
}

// MARK: - xctrace's table format

/// One cell of an exported row: what Instruments displays, and the raw value
/// underneath it (nanoseconds, for a time or a duration).
struct Cell {
    var display: String
    var raw: String
}

/// Reads `xctrace export --xpath` output into rows keyed by column mnemonic.
///
/// The format deduplicates: the first time a value appears it carries an `id`,
/// and every later appearance is an empty element whose `ref` names it. Ids
/// are global across the table and can be defined *inside* another cell — each
/// word of a narrative is an element of its own — so every id'd element is
/// remembered, not only a row's direct children.
final class TableReader: NSObject, XMLParserDelegate {
    private(set) var columns: [String] = []
    private(set) var rows: [[String: Cell]] = []

    /// An id'd element that has started and not yet ended.
    private struct OpenElement {
        let id: String
        let name: String
        let display: String
        let depth: Int
        let topLevel: Bool
        var text = ""
    }

    private var values: [String: Cell] = [:]
    private var inSchema = false
    private var inMnemonic = false
    private var mnemonic = ""
    private var rowDepth: Int?
    private var depth = 0
    private var row: [Cell] = []
    /// Innermost last. An element with a `ref`, or a sentinel, defines
    /// nothing and is never here.
    private var open: [OpenElement] = []
    /// Which kinds of element are worth remembering for a later `ref`. `nil`
    /// remembers every one; a table as large as `kdebug`, whose times and
    /// arguments are almost all unique, names the few it is read for.
    private let remembered: Set<String>?
    /// Handed each row instead of keeping it, for a table too large to hold.
    private let onRow: (([String: Cell]) -> Void)?

    private init(remembered: Set<String>?, onRow: (([String: Cell]) -> Void)?) {
        self.remembered = remembered
        self.onRow = onRow
    }

    static func read(
        _ file: URL,
        remembering remembered: Set<String>? = nil,
        onRow: (([String: Cell]) -> Void)? = nil
    ) -> TableReader {
        let reader = TableReader(remembered: remembered, onRow: onRow)
        guard let parser = XMLParser(contentsOf: file) else { fail("could not open \(file.path)") }
        parser.delegate = reader
        guard parser.parse() else {
            fail("could not parse \(file.lastPathComponent): \(parser.parserError.map { "\($0)" } ?? "unknown error")")
        }
        return reader
    }

    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        depth += 1
        switch name {
        case "schema":
            inSchema = true
            return
        case "mnemonic" where inSchema:
            inMnemonic = true
            mnemonic = ""
            return
        case "row":
            rowDepth = depth
            row = []
            return
        default:
            break
        }
        guard let rowDepth else { return }
        let topLevel = depth == rowDepth + 1
        if let reference = attributes["ref"] {
            if topLevel { row.append(values[reference] ?? Cell(display: "", raw: "")) }
        } else if let id = attributes["id"] {
            open.append(OpenElement(id: id, name: name, display: attributes["fmt"] ?? "", depth: depth, topLevel: topLevel))
        } else if topLevel {
            // A `<sentinel/>`: the column has no value in this row.
            row.append(Cell(display: "", raw: ""))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inMnemonic {
            mnemonic += string
        } else if !open.isEmpty {
            open[open.count - 1].text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement name: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer { depth -= 1 }
        switch name {
        case "schema":
            inSchema = false
            return
        case "mnemonic" where inSchema:
            inMnemonic = false
            columns.append(mnemonic)
            return
        case "row":
            var keyed: [String: Cell] = [:]
            for (index, cell) in row.enumerated() where index < columns.count {
                keyed[columns[index]] = cell
            }
            if let onRow {
                onRow(keyed)
            } else {
                rows.append(keyed)
            }
            rowDepth = nil
            return
        default:
            break
        }
        // Only the end tag of the innermost id'd element closes it; a `ref`
        // or a sentinel inside it ends deeper.
        guard let last = open.last, last.depth == depth else { return }
        open.removeLast()
        let cell = Cell(display: last.display, raw: last.text)
        if remembered?.contains(last.name) ?? true { values[last.id] = cell }
        if last.topLevel { row.append(cell) }
    }
}

/// The instant the recording began, which every row's time is relative to.
func traceStart(of trace: String) -> Date {
    let toc = String(decoding: xcrun(["xctrace", "export", "--input", trace, "--toc"]), as: UTF8.self)
    guard let open = toc.range(of: "<start-date>"),
          let close = toc.range(of: "</start-date>", range: open.upperBound..<toc.endIndex) else {
        fail("the trace has no start date; was the recording saved?")
    }
    let text = String(toc[open.upperBound..<close.lowerBound])
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: text) else { fail("unreadable trace start date \(text)") }
    return date
}

/// Exports one of the recording's tables into `directory` and reads it back
/// from there, a row at a time when `onRow` is given.
///
/// Through a file rather than a pipe into memory: an hour's `kdebug` table is
/// gigabytes of XML, and a parser reading from disk never holds more of it
/// than the row it is on.
@discardableResult
func table(
    _ schema: String,
    in trace: String,
    exportingInto directory: URL,
    remembering remembered: Set<String>? = nil,
    onRow: (([String: Cell]) -> Void)? = nil
) -> TableReader {
    let file = directory.appendingPathComponent("\(schema).xml")
    guard FileManager.default.createFile(atPath: file.path, contents: nil),
          let handle = try? FileHandle(forWritingTo: file) else {
        fail("could not write \(file.path)")
    }
    xcrun([
        "xctrace", "export", "--input", trace,
        "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"\(schema)\"]",
    ], into: handle)
    try? handle.close()
    defer { try? FileManager.default.removeItem(at: file) }
    return TableReader.read(file, remembering: remembered, onRow: onRow)
}

// MARK: - Processes

/// Which of the recording's SwiftUI events came from the app on the recorded
/// simulator.
///
/// Neither SwiftUI table names a process, and a recording of one simulator
/// sees every simulator on the machine: SwiftUI's tracepoints are collected
/// host-wide, so a second simulator running the app — another session's UI
/// tests — puts its bodies into this report under the same view names. The
/// events underneath them do name the thread that fired them, so the instant
/// is the join — and the two tables are joined to different sources, because
/// they are recorded differently: a body starts at exactly the instant of a
/// `kdebug` tracepoint, and a property update at exactly the instant of one of
/// SwiftUI's `os-signpost` events, never a tracepoint's. Measured on a 2026-10-08
/// recording: 5,214 of 5,214 bodies joined `kdebug`, and 0 of 1,930 property
/// events did, every one of which joined `os-signpost`. Which process ids are
/// the app on the recorded simulator is the one thing the trace cannot say;
/// `Scripts/render-trace.sh` watches for them while it records, and hands them
/// over as a file.
struct ProcessFilter {
    /// Each event's instant, as the raw nanoseconds the tables print, and the
    /// process that fired it.
    let processAt: [String: Int32]
    let appProcesses: Set<Int32>

    /// `nil` for an instant no event fired at, which is kept: the join failing
    /// is not evidence that the event came from elsewhere.
    func process(at time: String) -> Int32? {
        processAt[time]
    }

    /// - Parameter instants: The raw times of the events to be filtered. Only
    ///   those are kept from the tracepoints, which a long run has millions of.
    static func load(
        trace: String,
        processes file: String,
        at instants: Set<String>,
        exportingInto directory: URL
    ) -> Self {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            fail("could not read the app's process ids from \(file)")
        }
        let appProcesses = Set(text.split(whereSeparator: \.isNewline).compactMap { Int32($0) })
        var processAt: [String: Int32] = [:]
        // Only the thread is remembered between rows, for the same reason:
        // almost every instant and argument in these tables is unique.
        for schema in ["kdebug", "os-signpost"] {
            table(schema, in: trace, exportingInto: directory, remembering: ["thread"]) { row in
                guard let time = row["time"]?.raw, instants.contains(time), processAt[time] == nil,
                      let pid = processID(in: row["thread"]?.display) else { return }
                processAt[time] = pid
            }
        }
        return Self(processAt: processAt, appProcesses: appProcesses)
    }

    /// "Main Thread (0x2590) (ControlCenter, pid: 1134)" is process 1134.
    static func processID(in thread: String?) -> Int32? {
        guard let thread, let label = thread.range(of: "pid: ", options: .backwards) else { return nil }
        return Int32(thread[label.upperBound...].prefix { $0.isNumber })
    }
}

// MARK: - The result bundle

struct Step {
    let title: String
    let start: Double
}

/// One attempt at one test. A retried test is two of these.
struct TestRun {
    let identifier: String
    let result: String
    let steps: [Step]
    var start: Double { steps.first?.start ?? 0 }
}

func testRuns(in bundle: String) -> [TestRun] {
    struct Node: Decodable {
        let nodeType: String
        let nodeIdentifier: String?
        let result: String?
        let children: [Node]?
    }
    struct Tests: Decodable { let testNodes: [Node] }
    struct Activity: Decodable {
        let title: String
        let startTime: Double?
    }
    struct Attempt: Decodable { let activities: [Activity] }
    struct Activities: Decodable { let testRuns: [Attempt] }

    let decoder = JSONDecoder()
    let treeData = xcrun(["xcresulttool", "get", "test-results", "tests", "--path", bundle])
    guard let tree = try? decoder.decode(Tests.self, from: treeData) else {
        fail("could not read the test list from \(bundle)")
    }
    var cases: [Node] = []
    func collect(_ node: Node) {
        if node.nodeType == "Test Case" { cases.append(node) }
        node.children?.forEach(collect)
    }
    tree.testNodes.forEach(collect)

    var runs: [TestRun] = []
    for testCase in cases {
        guard let identifier = testCase.nodeIdentifier else { continue }
        let data = xcrun([
            "xcresulttool", "get", "test-results", "activities",
            "--test-id", identifier, "--path", bundle,
        ])
        guard let activities = try? decoder.decode(Activities.self, from: data) else { continue }
        // A retried test keeps its name for the attempt that decided it, the
        // last, and an earlier one is named apart: a baseline compares one
        // attempt with one attempt, and a test retried in only one of two
        // runs would otherwise read as having doubled.
        for (number, attempt) in activities.testRuns.enumerated() {
            let steps = attempt.activities.compactMap { activity in
                activity.startTime.map { Step(title: activity.title, start: $0) }
            }
            guard !steps.isEmpty else { continue }
            let name = number + 1 < activities.testRuns.count ? "\(identifier) (attempt \(number + 1))" : identifier
            runs.append(TestRun(identifier: name, result: testCase.result ?? "unknown", steps: steps))
        }
    }
    return runs.sorted { $0.start < $1.start }
}

// MARK: - Names

/// A type name with its generic parameters kept to `levels` deep.
///
/// A view is named at depth zero — `GlassStack<HStack<TupleContent<…>>>` is
/// one view to a reader, whatever SwiftUI resolved its content to — and a
/// property at two, because `State<Optional<Hike>>` and `State<Bool>` are
/// different properties and the parameter is what tells them apart.
func trimmed(_ type: String, keeping levels: Int) -> String {
    var result = ""
    var depth = 0
    for character in type {
        switch character {
        case "<":
            depth += 1
            if depth <= levels {
                result.append(character)
            } else if depth == levels + 1 {
                result += "<…"
            }
        case ">":
            if depth <= levels + 1 { result.append(character) }
            depth -= 1
        default:
            if depth <= levels { result.append(character) }
        }
    }
    // Instruments cuts a long enough type name off mid-parameter, so the
    // brackets it opened may never close.
    return result + String(repeating: ">", count: min(max(depth, 0), levels + 1))
}

// MARK: - Attribution

struct Evaluation {
    let time: Double
    let view: String
    let nanoseconds: Double
    /// Labels of the dynamic properties of this view type updated since its
    /// previous body.
    var causes: [String] = []
}

struct PropertyUpdate {
    let time: Double
    let view: String
    let label: String
    let narrative: String
}

/// What `ProcessFilter` turned away, and what it could not place.
struct Excluded {
    /// Bodies from another process, by process.
    var bodies: [Int32: Int] = [:]
    /// Property updates from another process, by process.
    var updates: [Int32: Int] = [:]
    /// Events no instant in the trace named a process for, which were kept.
    var unmatched = 0

    /// Sorts one event, and says whether it belongs to the app.
    mutating func admits(_ time: String, into foreign: WritableKeyPath<Self, [Int32: Int]>, filter: ProcessFilter?) -> Bool {
        guard let filter else { return true }
        guard let process = filter.process(at: time) else {
            unmatched += 1
            return true
        }
        guard filter.appProcesses.contains(process) else {
            self[keyPath: foreign][process, default: 0] += 1
            return false
        }
        return true
    }
}

/// Every update of an app view's dynamic property, labelled, with the
/// first-value "updates" a newly built view reports left out.
func propertyUpdates(
    _ properties: TableReader,
    origin: Double,
    modulePrefix: String,
    filter: ProcessFilter?,
    excluded: inout Excluded
) -> [PropertyUpdate] {
    let updates: [PropertyUpdate] = properties.rows.compactMap { row in
        guard row["event"]?.display == "Update",
              row["view-module"]?.display.hasPrefix(modulePrefix) == true,
              let view = row["view-type"]?.display,
              let property = row["link-type"]?.display,
              let narrative = row["narrative"]?.display else { return nil }
        // "<property> in <view> updated from <old> to <new>", where <new> is
        // the row's value — so the old value is whatever lies between.
        let newValue = row["value"]?.display ?? ""
        let prefix = "\(property) in \(view) updated from "
        let suffix = " to \(newValue)"
        var oldValue: String?
        if narrative.hasPrefix(prefix), narrative.hasSuffix(suffix), narrative.count >= prefix.count + suffix.count {
            oldValue = String(narrative.dropFirst(prefix.count).dropLast(suffix.count))
        }
        // A first value is not an update, so it is neither counted nor
        // filtered: the counts below are of the updates the report reads.
        guard oldValue != "<initialState>",
              excluded.admits(row["time"]?.raw ?? "", into: \.updates, filter: filter) else { return nil }
        var label = trimmed(property, keeping: 2)
        if oldValue == newValue { label += " (prints unchanged)" }
        return PropertyUpdate(
            time: origin + (Double(row["time"]?.raw ?? "") ?? 0) / 1_000_000_000,
            view: trimmed(view, keeping: 0),
            label: label,
            narrative: narrative
        )
    }
    return updates.sorted { $0.time < $1.time }
}

/// The app's bodies, in time order, each given the property updates that
/// preceded it.
func evaluations(
    _ bodies: TableReader,
    updates: [PropertyUpdate],
    origin: Double,
    modulePrefix: String,
    filter: ProcessFilter?,
    excluded: inout Excluded
) -> [Evaluation] {
    var result: [Evaluation] = []
    for row in bodies.rows {
        guard row["view-module"]?.display.hasPrefix(modulePrefix) == true,
              let view = row["view-type"]?.display else { continue }
        let start = row["start"]?.raw ?? ""
        guard excluded.admits(start, into: \.bodies, filter: filter) else { continue }
        result.append(Evaluation(
            time: origin + (Double(start) ?? 0) / 1_000_000_000,
            view: trimmed(view, keeping: 0),
            nanoseconds: Double(row["duration"]?.raw ?? "") ?? 0
        ))
    }
    result.sort { $0.time < $1.time }

    // Both in time order: each view type's pending updates go to its next
    // body. By type rather than by instance, because the trace names no
    // instance — so for a view drawn many times over, such as a list row, the
    // first row to re-evaluate is credited with every row's update.
    var pending: [String: [String]] = [:]
    var next = 0
    for index in result.indices {
        while next < updates.count, updates[next].time <= result[index].time {
            pending[updates[next].view, default: []].append(updates[next].label)
            next += 1
        }
        result[index].causes = pending.removeValue(forKey: result[index].view) ?? []
    }
    return result
}

// MARK: - Reporting

struct Tally {
    var count = 0
    var nanoseconds = 0.0
    var unexplained = 0
    var causes: [String: Int] = [:]

    mutating func add(_ evaluation: Evaluation) {
        count += 1
        nanoseconds += evaluation.nanoseconds
        if evaluation.causes.isEmpty { unexplained += 1 }
        for cause in Set(evaluation.causes) { causes[cause, default: 0] += 1 }
    }

    var why: String {
        var parts = causes
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4)
            .map { "\($0.key) ×\($0.value)" }
        if unexplained > 0 { parts.append("unexplained ×\(unexplained)") }
        return parts.joined(separator: ", ")
    }
}

func milliseconds(_ nanoseconds: Double) -> String {
    String(format: "%.1f", nanoseconds / 1_000_000)
}

func byCount(_ tallies: [String: Tally]) -> [(key: String, value: Tally)] {
    tallies.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
}

func describe(_ tallies: [String: Tally], limit: Int) -> String {
    let ordered = byCount(tallies)
    var parts = ordered.prefix(limit).map { "\($0.key) ×\($0.value.count)" }
    if ordered.count > limit {
        let rest = ordered.dropFirst(limit).reduce(0) { $0 + $1.value.count }
        parts.append("\(ordered.count - limit) more ×\(rest)")
    }
    return parts.joined(separator: ", ")
}

/// Markdown table cells cannot hold a pipe or a newline, and a step title
/// quotes whatever element it touched.
func cell(_ text: String) -> String {
    text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
}

func shortened(_ text: String, to length: Int) -> String {
    text.count <= length ? text : String(text.prefix(length - 1)) + "…"
}

/// One view's bodies within one step of one test.
struct StepTally {
    let test: String
    let step: String
    let view: String
    let tally: Tally
}

/// Per test and view, what changed against an earlier `bodies.tsv`. Only
/// tests present in both are compared — a test that did not run in one of
/// them says nothing about the change.
func comparison(with baselinePath: String, current: [String: [String: Tally]]) -> String {
    guard let text = try? String(contentsOfFile: baselinePath, encoding: .utf8) else {
        fail("could not read the baseline \(baselinePath)")
    }
    var before: [String: [String: Int]] = [:]
    for line in text.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, let count = Int(fields[3]) else { continue }
        before[fields[0], default: [:]][fields[2], default: 0] += count
    }
    var compared = 0
    var lines: [(test: String, view: String, was: Int, now: Int)] = []
    for (test, views) in current {
        guard let earlier = before[test] else { continue }
        compared += 1
        for view in Set(views.keys).union(earlier.keys) {
            let was = earlier[view] ?? 0
            let now = views[view]?.count ?? 0
            if was != now { lines.append((test, view, was, now)) }
        }
    }
    var output = "## Against the baseline\n\n"
    guard compared > 0 else { return output + "No test in this run is in the baseline.\n\n" }
    guard !lines.isEmpty else { return output + "\(compared) test(s) compared; no body count changed.\n\n" }
    let wasTotal = lines.reduce(0) { $0 + $1.was }
    let nowTotal = lines.reduce(0) { $0 + $1.now }
    output += "\(compared) test(s) compared. Across the views that changed: \(wasTotal) → \(nowTotal) bodies.\n\n"
    output += "| Test | View | Before | After | Δ |\n|---|---|---:|---:|---:|\n"
    let ranked = lines.sorted { lhs, rhs in
        let left = abs(lhs.now - lhs.was)
        let right = abs(rhs.now - rhs.was)
        return left != right ? left > right : (lhs.test, lhs.view) < (rhs.test, rhs.view)
    }
    for line in ranked {
        let delta = line.now - line.was
        output += "| \(cell(line.test)) | \(cell(line.view)) | \(line.was) | \(line.now) | \(delta > 0 ? "+" : "")\(delta) |\n"
    }
    return output + "\n"
}

func main() {
    let options = parseOptions()
    try? FileManager.default.createDirectory(atPath: options.output, withIntermediateDirectories: true)

    let start = traceStart(of: options.trace)
    let origin = start.timeIntervalSince1970
    let exports = URL(fileURLWithPath: options.output)
    let properties = table("swiftui-link-event", in: options.trace, exportingInto: exports)
    let bodies = table("swiftui-body-interval", in: options.trace, exportingInto: exports)
    let filter = options.processes.map { file in
        let instants = bodies.rows.compactMap { $0["start"]?.raw } + properties.rows.compactMap { $0["time"]?.raw }
        return ProcessFilter.load(trace: options.trace, processes: file, at: Set(instants), exportingInto: exports)
    }
    var excluded = Excluded()
    let updates = propertyUpdates(
        properties,
        origin: origin,
        modulePrefix: options.modulePrefix,
        filter: filter,
        excluded: &excluded
    )
    let all = evaluations(
        bodies,
        updates: updates,
        origin: origin,
        modulePrefix: options.modulePrefix,
        filter: filter,
        excluded: &excluded
    )
    let runs = testRuns(in: options.resultBundle)
    guard !runs.isEmpty else { fail("the result bundle names no test that ran") }

    var tsv = "test\tstep\tview\tbodies\tnanoseconds\tunexplained\n"
    var overall: [String: Tally] = [:]
    var perTest: [String: [String: Tally]] = [:]
    var hotSpots: [StepTally] = []
    var sections = ""
    var cursor = 0

    for (position, testRun) in runs.enumerated() {
        // A traced run is serial, so a test's window ends where the next one
        // begins. Evaluations before the first belong to nothing.
        let end = position + 1 < runs.count ? runs[position + 1].start : .infinity
        while cursor < all.count, all[cursor].time < testRun.start { cursor += 1 }
        var stepTallies: [[String: Tally]] = Array(repeating: [:], count: testRun.steps.count)
        var testTally: [String: Tally] = perTest[testRun.identifier] ?? [:]
        var stepIndex = 0
        while cursor < all.count, all[cursor].time < end {
            let evaluation = all[cursor]
            while stepIndex + 1 < testRun.steps.count, testRun.steps[stepIndex + 1].start <= evaluation.time {
                stepIndex += 1
            }
            stepTallies[stepIndex][evaluation.view, default: Tally()].add(evaluation)
            testTally[evaluation.view, default: Tally()].add(evaluation)
            overall[evaluation.view, default: Tally()].add(evaluation)
            cursor += 1
        }
        perTest[testRun.identifier] = testTally

        let runTotal = stepTallies.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        let runTime = stepTallies.reduce(0.0) { $0 + $1.values.reduce(0.0) { $0 + $1.nanoseconds } }
        sections += "### \(testRun.identifier) — \(testRun.result), \(runTotal) bodies, \(milliseconds(runTime)) ms\n\n"
        sections += "| Step | Bodies | Views |\n|---|---:|---|\n"
        for (stepPosition, step) in testRun.steps.enumerated() where !stepTallies[stepPosition].isEmpty {
            let title = "\(stepPosition). \(step.title)"
            let count = stepTallies[stepPosition].values.reduce(0) { $0 + $1.count }
            sections += "| \(cell(shortened(title, to: 90))) | \(count) | \(cell(describe(stepTallies[stepPosition], limit: 8))) |\n"
            let field = title.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            for (view, tally) in stepTallies[stepPosition].sorted(by: { $0.key < $1.key }) {
                tsv += "\(testRun.identifier)\t\(field)\t\(view)\t\(tally.count)\t\(Int(tally.nanoseconds))\t\(tally.unexplained)\n"
                hotSpots.append(StepTally(test: testRun.identifier, step: title, view: view, tally: tally))
            }
        }
        sections += "\n"
    }

    var report = "# Render trace\n\n"
    report += "Recorded \(ISO8601DateFormatter().string(from: start)); \(runs.count) test run(s); "
    report += options.modulePrefix.isEmpty
        ? "\(all.count) bodies of every view, SwiftUI's and UIKit's own included.\n\n"
        : "\(all.count) bodies of views from modules prefixed `\(options.modulePrefix)`.\n\n"
    if filter == nil {
        report += "No process ids were given, so a second simulator running the app during the recording "
        report += "is counted here as if it were this one.\n\n"
    } else {
        if !excluded.bodies.isEmpty || !excluded.updates.isEmpty {
            let bodies = excluded.bodies.values.reduce(0, +)
            let updates = excluded.updates.values.reduce(0, +)
            let processes = Set(excluded.bodies.keys).union(excluded.updates.keys).count
            report += "**\(bodies) bodies and \(updates) property updates from \(processes) other process(es) "
            report += "were left out**: another simulator was running these views while this one was recorded.\n\n"
        }
        // The filter's own health: an event no instant in the trace places is
        // kept, so a join that has stopped matching would otherwise quietly
        // turn the filter off.
        if excluded.unmatched > 0 {
            report += "\(excluded.unmatched) event(s) could not be placed in a process and were kept.\n\n"
        }
    }
    report += "*Why* names the dynamic properties of a view's type updated since its previous body. "
    report += "*Prints unchanged* is an update whose old and new values print identically. "
    report += "*Unexplained* is a body with no update: an `@Observable` it read, or a new value from its parent — "
    report += "where `Self._logChanges()` goes next.\n\n"

    if let baseline = options.baseline {
        report += comparison(with: baseline, current: perTest)
    }

    report += "## Hot spots: one view, one step, three or more bodies\n\n"
    let hot = hotSpots.filter { $0.tally.count >= 3 }
        .sorted { $0.tally.count != $1.tally.count ? $0.tally.count > $1.tally.count : $0.test < $1.test }
    if hot.isEmpty {
        report += "None.\n\n"
    } else {
        report += "| Bodies | View | Test | Step | Why |\n|---:|---|---|---|---|\n"
        for spot in hot.prefix(60) {
            report += "| \(spot.tally.count) | \(cell(spot.view)) | \(cell(spot.test)) | \(cell(shortened(spot.step, to: 70))) | \(cell(spot.tally.why)) |\n"
        }
        if hot.count > 60 { report += "\n\(hot.count - 60) more in bodies.tsv.\n" }
        report += "\n"
    }

    report += "## Every test, by view\n\n| View | Bodies | ms | Why (top four) |\n|---|---:|---:|---|\n"
    for (view, tally) in byCount(overall) {
        report += "| \(cell(view)) | \(tally.count) | \(milliseconds(tally.nanoseconds)) | \(cell(tally.why)) |\n"
    }
    report += "\n"

    // What each updated property actually went from and to, once per label:
    // the type alone says `Binding<Bool>`, the narrative says which one.
    var examples: [String: [String: (count: Int, narrative: String)]] = [:]
    for update in updates {
        var entry = examples[update.view, default: [:]][update.label] ?? (0, update.narrative)
        entry.count += 1
        examples[update.view, default: [:]][update.label] = entry
    }
    if !examples.isEmpty {
        report += "## Property updates, by view\n\n| View | Property | Updates | Example |\n|---|---|---:|---|\n"
        let ranked = examples.sorted { lhs, rhs in
            let left = lhs.value.values.reduce(0) { $0 + $1.count }
            let right = rhs.value.values.reduce(0) { $0 + $1.count }
            return left != right ? left > right : lhs.key < rhs.key
        }
        for (view, labels) in ranked {
            let ordered = labels.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            for (label, entry) in ordered {
                report += "| \(cell(view)) | \(cell(label)) | \(entry.count) | \(cell(shortened(entry.narrative, to: 200))) |\n"
            }
        }
        report += "\n"
    }

    report += "## Each test, by step\n\n" + sections

    let reportPath = (options.output as NSString).appendingPathComponent("report.md")
    let tsvPath = (options.output as NSString).appendingPathComponent("bodies.tsv")
    do {
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        try tsv.write(toFile: tsvPath, atomically: true, encoding: .utf8)
    } catch {
        fail("could not write the report: \(error)")
    }
    print(reportPath)
}

main()
