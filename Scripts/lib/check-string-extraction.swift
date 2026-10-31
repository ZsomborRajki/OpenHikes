// A source gate beside sync-string-catalogs.sh: that gate checks what the
// compiler extracted; this one catches English copy it never saw (#1028).
// SwiftSyntax is supplied by the selected Xcode toolchain, as SwiftLint's is.
// No package or shipping target gains a dependency.

import Foundation
import SwiftParser
import SwiftSyntax

private typealias Parameters = [String: Set<String>]

private func isLocalized(_ type: String) -> Bool {
    type.contains("LocalizedStringKey") || type.contains("LocalizedStringResource")
        || type.contains("String.LocalizationValue") || type == "IntentDialog"
        || type == "TypeDisplayRepresentation"
}

private func enclosingType(of node: some SyntaxProtocol) -> String? {
    var parent = node.parent
    while let current = parent {
        if let decl = current.as(StructDeclSyntax.self) { return decl.name.text }
        if let decl = current.as(EnumDeclSyntax.self) { return decl.name.text }
        if let decl = current.as(ClassDeclSyntax.self) { return decl.name.text }
        if let decl = current.as(ExtensionDeclSyntax.self) { return decl.extendedType.trimmedDescription }
        parent = current.parent
    }
    return nil
}

/// Memberwise initializers and helpers are part of the extraction boundary.
/// Read their types instead of keeping a second list of every view's labels.
private final class LocalizedParameters: SyntaxVisitor {
    var parameters: Parameters = [:]

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node.signature.parameterClause, to: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let name = enclosingType(of: node) { add(node.signature.parameterClause, to: name) }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.parent?.is(MemberBlockItemSyntax.self) == true,
              let name = enclosingType(of: node) else { return .visitChildren }
        for binding in node.bindings where binding.accessorBlock == nil {
            if isLocalized(binding.typeAnnotation?.type.trimmedDescription ?? "") {
                parameters[name, default: []].insert(binding.pattern.trimmedDescription)
            }
        }
        return .visitChildren
    }

    private func add(_ clause: FunctionParameterClauseSyntax, to name: String) {
        for parameter in clause.parameters where isLocalized(parameter.type.trimmedDescription) {
            parameters[name, default: []].insert(parameter.firstName.text)
        }
    }
}

private struct Finding: Codable {
    let path: String
    let line: Int
    let literal: String
}

