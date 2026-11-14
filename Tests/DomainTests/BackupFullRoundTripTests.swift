import XCTest
import SwiftData
import SQLite3
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
            let old = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none))
            let ctx = ModelContext(old)
            ctx.insert(OldSchema.AppState(id: id, activeMesoStartDate: start, mesoAnchorDate: anchor, mesoAnchorDayNumber: 4,
                                          appModeRaw: "mark", warmupHidden: true))
            try ctx.save()
        }

        let schema = AppSchema.makeSchema()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
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

/// Backup safety, layer 1: pre-import snapshot, undo, staleness guard.
final class ImportSafetyTests: XCTestCase {
    private var sandbox: DefaultsSandbox!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
        DataSentinelStore.overrideDefaults = UserDefaults(suiteName: "ep.sentinel.suite.\(UUID().uuidString)")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep_snap_\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        DataSentinelStore.overrideDefaults = nil
        try? FileManager.default.removeItem(at: dir)
        sandbox.restore()
        super.tearDown()
    }

    private func populated() throws -> (ModelContainer, ModelContext) {
        let c = try BackupTestSupport.makeContainer(); let ctx = ModelContext(c)
        try PopulatedStoreBuilder.build(in: ctx)
        return (c, ctx)
    }
    private func extraSession(_ ctx: ModelContext, day: Double, status: SessionStatus = .completed) throws {
        let s = Session(date: Date(timeIntervalSince1970: day), status: status, weekIndex: 1, dayLabel: "X", items: [])
        ctx.insert(s); try ctx.save()
    }
    /// An export under a unique name (the exporter's own names are per-second, so a second export would overwrite it).
    private func fileOf(_ ctx: ModelContext) throws -> URL {
        let exported = try BackupTestSupport.exportFile(ctx)
        let unique = FileManager.default.temporaryDirectory.appendingPathComponent("incoming_\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: exported, to: unique)
        return unique
    }
    private func counts(_ ctx: ModelContext) throws -> [Int] { try BackupContentSummary.of(store: ctx).verifiedCounts }

    func test_importOverAPopulatedStore_leavesAVerifiedSnapshot() throws {
        let (_, srcCtx) = try populated()
        try extraSession(srcCtx, day: 1_800_000_000)
        let incoming = try fileOf(srcCtx); defer { try? FileManager.default.removeItem(at: incoming) }
        let (targetC, targetCtx) = try populated()
        let before = try BackupContentSummary.of(store: targetCtx)
        XCTAssertFalse(before.isEmpty)

        try BackupRestoreCoordinator.restore(from: incoming, container: targetC, snapshotDirectory: dir)

        let snaps = PreImportSnapshots.list(in: dir)
        XCTAssertEqual(snaps.count, 1)
        let written = try BackupContentSummary.of(file: try XCTUnwrap(snaps.first).url)
        XCTAssertEqual(written.verifiedCounts, before.verifiedCounts, "the snapshot holds the pre-import store")
        XCTAssertTrue(snaps[0].url.lastPathComponent.hasPrefix("pre-import-"))
        XCTAssertEqual(try counts(ModelContext(targetC)), try BackupContentSummary.of(file: incoming).verifiedCounts, "and the import went ahead")
    }

    func test_aFailedSnapshot_blocksTheImport_andLeavesTheStoreUntouched() throws {
        let (_, srcCtx) = try populated()
        try extraSession(srcCtx, day: 1_800_000_000)
        let incoming = try fileOf(srcCtx); defer { try? FileManager.default.removeItem(at: incoming) }
        let (targetC, targetCtx) = try populated()
        let before = try counts(targetCtx)
        // a regular FILE where the Backups directory should be: writing the snapshot fails
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ep_blocker_\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker); defer { try? FileManager.default.removeItem(at: blocker) }

        XCTAssertThrowsError(try BackupRestoreCoordinator.restore(from: incoming, container: targetC, snapshotDirectory: blocker)) { e in
            guard case ImportSafetyError.snapshotFailed = e else { return XCTFail("expected snapshotFailed, got \(e)") }
            XCTAssertTrue(e.localizedDescription.contains("Nothing was changed"))
        }
        XCTAssertEqual(try counts(ModelContext(targetC)), before, "the import never started")
    }

    func test_snapshotOfAnEmptyStore_isSkipped_andOnlyTheLastFiveAreKept() throws {
        let emptyC = try BackupTestSupport.makeContainer()
        XCTAssertNil(try PreImportSnapshots.take(from: ModelContext(emptyC), in: dir))
        XCTAssertEqual(PreImportSnapshots.list(in: dir).count, 0)
        let (_, ctx) = try populated()
        for i in 0..<7 { try PreImportSnapshots.take(from: ctx, in: dir, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60)) }
        let kept = PreImportSnapshots.list(in: dir)
        XCTAssertEqual(kept.count, 5)
        XCTAssertEqual(kept.first?.date, Date(timeIntervalSince1970: 1_800_000_000 + 6 * 60), "newest first; the 2 oldest were pruned")
    }

    func test_undo_returnsTheStoreToItsExactPreImportCounts_andSnapshotsFirstItself() throws {
        let (_, srcCtx) = try populated()
        try extraSession(srcCtx, day: 1_800_000_000); try extraSession(srcCtx, day: 1_800_100_000)
        let incoming = try fileOf(srcCtx); defer { try? FileManager.default.removeItem(at: incoming) }
        let (targetC, targetCtx) = try populated()
        let before = try BackupContentSummary.of(store: targetCtx)
        let t0 = Date()

        try BackupRestoreCoordinator.restore(from: incoming, container: targetC, snapshotDirectory: dir, now: t0)
        XCTAssertNotEqual(try counts(ModelContext(targetC)), before.verifiedCounts, "the import changed the store")

        let undo = try XCTUnwrap(PreImportSnapshots.undoCandidate(in: dir, now: t0.addingTimeInterval(3600)))
        try BackupRestoreCoordinator.restore(from: undo.url, container: targetC, snapshotDirectory: dir, now: t0.addingTimeInterval(3600))
        let after = try BackupContentSummary.of(store: ModelContext(targetC))
        XCTAssertEqual(after.verifiedCounts, before.verifiedCounts, "exact pre-import counts")
        XCTAssertEqual(after.completedSessions, before.completedSessions)
        XCTAssertEqual(PreImportSnapshots.list(in: dir).count, 2, "the undo snapshotted the imported state first, so it can itself be undone")
    }

    func test_undoIsOfferedOnlyWhileTheNewestSnapshotIsUnder30DaysOld() throws {
        let (_, ctx) = try populated()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(PreImportSnapshots.undoCandidate(in: dir, now: t0), "no snapshot, no undo")
        try PreImportSnapshots.take(from: ctx, in: dir, now: t0)
        XCTAssertNotNil(PreImportSnapshots.undoCandidate(in: dir, now: t0.addingTimeInterval(29 * 86_400)))
        XCTAssertNil(PreImportSnapshots.undoCandidate(in: dir, now: t0.addingTimeInterval(31 * 86_400)))
    }

    // MARK: - Staleness guard

    private func summary(completed: Int, last: Double?) -> BackupContentSummary {
        BackupContentSummary(exportedAt: nil, sessions: completed, completedSessions: completed,
                             lastCompletedDate: last.map { Date(timeIntervalSince1970: $0) },
                             sessionHistory: 0, customExercises: 0, mesoBlocks: 0)
    }

    func test_guard_requiresTypedREPLACE_forFewerCompletedSessions_anEarlierLastSession_orBoth_otherwiseNormal() throws {
        let current = summary(completed: 40, last: 1_800_000_000)
        // fewer completed sessions, same last date
        XCTAssertTrue(ImportStalenessGuard.assess(incoming: summary(completed: 30, last: 1_800_000_000), current: current).requiresTypedWord)
        // same count, earlier last completed session
        XCTAssertTrue(ImportStalenessGuard.assess(incoming: summary(completed: 40, last: 1_790_000_000), current: current).requiresTypedWord)
        // both
        if case .requireTypedReplace(let r) = ImportStalenessGuard.assess(incoming: summary(completed: 10, last: 1_700_000_000), current: current) {
            XCTAssertEqual(r.count, 2)
        } else { XCTFail("both conditions should require the typed word") }
        // a file with no completed session at all, against a device that has some
        XCTAssertTrue(ImportStalenessGuard.assess(incoming: summary(completed: 0, last: nil), current: current).requiresTypedWord)
        // equal or newer: a normal confirm
        XCTAssertEqual(ImportStalenessGuard.assess(incoming: summary(completed: 40, last: 1_800_000_000), current: current), .normalConfirm)
        XCTAssertEqual(ImportStalenessGuard.assess(incoming: summary(completed: 55, last: 1_810_000_000), current: current), .normalConfirm)
        // an empty device (a fresh install restoring): normal
        XCTAssertEqual(ImportStalenessGuard.assess(incoming: summary(completed: 3, last: 1_700_000_000), current: summary(completed: 0, last: nil)), .normalConfirm)
    }

    func test_guard_acceptsOnlyTheWordREPLACE() {
        for ok in ["REPLACE", " REPLACE "] { XCTAssertTrue(ImportStalenessGuard.accepts(typed: ok), ok) }
        for bad in ["", "replace", "Replace", "REPLAC", "REPLACE IT", "yes"] { XCTAssertFalse(ImportStalenessGuard.accepts(typed: bad), bad) }
    }

    func test_guard_triggersOnAnOlderFile_readFromRealExports() throws {
        // an older export (fewer completed sessions) against a newer live store
        let (_, olderCtx) = try populated()
        let olderURL = try fileOf(olderCtx); defer { try? FileManager.default.removeItem(at: olderURL) }
        let (_, newerCtx) = try populated()
        try extraSession(newerCtx, day: 4_000_000_000)          // a later completed session
        let verdict = ImportStalenessGuard.assess(incoming: try BackupContentSummary.of(file: olderURL),
                                                  current: try BackupContentSummary.of(store: newerCtx))
        XCTAssertTrue(verdict.requiresTypedWord)
        // and the reverse direction is a normal confirm
        let newerURL = try fileOf(newerCtx); defer { try? FileManager.default.removeItem(at: newerURL) }
        XCTAssertEqual(ImportStalenessGuard.assess(incoming: try BackupContentSummary.of(file: newerURL),
                                                   current: try BackupContentSummary.of(store: olderCtx)), .normalConfirm)
    }

    // MARK: - Failure recovery

    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    /// An importer that really imports (wiping the store and writing the incoming data) and THEN throws: a failure after the wipe.
    /// `failRecovery`: the second call (re-importing the snapshot) throws as well.
    private func failingImporter(failRecovery: Bool, calls: Counter) -> BackupRestoreCoordinator.Importer {
        return { url, container in
            calls.n += 1
            if calls.n == 1 {
                _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: container)
                throw Boom()
            }
            if failRecovery { throw Boom() }
            return try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: container)
        }
    }
    private final class Counter { var n = 0 }

    func test_importThrowsAfterTheWipe_storeReturnsToExactPreImportCounts_snapshotKept_userToldItWasPutBack() throws {
        let (_, srcCtx) = try populated()
        try extraSession(srcCtx, day: 1_800_000_000); try extraSession(srcCtx, day: 1_800_100_000)
        let incoming = try fileOf(srcCtx); defer { try? FileManager.default.removeItem(at: incoming) }
        let (targetC, targetCtx) = try populated()
        let before = try BackupContentSummary.of(store: targetCtx)
        let calls = Counter()

        XCTAssertThrowsError(try BackupRestoreCoordinator.restore(
            from: incoming, container: targetC, snapshotDirectory: dir,
            importer: failingImporter(failRecovery: false, calls: calls))) { e in
            XCTAssertTrue(e.localizedDescription.contains("Your previous data was put back."), e.localizedDescription)
            XCTAssertTrue(e.localizedDescription.contains("boom"))
        }
        XCTAssertEqual(calls.n, 2, "the import, then the recovery from the snapshot")
        let after = try BackupContentSummary.of(store: ModelContext(targetC))
        XCTAssertEqual(after.verifiedCounts, before.verifiedCounts, "exact pre-import counts")
        XCTAssertEqual(after.completedSessions, before.completedSessions)
        let snaps = PreImportSnapshots.list(in: dir)
        XCTAssertEqual(snaps.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(snaps.first).url.path), "the snapshot file still exists")
    }

    func test_importFails_andRecoveryFailsToo_snapshotIsKept_undoStillOffered_errorPointsToSettings() throws {
        let (_, srcCtx) = try populated()
        try extraSession(srcCtx, day: 1_800_000_000)
        let incoming = try fileOf(srcCtx); defer { try? FileManager.default.removeItem(at: incoming) }
        let (targetC, targetCtx) = try populated()
        let before = try BackupContentSummary.of(store: targetCtx)
        let t0 = Date()
        let calls = Counter()

        XCTAssertThrowsError(try BackupRestoreCoordinator.restore(
            from: incoming, container: targetC, snapshotDirectory: dir, now: t0,
            importer: failingImporter(failRecovery: true, calls: calls))) { e in
            let m = e.localizedDescription
            XCTAssertTrue(m.contains("restore it from Settings"), m)
            XCTAssertTrue(m.contains("Restore pre-import state"), m)
            XCTAssertFalse(m.contains("was put back"), m)
        }
        XCTAssertEqual(calls.n, 2)
        let snap = try XCTUnwrap(PreImportSnapshots.undoCandidate(in: dir, now: t0.addingTimeInterval(60)), "Restore pre-import state is still offered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snap.url.path), "the snapshot file was not deleted")
        // and it really holds the pre-import data: restoring from it (through the real importer) works
        try BackupRestoreCoordinator.restore(from: snap.url, container: targetC, snapshotDirectory: dir, now: t0.addingTimeInterval(120))
        XCTAssertEqual(try BackupContentSummary.of(store: ModelContext(targetC)).verifiedCounts, before.verifiedCounts)
    }

    // MARK: - Interrupted-import marker

    func test_marker_isPresentDuringTheImport_andAbsentAfterSuccess() throws {
        let (_, srcCtx) = try populated()
        try extraSession(srcCtx, day: 1_800_000_000)
        let incoming = try fileOf(srcCtx); defer { try? FileManager.default.removeItem(at: incoming) }
        let (targetC, _) = try populated()
        var seen: InterruptedImportMarker?
        var markerFileDuring = false
        let dir = self.dir!
        try BackupRestoreCoordinator.restore(from: incoming, container: targetC, snapshotDirectory: dir) { url, container in
            markerFileDuring = InterruptedImportMarker.exists(in: dir)
            seen = InterruptedImportMarker.read(in: dir)
            return try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: container)
        }
        XCTAssertTrue(markerFileDuring)
        let snap = try XCTUnwrap(PreImportSnapshots.list(in: dir).first)
        XCTAssertEqual(seen?.snapshotPath, snap.url.path, "the marker names the snapshot")
        XCTAssertNotNil(seen?.startedAt)
        XCTAssertFalse(InterruptedImportMarker.exists(in: dir), "removed after the import succeeded")
    }

    func test_marker_isRemovedAfterInProcessRecovery_butKeptWhenRecoveryFails() throws {
        let (_, srcCtx) = try populated()
        try extraSession(srcCtx, day: 1_800_000_000)
        let incoming = try fileOf(srcCtx); defer { try? FileManager.default.removeItem(at: incoming) }
        let (targetC, _) = try populated()
        XCTAssertThrowsError(try BackupRestoreCoordinator.restore(from: incoming, container: targetC, snapshotDirectory: dir,
                                                                  importer: failingImporter(failRecovery: false, calls: Counter())))
        XCTAssertFalse(InterruptedImportMarker.exists(in: dir), "recovered in-process")
        XCTAssertThrowsError(try BackupRestoreCoordinator.restore(from: incoming, container: targetC, snapshotDirectory: dir,
                                                                  now: Date().addingTimeInterval(5),
                                                                  importer: failingImporter(failRecovery: true, calls: Counter())))
        XCTAssertTrue(InterruptedImportMarker.exists(in: dir), "recovery failed: the next launch must find the marker")
    }

    /// Simulates a kill mid-import: the snapshot and marker exist, and the store is left in a half-imported state.
    private func interruptedStore(restoreTo: inout BackupContentSummary) throws -> ModelContainer {
        let (_, srcCtx) = try populated()
        try extraSession(srcCtx, day: 1_800_000_000)
        let incoming = try fileOf(srcCtx); defer { try? FileManager.default.removeItem(at: incoming) }
        let (c, ctx) = try populated()
        restoreTo = try BackupContentSummary.of(store: ctx)
        let snap = try XCTUnwrap(PreImportSnapshots.take(from: ctx, in: dir, now: Date(timeIntervalSince1970: 1_800_000_000)))
        try InterruptedImportMarker.write(snapshot: snap.url, startedAt: snap.date, in: dir)
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: incoming, modelContainer: c)   // the store now differs
        return c
    }

    @MainActor
    func test_markerLeftAtLaunch_promptsAndHoldsBackBackfills_untilAnswered() throws {
        var expected = BackupContentSummary(exportedAt: nil, sessions: 0, completedSessions: 0, lastCompletedDate: nil, sessionHistory: 0, customExercises: 0, mesoBlocks: 0)
        let container = try interruptedStore(restoreTo: &expected)
        var backfillRuns = 0
        let gate = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), runBackfills: { _ in backfillRuns += 1 })
        gate.begin(container: container)
        let prompt = try XCTUnwrap(gate.interrupted, "a marker at launch raises the prompt")
        XCTAssertTrue(prompt.message.hasPrefix("A restore was interrupted. Restore your data from"), prompt.message)
        XCTAssertEqual(backfillRuns, 0, "backfills do not run before the user answers")
        gate.keepCurrentData()
        XCTAssertEqual(backfillRuns, 1, "they run once it is answered")
        XCTAssertNil(gate.interrupted)
        XCTAssertFalse(InterruptedImportMarker.exists(in: dir), "Keep current data deletes the marker")
        XCTAssertNotEqual(try BackupContentSummary.of(store: ModelContext(container)).verifiedCounts, expected.verifiedCounts, "the store was left as it was")
    }

    @MainActor
    func test_launchRestore_returnsExactPreImportCounts_thenRunsBackfills_andClearsTheMarker() throws {
        var expected = BackupContentSummary(exportedAt: nil, sessions: 0, completedSessions: 0, lastCompletedDate: nil, sessionHistory: 0, customExercises: 0, mesoBlocks: 0)
        let container = try interruptedStore(restoreTo: &expected)
        var backfillRuns = 0
        let gate = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), runBackfills: { _ in backfillRuns += 1 })
        gate.begin(container: container)
        XCTAssertEqual(backfillRuns, 0)
        gate.restore()
        XCTAssertNil(gate.errorMessage)
        XCTAssertNil(gate.interrupted)
        let after = try BackupContentSummary.of(store: ModelContext(container))
        XCTAssertEqual(after.verifiedCounts, expected.verifiedCounts, "exact pre-import counts")
        XCTAssertEqual(after.completedSessions, expected.completedSessions)
        XCTAssertFalse(InterruptedImportMarker.exists(in: dir))
        XCTAssertEqual(backfillRuns, 1)
    }

    @MainActor
    func test_noMarker_backfillsRunImmediately_andAMarkerWithoutItsSnapshotShowsAOneTimeNoticeWithoutBlocking() throws {
        let container = try BackupTestSupport.makeContainer()
        var runs = 0
        let gate = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), runBackfills: { _ in runs += 1 })
        gate.begin(container: container)
        XCTAssertEqual(runs, 1); XCTAssertNil(gate.interrupted)
        try InterruptedImportMarker.write(snapshot: dir.appendingPathComponent("pre-import-gone.json"), startedAt: Date(), in: dir)
        let gate2 = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), runBackfills: { _ in runs += 1 })
        gate2.begin(container: container)
        XCTAssertEqual(runs, 2); XCTAssertNil(gate2.interrupted)
        XCTAssertFalse(InterruptedImportMarker.exists(in: dir))
        XCTAssertTrue(gate2.showsMissingSnapshotNotice, "the user is told once, not silently")
        XCTAssertTrue(StartupGate.missingSnapshotMessage.hasPrefix("A restore was interrupted and its safety copy is missing."))
        XCTAssertTrue(StartupGate.missingSnapshotMessage.hasSuffix("import your latest export from Files."))
        gate2.showsMissingSnapshotNotice = false
        let gate3 = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), runBackfills: { _ in runs += 1 })
        gate3.begin(container: container)
        XCTAssertFalse(gate3.showsMissingSnapshotNotice, "the marker is gone, so the next launch does not repeat it")
        XCTAssertEqual(runs, 3)
    }

    func test_guard_aBackupExportedMomentsAgoFromTheSameDevice_isNotStale_evenWithFractionalSessionDates() throws {
        let (_, ctx) = try populated()
        // the store keeps sub-second dates; the exported file does not
        let last = Session(date: Date(timeIntervalSince1970: 1_800_000_000.734), status: .completed, weekIndex: 1, dayLabel: "Z", items: [])
        last.id = UUID()
        ctx.insert(last); try ctx.save()
        let file = try fileOf(ctx); defer { try? FileManager.default.removeItem(at: file) }
        let incoming = try BackupContentSummary.of(file: file)
        let current = try BackupContentSummary.of(store: ctx)
        XCTAssertLessThan(try XCTUnwrap(incoming.lastCompletedDate), try XCTUnwrap(current.lastCompletedDate),
                          "reproduces the false positive: the decoded file date is a fraction earlier")
        XCTAssertEqual(incoming.completedSessions, current.completedSessions)
        XCTAssertEqual(ImportStalenessGuard.assess(incoming: incoming, current: current), .normalConfirm, "no REPLACE for your own fresh export")
        // same without ids (an old file): whole-second precision alone is enough
        var noIds = incoming; noIds.completedSessionIds = []
        XCTAssertEqual(ImportStalenessGuard.assess(incoming: noIds, current: current), .normalConfirm)
        // a genuinely older file is still caught, even one second earlier
        var older = incoming; older.completedSessionIds = []
        older.lastCompletedDate = current.lastCompletedDate!.addingTimeInterval(-1.5)
        XCTAssertTrue(ImportStalenessGuard.assess(incoming: older, current: current).requiresTypedWord)
    }

    // MARK: - History exercise order

    private func historyWithSixExercises(_ ctx: ModelContext) throws {
        let names = ["Squat", "Bench", "Row", "Curl", "Lateral Raise", "Calf Raise"]
        let ex = names.enumerated().map { i, n in
            SessionHistoryExercise(name: n, primaryMuscle: nil, sets: 3, reps: 24, volume: Double(100 * (i + 1)), order: i)
        }
        ex.forEach(ctx.insert)
        let h = SessionHistory(date: Date(timeIntervalSince1970: 1_790_000_000), weekIndex: 2, title: "Six", subtitle: "w", totalExercises: 6,
                               totalSets: 18, totalVolume: 2100, exercises: ex)
        ctx.insert(h); try ctx.save()
    }

    /// The raw file, no normalisation: arrays keep the order they were written in.
    private func rawExport(_ ctx: ModelContext) throws -> [String: Any] {
        let url = try BackupTestSupport.exportFile(ctx); defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func historyExerciseNames(_ json: [String: Any]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for h in (json["sessionHistory"] as? [[String: Any]]) ?? [] {
            out[(h["title"] as? String) ?? "?"] = ((h["exercises"] as? [[String: Any]]) ?? []).map { ($0["name"] as? String) ?? "?" }
        }
        return out
    }

    func test_historyExerciseOrder_survivesExportImportExport_inIdenticalOrder() throws {
        let (_, ctx) = try populated()
        try historyWithSixExercises(ctx)
        let first = try rawExport(ctx)
        XCTAssertEqual(historyExerciseNames(first)["Six"], ["Squat", "Bench", "Row", "Curl", "Lateral Raise", "Calf Raise"])
        let target = try BackupTestSupport.makeContainer()
        let file = try fileOf(ctx); defer { try? FileManager.default.removeItem(at: file) }
        try BackupSnapshotImporter.importFullBackupJSON(from: file, modelContainer: target)
        let second = try rawExport(ModelContext(target))
        XCTAssertEqual(historyExerciseNames(second), historyExerciseNames(first), "identical arrays, identical order, every entry")
        // and a second hop
        let file2 = try fileOf(ModelContext(target)); defer { try? FileManager.default.removeItem(at: file2) }
        let target2 = try BackupTestSupport.makeContainer()
        try BackupSnapshotImporter.importFullBackupJSON(from: file2, modelContainer: target2)
        XCTAssertEqual(historyExerciseNames(try rawExport(ModelContext(target2))), historyExerciseNames(first))
        // the order field is in the file
        let sixExercises = try XCTUnwrap(((first["sessionHistory"] as? [[String: Any]])?.first { ($0["title"] as? String) == "Six" })?["exercises"] as? [[String: Any]])
        XCTAssertEqual(sixExercises.compactMap { $0["order"] as? Int }, [0, 1, 2, 3, 4, 5])
    }

    func test_oldBackupWithoutOrder_importsInArrayOrder_andLogsExportInSetOrder() throws {
        let (_, ctx) = try populated()
        try historyWithSixExercises(ctx)
        var json = try rawExport(ctx)
        var hs = try XCTUnwrap(json["sessionHistory"] as? [[String: Any]])
        for i in hs.indices {
            hs[i]["exercises"] = ((hs[i]["exercises"] as? [[String: Any]]) ?? []).map { var e = $0; e.removeValue(forKey: "order"); return e }
        }
        json["sessionHistory"] = hs
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("old_\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let target = try BackupTestSupport.makeContainer()
        try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: target)
        XCTAssertEqual(historyExerciseNames(try rawExport(ModelContext(target)))["Six"], ["Squat", "Bench", "Row", "Curl", "Lateral Raise", "Calf Raise"])
        // set logs are written in set-number order whatever the relationship returns
        for s in (try rawExport(ModelContext(target))["sessions"] as? [[String: Any]]) ?? [] {
            for it in (s["items"] as? [[String: Any]]) ?? [] {
                let nums = ((it["logs"] as? [[String: Any]]) ?? []).compactMap { $0["setNumber"] as? Int }
                XCTAssertEqual(nums, nums.sorted())
            }
        }
    }

    func test_orderBackfill_assignsTheCurrentRelationshipOrder_onlyToEntriesStillAllZero_once() throws {
        UserDefaults.standard.removeObject(forKey: "sessionHistoryExerciseOrder.v1.completed")
        defer { UserDefaults.standard.removeObject(forKey: "sessionHistoryExerciseOrder.v1.completed") }
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let legacy = (0..<4).map { SessionHistoryExercise(name: "L\($0)", primaryMuscle: nil, sets: 1, reps: 1, volume: 1) }   // all order 0
        let assigned = (0..<3).map { SessionHistoryExercise(name: "A\($0)", primaryMuscle: nil, sets: 1, reps: 1, volume: 1, order: 2 - $0) }
        (legacy + assigned).forEach(ctx.insert)
        ctx.insert(SessionHistory(date: Date(), weekIndex: 1, title: "legacy", subtitle: "", totalExercises: 4, totalSets: 4, totalVolume: 4, exercises: legacy))
        ctx.insert(SessionHistory(date: Date(), weekIndex: 1, title: "assigned", subtitle: "", totalExercises: 3, totalSets: 3, totalVolume: 3, exercises: assigned))
        try ctx.save()
        SessionHistoryExerciseOrderBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(legacy.map(\.order).sorted(), [0, 1, 2, 3], "legacy entry: distinct positions from the relationship order")
        XCTAssertEqual(assigned.map(\.order), [2, 1, 0], "an entry with orders already assigned is left alone")
        var lines: [String] = []; BackfillLog.collector = []
        SessionHistoryExerciseOrderBackfill.runIfNeeded(in: ctx)
        lines = BackfillLog.collector ?? []; BackfillLog.collector = nil
        XCTAssertEqual(BackfillLog.result(from: lines), "not needed")
    }
}

