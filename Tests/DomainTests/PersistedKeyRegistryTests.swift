import XCTest
import SwiftData
@testable import ElitePerformance

/// BA3: every UserDefaults / App Group key the app writes is in `PersistedKeyRegistry` with a disposition (backed up,
/// rebuilt on import, or excluded with a reason), and nothing in the registry is stale.
///
/// New persisted setting? Register it in Domain/Sync/PersistedKeyRegistry.swift, or better, store it in a model field.
final class PersistedKeyRegistryTests: XCTestCase {

    private var sandbox: DefaultsSandbox!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    // MARK: Production source scan

    private struct KeyUse: CustomStringConvertible {
        let key: String
        let file: String
        let line: Int
        var description: String { "\(file):\(line)  \"\(key)\"" }
    }

    private struct Unresolved: CustomStringConvertible {
        let expression: String
        let file: String
        let line: Int
        var description: String { "\(file):\(line)  forKey: \(expression)" }
    }

    private func sourceRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" {
            let hasAll = ["App", "Domain", "Features"].allSatisfy {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: dir.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
            }
            if hasAll { return dir }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("production source root not found")
    }

    private func productionFiles() throws -> [(path: String, lines: [String])] {
        let root = try sourceRoot()
        var out: [(String, [String])] = []
        for folder in ["App", "Domain", "Features", "Shared", "Utilities"] {
            let dir = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard url.lastPathComponent != "PersistedKeyRegistry.swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                // Comments are not code: drop `//` tails (no key literal contains `//`).
                let lines = text.components(separatedBy: "\n").map { line -> String in
                    guard let r = line.range(of: "//") else { return line }
                    return String(line[..<r.lowerBound])
                }
                out.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), lines))
            }
        }
        return out
    }

    private func matches(_ pattern: String, in line: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }

    /// Constant part of a literal that may interpolate: `warmup_done_\(id)` -> `warmup_done_`.
    private func constantPart(_ literal: String) -> String {
        literal.range(of: "\\(").map { String(literal[..<$0.lowerBound]) } ?? literal
    }

    private func scan() throws -> (uses: [KeyUse], unresolved: [Unresolved]) {
        let files = try productionFiles().filter { f in
            f.lines.contains { $0.contains("UserDefaults") || $0.contains("AppStorage") }
        }

        // Names declared anywhere (for qualified references such as AppStateBridge.warmupHiddenKey).
        let constPattern = #"\b(?:let|var)\s+(\w*(?:[Kk]ey|[Pp]refix)\w*)\s*(?::\s*[\w\[\]]+)?\s*=\s*"((?:[^"\\]|\\.)*)""#
        var globalNames = Set<String>()
        for f in files { for l in f.lines { for m in matches(constPattern, in: l) { globalNames.insert(m[0]) } } }

        var uses: [KeyUse] = []
        var unresolved: [Unresolved] = []
        for f in files {
            var localNames = Set<String>()
            for (i, line) in f.lines.enumerated() {
                let n = i + 1
                for m in matches(constPattern, in: line) {
                    localNames.insert(m[0])
                    uses.append(KeyUse(key: constantPart(m[1]), file: f.path, line: n))
                }
                // Arrays of keys: `let legacyKeys = [ "a", "b" ]`, literals up to the closing bracket.
                if !matches(#"\b(?:let|var)\s+\w*[Kk]ey\w*\s*=\s*\["#, in: line).isEmpty {
                    localNames.insert(matches(#"\b(?:let|var)\s+(\w*[Kk]ey\w*)\s*="#, in: line).first?.first ?? "")
                    var j = i
                    var chunk = line
                    while !chunk.contains("]"), j + 1 < f.lines.count { j += 1; chunk += f.lines[j] }
                    for m in matches(#""((?:[^"\\]|\\.)*)""#, in: chunk) {
                        uses.append(KeyUse(key: constantPart(m[0]), file: f.path, line: n))
                    }
                }
                for m in matches(#"\bfunc\s+(\w+)"#, in: line) { localNames.insert(m[0]) }
                for m in matches(#"\bfor\s+(?:\(?\s*)?(\w+)\s+in\b"#, in: line) { localNames.insert(m[0]) }
            }
            for (i, line) in f.lines.enumerated() {
                let n = i + 1
                for m in matches(#"forKey:\s*"((?:[^"\\]|\\.)*)""#, in: line) {
                    uses.append(KeyUse(key: constantPart(m[0]), file: f.path, line: n))
                }
                // Every literal after `AppStorage(`; empty ones (a `wrappedValue: ""` default) are dropped below, but must still be
                // tokenized so they cannot swallow the quote of the real key.
                if let r = line.range(of: "AppStorage(") {
                    for m in matches(#""((?:[^"\\]|\\.)*)""#, in: String(line[r.upperBound...])) {
                        uses.append(KeyUse(key: constantPart(m[0]), file: f.path, line: n))
                    }
                }
                for m in matches(#"forKey:\s*([A-Za-z_][\w\.]*)"#, in: line) {
                    let expr = m[0]
                    let parts = expr.split(separator: ".").map(String.init)
                    let ok = parts.count > 1 ? globalNames.contains(parts.last!) : localNames.contains(expr)
                    if !ok { unresolved.append(Unresolved(expression: expr, file: f.path, line: n)) }
                }
                for m in matches(#"AppStorage\(\s*(?:wrappedValue:[^,)]*,\s*)?([A-Za-z_][\w\.]*)\s*\)"#, in: line) {
                    let expr = m[0]
                    let parts = expr.split(separator: ".").map(String.init)
                    let ok = parts.count > 1 ? globalNames.contains(parts.last!) : localNames.contains(expr)
                    if !ok { unresolved.append(Unresolved(expression: expr, file: f.path, line: n)) }
                }
            }
        }
        return (uses.filter { !$0.key.isEmpty }, unresolved)
    }

    // MARK: Tests

    func test_everyKeyInProductionCode_isInTheRegistry() throws {
        let (uses, unresolved) = try scan()
        XCTAssertGreaterThan(uses.count, 20, "the scan found suspiciously few keys: has the source layout or the pattern changed?")

        let unregistered = uses.filter { use in
            !PersistedKeyRegistry.entries.contains { $0.match.covers(declared: use.key) }
        }
        XCTAssertTrue(unregistered.isEmpty, """
            Keys used by production code but missing from PersistedKeyRegistry (register each with a disposition):
            \(unregistered.map(\.description).joined(separator: "\n"))
            """)
        XCTAssertTrue(unresolved.isEmpty, """
            Key expressions the scan cannot resolve to a registered literal (use a key constant, or extend the scan):
            \(unresolved.map(\.description).joined(separator: "\n"))
            """)
    }

    func test_noRegistryEntryIsStale() throws {
        let uses = try scan().uses
        for entry in PersistedKeyRegistry.entries {
            XCTAssertTrue(uses.contains { entry.match.covers(declared: $0.key) },
                          "stale registry entry: \(entry.match) matches no key in production code")
        }
    }

    func test_everyEntryNamesARealBackupPathOrAReason() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: ctx)
        let export = try BackupTestSupport.exportJSON(ctx)
        let fields = Set(BackupSchemaMap.schemaFields().map { "\($0.entity).\($0.field)" })

        for entry in PersistedKeyRegistry.entries {
            switch entry.disposition {
            case .appState(let field):
                XCTAssertTrue(fields.contains("AppState.\(field)"), "\(entry.match): AppState.\(field) is not a schema field")
                XCTAssertFalse(BackupSchemaMap.isExcluded("AppState", field), "\(entry.match): AppState.\(field) is excluded from the backup")
                let keys = Set((BackupSchemaMap.objects("AppState", in: export) ?? []).flatMap { $0.keys })
                XCTAssertTrue(keys.contains(field), "\(entry.match): AppState.\(field) is not in the exported appState")
            case .model(let entity, let via):
                XCTAssertTrue(fields.contains { $0.hasPrefix("\(entity).") }, "\(entry.match): \(entity) is not a schema model")
                XCTAssertFalse(BackupSchemaMap.exclusions["\(entity).*"] != nil, "\(entry.match): \(entity) is excluded from the backup")
                XCTAssertFalse(via.isEmpty, "\(entry.match): name the code that moves it")
            case .rebuiltOnImport(let reason), .excluded(let reason):
                XCTAssertFalse(reason.isEmpty, "\(entry.match) needs a one-line reason")
            }
        }
    }
}