private final class ExtractionCheck: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    let parameters: Parameters
    var findings: [Finding] = []
    var extractedLiterals: [String] = []

    init(path: String, tree: SourceFileSyntax, parameters: Parameters) {
        self.path = path
        converter = SourceLocationConverter(fileName: path, tree: tree)
        self.parameters = parameters
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let words = node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
        let extracted = isExtracted(node) || isLocalizedAttribute(node)
        if looksLikeCopy(words), extracted,
           node.segments.allSatisfy({ $0.is(StringSegmentSyntax.self) }) {
            extractedLiterals.append(node.trimmedDescription)
        }
        if looksLikeCopy(words), !extracted, !isMachineText(node) {
            findings.append(Finding(
                path: path,
                line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                literal: node.trimmedDescription
            ))
        }
        // Interpolations can themselves contain a fallback or a status word.
        return .visitChildren
    }

    private func looksLikeCopy(_ words: String) -> Bool {
        guard words.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return false }
        return words.range(of: "\\s", options: .regularExpression) != nil
            || words.range(of: "^[A-Z][a-z]+(?:[A-Z][a-z]+)*$", options: .regularExpression) != nil
    }

    private func isExtracted(_ node: StringLiteralExprSyntax) -> Bool {
        if let argument = node.parent?.as(LabeledExprSyntax.self),
           let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) {
            let name = callName(call)
            let label = argument.label?.text ?? "_"
            if name == "String", ["localized", "defaultValue", "comment"].contains(label) { return true }
            if ["LocalizedStringKey", "LocalizedStringResource"].contains(name) { return true }
            if parameters[name]?.contains(label) == true { return true }
        }
        var parent = node.parent
        while let current = parent {
            if let argument = current.as(LabeledExprSyntax.self), argument.label?.text == "phrases",
               let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
               callName(call) == "AppShortcut" { return true }
            if let argument = current.as(LabeledExprSyntax.self),
               let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) {
                let name = callName(call)
                if frameworkParameters[name] == nil,
                   parameters[name]?.contains(argument.label?.text ?? "_") == true { return true }
            }
            // A String helper or a concatenation loses a key even inside a
            // localizable return type. Never infer extraction through a call.
            if current.is(FunctionCallExprSyntax.self) { return false }
            if let sequence = current.as(SequenceExprSyntax.self) {
                if sequence.elements.count == 3,
                   isLocalized(sequence.elements.last?.as(TypeExprSyntax.self)?.type.trimmedDescription ?? "") {
                    return true
                }
                if sequence.elements.contains(where: { $0.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" }) {
                    return false
                }
            }
            if let binding = current.as(PatternBindingSyntax.self) {
                return isLocalized(binding.typeAnnotation?.type.trimmedDescription ?? "")
            }
            if let decl = current.as(FunctionDeclSyntax.self) {
                return isLocalized(decl.signature.returnClause?.type.trimmedDescription ?? "")
            }
            parent = current.parent
        }
        return false
    }

    private func isMachineText(_ node: StringLiteralExprSyntax) -> Bool {
        var parent = node.parent
        var sawArgument = false
        var sawCall = false
        while let current = parent {
            if current.is(EnumCaseDeclSyntax.self) { return true } // stored/wire IDs
            if current.is(MacroExpansionDeclSyntax.self) || current.is(MacroExpansionExprSyntax.self) { return true }
            if current.is(AttributeSyntax.self) { return true } // metadata is extracted by its macro
            if let binding = current.as(PatternBindingSyntax.self),
               binding.pattern.trimmedDescription == "uiTestFixture" { return true }
            if let argument = current.as(LabeledExprSyntax.self), !sawArgument {
                sawArgument = true
                if Self.machineArguments.contains(argument.label?.text ?? "") { return true }
            }
            if let call = current.as(FunctionCallExprSyntax.self), !sawCall {
                sawCall = true
                if Self.machineCalls.contains(callName(call)) { return true }
            }
            parent = current.parent
        }
        return false
    }

    private func isLocalizedAttribute(_ node: StringLiteralExprSyntax) -> Bool {
        var parent = node.parent
        var label: String?
        while let current = parent {
            if let argument = current.as(LabeledExprSyntax.self) { label = argument.label?.text }
            if let attribute = current.as(AttributeSyntax.self) {
                return attribute.attributeName.trimmedDescription == "Parameter"
                    && ["title", "description"].contains(label ?? "")
            }
            if current.is(VariableDeclSyntax.self) { return false }
            parent = current.parent
        }
        return false
    }

    private func callName(_ call: FunctionCallExprSyntax) -> String {
        call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            ?? call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? ""
    }

    private static let machineArguments: Set<String> = [
        "systemImage", "systemName", "identifier", "forHTTPHeaderField", "subsystem", "category",
        "operation", "failureMessage", "couldNotAsk", "couldNotRecord", "describing", "privacy", "while",
    ]

    private static let machineCalls: Set<String> = [
        "Logger", "debug", "info", "notice", "warning", "error", "fault", "log", "print",
        "assert", "assertOffMainThread", "assertionFailure", "precondition", "preconditionFailure", "fatalError",
        "accessibilityIdentifier", "appendingPathComponent", "appendingPathExtension", "setValue",
        "NSPredicate", "ParseStrategy", "persisted", "OverpassConversation",
    ]
}

/// The framework overloads whose literal argument is a key. Custom helpers
/// are learned from their declarations by LocalizedParameters above.
private let frameworkParameters: Parameters = [
    "Text": ["_"], "Button": ["_"], "Label": ["_"], "Toggle": ["_"], "Picker": ["_"],
    "Section": ["_"], "LabeledContent": ["_"], "ContentUnavailableView": ["_"], "GroupBox": ["_"],
    "Menu": ["_"], "Link": ["_"], "Annotation": ["_"], "TextField": ["_"], "ProgressView": ["_"],
    "Tab": ["_"], "navigationTitle": ["_"], "accessibilityLabel": ["_"], "accessibilityHint": ["_"],
    "accessibilityValue": ["_"], "accessibilityAction": ["named"], "alert": ["_"],
    "confirmationDialog": ["_"], "configurationDisplayName": ["_"], "displayName": ["_"],
    "description": ["_"], "IntentDescription": ["_", "categoryName"],
    "AppShortcut": ["phrases", "shortTitle"], "DisplayRepresentation": ["title", "subtitle"],
    "TypeDisplayRepresentation": ["name"], "IntentDialog": ["_"], "value": ["_"],
]

private func inspect(_ sources: [(String, SourceFileSyntax)]) -> [ExtractionCheck] {
    let declarations = LocalizedParameters(viewMode: .sourceAccurate)
    for (_, tree) in sources { declarations.walk(tree) }
    let parameters = frameworkParameters.merging(declarations.parameters) { $0.union($1) }
    return sources.map { path, tree in
        let visitor = ExtractionCheck(path: path, tree: tree, parameters: parameters)
        visitor.walk(tree)
        return visitor
    }
}

private func check(_ sources: [(String, SourceFileSyntax)]) -> [Finding] {
    inspect(sources).flatMap(\.findings)
}

