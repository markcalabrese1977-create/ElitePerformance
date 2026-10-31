import XCTest
import SwiftData
@testable import ElitePerformance

/// BA2: a store with EVERY non-excluded field set to a non-default value survives export -> wipe -> import -> export.
/// No fixture file: the builder is the fixture, and the Schema proves it left no field at its default.
final class BackupFullRoundTripTests: XCTestCase {

    private var sandbox: DefaultsSandbox!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    func test_builder_setsEveryNonExcludedFieldToANonDefaultValue() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: ctx)
        let export = try BackupTestSupport.exportJSON(ctx)

        var untouched: [String] = []
        for (entity, field) in BackupSchemaMap.schemaFields() where !BackupSchemaMap.isExcluded(entity, field) {
            let key = BackupSchemaMap.dtoKey(entity, field)
            let objects = BackupSchemaMap.objects(entity, in: export) ?? []
            let anyNonDefault = objects.contains { !BackupSchemaMap.isDefault($0[key], entity: entity, key: key) }
            if !anyNonDefault { untouched.append("\(entity).\(field)") }
        }
        XCTAssertTrue(untouched.isEmpty, """
            PopulatedStoreBuilder leaves these at their default, so their round trip is untested. Set them to a non-default value:
            \(untouched.joined(separator: "\n"))
            """)
    }

    func test_exportWipeImportExport_isIdentical() throws {
        let source = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: source)
        let first = try BackupTestSupport.exportJSON(source)

        // Wipe = a fresh store.
        let fresh = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: fresh)
        let second = try BackupTestSupport.exportJSON(ModelContext(fresh))
        XCTAssertEqual(try Self.canonical(second), try Self.canonical(first), Self.firstDifference(first, second))

        // Wipe = the importer's own wipe of a store that already holds the data.
        try BackupTestSupport.restore(from: ModelContext(fresh), into: fresh)
        let third = try BackupTestSupport.exportJSON(ModelContext(fresh))
        XCTAssertEqual(try Self.canonical(third), try Self.canonical(first), "re-importing into a populated store: " + Self.firstDifference(first, third))
    }

    // MARK: Canonical form

    /// Sorted keys, and arrays of objects sorted by their own canonical text (their order is not meaningful in the
    /// file); arrays of scalars keep their order, which is the per-set order.
    private static func canonical(_ json: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: normalize(json), options: [.sortedKeys])
    }

    private static func normalize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] { return dict.mapValues(normalize) }
        if let array = value as? [Any] {
            let mapped = array.map(normalize)
            guard mapped.allSatisfy({ $0 is [String: Any] }) else { return mapped }
            return mapped.sorted { text($0) < text($1) }
        }
        return value
    }

    private static func text(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func firstDifference(_ a: Any, _ b: Any, path: String = "$") -> String {
        let a = normalize(a), b = normalize(b)
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            for key in Set(x.keys).union(y.keys).sorted() {
                if x[key] == nil || y[key] == nil { return "\(path).\(key): present in only one export" }
                let d = firstDifference(x[key]!, y[key]!, path: "\(path).\(key)")
                if !d.isEmpty { return d }
            }
            return ""
        }
        if let x = a as? [Any], let y = b as? [Any] {
            if x.count != y.count { return "\(path): \(x.count) vs \(y.count) elements" }
            for (i, pair) in zip(x, y).enumerated() {
                let d = firstDifference(pair.0, pair.1, path: "\(path)[\(i)]")
                if !d.isEmpty { return d }
            }
            return ""
        }
        return text(["v": a]) == text(["v": b]) ? "" : "\(path): \(a) vs \(b)"
    }
}

// MARK: - AppState.appModeRaw removal

/// `AppState.appModeRaw` was a dead field (nothing read or wrote it) and was removed. A store written before the removal
/// must still open (lightweight migration) with the rest of AppState intact, and an old backup that carries the key must
/// import without error.
final class AppModeRemovalTests: XCTestCase {

    private var sandbox: DefaultsSandbox!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    /// The AppState entity exactly as it was before the removal (the only other change is the one dropped column).
    enum OldSchema: VersionedSchema {
        static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
        static var models: [any PersistentModel.Type] { [AppState.self] }

        @Model
        final class AppState {
            var id: UUID?
            var createdAt: Date?
            var updatedAt: Date?
            var activeMesoStartDate: Date?
            var scheduledNextMesoStartDate: Date?
            var mesoPromptSnoozeUntil: Date?
            var mesoAnchorDate: Date?
            var mesoAnchorDayNumber: Int?
            var appModeRaw: String?
            var warmupHidden: Bool? = nil

            init(id: UUID?, activeMesoStartDate: Date?, mesoAnchorDate: Date?, mesoAnchorDayNumber: Int?,
                 appModeRaw: String?, warmupHidden: Bool?) {
                self.id = id
                self.activeMesoStartDate = activeMesoStartDate
                self.mesoAnchorDate = mesoAnchorDate
                self.mesoAnchorDayNumber = mesoAnchorDayNumber
                self.appModeRaw = appModeRaw
                self.warmupHidden = warmupHidden
            }
        }
    }

    func test_storeWrittenWithTheOldSchema_opensAndMigrates_withNoDataLoss() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appmode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.store")

        let id = UUID()
        let start = BackupTestSupport.date(1_700_000_000)
        let anchor = BackupTestSupport.date(1_700_086_400)
        do {
            let oldSchema = Schema(versionedSchema: OldSchema.self)
            let old = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(schema: oldSchema, url: url))
            let ctx = ModelContext(old)
            ctx.insert(OldSchema.AppState(id: id, activeMesoStartDate: start, mesoAnchorDate: anchor, mesoAnchorDayNumber: 4,
                                          appModeRaw: "mark", warmupHidden: true))
            try ctx.save()
        }

        let schema = AppSchema.makeSchema()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let rows = try ModelContext(container).fetch(FetchDescriptor<AppState>())
        XCTAssertEqual(rows.count, 1, "the AppState row survived the migration")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.activeMesoStartDate, start)
        XCTAssertEqual(row.mesoAnchorDate, anchor)
        XCTAssertEqual(row.mesoAnchorDayNumber, 4)
        XCTAssertEqual(row.warmupHidden, true)
    }

    func test_oldBackupCarryingAppModeRaw_importsCleanly_andTheKeyIsIgnored() throws {
        let source = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: source)

        let exported = try BackupTestSupport.exportFile(source)
        defer { try? FileManager.default.removeItem(at: exported) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any])
        var appState = try XCTUnwrap(json["appState"] as? [String: Any])
        XCTAssertNil(appState["appModeRaw"], "the exporter no longer writes the key")
        appState["appModeRaw"] = "mark"
        json["appState"] = appState

        let old = FileManager.default.temporaryDirectory.appendingPathComponent("old-backup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: old) }
        try JSONSerialization.data(withJSONObject: json).write(to: old)

        let targetContainer = try BackupTestSupport.makeContainer()
        XCTAssertNoThrow(try BackupSnapshotImporter.importFullBackupJSON(from: old, modelContainer: targetContainer))
        let restored = try XCTUnwrap(ModelContext(targetContainer).fetch(FetchDescriptor<AppState>()).first)
        XCTAssertEqual(restored.mesoAnchorDayNumber, 3, "the rest of AppState restored")
        XCTAssertEqual(restored.warmupHidden, true)
    }
}