/// Store safety: the app holds an iCloud container, so SwiftData would switch CloudKit sync on for any configuration that
/// does not opt out. Every configuration must say `cloudKitDatabase: .none`.
final class StoreSafetyTests: XCTestCase {
    private func swiftFiles() -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var out: [URL] = []
        for dir in ["App", "Domain", "Features", "Shared", "Utilities", "Tests"] {
            let base = root.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.pathExtension == "swift" { out.append(u) }
        }
        return out
    }

    func test_everyModelConfiguration_optsOutOfCloudKit_andNoDefaultContainerIsUsed() throws {
        var offenders: [String] = []
        var configurations = 0
        for file in swiftFiles() where file.lastPathComponent != "BackupFullRoundTripTests.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                let window = lines[i..<min(i + 3, lines.count)].joined(separator: " ")
                if line.contains("ModelConfiguration(") {
                    configurations += 1
                    if !window.contains("cloudKitDatabase: .none") { offenders.append("\(file.lastPathComponent):\(i + 1) ModelConfiguration without cloudKitDatabase: .none") }
                }
                if line.contains("ModelContainer(for") && !window.contains("configurations:") {
                    offenders.append("\(file.lastPathComponent):\(i + 1) ModelContainer without an explicit configuration")
                }
                if line.contains(".modelContainer(for:") {
                    offenders.append("\(file.lastPathComponent):\(i + 1) .modelContainer(for:) uses the default configuration")
                }
            }
        }
        XCTAssertGreaterThan(configurations, 50, "the scan found the configurations")
        XCTAssertEqual(offenders, [])
    }

    // MARK: - Open failure leaves the store alone

    private struct OpenBoom: Error {}

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ep_store_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func config(_ url: URL) -> ModelConfiguration {
        ModelConfiguration(schema: AppSchema.makeSchema(), url: url, cloudKitDatabase: .none)
    }
    /// A real populated store on disk (a few sessions), closed again.
    private func makePopulatedStore(at url: URL) throws {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: config(url))
        let ctx = ModelContext(c)
        for i in 0..<5 { ctx.insert(Session(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400), status: .completed, weekIndex: 1, dayLabel: "D", items: [])) }
        try ctx.save()
    }
    /// Every file in the directory: name -> (bytes, modification date).
    private func fingerprint(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for u in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            out[u.lastPathComponent] = try Data(contentsOf: u)
        }
        return out
    }

    func test_openFailure_leavesTheStoreFilesByteForByteUntouched_andReportsFailure() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("default.store")
        try makePopulatedStore(at: url)
        let before = try fingerprint(dir)
        XCTAssertFalse(before.isEmpty)
        var logs: [String] = []
        let result = AppStoreOpener.open(appSupport: dir, configuration: config(url), makeContainer: { _, _ in throw OpenBoom() }, log: { logs.append($0) })
        guard case .failed(let message) = result else { return XCTFail("an open failure must be reported, not papered over") }
        XCTAssertFalse(message.isEmpty, "the error text is carried to the screen")
        XCTAssertEqual(try fingerprint(dir), before, "no store file was deleted, moved, recreated or rewritten")
        XCTAssertTrue(logs.contains { $0.contains("Nothing was changed") })
    }

    func test_aCorruptStore_failsToOpen_andItsBytesAreUnchanged() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("default.store")
        try Data("this is not a sqlite database, but it is somebody's data".utf8).write(to: url)
        let before = try fingerprint(dir)
        let result = AppStoreOpener.open(appSupport: dir, configuration: config(url), log: { _ in })
        guard case .failed = result else { return XCTFail("a corrupt store must not open") }
        XCTAssertEqual(try fingerprint(dir), before, "not deleted, not recreated, not moved aside")
    }

    func test_legacyStoreFiles_areLoggedAndNeverOpened_theDefaultStoreIsUsed() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("ElitePerformanceStore_v2.store")
        try makePopulatedStore(at: legacy)                       // a legacy store with 5 sessions
        let legacyBefore = try Data(contentsOf: legacy)
        let defaultURL = dir.appendingPathComponent("default.store")
        var logs: [String] = []
        let result = AppStoreOpener.open(appSupport: dir, configuration: config(defaultURL), log: { logs.append($0) })
        guard case .opened(let container) = result else { return XCTFail("the default store opens") }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Session>()), 0, "the legacy store's sessions were NOT adopted")
        XCTAssertTrue(logs.contains { $0.contains("Legacy store files present") && $0.contains("ElitePerformanceStore_v2.store") })
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBefore, "the legacy file is untouched")
    }

    // MARK: - With the iCloud entitlement present

    private func entitlementsFile() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ElitePerformance/ElitePerformance.entitlements")
    }

    /// Tables SwiftData/CoreData create only when CloudKit mirroring is active.
    private func cloudKitMirroringTables(_ url: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return ["<could not open>"] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE name LIKE 'ANSCK%' OR name LIKE '%CLOUDKIT%'", -1, &stmt, nil) == SQLITE_OK else { return ["<query failed>"] }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return names
    }

    func test_withTheICloudEntitlement_aCopyOfAPopulatedStoreOpens_withItsCounts_andNoCloudKitMirroring() throws {
        let entitlements = try String(contentsOf: entitlementsFile(), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("iCloud.com.markcalabrese.ElitePerformance"), "this test must run WITH the iCloud entitlement")
        XCTAssertTrue(entitlements.contains("CloudDocuments"))

        // a populated on-disk store: the Oct 30 fixture when provided, else the BA2 populated store
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original.store")
        let seed = try ModelContainer(for: AppSchema.makeSchema(), configurations: config(original))
        let expected: [Int]
        if let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: seed)
            expected = try BackupContentSummary.of(file: URL(fileURLWithPath: path)).verifiedCounts
        } else {
            try PopulatedStoreBuilder.build(in: ModelContext(seed))
            expected = try BackupContentSummary.of(store: ModelContext(seed)).verifiedCounts
        }
        XCTAssertGreaterThan(expected[0], 0)
        // checkpoint into the main file by closing, then COPY the store files (never open the original again)
        let copyDir = try tempDir(); defer { try? FileManager.default.removeItem(at: copyDir) }
        let copy = copyDir.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: original.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) { try FileManager.default.copyItem(at: src, to: URL(fileURLWithPath: copy.path + suffix)) }
        }

        let result = AppStoreOpener.open(appSupport: copyDir, configuration: config(copy), log: { _ in })
        guard case .opened(let container) = result else { return XCTFail("the copy must open with the entitlement present: \(result)") }
        XCTAssertEqual(try BackupContentSummary.of(store: ModelContext(container)).verifiedCounts, expected, "the counts of the populated store")
        // not mirrored: the configuration says so, and the store has no CloudKit mirroring tables
        let cfg = try XCTUnwrap(container.configurations.first)
        XCTAssertEqual(String(describing: cfg.cloudKitDatabase), String(describing: ModelConfiguration.CloudKitDatabase.none))
        XCTAssertEqual(cloudKitMirroringTables(copy), [], "no CloudKit mirroring is active")
    }
}