private func selfTest() -> Int? {
    let fixtures: [(String, Int)] = [
        (#"Text("First sentence. " + "Second sentence.")"#, 2),
        (#"Text("First sentence. " + "Second sentence.").accessibilityIdentifier("view")"#, 2),
        (#"Text(title ?? "Fallback words").accessibilityIdentifier("view")"#, 1),
        (#"let label: String = "Current Speed"; Text(label)"#, 1),
        (#"Text(paused ? "Paused" : "Recording")"#, 2),
        (#"var errorDescription: String? { "Something went wrong." }"#, 1),
        (#"Text(verbatim: "A sentence hidden from extraction.")"#, 1),
        (#"Text("A sentence the compiler extracts.")"#, 0),
        (#"String(localized: "A sentence the compiler extracts.")"#, 0),
        (#"String(localized: "recording.start", defaultValue: "Start")"#, 0),
        (#"struct Figure { let title: LocalizedStringKey }; Figure(title: "Current Speed")"#, 0),
        (#"func caption(_ title: LocalizedStringKey) {}; caption("Current Speed")"#, 0),
        (#"var title: LocalizedStringResource { "Current Speed" }"#, 0),
        (#"var title: LocalizedStringResource { let fallback = "Current Speed"; return "\(fallback)" }"#, 1),
        (#"Logger(subsystem: "OpenHikes", category: "A diagnostic").error("Failure for a developer.")"#, 0),
        (#"Text(userTitle); Image(systemName: "figure.hiking"); enum Key: String { case title = "Stored Title" }"#, 0),
    ]
    var passed = true
    for (index, fixture) in fixtures.enumerated() {
        let actual = check([("fixture.swift", Parser.parse(source: fixture.0))]).count
        if actual != fixture.1 {
            fputs("error: string extraction fixture \(index) found \(actual), expected \(fixture.1)\n", stderr)
            passed = false
        }
    }
    return passed ? fixtures.count : nil
}

private struct Exclusion: Decodable {
    let path: String
    let reason: String
    let literals: [String]
}

private func run() throws -> Int32 {
    guard let fixtureCount = selfTest() else { return 1 }
    if CommandLine.arguments.contains("--self-test") {
        print("String extraction: \(fixtureCount) fixtures passed")
        return 0
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let folders = ["OpenHikes", "OpenWidget", "OpenHikesWatch", "OpenHikesWatchWidgets",
                   "OpenHikesData/Sources", "OpenHikesShared/Sources"]
    let paths = folders.flatMap { folder -> [String] in
        guard let files = FileManager.default.enumerator(atPath: root.appending(path: folder).path)
        else { return [] }
        return files.compactMap { $0 as? String }.filter {
            $0.hasSuffix(".swift") && !$0.contains("Seeded") && !$0.contains("SimulatedLocations/")
        }.map { "\(folder)/\($0)" }
    }.sorted()
    let sources = try paths.map { path in
        (path, Parser.parse(source: try String(contentsOf: root.appending(path: path), encoding: .utf8)))
    }
    let inspections = inspect(sources)
    // App Intent declarations and cross-target RoleButton defaults must stay
    // in the package. A package build emits no source .stringsdata. Give the
    // compiler their static localized literals in a temporary app-target-like
    // source file instead; it remains the authority on extraction and escapes.
    if CommandLine.arguments.contains("--shared-strings") {
        let literals = Set(inspections.filter { $0.path.hasPrefix("OpenHikesShared/Sources/") }
            .flatMap(\.extractedLiterals)).sorted()
        guard !literals.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        print("import Foundation")
        for (index, literal) in literals.enumerated() {
            print("let catalogKey\(index): LocalizedStringResource = \(literal)")
        }
        return 0
    }
    let findings = inspections.flatMap(\.findings)
    if CommandLine.arguments.contains("--dump") {
        FileHandle.standardOutput.write(try JSONEncoder().encode(findings))
        return 0
    }
    let exclusions = try JSONDecoder().decode(
        [Exclusion].self,
        from: Data(contentsOf: root.appending(path: "Scripts/string-extraction-exclusions.json"))
    )
    var remaining = findings
    var stale = false
    for exclusion in exclusions {
        guard !exclusion.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("error: string exclusion needs a reason: \(exclusion.path)\n", stderr)
            return 1
        }
        for literal in exclusion.literals {
            if let index = remaining.firstIndex(where: { $0.path == exclusion.path && $0.literal == literal }) {
                remaining.remove(at: index)
            } else {
                fputs("error: stale string exclusion in \(exclusion.path): \(literal)\n", stderr)
                stale = true
            }
        }
    }
    for finding in remaining {
        print("\(finding.path):\(finding.line): error: Text bypasses string extraction: \(finding.literal)")
    }
    if remaining.isEmpty && !stale { print("String extraction: source audit and \(fixtureCount) fixtures passed") }
    return remaining.isEmpty && !stale ? 0 : 2
}

do {
    exit(try run())
} catch {
    fputs("error: string extraction audit could not run: \(error)\n", stderr)
    exit(1)
}