/// Automatic backups: triggers, verify-then-move, retention, fallback, banner, verify button.
final class AutoBackupTests: XCTestCase {
    private var sandbox: DefaultsSandbox!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
        DataSentinelStore.overrideDefaults = UserDefaults(suiteName: "ep.sentinel.suite.\(UUID().uuidString)")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep_auto_\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        DataSentinelStore.overrideDefaults = nil
        try? FileManager.default.removeItem(at: dir)
        sandbox.restore()
        super.tearDown()
    }

    private func populated() throws -> (ModelContainer, ModelContext) {
        let c = try BackupTestSupport.makeContainer(); let ctx = ModelContext(c)
        try PopulatedStoreBuilder.build(in: ctx)
        return (c, ctx)
    }
    private func freshStatus() -> AutoBackupStatusStore {
        AutoBackupStatusStore(defaults: UserDefaults(suiteName: "ep.autobackup.test.\(UUID().uuidString)")!)
    }
    @MainActor private func service(_ status: AutoBackupStatusStore, destination: AutoBackupDestination? = nil, now: Date = Date(),
                         commit: String = "abc123", log: @escaping (String) -> Void = { _ in }) -> AutoBackupService {
        let d = destination ?? .local(dir)
        return AutoBackupService(status: status, resolveDestination: { d }, now: { now }, currentCommit: { commit }, log: log)
    }
    private func waitForBackups(_ count: Int, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if AutoBackupEngine.list(in: dir).count >= count { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("expected \(count) backup(s) in \(dir.path), found \(AutoBackupEngine.list(in: dir).count)")
    }
    private func t(_ days: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + days * 86_400) }

    // MARK: verify-then-move

    func test_place_verifiesThenMoves_andNamesAreUnique() throws {
        let (_, ctx) = try populated()
        let live = try BackupContentSummary.of(store: ctx)
        let temp = try BackupTestSupport.exportFile(ctx)
        let placed = try AutoBackupEngine.place(temp: temp, live: live, into: dir, now: t(0), coordinated: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: placed.url.path))
        XCTAssertEqual(try BackupContentSummary.of(file: placed.url).verifiedCounts, live.verifiedCounts)
        XCTAssertEqual(AutoBackupEngine.list(in: dir).map(\.date), [t(0)])
        _ = try AutoBackupEngine.place(temp: temp, live: live, into: dir, now: t(1), coordinated: false)
        XCTAssertEqual(AutoBackupEngine.list(in: dir).count, 2, "a new backup never overwrites an earlier one")
    }

    func test_aCorruptWriteOrMismatchedCounts_neverTouchesThePreviousBackup() throws {
        let (_, ctx) = try populated()
        let live = try BackupContentSummary.of(store: ctx)
        let good = try AutoBackupEngine.place(temp: try BackupTestSupport.exportFile(ctx), live: live, into: dir, now: t(0), coordinated: false)
        let goodBytes = try Data(contentsOf: good.url)
        // a corrupt export
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt_\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: corrupt); defer { try? FileManager.default.removeItem(at: corrupt) }
        XCTAssertThrowsError(try AutoBackupEngine.place(temp: corrupt, live: live, into: dir, now: t(1), coordinated: false))
        // a valid export of a DIFFERENT store (counts do not match the live store)
        let other = ModelContext(try BackupTestSupport.makeContainer())
        other.insert(Session(date: t(0), status: .completed, weekIndex: 1, dayLabel: "X", items: []))
        try other.save()
        let wrong = try BackupTestSupport.exportFile(other); defer { try? FileManager.default.removeItem(at: wrong) }
        XCTAssertThrowsError(try AutoBackupEngine.place(temp: wrong, live: live, into: dir, now: t(2), coordinated: false)) { e in
            guard case AutoBackupError.verifyFailed = e else { return XCTFail("\(e)") }
        }
        let after = AutoBackupEngine.list(in: dir)
        XCTAssertEqual(after.map(\.url), [good.url], "no new file, nothing removed")
        XCTAssertEqual(try Data(contentsOf: good.url), goodBytes, "the previous backup is byte-for-byte intact")
    }

    // MARK: retention

    func test_retention_keeps7Daily_8Weekly_12Monthly_andNeverTheNewestRemoved() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        // one backup a day for 400 days
        let dates = (0..<400).map { t(-Double($0)) }
        let keep = AutoBackupEngine.keepSet(dates, calendar: cal)
        XCTAssertTrue(keep.contains(dates[0]), "the newest is always kept")
        for d in 0..<7 { XCTAssertTrue(keep.contains(dates[d]), "each of the 7 most recent days") }
        XCTAssertLessThan(keep.count, 7 + 9 + 13 + 1, "bounded: daily + weekly + monthly (overlaps collapse)")
        XCTAssertGreaterThanOrEqual(keep.count, 7 + 7, "more than just the days")
        XCTAssertFalse(keep.contains(dates[399]), "something a year old and not a month's newest is pruned")
        // and the pruning removes exactly the others, from a real directory
        let (_, ctx) = try populated()
        let live = try BackupContentSummary.of(store: ctx)
        let temp = try BackupTestSupport.exportFile(ctx)
        for d in 0..<40 { _ = try AutoBackupEngine.place(temp: temp, live: live, into: dir, now: t(-Double(d)), coordinated: false) }
        let removed = AutoBackupEngine.prune(in: dir, calendar: cal)
        let left = AutoBackupEngine.list(in: dir)
        XCTAssertEqual(left.count + removed.count, 40)
        XCTAssertEqual(left.first?.date, t(0), "the newest verified backup survives")
        XCTAssertTrue(removed.count > 0)
        XCTAssertEqual(Set(left.map(\.date)), AutoBackupEngine.keepSet((0..<40).map { t(-Double($0)) }, calendar: cal))
        // a lone old backup is never deleted
        let single = FileManager.default.temporaryDirectory.appendingPathComponent("ep_single_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: single) }
        _ = try AutoBackupEngine.place(temp: temp, live: live, into: single, now: t(-900), coordinated: false)
        XCTAssertEqual(AutoBackupEngine.prune(in: single, calendar: cal).count, 0)
        XCTAssertEqual(AutoBackupEngine.list(in: single).count, 1)
        // files that are not ours are never listed, so never pruned
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        AutoBackupEngine.prune(in: dir, calendar: cal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }

    func test_retention_neverPrunesABackupWithMoreCompletedSessionsThanTheNewestVerifiedOne() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 60 daily backups whose data SHRINKS toward the present: day -59 had 300 sessions ... today has 40.
        var counts: [Date: Int] = [:]
        for d in 0..<60 {
            let date = t(-Double(d))
            let f = dir.appendingPathComponent(AutoBackupEngine.fileName(for: date))
            try Data("{}".utf8).write(to: f)
            counts[date] = max(40, 300 - (59 - d) * 4 + (d < 5 ? -200 : 0))      // newest few are the smallest
        }
        let newest = counts[t(0)]!
        let all = AutoBackupEngine.list(in: dir)
        let keep = AutoBackupEngine.keepSet(all.map(\.date), calendar: cal)
        let wouldPrune = all.filter { !keep.contains($0.date) }
        XCTAssertGreaterThan(wouldPrune.count, 20, "the plain retention rules would prune a lot")
        let removed = AutoBackupEngine.prune(in: dir, calendar: cal, completedSessions: { counts[$0.date] })
        let left = AutoBackupEngine.list(in: dir)
        for f in all where (counts[f.date] ?? 0) > newest {
            XCTAssertTrue(left.contains(f), "a backup with \(counts[f.date]!) completed sessions (> the newest's \(newest)) must survive")
        }
        for f in removed { XCTAssertLessThanOrEqual(counts[f.date] ?? 0, newest, "only backups no larger than the newest are pruned") }
        XCTAssertEqual(left.first?.date, t(0), "and the newest is kept")
        // with a growing history the guard changes nothing: the usual rules apply
        let growing = dir.appendingPathComponent("growing", isDirectory: true)
        try FileManager.default.createDirectory(at: growing, withIntermediateDirectories: true)
        var growCounts: [Date: Int] = [:]
        for d in 0..<60 {
            let date = t(-Double(d)); growCounts[date] = 300 - d
            try Data("{}".utf8).write(to: growing.appendingPathComponent(AutoBackupEngine.fileName(for: date)))
        }
        let gl = AutoBackupEngine.list(in: growing)
        let expectedKeep = AutoBackupEngine.keepSet(gl.map(\.date), calendar: cal)
        AutoBackupEngine.prune(in: growing, calendar: cal, completedSessions: { growCounts[$0.date] })
        XCTAssertEqual(Set(AutoBackupEngine.list(in: growing).map(\.date)), expectedKeep)
    }

    func test_retention_theRealDecodePath_protectsALargerOlderBackup() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        // an old backup of a LARGE store and a newest backup of a SMALL one, real files
        let (_, big) = try populated()
        for i in 0..<5 { big.insert(Session(date: t(Double(i)), status: .completed, weekIndex: 1, dayLabel: "B", items: [])) }
        try big.save()
        let bigLive = try BackupContentSummary.of(store: big)
        let (_, small) = try populated()
        let smallLive = try BackupContentSummary.of(store: small)
        XCTAssertGreaterThan(bigLive.completedSessions, smallLive.completedSessions)
        _ = try AutoBackupEngine.place(temp: try BackupTestSupport.exportFile(big), live: bigLive, into: dir, now: t(-600), coordinated: false)
        // filler (a backup a day for 30 days, then one a month for 15 months) so the old big one falls outside every retention bucket
        for d in 0..<30 { try Data("{}".utf8).write(to: dir.appendingPathComponent(AutoBackupEngine.fileName(for: t(-Double(d))))) }
        for k in 1...15 { try Data("{}".utf8).write(to: dir.appendingPathComponent(AutoBackupEngine.fileName(for: t(-Double(31 * k) - 40)))) }
        _ = try AutoBackupEngine.place(temp: try BackupTestSupport.exportFile(small), live: smallLive, into: dir, now: t(1), coordinated: false)
        let before = AutoBackupEngine.list(in: dir)
        let keep = AutoBackupEngine.keepSet(before.map(\.date), calendar: cal)
        XCTAssertFalse(keep.contains(t(-600)), "without the guard the large old backup would be pruned")
        AutoBackupEngine.prune(in: dir, calendar: cal)
        XCTAssertTrue(AutoBackupEngine.list(in: dir).contains { $0.date == t(-600) }, "the larger history survives")
    }

    // MARK: no iCloud

    @MainActor
    func test_withoutICloud_theBackupGoesToTheLocalFolder_andIsMarkedNotOffDevice() async throws {
        let (c, _) = try populated()
        let status = freshStatus()
        let svc = service(status, destination: .local(dir), now: t(0))
        let result = await svc.backUpNow(container: c)
        guard case .success(let file) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(file.url.path.hasPrefix(dir.path))
        XCTAssertEqual(status.lastSuccess, t(0))
        XCTAssertFalse(status.lastWasOffDevice, "local fallback is not off-device")
        XCTAssertNil(status.lastOffDeviceSuccess)
        XCTAssertTrue(status.lastVerified)
        // the iCloud destination reports off-device and its directory
        let ic = AutoBackupDestination.iCloud(dir.appendingPathComponent("icloud/Documents/Backups"))
        XCTAssertTrue(ic.isOffDevice); XCTAssertFalse(AutoBackupDestination.local(dir).isOffDevice)
        let svc2 = service(status, destination: ic, now: t(1))
        _ = await svc2.backUpNow(container: c)
        XCTAssertTrue(status.lastWasOffDevice)
        XCTAssertEqual(status.lastOffDeviceSuccess, t(1))
        XCTAssertEqual(AutoBackupEngine.list(in: dir.appendingPathComponent("icloud/Documents/Backups")).count, 1)
    }

    @MainActor
    func test_anEmptyStore_isNotBackedUp() async throws {
        let c = try BackupTestSupport.makeContainer()
        let result = await service(freshStatus(), now: t(0)).backUpNow(container: c)
        guard case .failure = result else { return XCTFail("an empty store has nothing to back up") }
        XCTAssertEqual(AutoBackupEngine.list(in: dir).count, 0)
    }

    // MARK: triggers

    @MainActor
    func test_trigger1_aCompletedSession_startsABackup() throws {
        let (c, _) = try populated()
        let svc = service(freshStatus(), now: t(0))
        svc.sessionCompleted(container: c)
        try waitForBackups(1)
    }

    @MainActor
    func test_trigger2_aNewBuildCommit_backsUpOnce() throws {
        let (c, _) = try populated()
        let status = freshStatus()
        let svc = service(status, now: t(0), commit: "build-A")
        XCTAssertTrue(svc.launchBackupIfBuildChanged(container: c))
        try waitForBackups(1)
        let deadline = Date().addingTimeInterval(5)
        while status.lastLaunchCommit != "build-A" && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(status.lastLaunchCommit, "build-A")
        XCTAssertFalse(svc.launchBackupIfBuildChanged(container: c), "same commit as the last launch: no backup")
        let svc2 = service(status, now: t(1), commit: "build-B")
        XCTAssertTrue(svc2.launchBackupIfBuildChanged(container: c), "a different commit backs up again")
    }

    @MainActor
    func test_trigger3_firstForegroundOfTheDay_whenTheLastSuccessIsOlderThan24h() throws {
        let (c, _) = try populated()
        let status = freshStatus()
        status.lastSuccess = t(0)
        // 23h later: first foreground of the day, but the last backup is recent
        XCTAssertFalse(service(status, now: t(0).addingTimeInterval(23 * 3600)).foregrounded(container: c))
        // two days later: a new calendar day, and the last success is more than 24h old
        let later = t(0).addingTimeInterval(50 * 3600)
        XCTAssertTrue(service(status, now: later).foregrounded(container: c))
        try waitForBackups(1)
        // a second foreground the same day does nothing
        XCTAssertFalse(service(status, now: later.addingTimeInterval(600)).foregrounded(container: c))
    }

    @MainActor
    func test_theBuildChangeBackup_runsAfterTheInterruptedCheck_andBeforeTheBackfills() throws {
        let c = try BackupTestSupport.makeContainer()
        var order: [String] = []
        let gate = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), beforeBackfills: { _ in order.append("backup") }, runBackfills: { _ in order.append("backfills") })
        gate.begin(container: c)
        XCTAssertEqual(order, ["backup", "backfills"])
        // with an interrupted import pending, neither runs until it is answered, and then in the same order
        order = []
        let (_, srcCtx) = try populated()
        let snap = try XCTUnwrap(PreImportSnapshots.take(from: srcCtx, in: dir, now: t(0)))
        try InterruptedImportMarker.write(snapshot: snap.url, startedAt: t(0), in: dir)
        let gate2 = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), beforeBackfills: { _ in order.append("backup") }, runBackfills: { _ in order.append("backfills") })
        gate2.begin(container: c)
        XCTAssertEqual(order, [], "held back behind the interrupted-restore prompt")
        gate2.keepCurrentData()
        XCTAssertEqual(order, ["backup", "backfills"])
    }

    // MARK: log lines

    @MainActor
    func test_everyAttemptLogsOneLine_withTriggerDestinationOutcomeAndCounts() async throws {
        let (c, ctx) = try populated()
        let counts = try BackupContentSummary.of(store: ctx).verifiedCounts
        let countsText = "sessions=\(counts[0]) history=\(counts[1]) custom=\(counts[2]) blocks=\(counts[3])"
        var lines: [String] = []
        // success, local fallback
        let svc = service(freshStatus(), destination: .local(dir), now: t(0), log: { lines.append($0) })
        _ = await svc.backUpNow(container: c)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("[manual]") && lines[0].contains(" local ") && lines[0].contains("verified") && lines[0].contains(countsText), lines[0])
        // success, iCloud destination
        lines = []
        let ic = AutoBackupDestination.iCloud(dir.appendingPathComponent("icloud"))
        _ = await service(freshStatus(), destination: ic, now: t(1), log: { lines.append($0) }).backUpNow(container: c)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains(" iCloud ") && lines[0].contains("verified"), lines[0])
        // failure: the destination cannot be written
        lines = []
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker_\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker); defer { try? FileManager.default.removeItem(at: blocker) }
        _ = await service(freshStatus(), destination: .local(blocker), now: t(2), log: { lines.append($0) }).backUpNow(container: c)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("FAILED") && lines[0].contains(" local ") && lines[0].contains(countsText), lines[0])
        // skipped: an empty store
        lines = []
        service(freshStatus(), now: t(3), log: { lines.append($0) }).sessionCompleted(container: try BackupTestSupport.makeContainer())
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("[sessionCompleted]") && lines[0].contains("skipped"), lines[0])
    }

    @MainActor
    func test_theBuildChangeTrigger_logsWhyItDidNotFire() throws {
        let (c, _) = try populated()
        var lines: [String] = []
        let status = freshStatus()
        status.lastLaunchCommit = "0f94a26"
        let svc = service(status, now: t(0), commit: "0f94a26", log: { lines.append($0) })
        XCTAssertFalse(svc.launchBackupIfBuildChanged(container: c))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("[buildChanged]") && lines[0].contains("not needed") && lines[0].contains("0f94a26"), lines[0])
    }

    // MARK: banner

    func test_banner_showsWithoutAVerifiedOffDeviceBackupFor7Days_andDismissalLastsUntilTomorrow() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let status = freshStatus()
        XCTAssertFalse(status.shouldShowBanner(now: t(0), hasData: false, calendar: cal), "nothing to protect")
        XCTAssertTrue(status.shouldShowBanner(now: t(0), hasData: true, calendar: cal), "never backed up off-device")
        status.recordSuccess(at: t(0), offDevice: false)
        XCTAssertTrue(status.shouldShowBanner(now: t(1), hasData: true, calendar: cal), "a local-only backup does not count")
        status.recordSuccess(at: t(0), offDevice: true)
        XCTAssertFalse(status.shouldShowBanner(now: t(6.9), hasData: true, calendar: cal))
        XCTAssertTrue(status.shouldShowBanner(now: t(7.1), hasData: true, calendar: cal))
        status.dismissBannerForToday(now: t(7.1), calendar: cal)
        XCTAssertFalse(status.shouldShowBanner(now: t(7.5), hasData: true, calendar: cal), "dismissed for today")
        XCTAssertTrue(status.shouldShowBanner(now: t(8.2), hasData: true, calendar: cal), "back the next day")
    }

    // MARK: verify button

    func test_verifyLatestBackup_decodesIntoAScratchContainerAndComparesCounts_withoutTouchingDeviceState() throws {
        let (_, ctx) = try populated()
        let live = try BackupContentSummary.of(store: ctx)
        let placed = try AutoBackupEngine.place(temp: try BackupTestSupport.exportFile(ctx), live: live, into: dir, now: t(0), coordinated: false)
        let sentinel = "meso.activeStartDateEpoch"
        UserDefaults.standard.set(123456.0, forKey: sentinel)
        let report = try AutoBackupVerification.verify(file: placed.url, against: ctx)
        XCTAssertTrue(report.matches, report.summary)
        XCTAssertEqual(report.backup, live.verifiedCounts)
        XCTAssertEqual(UserDefaults.standard.double(forKey: sentinel), 123456.0,
                       "the scratch import did not write the backup's AppState into this device's UserDefaults")
        // the live store moves on: the same backup no longer matches
        ctx.insert(Session(date: t(3), status: .completed, weekIndex: 1, dayLabel: "New", items: [])); try ctx.save()
        let after = try AutoBackupVerification.verify(file: placed.url, against: ctx)
        XCTAssertFalse(after.matches)
        XCTAssertTrue(after.summary.hasPrefix("Does not match"))
        XCTAssertEqual(try BackupContentSummary.of(store: ctx).sessions, live.sessions + 1, "and the live store was not modified by the verify")
    }
}

/// Missing-data sentinel: a store that opens with 0 completed sessions after a launch that had some must not be carried on with.
final class MissingDataSentinelTests: XCTestCase {
    private var dir: URL!
    private var sentinel: DataSentinelStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep_sentinel_\(UUID().uuidString)", isDirectory: true)
        sentinel = DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.\(UUID().uuidString)")!)
        DataSentinelStore.overrideDefaults = sentinel.defaults
    }
    override func tearDown() {
        DataSentinelStore.overrideDefaults = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func populated() throws -> (ModelContainer, ModelContext) {
        let c = try BackupTestSupport.makeContainer(); let ctx = ModelContext(c)
        try PopulatedStoreBuilder.build(in: ctx)
        return (c, ctx)
    }
    @MainActor
    private func gate(_ counts: Counts2, backups: @escaping @Sendable () -> [AutoBackupFile] = { [] }) -> StartupGate {
        StartupGate(directory: dir, sentinel: sentinel,
                    beforeBackfills: { _ in counts.before += 1 }, runBackfills: { _ in counts.backfills += 1 }, findBackups: backups)
    }
    private final class Counts2 { var before = 0, backfills = 0 }

    @MainActor
    func test_blocks_whenTheStoreIsEmptyButTheLastLaunchHadCompletedSessions_andRunsNothing() throws {
        sentinel.record(12)
        let empty = try BackupTestSupport.makeContainer()
        let counts = Counts2()
        let g = gate(counts)
        g.begin(container: empty)
        XCTAssertEqual(g.missingData, StartupGate.MissingData(expectedSessions: 12))
        XCTAssertEqual(StartupGate.missingDataMessage, "Your training data wasn't found. Nothing has been changed.")
        XCTAssertEqual(counts.backfills, 0, "no backfills")
        XCTAssertEqual(counts.before, 0, "no automatic backup (it runs in the before-backfills hook)")
        XCTAssertEqual(sentinel.completedSessions, 12, "the sentinel is not overwritten by the empty store")
        XCTAssertEqual(try BackupContentSummary.of(store: ModelContext(empty)).sessions, 0, "and nothing was written to the store")
    }

    @MainActor
    func test_noBlock_onAFreshInstall_andTheSentinelIsRecordedAfterASuccessfulLaunch() throws {
        let counts = Counts2()
        let fresh = try BackupTestSupport.makeContainer()
        let g = gate(counts)
        g.begin(container: fresh)
        XCTAssertNil(g.missingData, "no sentinel yet: a fresh install is not 'missing data'")
        XCTAssertEqual(counts.backfills, 1)
        XCTAssertEqual(sentinel.completedSessions, 0)
        // a launch with data records its count
        let (c, ctx) = try populated()
        let expected = try BackupContentSummary.of(store: ctx).completedSessions
        XCTAssertGreaterThan(expected, 0)
        let g2 = gate(counts); g2.begin(container: c)
        XCTAssertNil(g2.missingData)
        XCTAssertEqual(sentinel.completedSessions, expected, "persisted after a successful launch")
    }

    @MainActor
    func test_restoreNewestBackup_returnsTheData_runsBackfillsOnce_andTheNextLaunchIsNotBlocked() async throws {
        // a backup of a populated store exists
        let (_, src) = try populated()
        let live = try BackupContentSummary.of(store: src)
        let placed = try AutoBackupEngine.place(temp: try BackupTestSupport.exportFile(src), live: live, into: dir.appendingPathComponent("backups"),
                                                now: Date(timeIntervalSince1970: 1_800_000_000), coordinated: false)
        // the device's store has lost everything
        sentinel.record(live.completedSessions)
        let lost = try BackupTestSupport.makeContainer()
        let counts = Counts2()
        let g = gate(counts, backups: { [placed] in [placed] })
        g.begin(container: lost)
        XCTAssertNotNil(g.missingData)
        await g.loadNewestBackup()
        XCTAssertEqual(g.newestBackup, placed)
        XCTAssertEqual(g.newestBackupSummary?.completedSessions, live.completedSessions)
        g.restoreNewestBackup()
        XCTAssertNil(g.missingData); XCTAssertNil(g.missingDataError)
        XCTAssertEqual(try BackupContentSummary.of(store: ModelContext(lost)).verifiedCounts, live.verifiedCounts, "the data is back")
        XCTAssertEqual(counts.backfills, 1)
        XCTAssertEqual(sentinel.completedSessions, live.completedSessions, "the legitimate restore updated the sentinel")
        // next launch: the store has its sessions again
        let counts2 = Counts2(); let g2 = gate(counts2); g2.begin(container: lost)
        XCTAssertNil(g2.missingData); XCTAssertEqual(counts2.backfills, 1)
    }

    func test_aLegitimateImport_updatesTheSentinel_soAnOlderSmallerStoreIsNotFlagged() throws {
        let (_, src) = try populated()
        let exported = try BackupTestSupport.exportFile(src)
        let incoming = FileManager.default.temporaryDirectory.appendingPathComponent("incoming_\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: exported, to: incoming); defer { try? FileManager.default.removeItem(at: incoming) }
        let expected = try BackupContentSummary.of(file: incoming).completedSessions
        sentinel.record(999)
        let (target, _) = try populated()
        try BackupRestoreCoordinator.restore(from: incoming, container: target, snapshotDirectory: dir)
        XCTAssertEqual(sentinel.completedSessions, expected)
    }

    @MainActor
    func test_withNoBackupToRestore_theOnlyWayForwardIsToContinueWithEmptyData() async throws {
        sentinel.record(5)
        let counts = Counts2()
        let g = gate(counts, backups: { [] })
        g.begin(container: try BackupTestSupport.makeContainer())
        await g.loadNewestBackup()
        XCTAssertNil(g.newestBackup); XCTAssertTrue(g.backupLookupDone)
        // without the typed word nothing happens: still blocked, nothing ran, the sentinel is unchanged
        for wrong in ["", "continue", "Continue", "CONTINU", "yes", "CONTINUE NOW"] {
            XCTAssertFalse(g.continueWithEmptyData(typed: wrong), wrong)
        }
        XCTAssertNotNil(g.missingData); XCTAssertEqual(counts.backfills, 0); XCTAssertEqual(sentinel.completedSessions, 5)
        XCTAssertFalse(StartupGate.acceptsContinue(typed: "continue"))
        // the exact word proceeds
        XCTAssertTrue(g.continueWithEmptyData(typed: "CONTINUE"))
        XCTAssertNil(g.missingData); XCTAssertEqual(sentinel.completedSessions, 0); XCTAssertEqual(counts.backfills, 1)
    }

    @MainActor
    func test_aBackupWithNoCompletedSessions_isNotOfferedAsTheRestore() async throws {
        sentinel.record(5)
        // a backup of a store with a planned session only
        let c = try BackupTestSupport.makeContainer(); let ctx = ModelContext(c)
        ctx.insert(Session(date: Date(), status: .planned, weekIndex: 1, dayLabel: "P", items: [])); try ctx.save()
        let live = try BackupContentSummary.of(store: ctx)
        let empty = try AutoBackupEngine.place(temp: try BackupTestSupport.exportFile(ctx), live: live, into: dir.appendingPathComponent("b"), now: Date(), coordinated: false)
        let g = gate(Counts2(), backups: { [empty] in [empty] })
        g.begin(container: try BackupTestSupport.makeContainer())
        await g.loadNewestBackup()
        XCTAssertNil(g.newestBackup, "restoring a backup with no completed sessions would not bring the data back")
    }
}
