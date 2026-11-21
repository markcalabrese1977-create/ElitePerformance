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
        let gate = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), backupFirst: nil, runBackfills: { _ in backfillRuns += 1 })
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
        let gate = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), backupFirst: nil, runBackfills: { _ in backfillRuns += 1 })
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
        let gate = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), backupFirst: nil, runBackfills: { _ in runs += 1 })
        gate.begin(container: container)
        XCTAssertEqual(runs, 1); XCTAssertNil(gate.interrupted)
        try InterruptedImportMarker.write(snapshot: dir.appendingPathComponent("pre-import-gone.json"), startedAt: Date(), in: dir)
        let gate2 = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), backupFirst: nil, runBackfills: { _ in runs += 1 })
        gate2.begin(container: container)
        XCTAssertEqual(runs, 2); XCTAssertNil(gate2.interrupted)
        XCTAssertFalse(InterruptedImportMarker.exists(in: dir))
        XCTAssertTrue(gate2.showsMissingSnapshotNotice, "the user is told once, not silently")
        XCTAssertTrue(StartupGate.missingSnapshotMessage.hasPrefix("A restore was interrupted and its safety copy is missing."))
        XCTAssertTrue(StartupGate.missingSnapshotMessage.hasSuffix("import your latest export from Files."))
        gate2.showsMissingSnapshotNotice = false
        let gate3 = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), backupFirst: nil, runBackfills: { _ in runs += 1 })
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
    func test_trigger2_aNewBuildCommit_backsUpOnce_andTheCallWaitsForTheVerifiedFile() async throws {
        let (c, _) = try populated()
        let status = freshStatus()
        let svc = service(status, now: t(0), commit: "build-A")
        let first = try await svc.backUpIfBuildChanged(container: c).get()
        XCTAssertNotNil(first, "the backup is done (verified and placed) when the call returns, so backfills can follow")
        XCTAssertEqual(AutoBackupEngine.list(in: dir).count, 1)
        XCTAssertEqual(status.lastLaunchCommit, "build-A")
        XCTAssertEqual(status.lastBuildChangeBackup, first?.url.lastPathComponent)
        let again = try await svc.backUpIfBuildChanged(container: c).get()
        XCTAssertNil(again, "same commit as the last launch: no backup")
        let svc2 = service(status, now: t(1), commit: "build-B")
        let second = try await svc2.backUpIfBuildChanged(container: c).get()
        XCTAssertNotNil(second, "a different commit backs up again")
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
    private func spin(_ g: StartupGate, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while g.launching && g.startupGuard.failure == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    @MainActor
    func test_theBuildChangeBackup_runsAfterTheInterruptedCheck_andBeforeTheBackfills() throws {
        let c = try BackupTestSupport.makeContainer()
        var order: [String] = []
        let gate = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), backupFirst: { _ in order.append("backup"); return .success(nil) }, runBackfills: { _ in order.append("backfills") })
        gate.begin(container: c)
        spin(gate)
        XCTAssertEqual(order, ["backup", "backfills"])
        // with an interrupted import pending, neither runs until it is answered, and then in the same order
        order = []
        let (_, srcCtx) = try populated()
        let snap = try XCTUnwrap(PreImportSnapshots.take(from: srcCtx, in: dir, now: t(0)))
        try InterruptedImportMarker.write(snapshot: snap.url, startedAt: t(0), in: dir)
        let gate2 = StartupGate(directory: dir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!), backupFirst: { _ in order.append("backup"); return .success(nil) }, runBackfills: { _ in order.append("backfills") })
        gate2.begin(container: c)
        spin(gate2)
        XCTAssertEqual(order, [], "held back behind the interrupted-restore prompt")
        gate2.keepCurrentData()
        spin(gate2)
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
    func test_theBuildChangeTrigger_logsWhyItDidNotFire() async throws {
        let (c, _) = try populated()
        var lines: [String] = []
        let status = freshStatus()
        status.lastLaunchCommit = "0f94a26"
        let svc = service(status, now: t(0), commit: "0f94a26", log: { lines.append($0) })
        let none = try await svc.backUpIfBuildChanged(container: c).get()
        XCTAssertNil(none)
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

    /// For async tests: yield so the launch work's MainActor task can run.
    @MainActor
    private func settleAsync(_ g: StartupGate, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while g.launching && g.startupGuard.failure == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// The launch work is asynchronous (the pre-backfill backup is awaited): spin the main loop until it has finished.
    @MainActor
    private func settle(_ g: StartupGate, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while g.launching && g.startupGuard.failure == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    private func populated() throws -> (ModelContainer, ModelContext) {
        let c = try BackupTestSupport.makeContainer(); let ctx = ModelContext(c)
        try PopulatedStoreBuilder.build(in: ctx)
        return (c, ctx)
    }
    @MainActor
    private func gate(_ counts: Counts2, backups: @escaping @Sendable () -> [AutoBackupFile] = { [] }) -> StartupGate {
        StartupGate(directory: dir, sentinel: sentinel,
                    backupFirst: { _ in counts.before += 1; return .success(nil) }, runBackfills: { _ in counts.backfills += 1 }, findBackups: backups)
    }
    private final class Counts2 { var before = 0, backfills = 0 }

    @MainActor
    func test_blocks_whenTheStoreIsEmptyButTheLastLaunchHadCompletedSessions_andRunsNothing() throws {
        sentinel.record(12)
        let empty = try BackupTestSupport.makeContainer()
        let counts = Counts2()
        let g = gate(counts)
        g.begin(container: empty)
        settle(g)
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
        settle(g)
        XCTAssertNil(g.missingData, "no sentinel yet: a fresh install is not 'missing data'")
        XCTAssertEqual(counts.backfills, 1)
        XCTAssertEqual(sentinel.completedSessions, 0)
        // a launch with data records its count
        let (c, ctx) = try populated()
        let expected = try BackupContentSummary.of(store: ctx).completedSessions
        XCTAssertGreaterThan(expected, 0)
        let g2 = gate(counts); g2.begin(container: c); settle(g2)
        XCTAssertNil(g2.missingData)
        XCTAssertEqual(sentinel.completedSessions, expected, "persisted after a successful launch")
    }

    @MainActor
    func test_theLaunchLogsTheStoredAndWrittenSentinelCounts_andThePersistedValueReadsBackNextLaunch() throws {
        var lines: [String] = []
        let (c, ctx) = try populated()
        let completed = try BackupContentSummary.of(store: ctx).completedSessions
        sentinel.record(3)
        let g = StartupGate(directory: dir, sentinel: sentinel, backupFirst: nil, runBackfills: { _ in },
                            findBackups: { [] }, log: { lines.append($0) })
        g.begin(container: c)
        settle(g)
        XCTAssertTrue(lines.contains { $0.contains("read stored=3") && $0.contains("store holds \(completed) completed sessions") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("wrote \(completed), reads back \(completed)") }, "\(lines)")
        // a fresh handle on the same defaults (the next launch) reads what this launch wrote
        let next = DataSentinelStore(defaults: sentinel.defaults)
        XCTAssertEqual(next.completedSessions, completed)
        // a blocking launch says so
        lines = []
        sentinel.record(7)
        StartupGate(directory: dir, sentinel: sentinel, backupFirst: nil, runBackfills: { _ in }, findBackups: { [] },
                    log: { lines.append($0) }).begin(container: try BackupTestSupport.makeContainer())
        XCTAssertTrue(lines.contains { $0.contains("read stored=7") && $0.contains("0 completed sessions") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("BLOCKING") }, "\(lines)")
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
        settle(g)
        XCTAssertNotNil(g.missingData)
        await g.loadNewestBackup()
        XCTAssertEqual(g.newestBackup, placed)
        XCTAssertEqual(g.newestBackupSummary?.completedSessions, live.completedSessions)
        g.restoreNewestBackup(); await settleAsync(g)
        XCTAssertNil(g.missingData); XCTAssertNil(g.missingDataError)
        XCTAssertEqual(try BackupContentSummary.of(store: ModelContext(lost)).verifiedCounts, live.verifiedCounts, "the data is back")
        XCTAssertEqual(counts.backfills, 1)
        XCTAssertEqual(sentinel.completedSessions, live.completedSessions, "the legitimate restore updated the sentinel")
        // next launch: the store has its sessions again
        let counts2 = Counts2(); let g2 = gate(counts2); g2.begin(container: lost); await settleAsync(g2)
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
        XCTAssertTrue(g.continueWithEmptyData(typed: "CONTINUE")); await settleAsync(g)
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

// MARK: - VV: RIR entry (unset is distinct from 0)

final class RIREntryTests: XCTestCase {

    private var sandbox: DefaultsSandbox!
    override func setUp() { super.setUp(); sandbox = DefaultsSandbox() }
    override func tearDown() { sandbox.restore(); super.tearDown() }

    /// A completed 3-set item at repMax 8, target RIR 2, 100 lb.
    private func item(_ id: String, reps: [Int], rirs: [Int], load: Double = 100) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: 8, targetSets: reps.count, targetRIR: 2, suggestedLoad: load)
        i.actualReps = reps
        i.actualLoads = Array(repeating: load, count: reps.count)
        i.actualRIRs = rirs
        i.plannedRepsBySet = Array(repeating: 8, count: reps.count)
        i.repMin = 6; i.repMax = 8
        return i
    }

    func test_unsetIsDistinctFromZero_andOnlyCompoundsFeedDecisions() {
        let bench = item("bench_press", reps: [8, 8], rirs: [RIREntry.unset, 0])
        XCTAssertNil(RIREntry.recorded(bench, at: 0), "unset")
        XCTAssertEqual(RIREntry.recorded(bench, at: 1), 0, "a recorded zero is a value")
        XCTAssertNil(RIREntry.recorded(bench, at: 5), "no entry")
        XCTAssertEqual(RIREntry.decisionRIR(bench, at: 1), 0)

        XCTAssertTrue(RIREntry.isCompound("bench_press"))
        XCTAssertTrue(RIREntry.isCompound("barbell_row"))
        XCTAssertTrue(RIREntry.isCompound("hack_squat"))
        XCTAssertFalse(RIREntry.isCompound("cable_tricep_pushdown_straight_bar"), "a pushdown shares a cluster with the presses but is isolation")
        XCTAssertFalse(RIREntry.isCompound("seated_cable_fly"))
        XCTAssertFalse(RIREntry.isCompound("some_custom_exercise"), "no cluster, no RIR decisions")
        let fly = item("seated_cable_fly", reps: [8], rirs: [1])
        XCTAssertEqual(RIREntry.recorded(fly, at: 0), 1)
        XCTAssertNil(RIREntry.decisionRIR(fly, at: 0), "an isolation set never feeds a decision")
    }

    func test_compound_unsetRIR_isJudgedOnRepsAlone_andNeverClaimsTheTargetDifficulty() throws {
        let unset = item("bench_press", reps: [8, 8, 8], rirs: Array(repeating: RIREntry.unset, count: 3))
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: unset))
        XCTAssertGreaterThan(rec.nextSuggestedLoad ?? 0, 100, "every set at the top: reps alone earn the increase")
        XCTAssertFalse(rec.message.contains("target difficulty"), rec.message)

        let short = item("bench_press", reps: [7, 6, 6], rirs: Array(repeating: RIREntry.unset, count: 3))
        let hold = try XCTUnwrap(CoachingEngine.recommend(for: short))
        XCTAssertEqual(hold.nextSuggestedLoad, 100, "an unset RIR is not assumed on target; reps under the top hold")
    }

    func test_compound_aRecordedRIRBelowPlanMinusOne_blocksAnIncrease() throws {
        let hard = item("bench_press", reps: [8, 8, 8], rirs: [2, 2, 0])      // plan 2: 0 < 1
        XCTAssertEqual(try XCTUnwrap(CoachingEngine.recommend(for: hard)).nextSuggestedLoad, 100, "an RIR 0 set blocks the bump")
        let ok = item("bench_press", reps: [8, 8, 8], rirs: [2, 2, 1])        // 1 = plan-1 is allowed
        XCTAssertGreaterThan(try XCTUnwrap(CoachingEngine.recommend(for: ok)).nextSuggestedLoad ?? 0, 100)
        let onTarget = item("bench_press", reps: [8, 8, 8], rirs: [2, 2, 2])
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: onTarget))
        XCTAssertGreaterThan(rec.nextSuggestedLoad ?? 0, 100)
        XCTAssertTrue(rec.message.hasPrefix("24/24 reps — increase earned"), rec.message)
    }

    func test_isolation_ignoresRIRCompletely_repsAgainstTargetOnly() throws {
        for rirs in [[0, 0, 0], [RIREntry.unset, RIREntry.unset, RIREntry.unset], [4, 4, 4]] {
            let fly = item("seated_cable_fly", reps: [8, 8, 8], rirs: rirs)
            let rec = try XCTUnwrap(CoachingEngine.recommend(for: fly))
            XCTAssertGreaterThan(rec.nextSuggestedLoad ?? 0, 100, "RIR \(rirs) on an isolation lift never blocks nor earns")
            XCTAssertFalse(rec.message.contains("target difficulty"), rec.message)
        }
        let under = item("seated_cable_fly", reps: [6, 6, 6], rirs: [2, 2, 2])
        XCTAssertEqual(try XCTUnwrap(CoachingEngine.recommend(for: under)).nextSuggestedLoad, 100, "reps under the top hold, whatever the RIR says")
    }

    func test_progressionSnapshots_carryNoRIR_forUnsetOrIsolation() {
        let bench = item("bench_press", reps: [8, 8], rirs: [RIREntry.unset, 1])
        XCTAssertEqual(bench.toSetSnapshots().map(\.rir), [nil, 1.0])
        let fly = item("seated_cable_fly", reps: [8], rirs: [1])
        XCTAssertEqual(fly.toSetSnapshots().map(\.rir), [nil])
    }

    func test_unsetAndZeroAndOldValues_roundTripThroughABackupAsRecorded() throws {
        let source = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: source)
        // A new-style item (unset + a real 0 + a value) next to the old-style values the builder wrote.
        let session = try XCTUnwrap(try source.fetch(FetchDescriptor<Session>()).first { !$0.items.isEmpty })
        let fresh3 = SessionItem(order: 9, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        fresh3.actualReps = [8, 8, 8]; fresh3.actualLoads = [100, 100, 100]; fresh3.actualRIRs = [RIREntry.unset, 0, 3]
        source.insert(fresh3); session.items.append(fresh3)
        try source.save()
        let before = try source.fetch(FetchDescriptor<SessionItem>()).map { ($0.id, $0.actualRIRs) }
        XCTAssertTrue(before.contains { $0.1 == [-1, 0, 3] })

        let fresh = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: fresh)
        let after = try ModelContext(fresh).fetch(FetchDescriptor<SessionItem>()).map { ($0.id, $0.actualRIRs) }
        XCTAssertEqual(Set(after.map { "\($0.0 as Any)|\($0.1)" }), Set(before.map { "\($0.0 as Any)|\($0.1)" }),
                       "unset stays unset, 0 stays 0, every old value is exactly as recorded")
    }
}

// MARK: - WW: total-rep progression for compounds

final class TotalRepProgressionTests: XCTestCase {

    private func bench(_ reps: [Int], rirs: [Int]? = nil, id: String = "bench_press") -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: 8, targetSets: reps.count, targetRIR: 2, suggestedLoad: 185)
        i.actualReps = reps
        i.actualLoads = Array(repeating: 185, count: reps.count)
        i.actualRIRs = rirs ?? RIREntry.unsetArray(count: reps.count)
        i.plannedRepsBySet = Array(repeating: 8, count: reps.count)
        i.repMin = 6; i.repMax = 8
        return i
    }

    func test_benchPattern_8_7_6_is21of24_hold() throws {
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: bench([8, 7, 6], rirs: [2, 2, 1]), minLoadIncrement: 2.5))
        XCTAssertEqual(rec.nextSuggestedLoad, 185)
        XCTAssertTrue(rec.message.hasPrefix("21/24 — hold, climb reps"), rec.message)
    }

    func test_benchPattern_8_8_7_is23of24_increase_byTheLoadStep() throws {
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: bench([8, 8, 7], rirs: [2, 2, 1]), minLoadIncrement: 2.5))
        XCTAssertEqual(rec.nextSuggestedLoad, 187.5, "the configured 2.5 step")
        XCTAssertTrue(rec.message.hasPrefix("23/24 reps — increase earned"), rec.message)
    }

    func test_theLastSetsRecordedRIR_belowPlanMinusOne_blocksTheIncrease_andUnsetDoesNot() throws {
        let hard = try XCTUnwrap(CoachingEngine.recommend(for: bench([8, 8, 7], rirs: [2, 2, 0]), minLoadIncrement: 2.5))
        XCTAssertEqual(hard.nextSuggestedLoad, 185, "last set at RIR 0 (< plan-1): hold")
        let unset = try XCTUnwrap(CoachingEngine.recommend(for: bench([8, 8, 7]), minLoadIncrement: 2.5))
        XCTAssertEqual(unset.nextSuggestedLoad, 187.5, "unset RIR: reps decide")
    }

    func test_aFourSetCompound_sumsThePrimaryThreeSets_aFourthRowIsNotEvidence() throws {
        let four = try XCTUnwrap(CoachingEngine.recommend(for: bench([8, 8, 7, 4], rirs: [2, 2, 1, 1]), minLoadIncrement: 2.5))
        XCTAssertEqual(four.nextSuggestedLoad, 187.5)
        XCTAssertTrue(four.message.hasPrefix("23/24 reps — increase earned"), four.message)
    }

    func test_isolationKeepsTheEverySetAtTheTopRule() throws {
        let fly = try XCTUnwrap(CoachingEngine.recommend(for: bench([8, 8, 7], id: "seated_cable_fly"), minLoadIncrement: 2.5))
        XCTAssertEqual(fly.nextSuggestedLoad, 185, "8,8,7 on an isolation lift is not every set at the top")
        let all = try XCTUnwrap(CoachingEngine.recommend(for: bench([8, 8, 8], id: "seated_cable_fly"), minLoadIncrement: 2.5))
        XCTAssertEqual(all.nextSuggestedLoad, 187.5)
    }

    func test_theReduceRuleIsUnchanged_twoBadlyMissedSetsBackTheLoadOff() throws {
        let rec = try XCTUnwrap(CoachingEngine.recommend(for: bench([5, 4, 4], rirs: [2, 1, 1]), minLoadIncrement: 2.5))
        XCTAssertLessThan(rec.nextSuggestedLoad ?? 999, 185)
    }
}

// MARK: - YY: RIRUnsetBackfill

final class RIRUnsetBackfillTests: XCTestCase {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
    }

    private func item(_ id: String, reps: [Int], rirs: [Int]) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: 8, targetSets: reps.count, targetRIR: 2, suggestedLoad: 100)
        i.actualReps = reps; i.actualRIRs = rirs
        return i
    }

    func test_paddedFutureCompoundSets_becomeUnset_loggedZeroStays_isolationAndCompletedUntouched_idempotent() throws {
        let ctx = try context()
        let padded = item("bench_press", reps: [0, 0, 0], rirs: [0, 0, 0])
        let midSession = item("bench_press", reps: [8, 0, 0], rirs: [0, 0, 0])          // set 1 logged at a real RIR 0
        let isolation = item("seated_cable_fly", reps: [0, 0], rirs: [0, 0])
        let done = item("bench_press", reps: [0, 0], rirs: [0, 0])                       // completed: never touched
        let planned = Session(date: Date(), status: .planned, weekIndex: 1, items: [padded, isolation])
        let running = Session(date: Date(), status: .inProgress, weekIndex: 1, items: [midSession])
        let complete = Session(date: Date(), status: .completed, weekIndex: 1, items: [done])
        for s in [planned, running, complete] { ctx.insert(s) }
        try ctx.save()

        RIRUnsetBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(padded.actualRIRs, [-1, -1, -1])
        XCTAssertEqual(midSession.actualRIRs, [0, -1, -1], "the logged set keeps its recorded 0")
        XCTAssertEqual(isolation.actualRIRs, [0, 0])
        XCTAssertEqual(done.actualRIRs, [0, 0])

        let lines = LineSink()
        BackfillLog.collector = []
        RIRUnsetBackfill.runIfNeeded(in: ctx)
        lines.notes = BackfillLog.collector ?? []; BackfillLog.collector = nil
        XCTAssertEqual(BackfillLog.result(from: lines.notes), "not needed", "idempotent")
        XCTAssertEqual(padded.actualRIRs, [-1, -1, -1])
    }

    private final class LineSink { var notes: [String] = [] }

    // LOCAL ONLY, READ-ONLY.
    func test_audit_whatTheBackfillWouldChangeOnTheLatestBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let container = try ModelContainer(for: AppSchema.makeSchema(),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let todo = RIRUnsetBackfill.candidates(in: ctx)
        let items = Set(todo.map { ObjectIdentifier($0.item) }).count
        let text = "RIR UNSET BACKFILL DRY RUN — \(todo.count) sets on \(items) compound items would become unset (nothing was saved)"
        print(text)
        if let out = ProcessInfo.processInfo.environment["EP_AUDIT_REPORT_OUT"], !out.isEmpty { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

// MARK: - ZZ: no raw RIR reads

final class RIRAccessScanTests: XCTestCase {

    private func sourceRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while dir.path != "/" {
            let ok = ["App", "Domain", "Features"].allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            if ok { return dir }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("production source root not found")
    }

    /// Element access to `actualRIRs` (subscript, enumeration, or any sequence read) belongs to `RIREntry`; the backup
    /// DTO, exporter and importer carry the array whole. Whole-array copies and `.count` are fine.
    func test_noProductionCodeReadsOrWritesActualRIRsElementsOutsideRIREntry() throws {
        let root = try sourceRoot()
        let pattern = try NSRegularExpression(pattern:
            #"actualRIRs\s*\[|actualRIRs\.(enumerated|safe\w*|first|last|map|compactMap|flatMap|reduce|filter|min|max|prefix|suffix|append|insert|remove\w*|contains|indices|sorted)|at\(\s*[\w.]*actualRIRs"#)
        var offenders: [String] = []
        for folder in ["App", "Domain", "Features", "Shared", "Utilities"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                if rel.hasSuffix("Programs/RIREntry.swift") || rel.hasPrefix("Domain/Backup/") { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (n, raw) in text.components(separatedBy: "\n").enumerated() {
                    let line = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
                    if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { offenders.append("\(rel):\(n + 1): \(raw.trimmingCharacters(in: .whitespaces))") }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "read and write RIR through RIREntry so -1 never reaches arithmetic:\n" + offenders.joined(separator: "\n"))
    }

    func test_anUnsetRIR_givesTheRepsOnlyE1RM_andTheCSVCellIsEmpty() throws {
        func bench(_ rir: Int) -> SessionItem {
            let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 1, targetRIR: 2, suggestedLoad: 200)
            i.actualReps = [8]; i.actualLoads = [200]; i.actualRIRs = [rir]; i.plannedRepsBySet = [8]
            return i
        }
        func best(_ i: SessionItem) -> Double {
            WorkingSetFilter.workingRows(of: i).map { E1RMCalculator.e1RM(load: $0.load, reps: $0.reps + min(max($0.rir, 0), HistorySeedLoad.maxCreditedRIR)) }.max() ?? 0
        }
        let repsOnly = E1RMCalculator.e1RM(load: 200, reps: 8)
        XCTAssertEqual(best(bench(RIREntry.unset)), repsOnly, accuracy: 0.0001, "unset credits nothing")
        XCTAssertEqual(best(bench(0)), repsOnly, accuracy: 0.0001, "a recorded 0 credits nothing either")
        XCTAssertGreaterThan(best(bench(2)), repsOnly, "a recorded RIR 2 is credited")
        XCTAssertNil(RIREntry.recorded(bench(RIREntry.unset), at: 0))
    }
}

// MARK: - CCC: custom exercises can be compound

final class CustomCompoundTests: XCTestCase {

    private var sandbox: DefaultsSandbox!
    override func setUp() { super.setUp(); sandbox = DefaultsSandbox() }
    override func tearDown() { sandbox.restore(); super.tearDown() }

    private func context() throws -> ModelContext {
        ModelContext(try BackupTestSupport.makeContainer())
    }

    private func custom(_ ctx: ModelContext, _ name: String, muscle: String, compound: Bool?) -> CustomExercise {
        let c = CustomExercise(id: "custom_\(UUID().uuidString.lowercased())", name: name, primaryMuscleRaw: muscle, isCompound: compound)
        ctx.insert(c)
        return c
    }

    func test_anUndecidedCustom_inheritsFromItsMatch_anExplicitValueWins_aWeakMatchIsFalse() throws {
        let ctx = try context()
        XCTAssertTrue(custom(ctx, "Smith Incline Bench Press", muscle: "chest", compound: nil).resolvedIsCompound)
        XCTAssertTrue(custom(ctx, "Smith Split Squat", muscle: "quads", compound: nil).resolvedIsCompound, "a close match to a compound")
        XCTAssertTrue(custom(ctx, "DB Row [Lat Bias]", muscle: "back", compound: nil).resolvedIsCompound, "ambiguous muscle, but every tied row is compound")
        XCTAssertFalse(custom(ctx, "DB Row [Lat Bias]", muscle: "back", compound: false).resolvedIsCompound, "the lifter's false still wins")
        XCTAssertFalse(custom(ctx, "Straight-Arm Cable Pulldown", muscle: "back", compound: nil).resolvedIsCompound)
        XCTAssertFalse(custom(ctx, "Cable EZ-Bar Curl", muscle: "biceps", compound: nil).resolvedIsCompound)
        XCTAssertFalse(custom(ctx, "Incline DB Lateral Raise", muscle: "shoulders", compound: nil).resolvedIsCompound)
        XCTAssertFalse(custom(ctx, "Band Pushdown [Rehab]", muscle: "triceps", compound: nil).resolvedIsCompound)
        XCTAssertFalse(custom(ctx, "Totally Unknown Movement", muscle: "chest", compound: nil).resolvedIsCompound, "no match: false")

        XCTAssertFalse(custom(ctx, "Smith Incline Bench Press", muscle: "chest", compound: false).resolvedIsCompound, "the lifter's false wins")
        XCTAssertTrue(custom(ctx, "Hammer Curl [Hotel]", muscle: "biceps", compound: true).resolvedIsCompound, "the lifter's true wins")
    }

    func test_anAmbiguousMatch_takesTheValueAllTiedCandidatesShare_aDisagreementIsFalse() throws {
        // Rows: several built-in rows tie and disagree on the muscle, but every one is compound.
        for (name, muscle) in [("DB Row [Lat Bias]", MuscleGroup.back), ("Lever Row", .back), ("One Arm DB Row [Hotel]", .back)] {
            let s = try XCTUnwrap(MuscleSuggester.suggest(name: name, coarse: muscle))
            XCTAssertEqual(s.confidence == .tagged ? s.baseConfidence : s.confidence, .ambiguous, name)
            let tied = s.tiedBuiltIns.compactMap { n in ExerciseCatalog.builtIn.first { $0.name == n }?.isCompound }
            XCTAssertGreaterThan(tied.count, 1, "\(name): a real tie")
            XCTAssertTrue(tied.allSatisfy { $0 }, name)
            XCTAssertTrue(MuscleSuggester.suggestedCompound(name: name, coarse: muscle), "\(name): all tied candidates compound")
        }
        // Mixed: scan for an ambiguous suggestion whose tied candidates disagree on compound; it must be false.
        let names = ["Press", "Row", "Pulldown", "Extension", "Raise", "Fly", "Curl", "Pushdown", "Squat", "Pull", "Cable Press", "Row Pulldown", "Press Fly", "Extension Curl"]
        var allSame = 0, mixed = 0
        for name in names {
            for muscle in MuscleGroup.allCases {
                guard let s = MuscleSuggester.suggest(name: name, coarse: muscle) else { continue }
                guard (s.confidence == .tagged ? s.baseConfidence : s.confidence) == .ambiguous else { continue }
                let values = Set(s.tiedBuiltIns.compactMap { n in ExerciseCatalog.builtIn.first { $0.name == n }?.isCompound })
                let result = MuscleSuggester.suggestedCompound(name: name, coarse: muscle)
                if values.count > 1 { mixed += 1; XCTAssertFalse(result, "\(name) / \(muscle): the candidates disagree") }
                else { allSame += 1; XCTAssertEqual(result, values.first ?? false, "\(name) / \(muscle)") }
            }
        }
        XCTAssertGreaterThan(allSame + mixed, 0, "the sweep must reach ambiguous matches")
        // The tie rule itself: all compound -> true; mixed (a compound and an isolation) -> false; empty or unknown -> false.
        XCTAssertTrue(MuscleSuggester.tieIsCompound(["Bench Press", "Barbell Row"]))
        XCTAssertFalse(MuscleSuggester.tieIsCompound(["Bench Press", "EZ Bar Curl"]), "mixed")
        XCTAssertFalse(MuscleSuggester.tieIsCompound(["EZ Bar Curl", "Hammer Curl"]), "all isolation")
        XCTAssertFalse(MuscleSuggester.tieIsCompound([]))
        XCTAssertFalse(MuscleSuggester.tieIsCompound(["No Such Lift"]))
    }

    func test_RIREntry_readsACustomsResolvedCompoundStatus_andRIRUnsetBackfillFollowsEachLaunch() throws {
        let ctx = try context()
        let row = custom(ctx, "Lever Row", muscle: "back", compound: false)       // decided: not compound
        let item = SessionItem(order: 1, exerciseId: row.id, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        item.actualReps = [0, 0, 0]; item.actualRIRs = [0, 0, 0]
        ctx.insert(Session(date: Date(), status: .planned, weekIndex: 1, items: [item]))
        try ctx.save()
        ExerciseCatalog.rebuildCustomMirror(from: ctx)
        XCTAssertFalse(RIREntry.isCompound(row.id))
        RIRUnsetBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(item.actualRIRs, [0, 0, 0], "an isolation custom is untouched")

        row.isCompound = true                                                         // the lifter flips the toggle later
        try ctx.save()
        ExerciseCatalog.rebuildCustomMirror(from: ctx)
        XCTAssertTrue(RIREntry.isCompound(row.id))
        RIRUnsetBackfill.runIfNeeded(in: ctx)                                         // the next launch re-evaluates
        XCTAssertEqual(item.actualRIRs, [-1, -1, -1], "newly-compound custom: padded zeros become unset")
    }

    func test_theBackfill_decidesOnlyUndecidedCustoms_logsTheNames_andRebuildsTheMirror() throws {
        let ctx = try context()
        let undecidedPress = custom(ctx, "Smith Incline Bench Press", muscle: "chest", compound: nil)
        let undecidedCurl = custom(ctx, "Cable EZ-Bar Curl", muscle: "biceps", compound: nil)
        let decided = custom(ctx, "Landmine Press", muscle: "shoulders", compound: false)
        try ctx.save()
        BackfillLog.collector = []
        CustomExerciseCompoundBackfill.runIfNeeded(in: ctx)
        let notes = BackfillLog.collector ?? []; BackfillLog.collector = nil
        XCTAssertEqual(undecidedPress.isCompound, true)
        XCTAssertEqual(undecidedCurl.isCompound, false)
        XCTAssertEqual(decided.isCompound, false, "a decided value is never overridden")
        XCTAssertTrue(BackfillLog.result(from: notes).contains("Smith Incline Bench Press"), notes.joined())
        XCTAssertFalse(BackfillLog.result(from: notes).contains("Landmine"), "decided customs are not in the list")
        XCTAssertTrue(RIREntry.isCompound(undecidedPress.id), "the catalog mirror was rebuilt")
        BackfillLog.collector = []
        CustomExerciseCompoundBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(BackfillLog.result(from: BackfillLog.collector ?? []), "not needed", "idempotent")
        BackfillLog.collector = nil
    }

    /// The column was a non-optional Bool; an existing store must open with every value intact.
    enum OldSchema: VersionedSchema {
        static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
        static var models: [any PersistentModel.Type] { [CustomExercise.self] }

        @Model
        final class CustomExercise {
            var id: String
            var name: String
            var primaryMuscleRaw: String
            var isCompound: Bool
            var createdAt: Date
            var isBodyweight: Bool = false
            var fineMuscleRaw: String? = nil
            var fineSecondaryShares: [String: Double]? = nil
            init(id: String, name: String, primaryMuscleRaw: String, isCompound: Bool, createdAt: Date) {
                self.id = id; self.name = name; self.primaryMuscleRaw = primaryMuscleRaw; self.isCompound = isCompound; self.createdAt = createdAt
            }
        }
    }

    func test_aStoreWrittenWithTheNonOptionalColumn_opensAndKeepsEveryValue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.store")
        do {
            let oldSchema = Schema(versionedSchema: OldSchema.self)
            let old = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none))
            let ctx = ModelContext(old)
            ctx.insert(OldSchema.CustomExercise(id: "custom_a", name: "A", primaryMuscleRaw: "back", isCompound: true, createdAt: Date()))
            ctx.insert(OldSchema.CustomExercise(id: "custom_b", name: "B", primaryMuscleRaw: "biceps", isCompound: false, createdAt: Date()))
            try ctx.save()
        }
        let schema = AppSchema.makeSchema()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        let rows = try ModelContext(container).fetch(FetchDescriptor<CustomExercise>(sortBy: [SortDescriptor(\.id)]))
        XCTAssertEqual(rows.map(\.id), ["custom_a", "custom_b"])
        XCTAssertEqual(rows.map(\.isCompound), [true, false], "the lifter's existing values carry over as decisions")
    }

    // LOCAL ONLY, READ-ONLY: the list the backfill would produce, and how the suggestion compares with what is stored.
    func test_audit_compoundBackfillOnTheLatestBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let container = try ModelContainer(for: AppSchema.makeSchema(),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let customs = try ctx.fetch(FetchDescriptor<CustomExercise>(sortBy: [SortDescriptor(\.name)]))
        var lines = ["COMPOUND BACKFILL AUDIT — \(customs.count) custom exercises; undecided (nil) in the file: \(customs.filter { $0.isCompound == nil }.count)"]
        for c in customs {
            let s = MuscleSuggester.suggest(name: c.name, coarse: MuscleGroup(rawValue: c.primaryMuscleRaw) ?? .chest)
            let suggested = MuscleSuggester.suggestedCompound(name: c.name, coarse: MuscleGroup(rawValue: c.primaryMuscleRaw) ?? .chest)
            let mark = (c.isCompound == nil ? "nil" : String(c.isCompound!)) + " | suggested " + String(suggested)
            let why = s.map { "\($0.confidence.rawValue)\($0.baseConfidence.map { "/" + $0.rawValue } ?? "") like \($0.basedOn)" } ?? "no match"
            lines.append("\(c.name): stored \(mark) · \(why)\(c.isCompound != nil && c.isCompound! != suggested ? "   <-- stored differs from suggestion" : "")")
        }
        let text = lines.joined(separator: "\n")
        print(text)
        if let out = ProcessInfo.processInfo.environment["EP_AUDIT_REPORT_OUT"], !out.isEmpty { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

// MARK: - EEE: next-meso starting loads, with and without RIR credit (local audit)

final class NextMesoSeedAuditTests: XCTestCase {

    // LOCAL ONLY, READ-ONLY.
    func test_audit_nextMesoStartingLoads_withAndWithoutRIRCredit() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let container = try ModelContainer(for: AppSchema.makeSchema(),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let meso = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first { $0.status == .active && !$0.isMaintenance })
        let now = Date(timeIntervalSince1970: 1_794_000_000)   // overridden below by the last completed session
        let last = meso.sessions.filter { $0.status == .completed }.map(\.date).max() ?? now
        let at = last.addingTimeInterval(86_400)

        func table(credit: Bool) -> [String: [String]] {
            let plan = SessionItemEditService.planNextMeso(meso: meso, name: "audit", endOldMesoNow: true, context: ctx, now: at, creditRIR: credit)
            var out: [String: [String]] = [:]
            var seen = Set<String>()
            for s in plan.sessions where s.weekIndex == 1 || s.weekIndex <= 3 {
                for i in s.items {
                    let name = ExerciseCatalog.displayName(for: i.exerciseId)
                    let key = "\(name)|\(s.dayLabel ?? "-")|\(s.letter)"
                    guard seen.insert(key).inserted else { continue }
                    out[name, default: []].append("\(s.letter.uppercased()) \(s.dayLabel ?? "-"): \(i.seed) (\(i.seedSource.rawValue))" + (i.topCount > 0 ? " top \(i.topSeed)" : ""))
                }
            }
            return out
        }
        let repsOnly = table(credit: false), credited = table(credit: true)
        let wanted = ["bench", "smith incline", "decline", "single leg press", "t-bar", "t bar"]
        var lines = ["NEXT MESO STARTING LOADS — reps-only (new) vs RIR-credited (old); source session set: \(meso.name)"]
        for name in repsOnly.keys.sorted() where wanted.contains(where: { name.lowercased().contains($0) }) {
            lines.append(name)
            let a = repsOnly[name] ?? [], b = credited[name] ?? []
            for (x, y) in zip(a, b) { lines.append("   reps-only \(x)   |   credited \(y)") }
        }
        let text = lines.joined(separator: "\n")
        print(text)
        if let out = ProcessInfo.processInfo.environment["EP_AUDIT_REPORT_OUT"], !out.isEmpty { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

// MARK: - FFF: a verified backup before any seeding

@MainActor
final class SeedBackupGuardTests: XCTestCase {
    private var sandbox: DefaultsSandbox!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
        DataSentinelStore.overrideDefaults = UserDefaults(suiteName: "ep.sentinel.suite.\(UUID().uuidString)")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep_seed_\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        DataSentinelStore.overrideDefaults = nil
        try? FileManager.default.removeItem(at: dir)
        sandbox.restore()
        super.tearDown()
    }

    private func status() -> AutoBackupStatusStore {
        AutoBackupStatusStore(defaults: UserDefaults(suiteName: "ep.autobackup.test.\(UUID().uuidString)")!)
    }

    private func populatedContainer() throws -> ModelContainer {
        let c = try BackupTestSupport.makeContainer()
        try PopulatedStoreBuilder.build(in: ModelContext(c))
        return c
    }

    func test_beforeMesoSeed_runsAVerifiedBackup_andLogsTheReason() async throws {
        var lines: [String] = []
        let d = dir!
        let svc = AutoBackupService(status: status(), resolveDestination: { .local(d) }, log: { lines.append($0) })
        let result = await svc.backUpBeforeMesoSeed(container: try populatedContainer())
        let file = try XCTUnwrap(try result.get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(AutoBackupEngine.list(in: dir).count, 1)
        XCTAssertTrue(lines.contains { $0.contains("[beforeMesoSeed] local verified") }, lines.joined(separator: "\n"))
    }

    func test_anEmptyStore_hasNothingToProtect_andGoesStraightThrough() async throws {
        let d = dir!
        let svc = AutoBackupService(status: status(), resolveDestination: { .local(d) }, log: { _ in })
        let result = await svc.backUpBeforeMesoSeed(container: try BackupTestSupport.makeContainer())
        XCTAssertNil(try result.get(), "success with no file")
        XCTAssertTrue(AutoBackupEngine.list(in: dir).isEmpty)
    }

    func test_aFailedBackup_blocksTheSeed_untilBackUpNowSucceeds() async throws {
        // The destination is a regular file, so the backup cannot be placed.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ep_blocker_\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let container = try populatedContainer()
        final class Box: @unchecked Sendable { var url: URL; init(_ u: URL) { url = u } }
        let destination = Box(blocker)
        let svc = AutoBackupService(status: status(), resolveDestination: { .local(destination.url) }, log: { _ in })
        let guardian = SeedBackupGuard(backup: { await svc.backUpBeforeMesoSeed(container: $0) })

        var seeded = 0
        guardian.run(container: container) { seeded += 1 }
        try await waitUntil { guardian.failure != nil }
        XCTAssertEqual(seeded, 0, "the seed did not run")
        XCTAssertTrue(guardian.failure?.contains("Nothing has been changed") == true, guardian.failure ?? "nil")

        destination.url = dir                   // the lifter fixes the problem and taps Back up now
        guardian.retry()
        try await waitUntil { seeded == 1 }
        XCTAssertNil(guardian.failure)
        XCTAssertEqual(AutoBackupEngine.list(in: dir).count, 1)
    }

    func test_continueWithoutBackup_needsTheTypedWord() async throws {
        let guardian = SeedBackupGuard(backup: { _ in .failure(AutoBackupError.emptyStore) })
        var seeded = 0
        guardian.run(container: try BackupTestSupport.makeContainer()) { seeded += 1 }
        try await waitUntil { guardian.failure != nil }
        XCTAssertFalse(guardian.continueWithoutBackup(typed: "continue"))
        XCTAssertFalse(guardian.continueWithoutBackup(typed: ""))
        XCTAssertEqual(seeded, 0)
        XCTAssertTrue(guardian.continueWithoutBackup(typed: "CONTINUE"))
        XCTAssertEqual(seeded, 1)
        XCTAssertEqual(guardian.proceededWithoutBackup, 1)
        XCTAssertNil(guardian.failure)
    }

    func test_cancel_dropsTheSeed_andTheBackupAlwaysComesFirst() async throws {
        var order: [String] = []
        let guardian = SeedBackupGuard(backup: { _ in order.append("backup"); return .success(nil) })
        var cancelled = 0
        guardian.run(container: try BackupTestSupport.makeContainer()) { order.append("seed") }
        try await waitUntil { order.count == 2 }
        XCTAssertEqual(order, ["backup", "seed"])

        let failing = SeedBackupGuard(backup: { _ in .failure(AutoBackupError.emptyStore) })
        failing.run(container: try BackupTestSupport.makeContainer(), cancel: { cancelled += 1 }) { order.append("never") }
        try await waitUntil { failing.failure != nil }
        failing.cancel()
        XCTAssertEqual(cancelled, 1)
        XCTAssertFalse(order.contains("never"))
        XCTAssertNil(failing.failure)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

// MARK: - GGG: lastKnownLoad reads only the past

final class LastKnownLoadTests: XCTestCase {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
    }
    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Calendar.current.startOfDay(for: Date()))! }

    private func session(_ ctx: ModelContext, id: String = "bench_press", status: SessionStatus, at: Int, actual: [Double] = [], suggested: Double = 0, wave: String? = nil) -> Session {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: suggested, waveRaw: wave)
        i.actualLoads = actual; i.actualReps = actual.map { _ in 8 }
        let s = Session(date: day(at), status: status, weekIndex: 1, items: [i])
        ctx.insert(s)
        return s
    }

    func test_aFuturePlannedLoad_isIgnored() throws {
        let ctx = try context()
        let current = session(ctx, status: .inProgress, at: 0, wave: "a")
        _ = session(ctx, status: .planned, at: 7, suggested: 300, wave: "a")          // a future plan: must never be read
        _ = session(ctx, status: .planned, at: -3, suggested: 280, wave: "a")         // a missed, never-completed plan: not lifted
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "bench_press", currentSession: current, context: ctx), 0,
                       "no completed session before today: nothing known, even though plans exist")
        _ = session(ctx, status: .completed, at: -10, actual: [200, 200, 200], suggested: 205, wave: "a")
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "bench_press", currentSession: current, context: ctx), 200)
    }

    func test_aCompletedSessionDatedAfterTheCurrentOne_isIgnored_andTheLatestEarlierOneWins() throws {
        let ctx = try context()
        let current = session(ctx, status: .inProgress, at: 0)
        _ = session(ctx, status: .completed, at: 2, actual: [999, 999, 999])           // dated later (e.g. a back-dated entry)
        _ = session(ctx, status: .completed, at: -20, actual: [150, 150, 150])
        _ = session(ctx, status: .completed, at: -5, actual: [160, 160, 160])
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "bench_press", currentSession: current, context: ctx), 160)
    }

    func test_matchesOnTheCanonicalExerciseId_notTheRawString() throws {
        let ctx = try context()
        let current = session(ctx, id: "bench_press", status: .inProgress, at: 0)
        // The legacy uuid alias of a built-in resolves to the same canonical id.
        let legacy = "e8f675c1-2bc2-4eeb-a0b2-d701a6412f58"                           // -> seated_cable_press
        let cur2 = session(ctx, id: "seated_cable_press", status: .inProgress, at: 0)
        _ = session(ctx, id: legacy, status: .completed, at: -4, actual: [90, 90, 90])
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "seated_cable_press", currentSession: cur2, context: ctx), 90)
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "bench_press", currentSession: current, context: ctx), 0, "another lift is not matched")
    }

    func test_sameWavePreferred_thenAnyEarlierCompleted_andBodyweightIsZero() throws {
        let ctx = try context()
        let current = session(ctx, status: .inProgress, at: 0, wave: "b")
        _ = session(ctx, status: .completed, at: -3, actual: [180, 180, 180], wave: "a")
        _ = session(ctx, status: .completed, at: -10, actual: [170, 170, 170], wave: "b")
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "bench_press", currentSession: current, context: ctx), 170, "same wave first")
        let c2 = session(ctx, status: .inProgress, at: 0, wave: "c")
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "bench_press", currentSession: c2, context: ctx), 180, "else the latest earlier completed one")
        let bw = session(ctx, id: "pull_up", status: .inProgress, at: 0)
        _ = session(ctx, id: "pull_up", status: .completed, at: -2, actual: [25, 25, 25])
        XCTAssertEqual(LoadProjectionService.lastKnownLoad(for: "pull_up", currentSession: bw, context: ctx), 0)
    }
}

// MARK: - HHH: build identity in backups

final class BackupBuildIdentityTests: XCTestCase {

    private var sandbox: DefaultsSandbox!
    override func setUp() { super.setUp(); sandbox = DefaultsSandbox() }
    override func tearDown() { sandbox.restore(); super.tearDown() }

    private func exportJSON(metadata: BackupMetadataDTO? = nil) throws -> (URL, [String: Any]) {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: ctx)
        let result = try metadata.map { try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx, metadata: $0) }
            ?? BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        let url = result.url
        return (url, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]))
    }

    private func rewrite(_ json: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hhh-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func test_theExportCarriesTheBuildIdentity_andTheRestoreSheetTextReadsRight() throws {
        let meta = BackupMetadataDTO(appVersion: "1.2.2", build: "1", gitCommit: "abc1234", gitBranch: "main", schemaVersion: 1)
        let (url, json) = try exportJSON(metadata: meta)
        defer { try? FileManager.default.removeItem(at: url) }
        let m = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(Set(m.keys), ["appVersion", "build", "gitCommit", "gitBranch", "schemaVersion"])
        XCTAssertEqual(m["appVersion"] as? String, "1.2.2"); XCTAssertEqual(m["gitCommit"] as? String, "abc1234")
        let summary = try BackupContentSummary.of(file: url)
        XCTAssertEqual(summary.buildIdentity, "Backup from 1.2.2 (1) · abc1234")
        XCTAssertNil(summary.newerFormatWarning)

        // The default export stamps THIS build.
        let (url2, json2) = try exportJSON()
        defer { try? FileManager.default.removeItem(at: url2) }
        let m2 = try XCTUnwrap(json2["metadata"] as? [String: Any])
        XCTAssertEqual(m2["appVersion"] as? String, BuildInfo.version)
        XCTAssertEqual(m2["gitCommit"] as? String, BuildInfo.commit)
        XCTAssertEqual(m2["schemaVersion"] as? Int, BackupMetadataDTO.currentSchemaVersion)
    }

    func test_aFileWithoutMetadata_importsAsBefore_andShowsNoIdentity() throws {
        let (url, exported) = try exportJSON()
        var json = exported
        defer { try? FileManager.default.removeItem(at: url) }
        json.removeValue(forKey: "metadata")
        let old = try rewrite(json)
        defer { try? FileManager.default.removeItem(at: old) }
        let summary = try BackupContentSummary.of(file: old)
        XCTAssertNil(summary.buildIdentity); XCTAssertNil(summary.newerFormatWarning)
        let target = try BackupTestSupport.makeContainer()
        XCTAssertNoThrow(try BackupSnapshotImporter.importFullBackupJSON(from: old, modelContainer: target))
        XCTAssertFalse(try ModelContext(target).fetch(FetchDescriptor<Session>()).isEmpty)
        // A partial block (only some keys) is tolerated too.
        json["metadata"] = ["appVersion": "1.0"]
        let partial = try rewrite(json)
        defer { try? FileManager.default.removeItem(at: partial) }
        XCTAssertEqual(try BackupContentSummary.of(file: partial).buildIdentity, "Backup from 1.0")
    }

    func test_aNewerSchemaVersion_warns_butStillImports() throws {
        let newer = BackupMetadataDTO(appVersion: "9.0", build: "7", gitCommit: "ffff000", gitBranch: "main",
                                      schemaVersion: BackupMetadataDTO.currentSchemaVersion + 1)
        let (url, _) = try exportJSON(metadata: newer)
        defer { try? FileManager.default.removeItem(at: url) }
        let summary = try BackupContentSummary.of(file: url)
        let warning = try XCTUnwrap(summary.newerFormatWarning)
        XCTAssertTrue(warning.contains("newer version"), warning)
        XCTAssertNoThrow(try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: try BackupTestSupport.makeContainer()))
    }

    func test_exportImportExport_keepsTheIdentity() throws {
        let source = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: source)
        let first = try BackupTestSupport.exportJSON(source)
        XCTAssertNotNil(first["metadata"], "BA2's export carries the identity")
        let fresh = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: fresh)
        XCTAssertEqual((try BackupTestSupport.exportJSON(ModelContext(fresh))["metadata"] as? [String: Any])?["gitCommit"] as? String,
                       BuildInfo.commit)
    }
}

// MARK: - KKK / LLL / MMM: the upgrade backup, one backup per launch, iCloud unavailable

@MainActor
final class UpgradeBackupTests: XCTestCase {
    private var sandbox: DefaultsSandbox!
    private var dir: URL!
    private var snapDir: URL!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
        DataSentinelStore.overrideDefaults = UserDefaults(suiteName: "ep.sentinel.suite.\(UUID().uuidString)")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep_up_\(UUID().uuidString)", isDirectory: true)
        snapDir = FileManager.default.temporaryDirectory.appendingPathComponent("ep_upsnap_\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        DataSentinelStore.overrideDefaults = nil
        try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: snapDir)
        sandbox.restore()
        super.tearDown()
    }

    private func status() -> AutoBackupStatusStore {
        AutoBackupStatusStore(defaults: UserDefaults(suiteName: "ep.autobackup.test.\(UUID().uuidString)")!)
    }
    private func populated() throws -> ModelContainer {
        let c = try BackupTestSupport.makeContainer()
        try PopulatedStoreBuilder.build(in: ModelContext(c))
        return c
    }
    private func service(_ s: AutoBackupStatusStore, destination: AutoBackupDestination? = nil, commit: String = "new-build",
                         availability: AutoBackupDestination.ICloudAvailability = .available, now: Date = Date()) -> AutoBackupService {
        let d = destination ?? .local(dir!)
        return AutoBackupService(status: s, resolveDestination: { d }, checkAvailability: { availability }, now: { now }, currentCommit: { commit }, log: { _ in })
    }
    private func spin(_ g: StartupGate, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while g.launching && g.startupGuard.failure == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // KKK ------------------------------------------------------------------

    func test_theUpgradeBackup_isTakenAndPlacedBeforeTheBackfillsRun_andHoldsTheOldData() async throws {
        let container = try populated()
        let ctx = ModelContext(container)
        let marker = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SessionHistoryExercise>()).first)
        marker.order = 7                                                      // the "pre-backfill" state
        try ctx.save()
        let svc = service(status())
        var filesWhenBackfillsStarted = -1
        var orderInBackup: Int?
        let gate = StartupGate(directory: snapDir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!),
                               backupFirst: { await svc.backUpIfBuildChanged(container: $0) },
                               runBackfills: { c in
                                   filesWhenBackfillsStarted = AutoBackupEngine.list(in: self.dir).count
                                   // what the backup file holds, read at the moment the backfills start
                                   if let f = AutoBackupEngine.list(in: self.dir).first,
                                      let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: f.url)) as? [String: Any],
                                      let history = json["sessionHistory"] as? [[String: Any]] {
                                       orderInBackup = history.flatMap { ($0["exercises"] as? [[String: Any]]) ?? [] }.compactMap { $0["order"] as? Int }.first { $0 == 7 }
                                   }
                                   let m = try? ModelContext(c).fetch(FetchDescriptor<SessionHistoryExercise>()).first { $0.order == 7 }
                                   m?.order = 0; try? ModelContext(c).save()      // a backfill changing the data afterwards
                               },
                               findBackups: { [] })
        gate.begin(container: container)
        XCTAssertTrue(gate.launching, "the app waits: no data screen before the backup is done")
        await spin(gate)
        XCTAssertEqual(filesWhenBackfillsStarted, 1, "the backup was verified and placed BEFORE the first backfill ran")
        XCTAssertEqual(orderInBackup, 7, "and it holds the data as it was before the backfills")
        XCTAssertFalse(gate.launching)
    }

    func test_aFailedUpgradeBackup_holdsTheBackfills_untilBackUpNowWorks_orCONTINUEIsTyped() async throws {
        let container = try populated()
        let s = status()
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ep_blk_\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker); defer { try? FileManager.default.removeItem(at: blocker) }
        final class Box: @unchecked Sendable { var url: URL; init(_ u: URL) { url = u } }
        let destination = Box(blocker)
        let svc = AutoBackupService(status: s, resolveDestination: { .local(destination.url) }, checkAvailability: { .available },
                                    currentCommit: { "new-build" }, log: { _ in })
        var backfills = 0
        let gate = StartupGate(directory: snapDir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!),
                               backupFirst: { await svc.backUpIfBuildChanged(container: $0) },
                               onContinueWithoutBackup: { svc.recordLaunchWithoutBackup() },
                               runBackfills: { _ in backfills += 1 }, findBackups: { [] })
        gate.begin(container: container)
        await spin(gate)
        XCTAssertNotNil(gate.startupGuard.failure, "the prompt is up")
        XCTAssertEqual(backfills, 0, "the backfills are held")
        XCTAssertTrue(gate.launching)
        XCTAssertNil(s.lastLaunchCommit, "this build is not recorded as launched")

        destination.url = dir                                  // fixed: Back up now
        gate.startupGuard.retry()
        await spin(gate)
        XCTAssertEqual(backfills, 1)
        XCTAssertEqual(s.lastLaunchCommit, "new-build")

        // the other way out: CONTINUE without a backup
        let s2 = status()
        destination.url = blocker
        let svc2 = AutoBackupService(status: s2, resolveDestination: { .local(destination.url) }, checkAvailability: { .available },
                                     currentCommit: { "build-2" }, log: { _ in })
        var runs2 = 0
        let gate2 = StartupGate(directory: snapDir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!),
                                backupFirst: { await svc2.backUpIfBuildChanged(container: $0) },
                                onContinueWithoutBackup: { svc2.recordLaunchWithoutBackup() },
                                runBackfills: { _ in runs2 += 1 }, findBackups: { [] })
        gate2.begin(container: container)
        await spin(gate2)
        XCTAssertFalse(gate2.startupGuard.continueWithoutBackup(typed: "continue"))
        XCTAssertEqual(runs2, 0)
        XCTAssertTrue(gate2.startupGuard.continueWithoutBackup(typed: "CONTINUE"))
        XCTAssertEqual(runs2, 1)
        XCTAssertEqual(s2.lastLaunchCommit, "build-2", "recorded, so the prompt does not repeat every launch")
    }

    func test_theBuildChangeBackup_survivesALaterBackupTheSameDay() async throws {
        let container = try populated()
        let s = status()
        let first = try await service(s, now: Date(timeIntervalSince1970: 1_800_000_000)).backUpIfBuildChanged(container: container).get()
        let kept = try XCTUnwrap(first)
        // later the same day: a session-completed and a manual backup, each of which prunes
        for minute in 1...3 {
            _ = await service(s, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 600)).backUpNow(container: container)
        }
        let names = AutoBackupEngine.list(in: dir).map { $0.url.lastPathComponent }
        XCTAssertTrue(names.contains(kept.url.lastPathComponent), "the pre-upgrade snapshot is never rotated away: \(names)")
        XCTAssertEqual(s.lastBuildChangeBackup, kept.url.lastPathComponent)
    }

    // LLL ------------------------------------------------------------------

    func test_oneBackupPerLaunch_dailyIsSkippedAfterTheLaunchBackup_andWhileOneIsRunning() async throws {
        let container = try populated()
        let s = status()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let svc = service(s, now: t0)
        _ = try await svc.backUpIfBuildChanged(container: container).get()
        XCTAssertFalse(svc.foregrounded(container: container), "a verified backup is under 24h old: no daily")
        XCTAssertEqual(AutoBackupEngine.list(in: dir).count, 1, "one backup for this launch")
        // 25h later the first foreground of that day does back up
        let later = service(s, now: t0.addingTimeInterval(25 * 3600))
        XCTAssertTrue(later.foregrounded(container: container))
    }

    // MMM ------------------------------------------------------------------

    func test_iCloudAvailability_saysWhy() {
        typealias A = AutoBackupDestination
        XCTAssertEqual(A.availability(hasAccount: false, containerAvailable: false), .noAccount)
        XCTAssertEqual(A.availability(hasAccount: true, containerAvailable: false), .driveOffForApp)
        XCTAssertEqual(A.availability(hasAccount: true, containerAvailable: true), .available)
        XCTAssertTrue(A.ICloudAvailability.noAccount.explanation?.contains("No iCloud account") == true)
        XCTAssertTrue(A.ICloudAvailability.driveOffForApp.explanation?.contains("iCloud Drive is turned off") == true)
        XCTAssertNil(A.ICloudAvailability.available.explanation)
    }

    func test_aLocalBackup_recordsWhyICloudIsUnavailable_andLocalOnlySuppressesTheBannerUntilICloudReturns() async throws {
        let container = try populated()
        let s = status()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let svc = service(s, availability: .noAccount, now: t0)
        _ = await svc.backUpNow(container: container)
        XCTAssertEqual(svc.iCloudAvailability, .noAccount, "the Settings status line reads this")

        XCTAssertTrue(s.shouldShowBanner(now: t0.addingTimeInterval(8 * 86_400), hasData: true), "no off-device backup for over 7 days")
        s.localOnly = true                                      // "Use local backups only"
        XCTAssertFalse(s.shouldShowBanner(now: t0.addingTimeInterval(8 * 86_400), hasData: true))
        XCTAssertFalse(s.shouldShowBanner(now: t0.addingTimeInterval(30 * 86_400), hasData: true), "stays away")

        // iCloud becomes available: a backup reaches it, and the choice is cleared
        let ic = AutoBackupDestination.iCloud(dir.appendingPathComponent("icloud"))
        _ = await service(s, destination: ic, now: t0.addingTimeInterval(86_400)).backUpNow(container: container)
        XCTAssertFalse(s.localOnly)
        XCTAssertEqual(AutoBackupService(status: s).iCloudAvailability, .available)
        XCTAssertTrue(s.shouldShowBanner(now: t0.addingTimeInterval(86_400 + 8 * 86_400), hasData: true), "the banner works normally again")
    }
}

// MARK: - JJJ: relocation of data left in an older store

@MainActor
final class LegacyStoreRelocationTests: XCTestCase {
    private var sandbox: DefaultsSandbox!
    private var root: URL!
    private var appGroup: URL!      // where default.store lives (and where a pinned named store would be)
    private var sandboxDir: URL!    // the app's own Application Support
    private var snapDir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
        DataSentinelStore.overrideDefaults = UserDefaults(suiteName: "ep.sentinel.suite.\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep_legacy_t_\(UUID().uuidString)", isDirectory: true)
        appGroup = root.appendingPathComponent("group/Application Support", isDirectory: true)
        sandboxDir = root.appendingPathComponent("sandbox/Application Support", isDirectory: true)
        snapDir = root.appendingPathComponent("snapshots", isDirectory: true)
        for d in [appGroup!, sandboxDir!, snapDir!] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defaults = UserDefaults(suiteName: "ep.legacy.test.\(UUID().uuidString)")
    }
    override func tearDown() {
        DataSentinelStore.overrideDefaults = nil
        try? FileManager.default.removeItem(at: root)
        sandbox.restore()
        super.tearDown()
    }

    private var currentURL: URL { appGroup.appendingPathComponent("default.store") }

    /// A store file with `completed` completed sessions and `planned` planned ones.
    @discardableResult
    private func makeStore(at url: URL, completed: Int, planned: Int = 0) throws -> ModelContainer {
        let schema = AppSchema.makeSchema()
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        let ctx = ModelContext(c)
        for i in 0..<completed {
            ctx.insert(Session(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400), status: .completed, weekIndex: 1, dayLabel: "D\(i)", items: []))
        }
        for i in 0..<planned {
            ctx.insert(Session(date: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 86_400), status: .planned, weekIndex: 2, dayLabel: "P\(i)", items: []))
        }
        try ctx.save()
        return c
    }

    private func find(completed: Int, pin: String? = nil, offered: Set<String> = []) -> LegacyStoreRelocation.Finding? {
        LegacyStoreRelocation.find(currentStore: currentURL, currentCompleted: completed, sandboxSupport: sandboxDir, pinLabel: pin,
                                   offered: offered, log: { _ in })
    }

    func test_noOlderFiles_noOffer() throws {
        try makeStore(at: currentURL, completed: 2)
        XCTAssertNil(find(completed: 2))
    }

    func test_anOlderStoreWithFewerOrEqualCompletedSessions_isNotOffered_evenWithMoreSessionsInTotal() throws {
        try makeStore(at: currentURL, completed: 4)
        try makeStore(at: appGroup.appendingPathComponent("ElitePerformanceStore.store"), completed: 3)              // fewer
        try makeStore(at: appGroup.appendingPathComponent("ElitePerformanceStore_v2.store"), completed: 4)           // equal
        try makeStore(at: sandboxDir.appendingPathComponent("default.store"), completed: 2, planned: 30)             // many sessions, few completed
        XCTAssertNil(find(completed: 4), "only STRICTLY more completed sessions is offered")
    }

    func test_strictlyMore_isOffered_fromTheSandboxAndFromTheAppGroupFolder() throws {
        try makeStore(at: currentURL, completed: 2)
        let sandboxStore = sandboxDir.appendingPathComponent("default.store")
        try makeStore(at: sandboxStore, completed: 5)
        let a = try XCTUnwrap(find(completed: 2))
        XCTAssertEqual(a.candidate.location, .sandbox); XCTAssertEqual(a.candidate.completedSessions, 5); XCTAssertEqual(a.currentCompletedSessions, 2)
        XCTAssertTrue(a.message.contains("5 completed sessions") && a.message.contains("2 in the data"), a.message)

        try FileManager.default.removeItem(at: sandboxStore)
        try makeStore(at: appGroup.appendingPathComponent("ElitePerformanceStore.store"), completed: 6)
        let b = try XCTUnwrap(find(completed: 2, pin: "ElitePerformanceStore"))
        XCTAssertEqual(b.candidate.location, .appGroup); XCTAssertTrue(b.candidate.wasPinned, "the released build's pin named this file")
    }

    func test_ofSeveralCandidates_theOneWithTheMostCompletedSessionsIsOffered() throws {
        try makeStore(at: currentURL, completed: 1)
        try makeStore(at: appGroup.appendingPathComponent("ElitePerformanceStore.store"), completed: 3)
        try makeStore(at: sandboxDir.appendingPathComponent("default.store"), completed: 7)
        XCTAssertEqual(try XCTUnwrap(find(completed: 1)).candidate.completedSessions, 7)
    }

    func test_anUnreadableCandidate_isIgnored_andAnAlreadyOfferedOneIsNotOfferedAgain() throws {
        try makeStore(at: currentURL, completed: 1)
        try Data("not a database".utf8).write(to: appGroup.appendingPathComponent("ElitePerformanceStore_v2.store"))
        XCTAssertNil(find(completed: 1), "unreadable: ignored, nothing opened for write")
        let good = sandboxDir.appendingPathComponent("default.store")
        try makeStore(at: good, completed: 4)
        XCTAssertNotNil(find(completed: 1))
        XCTAssertNil(find(completed: 1, offered: [good.standardizedFileURL.path]))
    }

    private func gate(finder: @escaping @MainActor (ModelContainer, Int) -> LegacyStoreRelocation.Finding?, runs: @escaping @MainActor () -> Void,
                      offered: LegacyStoreRelocation.OfferedStore) -> StartupGate {
        StartupGate(directory: snapDir, sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "ep.sentinel.test.\(UUID().uuidString)")!),
                    backupFirst: nil, legacyFinder: finder, offered: offered, runBackfills: { _ in runs() }, findBackups: { [] })
    }

    func test_bringingTheOlderDataOver_goesThroughTheCoordinator_andNeverTouchesTheOriginal() throws {
        let current = try makeStore(at: currentURL, completed: 2)
        let legacy = sandboxDir.appendingPathComponent("default.store")
        try makeStore(at: legacy, completed: 5, planned: 3)
        let legacyBytes = try Data(contentsOf: legacy)
        let offered = LegacyStoreRelocation.OfferedStore(defaults: defaults)
        var backfills = 0
        let g = gate(finder: { c, completed in
            LegacyStoreRelocation.find(currentStore: self.currentURL, currentCompleted: completed, sandboxSupport: self.sandboxDir,
                                       pinLabel: "DEFAULT", offered: offered.paths, log: { _ in })
        }, runs: { backfills += 1 }, offered: offered)

        g.begin(container: current)
        XCTAssertNotNil(g.legacyOffer, "asked, not silently moved")
        XCTAssertEqual(backfills, 0, "nothing runs until it is answered")
        XCTAssertEqual(try BackupContentSummary.of(store: ModelContext(current)).completedSessions, 2, "the store is unchanged while the prompt is up")

        g.relocateLegacyStore()
        XCTAssertNil(g.legacyOffer); XCTAssertNil(g.legacyError)
        let now = try BackupContentSummary.of(store: ModelContext(current))
        XCTAssertEqual(now.completedSessions, 5); XCTAssertEqual(now.sessions, 8, "all sessions came over")
        XCTAssertFalse(PreImportSnapshots.list(in: snapDir).isEmpty, "the coordinator took a verified snapshot of what was there first")
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes, "the original file is byte-for-byte untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "and never deleted")
        XCTAssertEqual(backfills, 1, "the launch carried on")
        XCTAssertTrue(offered.paths.contains(legacy.standardizedFileURL.path), "the offered marker is set")

        // the next launch: not asked again (the answered file, and the store now holds the same data anyway)
        let again = gate(finder: { _, completed in
            LegacyStoreRelocation.find(currentStore: self.currentURL, currentCompleted: completed, sandboxSupport: self.sandboxDir,
                                       pinLabel: "DEFAULT", offered: offered.paths, log: { _ in })
        }, runs: {}, offered: offered)
        again.begin(container: current)
        XCTAssertNil(again.legacyOffer)
    }

    func test_decliningLeavesEverythingAlone_andIsNotAskedAgain() throws {
        let current = try makeStore(at: currentURL, completed: 2)
        let legacy = sandboxDir.appendingPathComponent("default.store")
        try makeStore(at: legacy, completed: 9)
        let offered = LegacyStoreRelocation.OfferedStore(defaults: defaults)
        var backfills = 0
        let finder: @MainActor (ModelContainer, Int) -> LegacyStoreRelocation.Finding? = { _, completed in
            LegacyStoreRelocation.find(currentStore: self.currentURL, currentCompleted: completed, sandboxSupport: self.sandboxDir,
                                       pinLabel: nil, offered: offered.paths, log: { _ in })
        }
        let g = gate(finder: finder, runs: { backfills += 1 }, offered: offered)
        g.begin(container: current)
        XCTAssertNotNil(g.legacyOffer)
        g.declineLegacyStore()
        XCTAssertNil(g.legacyOffer)
        XCTAssertEqual(try BackupContentSummary.of(store: ModelContext(current)).completedSessions, 2)
        XCTAssertEqual(backfills, 1)
        XCTAssertTrue(PreImportSnapshots.list(in: snapDir).isEmpty, "no import, no snapshot")
        let again = gate(finder: finder, runs: {}, offered: offered)
        again.begin(container: current)
        XCTAssertNil(again.legacyOffer, "asked at most once per file")
    }

    func test_aFailedRelocation_changesNothing_andKeepsTheOffer() throws {
        let current = try makeStore(at: currentURL, completed: 2)
        let legacy = sandboxDir.appendingPathComponent("default.store")
        try makeStore(at: legacy, completed: 5)
        let bad = LegacyStoreRelocation.Finding(candidate: .init(url: legacy, location: .sandbox, completedSessions: 99, sessions: 99, lastCompletedDate: nil, wasPinned: false),
                                                currentCompletedSessions: 2)   // claims more than the file holds
        let offered = LegacyStoreRelocation.OfferedStore(defaults: defaults)
        let g = gate(finder: { _, _ in bad }, runs: {}, offered: offered)
        g.begin(container: current)
        g.relocateLegacyStore()
        XCTAssertNotNil(g.legacyOffer, "still offered")
        XCTAssertTrue(g.legacyError?.contains("Nothing was changed") == true, g.legacyError ?? "nil")
        XCTAssertEqual(try BackupContentSummary.of(store: ModelContext(current)).completedSessions, 2)
        XCTAssertTrue(offered.paths.isEmpty)
    }

    func test_theOpenerLogsLegacyFilesInTheAppGroupFolderToo() throws {
        try makeStore(at: appGroup.appendingPathComponent("ElitePerformanceStore_v2.store"), completed: 1)
        try makeStore(at: sandboxDir.appendingPathComponent("ElitePerformanceStore.store"), completed: 1)
        var logs: [String] = []
        let schema = AppSchema.makeSchema()
        let config = ModelConfiguration(schema: schema, url: currentURL, cloudKitDatabase: .none)
        let result = AppStoreOpener.open(appSupport: sandboxDir, configuration: config, log: { logs.append($0) })
        guard case .opened = result else { return XCTFail("opens") }
        let line = try XCTUnwrap(logs.first { $0.contains("Legacy store files present") })
        XCTAssertTrue(line.contains("ElitePerformanceStore_v2.store (app-group Application Support)"), line)
        XCTAssertTrue(line.contains("ElitePerformanceStore.store (sandbox Application Support)"), line)
    }
}

// MARK: - R1: Change Program never deletes logged work

final class ChangeProgramGuardTests: XCTestCase {
    private let cal = Calendar.current
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: Date()))! }

    private func context() throws -> ModelContext {
        ModelContext(try BackupTestSupport.makeContainer())
    }
    private func session(_ ctx: ModelContext, _ offset: Int, _ status: SessionStatus, logged: Bool = false, meso: MesoBlock? = nil) -> Session {
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        if logged { item.actualReps = [8, 8, 0]; item.actualLoads = [100, 100, 0] }
        let s = Session(date: day(offset), status: status, weekIndex: 1, dayLabel: "Push", items: [item])
        s.meso = meso
        ctx.insert(s)
        return s
    }

    func test_planListsExactlyThePlannedSessionsItWouldDelete_withCountAndRange() throws {
        let ctx = try context()
        _ = session(ctx, -3, .completed); _ = session(ctx, -1, .planned)                // history and the past: untouched
        for o in [1, 3, 8] { _ = session(ctx, o, .planned) }
        let maint = MesoBlock(name: "Maintenance", startDate: day(0), totalWeeks: 4, isMaintenance: true); ctx.insert(maint)
        _ = session(ctx, 2, .planned, meso: maint)                                       // maintenance sessions are never deleted
        try ctx.save()
        let plan = DUPProgramReplaceService.plan(startDate: day(0), context: ctx)
        XCTAssertTrue(plan.isAllowed)
        XCTAssertEqual(plan.sessionsToDelete.count, 3)
        XCTAssertEqual(plan.dateRange?.first, day(1)); XCTAssertEqual(plan.dateRange?.last, day(8))
        XCTAssertTrue(plan.message.hasPrefix("3 planned sessions"), plan.message)
    }

    func test_anInProgressSession_orAPlannedOneWithLoggedSets_refusesTheReplacement_andNothingIsDeleted() throws {
        for blocker in [(SessionStatus.inProgress, false), (SessionStatus.planned, true)] {
            let ctx = try context()
            _ = session(ctx, 1, .planned); _ = session(ctx, 2, .planned)
            _ = session(ctx, 3, blocker.0, logged: blocker.1)
            try ctx.save()
            let plan = DUPProgramReplaceService.plan(startDate: day(0), context: ctx)
            XCTAssertFalse(plan.isAllowed)
            XCTAssertEqual(plan.blockers.count, 1)
            XCTAssertTrue(plan.message.contains("never deleted"), plan.message)
            let before = try ctx.fetchCount(FetchDescriptor<Session>())
            XCTAssertThrowsError(try DUPProgramReplaceService.replacePlannedProgram(startDate: day(0), trainingWeekdays: [2, 3, 4, 5, 6, 7], context: ctx))
            XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Session>()), before, "the service itself refuses: no session was deleted")
        }
    }

    func test_withNothingInTheWay_theReplacementDeletesThePlannedSessions_andKeepsHistory() throws {
        let ctx = try context()
        let done = session(ctx, -5, .completed, logged: true)
        for o in [1, 2, 9] { _ = session(ctx, o, .planned) }
        try ctx.save()
        try DUPProgramReplaceService.replacePlannedProgram(startDate: day(0), trainingWeekdays: [2, 3, 4, 5, 6, 7], context: ctx)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        XCTAssertTrue(all.contains { $0.persistentModelID == done.persistentModelID }, "completed history is kept")
        XCTAssertFalse(all.contains { $0.dayLabel == "Push" && $0.date >= day(0) && $0.status == .planned && $0.items.first?.suggestedLoad == 100 }, "the old planned sessions are gone")
    }
}

// MARK: - R2: per-exercise load step

final class PerExerciseLoadStepTests: XCTestCase {

    private func bench(_ id: String = "bench_press") -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        i.actualReps = [8, 8, 8]; i.actualLoads = [100, 100, 100]; i.actualRIRs = [2, 2, 2]
        i.plannedRepsBySet = [8, 8, 8]; i.repMin = 6; i.repMax = 8
        return i
    }
    private func profile(default step: Double = 5, own: [String: Double] = [:]) -> UserProfile {
        let p = UserProfile()
        p.minLoadIncrement = step
        p.loadStepByExercise = own
        return p
    }

    func test_resolutionOrder_perExerciseOverride_thenDefaultStep_thenClusterDefault() {
        let p = profile(default: 5, own: ["bench_press": 2.5])
        XCTAssertEqual(UserProfile.loadStep(for: "bench_press", profile: p), 2.5, "the lift's own step wins")
        XCTAssertEqual(UserProfile.loadStep(for: "machine_chest_press", profile: p), 5, "another lift: the default step")
        XCTAssertEqual(UserProfile.loadStep(for: "bench_press", profile: nil), UnitAwareRounding.defaultIncrement(unit: .lb), "no profile: the unit's default")
        // CoachingEngine.loadIncrement: own > default > cluster
        let item = bench()
        XCTAssertEqual(CoachingEngine.loadIncrement(for: item, base: 100, minLoadIncrement: 5, perExerciseStep: 2.5), 2.5)
        XCTAssertEqual(CoachingEngine.loadIncrement(for: item, base: 100, minLoadIncrement: 5), 5)
        XCTAssertEqual(CoachingEngine.loadIncrement(for: item, base: 100, minLoadIncrement: nil),
                       ChestArmsLowBackMesoProfile.config(for: .primaryChestPress).primaryLoadIncrement, "the cluster default only when nothing else is set")
        // aliases resolve to the same lift
        XCTAssertEqual(UserProfile.loadStepOverride(for: "bench_press", profile: p), 2.5)
        p.setLoadStep(nil, exerciseId: "bench_press")
        XCTAssertNil(UserProfile.loadStepOverride(for: "bench_press", profile: p), "cleared")
    }

    func test_benchEarnsATwoPointFiveIncrease_whileAMachineStaysAtFive() throws {
        let p = profile(default: 5, own: ["bench_press": 2.5])
        let b = try XCTUnwrap(CoachingEngine.recommend(for: bench("bench_press"), profile: p))
        let m = try XCTUnwrap(CoachingEngine.recommend(for: bench("machine_chest_press"), profile: p))
        XCTAssertEqual(b.nextSuggestedLoad, 102.5, "bench steps by its own 2.5")
        XCTAssertEqual(m.nextSuggestedLoad, 105, "the machine steps by the default 5")
        // and with no override, both follow the default
        let plain = profile(default: 5)
        XCTAssertEqual(try XCTUnwrap(CoachingEngine.recommend(for: bench(), profile: plain)).nextSuggestedLoad, 105)
    }

    func test_carryForwardWritesTheLiftsOwnStep() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let p = profile(default: 5, own: ["bench_press": 2.5]); ctx.insert(p)
        let cal = Calendar.current
        func target(_ id: String) -> SessionItem {
            let t = SessionItem(order: 1, exerciseId: id, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
            t.plannedLoadsBySet = [100, 100, 100]; t.plannedRepsBySet = [8, 8, 8]; return t
        }
        let benchSrc = bench("bench_press"), machSrc = bench("machine_chest_press")
        benchSrc.plannedLoadsBySet = [100, 100, 100]; machSrc.plannedLoadsBySet = [100, 100, 100]
        let done = Session(date: cal.date(byAdding: .day, value: -1, to: Date())!, status: .completed, weekIndex: 1, dayLabel: "Push", items: [benchSrc, machSrc])
        let tb = target("bench_press"), tm = target("machine_chest_press")
        let next = Session(date: cal.date(byAdding: .day, value: 6, to: Date())!, status: .planned, weekIndex: 2, dayLabel: "Push", items: [tb, tm])
        ctx.insert(done); ctx.insert(next)
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: done)
        XCTAssertEqual(tb.suggestedLoad, 102.5, "bench carried forward by 2.5")
        XCTAssertEqual(tm.suggestedLoad, 105, "the machine by the default 5")
    }

    func test_theStepSurvivesABackupRoundTrip_andOldBackupsHaveNone() throws {
        let src = ModelContext(try BackupTestSupport.makeContainer())
        try PopulatedStoreBuilder.build(in: src)
        let fresh = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: src, into: fresh)
        let restored = try XCTUnwrap(ModelContext(fresh).fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertEqual(restored.loadStepByExercise, ["bench_press": 2.5, "machine_chest_press": 5.0])
        // an old file without the key: no overrides, the default step everywhere
        let exported = try BackupTestSupport.exportFile(src)
        defer { try? FileManager.default.removeItem(at: exported) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any])
        XCTAssertNotNil((json["userProfile"] as? [String: Any])?["loadStepByExercise"], "the exporter writes it")
        var profile = try XCTUnwrap(json["userProfile"] as? [String: Any]); profile.removeValue(forKey: "loadStepByExercise"); json["userProfile"] = profile
        let old = FileManager.default.temporaryDirectory.appendingPathComponent("oldstep_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: old) }
        try JSONSerialization.data(withJSONObject: json).write(to: old)
        let target = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: old, modelContainer: target)
        XCTAssertTrue(try XCTUnwrap(ModelContext(target).fetch(FetchDescriptor<UserProfile>()).first).loadStepByExercise.isEmpty)
    }
}

// MARK: - R4: the silent meso start date re-sync

final class MesoStartDateResyncTests: XCTestCase {
    private let cal = Calendar.current
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: Date()))! }

    func test_aDifferingStartDateIsResynced_withOneLogLine_andNothingElseChanges() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let meso = MesoBlock(name: "A", startDate: day(-20), status: .active, totalWeeks: 8); ctx.insert(meso)
        let s = Session(date: day(2), status: .planned, weekIndex: 1, dayLabel: "Push", items: []); s.meso = meso; ctx.insert(s)
        let state = AppState(); state.activeMesoStartDate = day(-3); state.scheduledNextMesoStartDate = day(30); ctx.insert(state)
        try ctx.save()
        BackfillLog.collector = []
        MesoStartDateResync.runIfNeeded(in: ctx)
        let notes = BackfillLog.collector ?? []; BackfillLog.collector = nil
        XCTAssertEqual(notes.count, 1, "one line")
        XCTAssertTrue(notes[0].contains("re-synced"), notes[0])
        XCTAssertEqual(state.activeMesoStartDate, day(-20))
        XCTAssertEqual(state.scheduledNextMesoStartDate, day(30), "a scheduled next meso is left alone")
        XCTAssertEqual(s.date, day(2))
        BackfillLog.collector = []
        MesoStartDateResync.runIfNeeded(in: ctx)
        XCTAssertEqual(BackfillLog.result(from: BackfillLog.collector ?? []), "not needed", "idempotent")
        BackfillLog.collector = nil
    }

    func test_nothingToDo_withNoActiveBlock_orWithNoStoredDate() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        BackfillLog.collector = []
        MesoStartDateResync.runIfNeeded(in: ctx)
        XCTAssertEqual(BackfillLog.result(from: BackfillLog.collector ?? []), "not needed")
        let meso = MesoBlock(name: "A", startDate: day(-5), status: .active, totalWeeks: 8); ctx.insert(meso); try ctx.save()
        BackfillLog.collector = []
        MesoStartDateResync.runIfNeeded(in: ctx)
        XCTAssertEqual(BackfillLog.result(from: BackfillLog.collector ?? []), "not needed", "no AppState row: none is created")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<AppState>()), 0)
        BackfillLog.collector = nil
    }
}

// MARK: - R5: Program day page

final class ProgramDayPageTests: XCTestCase {

    func test_headerReps_comeFromThePerSetPlan_notTheFlattenedDefault() {
        let i = SessionItem(order: 1, exerciseId: "t_bar_row", targetReps: 6, targetSets: 3, targetRIR: 2, suggestedLoad: 340)
        i.plannedRepsBySet = [8, 8, 8, 0]
        XCTAssertEqual(ProgramDayDetailView.planRepsText(for: i), "8 reps", "targetReps says 6; the plan says 8")
        i.plannedRepsBySet = [8, 7, 6, 0]
        XCTAssertEqual(ProgramDayDetailView.planRepsText(for: i), "6–8 reps")
        i.plannedRepsBySet = []
        XCTAssertEqual(ProgramDayDetailView.planRepsText(for: i), "6 reps", "empty plan: the default")
        // the spare 4th row is not a planned set
        let j = SessionItem(order: 1, exerciseId: "t_bar_row", targetReps: 6, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        j.plannedRepsBySet = [8, 8, 8, 12]
        XCTAssertEqual(ProgramDayDetailView.planRepsText(for: j), "8 reps")
    }

    func test_theTodayRowPastThePlannedSets_isLabelledOptionalExtraSet() {
        XCTAssertTrue(UISessionSet.extraSetLabel(repRange: RepRange(min: 8, max: 10), rir: 2).hasPrefix("OPTIONAL EXTRA SET"))
    }

    func test_seedingWidensTheSetBandToCoverTheWeeksRamp() {
        // DUP10: Pull-Up style slot, 2-3 band, ramp [.., 4 in week 8]
        let ex = ResolvedExercisePlan(order: 2, exerciseId: "pull_up", priority: .standard, notes: nil, wave: .b, setMin: 2, setMax: 3,
                                      repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2, intensifier: .none, intensifierNotes: nil,
                                      defaultSets: 4, defaultTargetReps: 8, defaultTargetRIR: 2)
        let day = MaterializedProgramDay(templateId: "t", weekNumber: 8, wave: .b, dayNumber: 1, title: "Pull A", role: "pull", exercises: [ex])
        let item = DUPSessionMaterializer.makeSessionItems(from: day)[0]
        XCTAssertEqual(item.targetSets, 4)
        XCTAssertEqual([item.setMin, item.setMax], [2, 4], "the band covers the 4-set week")
        let ordinary = ResolvedExercisePlan(order: 2, exerciseId: "pull_up", priority: .standard, notes: nil, wave: .a, setMin: 2, setMax: 3,
                                            repMin: 8, repMax: 10, targetRIRMin: 2, targetRIRMax: 2, intensifier: .none, intensifierNotes: nil,
                                            defaultSets: 3, defaultTargetReps: 8, defaultTargetRIR: 2)
        let i2 = DUPSessionMaterializer.makeSessionItems(from: MaterializedProgramDay(templateId: "t", weekNumber: 1, wave: .a, dayNumber: 1, title: "x", role: "pull", exercises: [ordinary]))[0]
        XCTAssertEqual([i2.setMin, i2.setMax], [2, 3], "a week inside the band keeps it")
    }

    func test_changeForRemainingSessions_skipsHandEditedItems_andReportsTheCount_thisSessionStaysExplicit() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let meso = MesoBlock(name: "M", startDate: Date(), status: .active, totalWeeks: 8); ctx.insert(meso)
        func item(edited: Bool) -> SessionItem {
            let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100, waveRaw: "a", repMin: 6, repMax: 8)
            i.plannedRepsBySet = [8, 8, 8]; i.plannedRIRsBySet = [2, 2, 2]; i.plannedLoadsBySet = [100, 100, 100]; i.planEdited = edited
            return i
        }
        var sessions: [Session] = []
        for (n, edited) in [(1, false), (8, true), (15, false)] {
            let s = Session(date: Calendar.current.date(byAdding: .day, value: n, to: Calendar.current.startOfDay(for: Date()))!, status: .planned, weekIndex: n, dayLabel: "Push", items: [item(edited: edited)])
            s.meso = meso; ctx.insert(s); meso.sessions.append(s); sessions.append(s)
        }
        try ctx.save()
        let change = PrescriptionChange(setDelta: nil, repRange: 8...10, rirRange: nil, note: nil, topSet: nil)
        let all = SessionItemEditService.planChangePrescription(meso: meso, dayLabel: "Push", exerciseId: "bench_press", scope: .allRemaining, change: change)
        XCTAssertEqual(all.targets.count, 2, "the two unedited sessions change")
        XCTAssertEqual(all.editedSkipped, 1, "the hand-edited one is skipped and counted")
        XCTAssertEqual(ReplaceExerciseModel.reasonText(.planEdited), "edited by you, left as it is")
        let only = SessionItemEditService.planChangePrescription(meso: meso, dayLabel: "Push", exerciseId: "bench_press", scope: .thisSession(sessions[1]), change: change)
        XCTAssertEqual(only.targets.count, 1, "an explicit this-session edit of the edited item is allowed")
        XCTAssertEqual(only.editedSkipped, 0)
    }
}

// MARK: - R6: Insert deload week takes a verified backup first

final class InsertDeloadBackupFirstTests: XCTestCase {
    /// Every flow that writes a block runs behind `SeedBackupGuard.run`; the three seeding flows and Insert deload share it.
    func test_theInsertDeloadFlow_runsBehindTheBackupGuard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Features/Home/InsertDeloadFlow.swift"), encoding: .utf8)
        let insert = try XCTUnwrap(text.range(of: "struct InsertDeloadFlow")).lowerBound
        let remove = try XCTUnwrap(text.range(of: "struct RemoveDeloadModel")).lowerBound
        let section = String(text[insert..<remove])
        let guardPos = try XCTUnwrap(section.range(of: "seedGuard.run(container:"), "the apply button goes through the guard").lowerBound
        let applyPos = try XCTUnwrap(section.range(of: "model.apply(plan)")).lowerBound
        XCTAssertLessThan(guardPos, applyPos, "the guard wraps the apply")
        XCTAssertTrue(section.contains(".seedBackupGuard(seedGuard)"), "and its prompt is attached")
    }

    @MainActor
    func test_aFailedBackup_blocksTheInsert_untilContinueIsTyped() async throws {
        let guardian = SeedBackupGuard(backup: { _ in .failure(AutoBackupError.emptyStore) })
        var inserted = 0
        guardian.run(container: try BackupTestSupport.makeContainer()) { inserted += 1 }
        for _ in 0..<100 where guardian.failure == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(guardian.failure)
        XCTAssertEqual(inserted, 0)
        XCTAssertTrue(guardian.continueWithoutBackup(typed: "CONTINUE"))
        XCTAssertEqual(inserted, 1)
    }
}

// MARK: - R7: the meso card's menu

final class MesoCardMenuTests: XCTestCase {
    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    func test_viewMesoSummaryStaysVisible_theThreeBlockActionsLiveInOneMenu() throws {
        let plan = try source("Features/Home/ProgramPlanView.swift")
        let header = try XCTUnwrap(plan.range(of: "private var activeBlockHeaderSection"))
        let content = try XCTUnwrap(plan.range(of: "private var content: some View"))
        let card = String(plan[header.lowerBound..<content.lowerBound])
        let menuStart = try XCTUnwrap(card.range(of: "Menu {")).lowerBound
        let menuEnd = try XCTUnwrap(card.range(of: "} label: {\n                            Image(systemName: \"ellipsis.circle\")")).lowerBound
        let menu = String(card[menuStart..<menuEnd])
        for action in ["Start next meso from this one", "Insert deload week"] {
            XCTAssertTrue(menu.contains(action), "\(action) is in the menu")
            XCTAssertEqual(card.components(separatedBy: action).count - 1, 1, "and only there: \(action)")
        }
        XCTAssertFalse(menu.contains("Change program"), "Change program is the header row, not a duplicate menu item")
        XCTAssertFalse(menu.contains("onChangeProgram"))
        XCTAssertEqual(card.components(separatedBy: "ChangeProgramRow(action: onChangeProgram)").count - 1, 1, "the header row stays, exactly once")
        let outside = String(card[menuEnd...])
        XCTAssertTrue(outside.contains("View Meso Summary"), "View Meso Summary stays visible on the card")
        XCTAssertFalse(menu.contains("View Meso Summary"))
    }

    func test_changeProgramIsNoLongerAToolbarCapsule() throws {
        let home = try source("Features/Home/HomeView.swift")
        XCTAssertFalse(home.contains("Image(systemName: \"line.3.horizontal.decrease.circle\")"), "the toolbar capsule is gone")
        XCTAssertTrue(home.contains("onChangeProgram:"), "the card's menu opens the same wizard")
    }
}

// MARK: - R8: the Settings structure

final class SettingsStructureTests: XCTestCase {
    private func settings() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Features/Settings/SettingsView.swift"), encoding: .utf8)
    }

    /// The main screen: from `Form {` to the end of its sections (before the helper screens).
    private func mainScreen(_ text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "        Form {")).lowerBound
        let end = try XCTUnwrap(text.range(of: "        .navigationTitle(\"Settings\")")).lowerBound
        return String(text[start..<end])
    }

    func test_theMainScreenHasTheFourGroups_andNoRedRows() throws {
        let main = try mainScreen(try settings())
        for header in ["Section(\"Training\")", "Section(\"Analytics\")", "Section(\"Backup & Restore\")", "Section(\"About\")"] {
            XCTAssertTrue(main.contains(header), header)
        }
        XCTAssertFalse(main.contains(".foregroundStyle(.red)"), "no red rows on the main Settings screen: they live one screen away")
        XCTAssertFalse(main.contains("role: .destructive"))
        for gone in ["Data Repair", "Reset Mesocycle", "Remove Unrecognized", "Repair Exercise Data", "Repair maintenance loads", "Sync meso start date", "Import Full Backup", "Export Full Backup", "Restore from \\("] {
            XCTAssertFalse(main.contains(gone), "\(gone) is not on the main screen")
        }
    }

    func test_restoreAndMoveDataScreens_holdTheRestoreAndImportExportRows() throws {
        let text = try settings()
        let restoreAt = try XCTUnwrap(text.range(of: "private var restoreScreen")).lowerBound
        let restore = String(text[restoreAt...].prefix(2600))
        XCTAssertTrue(restore.contains("Restore from \\(") && restore.contains("Restore pre-import state"))
        let moveAt = try XCTUnwrap(text.range(of: "private var moveDataScreen")).lowerBound
        let move = String(text[moveAt...].prefix(3500))
        for row in ["Import Full Backup (JSON)", "Export Full Backup (JSON)", "Export Completed Sessions (CSV)"] { XCTAssertTrue(move.contains(row), row) }
        XCTAssertFalse(move.contains("app state, meso blocks, sessions, history, and notes"), "the stale export footer is replaced")
        XCTAssertTrue(move.contains("custom exercises"))
    }

    func test_theDefaultLoadStepLabel() throws {
        XCTAssertTrue(try settings().contains("Default load step (all lifts unless overridden per exercise)"))
    }
}

// MARK: - R9: the iCloud reason is known when the screen appears

@MainActor
final class ICloudReasonOnAppearTests: XCTestCase {
    private func status() -> AutoBackupStatusStore {
        AutoBackupStatusStore(defaults: UserDefaults(suiteName: "ep.autobackup.test.\(UUID().uuidString)")!)
    }

    func test_afterRefreshing_theReasonIsKnown_withoutAnyBackupHavingRun() async {
        for (reason, expected) in [(AutoBackupDestination.ICloudAvailability.noAccount, "No iCloud account"),
                                   (.driveOffForApp, "iCloud Drive is turned off")] {
            let svc = AutoBackupService(status: status(), checkAvailability: { reason })
            XCTAssertEqual(svc.iCloudAvailability, .available, "before the check nothing is known")
            await svc.refreshICloudAvailability()
            XCTAssertEqual(svc.iCloudAvailability, reason)
            XCTAssertTrue(svc.iCloudAvailability.explanation?.contains(expected) == true)
        }
    }

    func test_theLocalOnlyChoice_suppressesTheBanner_untilICloudIsAvailableAgain() async {
        let s = status()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unavailable = AutoBackupService(status: s, checkAvailability: { .noAccount })
        await unavailable.refreshICloudAvailability()
        XCTAssertTrue(s.shouldShowBanner(now: now, hasData: true))
        s.localOnly = true
        XCTAssertFalse(s.shouldShowBanner(now: now, hasData: true), "'Use local backups only' hides it")
        await unavailable.refreshICloudAvailability()
        XCTAssertTrue(s.localOnly, "still unavailable: the choice stands")
        let back = AutoBackupService(status: s, checkAvailability: { .available })
        await back.refreshICloudAvailability()
        XCTAssertFalse(s.localOnly, "iCloud is available again: the choice is cleared")
        XCTAssertEqual(back.iCloudAvailability, .available)
        XCTAssertTrue(s.shouldShowBanner(now: now, hasData: true), "the banner works normally again")
    }

    func test_bothScreensAskOnAppear() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Features/Settings/SettingsView.swift", "Features/MainTab/MainTabView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("refreshICloudAvailability()"), file)
        }
    }
}

// MARK: - S1/S2: a new phone can restore and import

@MainActor
final class FreshDeviceRestoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ep_fresh_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func touch(_ dir: URL, _ date: Date) {
        let u = dir.appendingPathComponent(AutoBackupEngine.fileName(for: date))
        try? Data("{}".utf8).write(to: u)
    }

    func test_S1_import_and_restore_areNeverDisabled_onlyExportNeedsData() {
        for count in [0, 1, 5] {
            for hasData in [false, true] {
                for busy in [false, true] {
                    let a = BackupRowAvailability.of(backupCount: count, storeHasData: hasData, busy: busy)
                    XCTAssertTrue(a.importEnabled, "import is always enabled")
                    XCTAssertTrue(a.restoreEnabled, "Restore always opens")
                    XCTAssertEqual(a.exportEnabled, hasData)
                }
            }
        }
        let empty = BackupRowAvailability.of(backupCount: 0, storeHasData: false, busy: false)
        XCTAssertTrue(empty.importEnabled); XCTAssertTrue(empty.restoreEnabled)
        XCTAssertFalse(empty.exportEnabled); XCTAssertFalse(empty.verifyEnabled)
    }

    func test_S2_listsBackupsFromICloudAndLocal_whoeverWroteThem_newestFirst() {
        let icloud = tempDir(), local = tempDir()
        defer { try? FileManager.default.removeItem(at: icloud); try? FileManager.default.removeItem(at: local) }
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        touch(icloud, t); touch(local, t.addingTimeInterval(60)); touch(local, t.addingTimeInterval(-60))
        touch(icloud, t)   // same name in both: one backup
        touch(local, t)
        let all = AutoBackupEngine.listAll(primary: icloud, local: local)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.date), [t.addingTimeInterval(60), t, t.addingTimeInterval(-60)])
        XCTAssertEqual(all[1].url.deletingLastPathComponent().standardizedFileURL, icloud.standardizedFileURL, "the primary copy wins")
        XCTAssertEqual(AutoBackupEngine.listAll(primary: local, local: local).count, 3, "the same folder given twice lists once")
    }

    func test_S2_serviceListsLocalBackups_evenWhenICloudIsTheDestination_andOnAnEmptyStore() async {
        let icloud = tempDir(), local = tempDir()
        defer { try? FileManager.default.removeItem(at: icloud); try? FileManager.default.removeItem(at: local) }
        touch(local, Date(timeIntervalSince1970: 1_800_000_000))
        let viaICloud = AutoBackupService(status: AutoBackupStatusStore(defaults: UserDefaults(suiteName: "ep.fresh.\(UUID().uuidString)")!),
                                          resolveDestination: { .iCloud(icloud) }, localBackupsDirectory: local)
        let r1 = await viaICloud.availableBackups()
        XCTAssertEqual(r1.files.count, 1)
        touch(icloud, Date(timeIntervalSince1970: 1_800_000_500))
        let r2 = await viaICloud.availableBackups()
        XCTAssertEqual(r2.files.count, 2, "both folders, whichever device wrote them")
        let viaLocal = AutoBackupService(status: AutoBackupStatusStore(defaults: UserDefaults(suiteName: "ep.fresh.\(UUID().uuidString)")!),
                                         resolveDestination: { .local(local) }, localBackupsDirectory: local)
        let r3 = await viaLocal.availableBackups()
        XCTAssertEqual(r3.files.count, 1)
    }

    func test_settingsGatesOnlyThroughTheTestedRules() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Features/Settings/SettingsView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private var moveDataScreen"))
        let end = try XCTUnwrap(text.range(of: ".navigationTitle(\"Move data\")"))
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("showImportBackupPicker = true") && body.range(of: #"Import Full Backup[\s\S]{0,200}\.disabled"#, options: .regularExpression) != nil, "import is never disabled")
        XCTAssertTrue(text.contains("NavigationLink(\"Restore from a backup\") { restoreScreen }"))
        XCTAssertFalse(text.range(of: #"NavigationLink\("Restore from a backup"\)[^\n]*\n\s*\.disabled"#, options: .regularExpression) != nil)
        XCTAssertFalse(text.range(of: #"NavigationLink\("Move data[^\n]*\n\s*\.disabled"#, options: .regularExpression) != nil)
    }

    /// A NavigationLink outside a NavigationStack is disabled: Restore and Move data looked greyed and did nothing.
    func test_settingsIsItsOwnNavigationStack_soItsLinksAreEnabled() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Features/Settings/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("var body: some View {\n        NavigationStack { settingsForm }"))
        let tab = try String(contentsOf: root.appendingPathComponent("Features/MainTab/MainTabView.swift"), encoding: .utf8)
        XCTAssertFalse(tab.contains("NavigationStack {\n                SettingsView()"), "no nested stack around it")
    }

    /// On a new phone the restore rebuilds ContentView while the store is still empty; the welcome sheet must go once data lands.
    func test_firstRunSheetClosesWhenDataArrives() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("App/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains(".onChange(of: sessions.isEmpty)"))
        XCTAssertTrue(text.contains("if !empty { showFirstRunOnboarding = false }"))
        XCTAssertTrue(text.contains("sessions.isEmpty && !RestoreActivity.inProgress"))
        let settings = try String(contentsOf: root.appendingPathComponent("Features/Settings/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("RestoreActivity.inProgress = true") && settings.contains("RestoreActivity.inProgress = false"))
    }

    /// Every user-facing pointer to the undo names the real path (Settings → Backup & Restore → Restore), never the old one.
    func test_undoPointersNameTheRealPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Features/Settings/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("A copy of your current data is saved first; Settings → Backup & Restore → Restore can undo this."))
        for file in ["Features/Settings/SettingsView.swift", "Domain/Backup/ImportSafety.swift", "Domain/Backup/LegacyStoreRelocation.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("Settings → Restore pre-import state"), "\(file) still points at the old path")
        }
    }
}

// MARK: - Privacy: purpose strings and the privacy manifest match what the app uses (App Store validation)

/// Fails when the app uses a protected capability or a required-reason API that the build does not declare: the purpose string
/// (from the target's INFOPLIST_KEY_ build settings, in BOTH configurations), the entitlement/Info pairing, or the
/// PrivacyInfo.xcprivacy entry. Source-driven so it needs no archive, plus the built bundle when the tests are hosted.
final class PrivacyDeclarationsTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func appSources() throws -> [(path: String, text: String)] {
        var out: [(String, String)] = []
        for dir in ["App", "Domain", "Features", "Shared", "Utilities", "ElitePerformance"] {
            guard let e = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.pathExtension == "swift" {
                out.append((u.path.replacingOccurrences(of: root.path + "/", with: ""), try String(contentsOf: u, encoding: .utf8)))
            }
        }
        XCTAssertGreaterThan(out.count, 100)
        return out
    }

    private func codeLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    /// Value of an INFOPLIST_KEY_ setting in every configuration that sets it (the app target sets them in Debug and Release).
    private func infoKeyValues(_ key: String) throws -> [String] {
        let pbx = try String(contentsOf: root.appendingPathComponent("ElitePerformance.xcodeproj/project.pbxproj"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: "INFOPLIST_KEY_\(key) = \"([^\"]*)\";")
        return re.matches(in: pbx, range: NSRange(pbx.startIndex..., in: pbx)).compactMap { Range($0.range(at: 1), in: pbx).map { String(pbx[$0]) } }
    }

    private func requireKey(_ key: String, because why: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let values = try infoKeyValues(key)
        XCTAssertEqual(values.count, 2, "\(key) must be set in both Debug and Release (needed: \(why))", file: file, line: line)
        for v in values { XCTAssertGreaterThan(v.trimmingCharacters(in: .whitespaces).count, 30, "\(key) needs a real, specific sentence", file: file, line: line) }
    }

    private func manifest() throws -> [String: Any] {
        let url = root.appendingPathComponent("ElitePerformance/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func test_purposeStrings_coverEveryProtectedCapabilityTheCodeUses() throws {
        let sources = try appSources()
        let all = sources.map { codeLines($0.text) }.joined(separator: "\n")
        let entitlements = try String(contentsOf: root.appendingPathComponent("ElitePerformance/ElitePerformance.entitlements"), encoding: .utf8)

        // HealthKit: reading needs the share string; the authorization API names both directions, so Apple also wants the update string.
        if all.contains("import HealthKit") || entitlements.contains("com.apple.developer.healthkit") {
            try requireKey("NSHealthShareUsageDescription", because: "HealthKit read access")
        }
        if all.range(of: #"requestAuthorization\(|statusForAuthorizationRequest\("#, options: .regularExpression) != nil {
            try requireKey("NSHealthUpdateUsageDescription", because: "requestAuthorization(toShare:read:) is referenced (ITMS-90683)")
        }
        // Frameworks that need a purpose string the moment they are used.
        let needs: [(String, [String])] = [
            ("import AVFoundation", ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"]),
            ("import Photos", ["NSPhotoLibraryUsageDescription"]),
            ("import PhotosUI", ["NSPhotoLibraryUsageDescription"]),
            ("import CoreMotion", ["NSMotionUsageDescription"]),
            ("import CoreLocation", ["NSLocationWhenInUseUsageDescription"]),
            ("import LocalAuthentication", ["NSFaceIDUsageDescription"]),
            ("import Contacts", ["NSContactsUsageDescription"]),
            ("import EventKit", ["NSCalendarsUsageDescription"]),
            ("import Speech", ["NSSpeechRecognitionUsageDescription"]),
            ("import CoreBluetooth", ["NSBluetoothAlwaysUsageDescription"]),
            ("import AppTrackingTransparency", ["NSUserTrackingUsageDescription"]),
        ]
        for (marker, keys) in needs where all.contains(marker) {
            for k in keys { try requireKey(k, because: marker) }
        }
        // Entitlement/Info pairing: the iCloud container the backups use must be declared for the Files app.
        if entitlements.contains("com.apple.developer.ubiquity-container-identifiers") {
            let plist = try String(contentsOf: root.appendingPathComponent("Config/Info-iCloud.plist"), encoding: .utf8)
            XCTAssertTrue(plist.contains("NSUbiquitousContainers"))
        }
    }

    func test_theAppWritesNothingToHealth_andTheUpdateStringSaysSo() throws {
        let all = try appSources().map { codeLines($0.text) }.joined(separator: "\n")
        let writeAPIs = ["HKWorkoutBuilder", "HKWorkoutSession", "HKLiveWorkoutBuilder", "saveObject", "healthStore.save", "store.save(", "HKHealthStore().save", ".delete(self", "HKCategorySample(", "HKQuantitySample(", "HKWorkout(activityType", "addSamples", "finishWorkout", "endCollection"]
        let found = writeAPIs.filter { all.contains($0) }
        let update = try infoKeyValues("NSHealthUpdateUsageDescription")
        if found.isEmpty {
            XCTAssertFalse(all.range(of: #"toShare:\s*(?!\[\]|nil)[^,)\s]"#, options: .regularExpression) != nil, "no non-empty toShare set anywhere")
            for v in update { XCTAssertTrue(v.contains("does not write"), "no write API is used, so the update string must not claim a write") }
        } else {
            for v in update { XCTAssertFalse(v.contains("does not write"), "write APIs \(found) are used; the update string must name what is written") }
        }
    }

    func test_privacyManifest_declaresEveryRequiredReasonAPIUsed() throws {
        let all = try appSources().map { codeLines($0.text) }.joined(separator: "\n")
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertNotNil(m["NSPrivacyTrackingDomains"] as? [Any])
        XCTAssertNotNil(m["NSPrivacyCollectedDataTypes"] as? [Any])
        let declared = (m["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
        func reasons(_ category: String) -> [String] {
            declared.first { $0["NSPrivacyAccessedAPIType"] as? String == category }?["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        let used: [(category: String, pattern: String)] = [
            ("NSPrivacyAccessedAPICategoryUserDefaults", #"UserDefaults|@AppStorage|NSUserDefaults"#),
            ("NSPrivacyAccessedAPICategoryFileTimestamp", #"attributesOfItem|ModificationDate|CreationDate|\.creationDate|\.modificationDate|resourceValues|\bfstat\(|\blstat\(|\bstat\(|getattrlist|\.fileModificationDate"#),
            ("NSPrivacyAccessedAPICategoryDiskSpace", #"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|NSFileSystemFreeSize|\bstatfs\(|\bstatvfs\("#),
            ("NSPrivacyAccessedAPICategorySystemBootTime", #"systemUptime|mach_absolute_time"#),
            ("NSPrivacyAccessedAPICategoryActiveKeyboards", #"activeInputModes"#),
        ]
        for (category, pattern) in used where all.range(of: pattern, options: .regularExpression) != nil {
            XCTAssertFalse(reasons(category).isEmpty, "the code uses a \(category) API but PrivacyInfo.xcprivacy declares no reason for it (ITMS-91053)")
        }
        // The declaration is not decoration: an app-group suite and @AppStorage are both in use, so both reasons stay.
        XCTAssertTrue(reasons("NSPrivacyAccessedAPICategoryUserDefaults").contains("CA92.1"))
    }

    func test_manifestAndStringsAreInTheBuiltBundle_whenHosted() throws {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier?.hasSuffix(".xctest") == false, bundle.object(forInfoDictionaryKey: "CFBundleExecutable") != nil else {
            throw XCTSkip("tests are not app-hosted; the source-level checks above cover the same declarations")
        }
        XCTAssertNotNil(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "the manifest must ship in the app bundle")
        for k in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"] {
            XCTAssertNotNil(bundle.object(forInfoDictionaryKey: k) as? String, "built Info.plist lacks \(k)")
        }
    }
}

// MARK: - T1: "Edit set" keeps the logged values (it used to reset a 135 x 8 set to 0 x 8)

@MainActor
final class EditLoggedSetTests: XCTestCase {
    private func makeLoggedSession() throws -> (SessionScreenViewModel, ModelContext, Session, UUID) {
        let container = try BackupTestSupport.makeContainer()
        let ctx = ModelContext(container)
        let item = BackupTestSupport.item(1, "bench_press", name: "Bench Press")
        ctx.insert(item)
        let s = Session(date: Date(timeIntervalSince1970: 1_800_000_000), status: .planned, weekIndex: 1, dayLabel: "Upper A", items: [])
        ctx.insert(s)
        s.items.append(item)
        try ctx.save()
        let vm = SessionScreenViewModel(session: s)
        let id = vm.exercises[0].id
        // log set 1 at 135 x 8, RIR 2
        vm.updateActualLoad(exerciseID: id, setIndex: 1, text: "135")
        vm.updateActualReps(exerciseID: id, setIndex: 1, text: "8")
        vm.updateActualRIR(exerciseID: id, setIndex: 1, text: "2")
        vm.handleSetLogged(exerciseID: id, setIndex: 1, context: ctx)
        return (vm, ctx, s, id)
    }

    private func set1(_ vm: SessionScreenViewModel) -> UISessionSet { vm.exercises[0].sets.first { $0.index == 1 }! }

    func test_unlock_keepsLoadRepsAndRIR_andChangesNothingPersisted() throws {
        let (vm, ctx, s, id) = try makeLoggedSession()
        XCTAssertEqual(set1(vm).status, .completed)
        XCTAssertEqual(s.items[0].actualLoads.first, 135)

        vm.editSet(exerciseID: id, setIndex: 1, context: ctx)

        let e = set1(vm)
        XCTAssertTrue(e.isEditing)
        XCTAssertEqual(e.actualLoad, 135); XCTAssertEqual(e.actualReps, 8); XCTAssertEqual(e.actualRIR, 2)
        XCTAssertEqual(e.actualLoadText, "135"); XCTAssertEqual(e.actualRepsText, "8")
        // the store is untouched, even after an unrelated save while the edit is open
        vm.persist(using: ctx)
        XCTAssertEqual(s.items[0].actualLoads.first, 135)
        XCTAssertEqual(s.items[0].actualReps.first, 8)
        XCTAssertEqual(RIREntry.recorded(s.items[0], at: 0), 2)
    }

    func test_editRepsOnly_keepsTheLoad_andSaveWritesIt() throws {
        let (vm, ctx, s, id) = try makeLoggedSession()
        vm.editSet(exerciseID: id, setIndex: 1, context: ctx)
        vm.updateActualReps(exerciseID: id, setIndex: 1, text: "9")
        // before Save the store still holds the logged reps
        vm.persist(using: ctx)
        XCTAssertEqual(s.items[0].actualReps.first, 8)

        vm.saveEditedSet(exerciseID: id, setIndex: 1, context: ctx)
        XCTAssertFalse(set1(vm).isEditing)
        XCTAssertEqual(set1(vm).status, .completed)
        XCTAssertEqual(s.items[0].actualReps.first, 9)
        XCTAssertEqual(s.items[0].actualLoads.first, 135, "load unchanged when only reps were edited")
        XCTAssertEqual(RIREntry.recorded(s.items[0], at: 0), 2, "RIR unchanged")
    }

    func test_cancel_leavesTheSetExactlyAsLogged() throws {
        let (vm, ctx, s, id) = try makeLoggedSession()
        let before = set1(vm)
        vm.editSet(exerciseID: id, setIndex: 1, context: ctx)
        vm.updateActualLoad(exerciseID: id, setIndex: 1, text: "999")
        vm.updateActualReps(exerciseID: id, setIndex: 1, text: "1")
        vm.updateActualRIR(exerciseID: id, setIndex: 1, text: "4")
        vm.cancelEditSet(exerciseID: id, setIndex: 1)

        let after = set1(vm)
        XCTAssertFalse(after.isEditing)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.actualLoad, before.actualLoad); XCTAssertEqual(after.actualReps, before.actualReps)
        XCTAssertEqual(after.actualRIR, before.actualRIR)
        XCTAssertEqual(after.actualLoadText, before.actualLoadText); XCTAssertEqual(after.actualRepsText, before.actualRepsText)
        vm.persist(using: ctx)
        XCTAssertEqual(s.items[0].actualLoads.first, 135); XCTAssertEqual(s.items[0].actualReps.first, 8)
    }

    func test_editingAPlanless_loggedSet_doesNotFallBackToThePlanLoad() throws {
        // The plan load is 0 for this item: the old code re-seeded the field from the plan (0). The logged 135 must stay.
        let (vm, ctx, _, id) = try makeLoggedSession()
        XCTAssertEqual(set1(vm).plannedLoad, 0)
        vm.editSet(exerciseID: id, setIndex: 1, context: ctx)
        XCTAssertEqual(set1(vm).actualLoadText, "135")
    }
}

// MARK: - T2: set-row layout never truncates or wraps a label mid-word

/// A source guard for the narrow-screen layout (the screenshots in docs/screenshots/layout are the visual proof): the Log/Skip/
/// Pump/Edit controls sit on their own line UNDER the inputs, every label is single-line and fixed-size, and both rows can fall
/// back to a stacked layout at the largest text sizes.
final class SetRowLayoutTests: XCTestCase {
    private var source: String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("Features/Session/SessionView.swift"), encoding: .utf8)) ?? ""
    }

    func test_actionsLiveUnderTheInputs_notInAColumnBesideThem() {
        let s = source
        let inputs = try? XCTUnwrap(s.range(of: "ViewThatFits(in: .horizontal) {\n                HStack(alignment: .bottom, spacing: 8) { loadField; repsField; rirField"))
        let actions = try? XCTUnwrap(s.range(of: "                actionBar\n                VStack(alignment: .leading, spacing: 8) { actionBar }"))
        XCTAssertNotNil(inputs); XCTAssertNotNil(actions)
        if let i = inputs, let a = actions { XCTAssertLessThan(i.lowerBound, a.lowerBound, "actions come after the inputs") }
        XCTAssertFalse(s.contains("// Log / Skip / Edit\n                VStack(spacing: 4)"), "the narrow right-hand column is gone")
    }

    func test_everyActionLabelIsSingleLineAndFixedSize() {
        let s = source
        guard let start = s.range(of: "@ViewBuilder private var actionBar: some View {"),
              let end = s.range(of: "    // MARK: - Swap Sheet") ?? s.range(of: "// MARK: - Swap Sheet") else { return XCTFail("actionBar not found") }
        let bar = String(s[start.lowerBound..<end.lowerBound])
        for label in ["Text(\"Log\")", "Text(\"Done\")", "Text(\"Skip\")", "Text(uiSet.pumpRating == .none ? \"Pump\" : uiSet.pumpRating.label)"] {
            let r = try? XCTUnwrap(bar.range(of: label), label)
            guard let r else { continue }
            let tail = String(bar[r.upperBound...].prefix(400))
            XCTAssertTrue(tail.contains(".fixedSize()") || tail.contains(".lineLimit(1)"), "\(label) must not wrap")
        }
        XCTAssertTrue(s.contains("@ScaledMetric(relativeTo: .callout) private var chipSize"), "RIR chips scale with Dynamic Type")
    }
}

// MARK: - App Store sample: coach notes from the REAL completion path (generator, skipped unless the env vars are set)

/// Replays every completed session of the invented App Store sample (scripts/make_appstore_sample.py) through the app's own
/// set-logging path (`SessionScreenViewModel.handleSetLogged` -> `CoachingEngine`, then `persist` -> `PlanMemoryEngine`), oldest
/// first, so every coach note and every carried-forward plan is what the engine writes. The sample's reps and RIR are the
/// lifter's inputs; the load logged is the load the engine suggested for that set.
///   TEST_RUNNER_EP_SAMPLE_IN=<sample.json> TEST_RUNNER_EP_SAMPLE_OUT=<out.json> scripts/run_bounded.sh -- -only-testing:ElitePerformanceTests/AppStoreSampleReplayTests
@MainActor
final class AppStoreSampleReplayTests: XCTestCase {
    func test_replaySampleThroughTheRealCompletionPath() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["EP_SAMPLE_IN"], let output = env["EP_SAMPLE_OUT"], !input.isEmpty, !output.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_SAMPLE_IN and TEST_RUNNER_EP_SAMPLE_OUT to run the App Store sample generator")
        }
        let container = try BackupTestSupport.makeContainer()
        try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: input), modelContainer: container, applyingDeviceSideEffects: false)
        let ctx = ModelContext(container)

        struct Intent { var reps: [Int]; var rirs: [Int]; var loads: [Double] }
        let completed = try ctx.fetch(FetchDescriptor<Session>()).filter { $0.status == .completed }.sorted { $0.date < $1.date }
        XCTAssertGreaterThan(completed.count, 50)
        var noteCount = 0, exerciseCount = 0

        for session in completed {
            let originalDate = session.date, originalCompleted = session.completedAt ?? session.date
            var intents: [UUID: Intent] = [:]
            for item in session.items {
                if let id = item.id { intents[id] = Intent(reps: item.actualReps, rirs: item.actualRIRs, loads: item.actualLoads) }
                let n = item.targetSets
                item.actualReps = Array(repeating: 0, count: n); item.actualLoads = Array(repeating: 0, count: n)
                item.actualRIRs = RIREntry.unsetArray(count: n)
                item.pumpRatingsBySet = Array(repeating: 0, count: n)
                item.isCompleted = false; item.coachNote = nil
            }
            session.status = .inProgress
            session.completedAt = originalCompleted     // persist() only stamps "now" when this is nil; the sample's dates stay
            try ctx.save()

            let vm = SessionScreenViewModel(session: session)
            for ex in vm.exercises {
                guard let itemID = ex.itemID, let intent = intents[itemID] else { continue }
                for set in ex.sets {
                    let i = set.index - 1
                    guard i < intent.reps.count, intent.reps[i] > 0 else { continue }
                    let suggested = vm.exercises.first(where: { $0.id == ex.id })?.sets.first(where: { $0.index == set.index })?.plannedLoad ?? 0
                    let load = suggested > 0 ? suggested : intent.loads[i]
                    vm.updateActualLoad(exerciseID: ex.id, setIndex: set.index, text: load.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(load))" : "\(load)")
                    vm.updateActualReps(exerciseID: ex.id, setIndex: set.index, text: "\(intent.reps[i])")
                    if i < intent.rirs.count, intent.rirs[i] >= 0 { vm.updateActualRIR(exerciseID: ex.id, setIndex: set.index, text: "\(intent.rirs[i])") }
                    vm.handleSetLogged(exerciseID: ex.id, setIndex: set.index, context: ctx)
                    vm.setPumpRating(exerciseID: ex.id, setIndex: set.index, rating: .good, context: ctx)
                }
            }
            XCTAssertEqual(session.status, .completed, "\(session.dayLabel ?? "?") W\(session.weekIndex): every planned set was replayed")
            session.date = originalDate; session.completedAt = originalCompleted
            exerciseCount += session.items.count
            noteCount += session.items.filter { ($0.coachNote ?? "").isEmpty == false }.count
            try ctx.save()
        }

        // PR flags: the engine does not write isPR here (the Meso Summary computes PR chips from history); the sample sets none.
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        try? FileManager.default.removeItem(atPath: output)
        try FileManager.default.copyItem(at: result.url, to: URL(fileURLWithPath: output))

        var lines: [String] = []
        for s in completed.filter({ $0.dayLabel == "Push A" }).suffix(3) {
            for item in s.items.sorted(by: { $0.order < $1.order }) { lines.append("W\(s.weekIndex) \(s.dayLabel ?? "") | \(item.exerciseNameSnapshot ?? item.exerciseId) | \(item.coachNote ?? "(none)")") }
        }
        try lines.joined(separator: "\n").write(toFile: output + ".notes.txt", atomically: true, encoding: .utf8)
        print("APPSTORE_SAMPLE: replayed \(completed.count) sessions, \(noteCount)/\(exerciseCount) exercises have an engine-written coach note")
        XCTAssertGreaterThan(noteCount, exerciseCount / 2, "most exercises carry an engine-written note")
    }
}

// MARK: - PlaceholderRefresh dry run on a real backup

final class PlaceholderRefreshDryRunTests: XCTestCase {

    /// LOCAL ONLY, READ-ONLY: every change `PlaceholderRefresh` would make on a real backup, old -> new with its reason.
    /// Nothing is saved; the backup is imported into an in-memory store.
    func test_audit_whatPlaceholderRefreshWouldChangeOnTheLatestBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let container = try ModelContainer(for: AppSchema.makeSchema(),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let now = ISO8601DateFormatter().date(from: ProcessInfo.processInfo.environment["EP_AUDIT_NOW"] ?? "2026-11-17T23:20:00Z") ?? Date()
        let profile = try? ctx.fetch(FetchDescriptor<UserProfile>()).first
        let unit = profile?.loadUnit ?? .lb
        let changes = PlaceholderRefresh.plan(in: ctx, now: now)
        let fmt = DateFormatter(); fmt.dateFormat = "EEE MMM d"
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        var lines = ["PLACEHOLDER REFRESH DRY RUN (as of \(now)) — \(changes.count) planned exercises would change (nothing was saved), unit \(unit)"]
        for c in changes.sorted(by: { ($0.session.date, $0.item.order) < ($1.session.date, $1.item.order) }) {
            let what = c.noteOnly ? "stays \(n(c.oldLoad)) (note: \(c.note ?? ""))" : "\(n(c.oldLoad)) -> \(n(c.newLoad))"
            lines.append("\(fmt.string(from: c.session.date)) wk\(c.session.weekIndex) \(c.session.dayLabel ?? "-") · \(ExerciseCatalog.displayName(for: c.item.exerciseId)) (\(c.item.waveRaw ?? "-")): \(what) · \(c.reason.text)")
        }
        // Idempotence: apply, then plan again.
        PlaceholderRefresh.apply(changes, ctx: .init(profile: profile, customExercises: (try? ctx.fetch(FetchDescriptor<CustomExercise>())) ?? []))
        let second = PlaceholderRefresh.plan(in: ctx, now: now)
        lines.append("second pass after applying: \(second.count) changes")
        let text = lines.joined(separator: "\n")
        print(text)
        if let out = ProcessInfo.processInfo.environment["EP_AUDIT_REPORT_OUT"], !out.isEmpty { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        XCTAssertTrue(second.isEmpty, "idempotent")
    }
}

// MARK: - PlaceholderRefresh: the real cases as fixtures

/// The Nov 17 backup's real cases, rebuilt by hand: T-Bar Row Pull A (wk 6 c, set 3 skipped), Legs B (wk 7 a missed, wk 8 b
/// performed), Single Arm Pulldown Pull B (wk 8 b hand-edited). "Today" is Tue Nov 17 2026.
final class PlaceholderRefreshTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current
    private func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 9))! }
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 20))! }
    private let sep22 = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!

    private func context(profile: UserProfile? = nil) throws -> (ModelContext, MesoBlock) {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        let meso = MesoBlock(name: "12-Week DUP Meso", startDate: day(9, 25), status: .active, totalWeeks: 12)
        meso.createdAt = day(8, 1)          // fixtures' items (written Sep 22) have been written since the block was created
        ctx.insert(meso)
        if let profile { ctx.insert(profile) }
        return (ctx, meso)
    }

    @discardableResult
    private func session(_ ctx: ModelContext, _ meso: MesoBlock, _ date: Date, _ status: SessionStatus, week: Int, label: String, _ items: [SessionItem]) -> Session {
        let s = Session(date: date, status: status, weekIndex: week, dayLabel: label, items: items)
        s.meso = meso; ctx.insert(s); meso.sessions.append(s)
        return s
    }

    private func item(_ id: String, wave: String, sets: Int = 3, repMin: Int, repMax: Int, rir: Int = 2, suggested: Double,
                      planned: [Double]? = nil, actual: [Double] = [], reps: [Int] = [], rirs: [Int] = [],
                      patterns: [String] = [], feedback: [String] = [], edited: Bool = false, updated: Date? = nil) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: repMin, targetSets: sets, targetRIR: rir, suggestedLoad: suggested,
                            waveRaw: wave, priorityRaw: "anchor", repMin: repMin, repMax: repMax, targetRIRMin: rir, targetRIRMax: rir,
                            plannedRepsBySet: Array(repeating: repMin, count: sets),
                            plannedLoadsBySet: planned ?? Array(repeating: suggested, count: sets),
                            plannedRIRsBySet: Array(repeating: rir, count: sets),
                            actualReps: reps, actualLoads: actual, actualRIRs: rirs,
                            restPausePatternsBySet: patterns, setFeedbackBySet: feedback)
        i.planEdited = edited
        i.updatedAt = updated ?? sep22
        return i
    }

    private func tBar(_ ctx: ModelContext, _ meso: MesoBlock, feedback: [String]? = nil) -> (done: SessionItem, target: SessionItem) {
        let done = item("t_bar_row", wave: "c", repMin: 8, repMax: 10, suggested: 330, planned: [330, 330, 330, 0],
                        actual: [330, 330, 0, 0], reps: [10, 10, 0, 0], rirs: [2, 1, 0, 0],
                        patterns: ["", "", "SKIP", ""], feedback: feedback ?? ["", "", "fatigue", ""], edited: true)
        let target = item("t_bar_row", wave: "c", repMin: 8, repMax: 10, suggested: 255)
        session(ctx, meso, day(11, 1), .completed, week: 6, label: "Pull A", [done])
        session(ctx, meso, day(11, 22), .planned, week: 9, label: "Pull A", [target])
        return (done, target)
    }

    // MARK: Rule 1 — the held load

    func test_TBar_Nov22_isHeldAt330_notLoweredToTheStaleSeed() throws {
        let (ctx, meso) = try context()
        let (done, target) = tBar(ctx, meso)
        XCTAssertFalse(CoachingEngine.hasSufficientPrimaryEvidence(done), "2 of 3 sets performed: carry-forward cannot write")
        XCTAssertEqual(CoachingEngine.heldLoad(for: done), 330)

        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].oldLoad, 255); XCTAssertEqual(changes[0].newLoad, 330)
        XCTAssertEqual(target.suggestedLoad, 330)
        XCTAssertEqual(target.plannedLoadsBySet, [330, 330, 330])
        XCTAssertFalse(target.planEdited, "an automatic write")
        XCTAssertTrue(target.coachNote?.contains("Held at 330") == true, target.coachNote ?? "nil")
    }

    func test_aSkippedSetNeverLowersOrRaises_andAPainSkipLeavesTheTargetAlone() throws {
        for reason in ["", "soreness", "disruption", "fatigue"] {
            let (ctx, meso) = try context()
            let (_, target) = tBar(ctx, meso, feedback: ["", "", reason, ""])
            let changes = PlaceholderRefresh.run(in: ctx, now: now)
            XCTAssertEqual(changes.first?.newLoad, 330, "skip reason \(reason.isEmpty ? "none" : reason): the held load, never a decrease from the unperformed set")
            XCTAssertEqual(target.suggestedLoad, 330)
        }
        let (ctx, meso) = try context()
        let (_, target) = tBar(ctx, meso, feedback: ["", "", "pain", ""])
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "pain holds: nothing is written")
        XCTAssertEqual(target.suggestedLoad, 255)
    }

    func test_enoughEvidenceIsCarryForwardsToWrite_notPlaceholderRefreshs() throws {
        let (ctx, meso) = try context()
        let done = item("t_bar_row", wave: "c", repMin: 8, repMax: 10, suggested: 330, actual: [330, 330, 330], reps: [10, 10, 10], rirs: [2, 2, 2])
        let target = item("t_bar_row", wave: "c", repMin: 8, repMax: 10, suggested: 255)
        session(ctx, meso, day(11, 1), .completed, week: 6, label: "Pull A", [done])
        session(ctx, meso, day(11, 22), .planned, week: 9, label: "Pull A", [target])
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(target.suggestedLoad, 255)
    }

    func test_aFailedAttempt_countsAsPerformed_soItIsTheHeldLoad() throws {
        let (ctx, meso) = try context()
        // One set attempted at 330 and failed (no reps); the other two never touched.
        let done = item("t_bar_row", wave: "c", repMin: 8, repMax: 10, suggested: 330, actual: [330, 0, 0], reps: [0, 0, 0], rirs: [0, -1, -1])
        let target = item("t_bar_row", wave: "c", repMin: 8, repMax: 10, suggested: 255)
        session(ctx, meso, day(11, 1), .completed, week: 6, label: "Pull A", [done])
        session(ctx, meso, day(11, 22), .planned, week: 9, label: "Pull A", [target])
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(changes.first?.newLoad, 330)
        XCTAssertTrue(changes.first?.reason.text.contains("1 of 3") == true, changes.first?.reason.text ?? "")
    }

    // MARK: Rule 2 — estimate after a missed session

    /// Legs B: wk 7 (a, Nov 10) never logged; wk 8 (b, Nov 17) performed RDL 325 x 10, 10, 9 at RIR 2; wk 10 (a, Dec 1) still
    /// carries the seed copied from wk 7.
    private func legsB(_ ctx: ModelContext, _ meso: MesoBlock, targetLoad: Double = 280, targetEdited: Bool = false, updated: Date? = nil) -> SessionItem {
        let missed = item("romanian_deadlift", wave: "a", repMin: 6, repMax: 8, suggested: 280)
        let done = item("romanian_deadlift", wave: "b", repMin: 8, repMax: 10, suggested: 325, actual: [325, 325, 325], reps: [10, 10, 9], rirs: [2, 2, 2])
        let target = item("romanian_deadlift", wave: "a", repMin: 6, repMax: 8, suggested: targetLoad, edited: targetEdited, updated: updated)
        session(ctx, meso, day(11, 10), .planned, week: 7, label: "Legs B", [missed])
        session(ctx, meso, day(11, 17), .completed, week: 8, label: "Legs B", [done])
        session(ctx, meso, day(12, 1), .planned, week: 10, label: "Legs B", [target])
        return target
    }

    func test_LegsB_Dec1_isEstimatedFromTheNov17Sets_withTheRuleTheSpecStates() throws {
        let (ctx, meso) = try context()
        let target = legsB(ctx, meso)
        // 325 x 10 at RIR 2 -> e1RM = 325 * (1 + 12/30) = 455. Target: 8 reps + RIR 2 -> 455 / (1 + 10/30) = 341.25; x 0.95 = 324.2;
        // round DOWN to the default 2.5 step -> 322.5. Floor: the target's repMax (8) is no more than the 10 reps done at 325,
        // so the written load is max(322.5, 325) = 325.
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(target.suggestedLoad, 325)
        XCTAssertEqual(target.plannedLoadsBySet, [325, 325, 325])
        XCTAssertEqual(target.coachNote, "Estimated from your recent B-week sets — set 1 calibrates.")
        XCTAssertFalse(target.planEdited)
        guard case .estimated(_, let letter, let e1rm, let why) = changes[0].reason else { return XCTFail("estimated") }
        XCTAssertEqual(letter, "b"); XCTAssertEqual(e1rm, 455, accuracy: 0.01)
        XCTAssertTrue(why.contains("Nov 10") && why.contains("missed"), why)
    }

    /// The floor: CS Incline DB Row, source B week 90 x 10, 10, 10 at RIR 2, 2, 1; target an A week at 6-8, RIR 2.
    /// e1RM = 90 * (1 + 12/30) = 126; 126 / (1 + 10/30) = 94.5; x 0.95 = 89.8 -> rounds down to 85. The target's repMax (8)
    /// is no more than the 10 reps done at 90, so the written load is max(85, 90) = 90.
    func test_floor_aTargetNoHarderThanTheSourceSet_neverWritesBelowThatSetsLoad() throws {
        let (ctx, meso) = try context()
        let missed = item("cs_incline_db_row", wave: "a", repMin: 6, repMax: 8, suggested: 85)
        let done = item("cs_incline_db_row", wave: "b", repMin: 8, repMax: 10, suggested: 90, actual: [90, 90, 90], reps: [10, 10, 10], rirs: [2, 2, 1])
        let target = item("cs_incline_db_row", wave: "a", repMin: 6, repMax: 8, suggested: 85)
        session(ctx, meso, day(11, 3), .planned, week: 7, label: "Pull B", [missed])
        session(ctx, meso, day(11, 10), .completed, week: 8, label: "Pull B", [done])
        session(ctx, meso, day(12, 2), .planned, week: 10, label: "Pull B", [target])
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 90, "not 85")
        XCTAssertEqual(target.plannedLoadsBySet, [90, 90, 90])
        XCTAssertEqual(changes.last?.newLoad, 90)
    }

    func test_floor_doesNotApplyWhenTheTargetAsksForMoreRepsThanTheSourceSet() throws {
        let (ctx, meso) = try context()
        let done = item("cs_incline_db_row", wave: "b", repMin: 8, repMax: 10, suggested: 90, actual: [90, 90, 90], reps: [8, 8, 8], rirs: [2, 2, 2])
        let target = item("cs_incline_db_row", wave: "a", repMin: 10, repMax: 12, suggested: 60)
        session(ctx, meso, day(11, 3), .planned, week: 7, label: "Pull B", [item("cs_incline_db_row", wave: "a", repMin: 10, repMax: 12, suggested: 60)])
        session(ctx, meso, day(11, 10), .completed, week: 8, label: "Pull B", [done])
        session(ctx, meso, day(12, 2), .planned, week: 10, label: "Pull B", [target])
        _ = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertLessThan(target.suggestedLoad, 90, "12 reps asked vs 8 done: the estimate stands, no floor")
    }

    func test_theStepIsTheExercisesEffectiveStep_androundsDown() throws {
        let profile = UserProfile(); profile.minLoadIncrement = 5
        let (ctx, meso) = try context(profile: profile)
        let target = legsB(ctx, meso)
        // 6-rep source sets (so the floor, which needs target repMax <= reps done, does not apply): 325 x 6 at RIR 2 ->
        // e1RM 411.7; / (1 + 10/30) = 308.8; x 0.95 = 293.4 -> rounds DOWN to the 5 lb step: 290 (2.5 step would give 292.5).
        for s in meso.sessions where s.status == .completed { for i in s.items { i.actualReps = [6, 6, 6] } }
        _ = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 290, "293.4 rounds DOWN to the 5 lb step")
    }

    func test_theMaxLoadClampsTheEstimate() throws {
        let profile = UserProfile(); profile.minLoadIncrement = 5
        profile.maxLoadByExerciseStored = ["romanian_deadlift": 300]
        let (ctx, meso) = try context(profile: profile)
        let target = legsB(ctx, meso)
        _ = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 300)
    }

    func test_aMissingRIR_countsAsTheItemsTargetRIR() throws {
        let (ctx, meso) = try context()
        let target = legsB(ctx, meso)
        // Unset the logged RIRs: the source item's target RIR (2) stands in, so the numbers are the same as with 2.
        // 6-rep sets keep the floor out of it: 325 x 6 at RIR 2 -> 293.4 -> 292.5 (the same as with RIR logged as 2).
        for s in meso.sessions where s.status == .completed { for i in s.items { i.actualRIRs = [-1, -1, -1]; i.actualReps = [6, 6, 6] } }
        _ = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 292.5)
    }

    func test_onlySetsOfTwelveRepsOrFewerQualify() throws {
        let (ctx, meso) = try context()
        let target = legsB(ctx, meso)
        // A newer same-day session of 15-rep sets is passed over for the 10-rep session before it.
        let light = item("romanian_deadlift", wave: "c", repMin: 12, repMax: 15, suggested: 200, actual: [200, 200, 200], reps: [15, 15, 15], rirs: [2, 2, 2])
        session(ctx, meso, day(11, 18) , .completed, week: 8, label: "Legs B", [light])
        _ = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 325, "the 15-rep session is not a source (the 10-rep session is: 322.5, floored to its 325)")

        // Only 15-rep sets exist: no qualifying source, the target is left alone.
        let (ctx2, meso2) = try context()
        let only = item("romanian_deadlift", wave: "b", repMin: 12, repMax: 15, suggested: 200, actual: [200, 200, 200], reps: [15, 15, 15], rirs: [2, 2, 2])
        let target2 = item("romanian_deadlift", wave: "a", repMin: 6, repMax: 8, suggested: 280)
        session(ctx2, meso2, day(11, 17), .completed, week: 8, label: "Legs B", [only])
        session(ctx2, meso2, day(12, 1), .planned, week: 10, label: "Legs B", [target2])
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx2, now: now).isEmpty)
        XCTAssertEqual(target2.suggestedLoad, 280)
    }

    func test_noSourceAtAll_leavesTheTargetAlone() throws {
        let (ctx, meso) = try context()
        let target = item("romanian_deadlift", wave: "a", repMin: 6, repMax: 8, suggested: 280)
        session(ctx, meso, day(12, 1), .planned, week: 10, label: "Legs B", [target])
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(target.suggestedLoad, 280)
    }

    // MARK: Rule 3 — never

    func test_SAPulldown_Nov18_handEdited_isUntouched() throws {
        let (ctx, meso) = try context()
        // wk 7 (a, Nov 11) performed 110 x 3 then 100 x 5, 5, 6; wk 8 (b, Nov 18) was set to 110 by hand.
        let done = item("custom_sa_pulldown", wave: "a", repMin: 6, repMax: 8, suggested: 100, actual: [110, 100, 100], reps: [3, 5, 5], rirs: [2, 2, 2])
        let handEdited = item("custom_sa_pulldown", wave: "b", repMin: 6, repMax: 8, suggested: 0, planned: [110, 110, 110], edited: true)
        session(ctx, meso, day(11, 11), .completed, week: 7, label: "Pull B", [done])
        session(ctx, meso, day(11, 18), .planned, week: 8, label: "Pull B", [handEdited])
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(handEdited.plannedLoadsBySet, [110, 110, 110])
        XCTAssertEqual(handEdited.suggestedLoad, 0)
        XCTAssertTrue(handEdited.planEdited)
    }

    func test_neverTouchesAnEditedItem_whateverTheRule() throws {
        let (ctx, meso) = try context()
        let target = legsB(ctx, meso, targetEdited: true)
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(target.suggestedLoad, 280)
        let (ctx2, meso2) = try context()
        let (_, t2) = tBar(ctx2, meso2)
        t2.planEdited = true
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx2, now: now).isEmpty)
        XCTAssertEqual(t2.suggestedLoad, 255)
    }

    func test_neverLowersATargetTheLifterPerformedAgainstSinceItWasWritten() throws {
        // Seated leg curl Dec 1 (a): target 175. The Nov 17 sets (175 x 12 x 3 at RIR 2) estimate 170: lower than the target, and the
        // lifter has performed 175 since the target was last written. It stays.
        let (ctx, meso) = try context()
        let missed = item("seated_leg_curl", wave: "a", repMin: 8, repMax: 10, suggested: 175)
        let done = item("seated_leg_curl", wave: "b", repMin: 10, repMax: 12, suggested: 175, actual: [175, 175, 175], reps: [12, 12, 12], rirs: [2, 2, 2])
        let target = item("seated_leg_curl", wave: "a", repMin: 8, repMax: 10, suggested: 175, updated: day(10, 10))
        session(ctx, meso, day(11, 10), .planned, week: 7, label: "Legs B", [missed])
        session(ctx, meso, day(11, 17), .completed, week: 8, label: "Legs B", [done])
        session(ctx, meso, day(12, 1), .planned, week: 10, label: "Legs B", [target])
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(target.suggestedLoad, 175)

        // Written AFTER the last performance, the same estimate may lower it - but the floor (repMax 10 <= the 12 reps done at 175)
        // holds it at 175, so nothing is lowered here either.
        target.updatedAt = day(11, 18)
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(target.suggestedLoad, 175)
    }

    /// Calf raise, Legs B Dec 1 (a): target 330 (10-12 reps). The lifter performed 301 x 12, 12, 11 on Nov 17 - under the target's
    /// load - so nothing shows 330 was doable and it lowers to the estimate.
    func test_calfDec1_lowersToTheEstimate_whenNothingPerformedShowsTheTargetWasDoable() throws {
        let (ctx, meso) = try context()
        let missed = item("smith_machine_calves", wave: "a", repMin: 10, repMax: 12, suggested: 330)
        let done = item("smith_machine_calves", wave: "b", repMin: 12, repMax: 15, suggested: 301, actual: [301, 301, 301], reps: [12, 12, 11], rirs: [1, 1, 1])
        let target = item("smith_machine_calves", wave: "a", repMin: 10, repMax: 12, suggested: 330, updated: day(10, 10))
        session(ctx, meso, day(11, 10), .planned, week: 7, label: "Legs B", [missed])
        session(ctx, meso, day(11, 17), .completed, week: 8, label: "Legs B", [done])
        session(ctx, meso, day(12, 1), .planned, week: 10, label: "Legs B", [target])
        // 301 x 12 at RIR 1 -> e1RM 301 * (1 + 13/30) = 431.5; target 12 reps + RIR 2 -> 431.5 / (1 + 14/30) = 294.1; x 0.95 = 279.4;
        // down to the 2.5 step -> 277.5. Floor: the target's repMax (12) is no more than the 12 reps done at 301, so max(277.5, 301) = 301.
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(target.suggestedLoad, 301)
        XCTAssertEqual(target.plannedLoadsBySet, [301, 301, 301])
    }

    func test_aLoadAtOrAboveTheTargetStillLowersWhenTheRepsWereBelowTheTargetsRepMin() throws {
        // Leg curl, Dec 1 (a, 8-10): 175 x 12 x 3 blocks the lowering (load >= 175, reps >= 8). 175 x 6 does not: it was not done in range.
        func run(reps: [Int]) throws -> Double {
            let (ctx, meso) = try context()
            let missed = item("seated_leg_curl", wave: "a", repMin: 8, repMax: 10, suggested: 175)
            let done = item("seated_leg_curl", wave: "b", repMin: 10, repMax: 12, suggested: 175, actual: [175, 175, 175], reps: reps, rirs: [2, 2, 2])
            let target = item("seated_leg_curl", wave: "a", repMin: 8, repMax: 10, suggested: 175, updated: day(10, 10))
            session(ctx, meso, day(11, 10), .planned, week: 7, label: "Legs B", [missed])
            session(ctx, meso, day(11, 17), .completed, week: 8, label: "Legs B", [done])
            session(ctx, meso, day(12, 1), .planned, week: 10, label: "Legs B", [target])
            _ = PlaceholderRefresh.run(in: ctx, now: now)
            return target.suggestedLoad
        }
        XCTAssertEqual(try run(reps: [12, 12, 12]), 175, "doable in range: it stays")
        XCTAssertLessThan(try run(reps: [6, 6, 6]), 175, "175 was not done in the 8-10 range: it lowers")
    }

    // MARK: No recent history

    func test_aTargetAtZeroWithNothingToEstimateFrom_keepsTheNoHistoryNote_once() throws {
        let (ctx, meso) = try context()
        let zero = item("romanian_deadlift", wave: "a", repMin: 6, repMax: 8, suggested: 0, planned: [0, 0, 0])
        let sized = item("seated_leg_curl", wave: "a", repMin: 8, repMax: 10, suggested: 175)
        session(ctx, meso, day(12, 1), .planned, week: 10, label: "Legs B", [zero, sized])
        let first = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].noteOnly)
        XCTAssertEqual(zero.suggestedLoad, 0)
        XCTAssertEqual(zero.prescriptionNotes, "No recent history — set a load.")
        XCTAssertNil(sized.prescriptionNotes, "a target with a load is not told it has no history")
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "once")
        XCTAssertEqual(zero.prescriptionNotes, "No recent history — set a load.")
    }

    // MARK: Rule 2, in order: (i) the same letter's held load, (ii) the estimate for a repMin <= 12, (iii) leave + placeholder note

    /// Pull B lateral raise, Nov 25 (c, 15-20 reps, target 30): the Nov 4 c session was missed; Oct 14 (c) performed 30 x 20 x 3,
    /// and Nov 11 (a) performed 35 x 12 x 3. Oct 14 is exactly two 3-week rotations before Nov 25.
    private func lateralRaise(_ ctx: ModelContext, _ meso: MesoBlock) -> SessionItem {
        let oct14 = item("dumbbell_lateral_raise", wave: "c", repMin: 15, repMax: 20, suggested: 30, actual: [30, 30, 30], reps: [20, 20, 20], rirs: [1, 1, 1])
        let oct21 = item("dumbbell_lateral_raise", wave: "a", repMin: 10, repMax: 12, suggested: 40)
        let oct28 = item("dumbbell_lateral_raise", wave: "b", repMin: 12, repMax: 15, suggested: 32.5)
        let nov4 = item("dumbbell_lateral_raise", wave: "c", repMin: 15, repMax: 20, suggested: 35)
        let nov11 = item("dumbbell_lateral_raise", wave: "a", repMin: 10, repMax: 12, suggested: 35, actual: [35, 35, 35], reps: [12, 12, 12], rirs: [1, 1, 1])
        let target = item("dumbbell_lateral_raise", wave: "c", repMin: 15, repMax: 20, suggested: 30, updated: day(10, 15))
        session(ctx, meso, day(10, 14), .completed, week: 3, label: "Pull B", [oct14])
        session(ctx, meso, day(10, 21), .planned, week: 4, label: "Pull B", [oct21])
        session(ctx, meso, day(10, 28), .planned, week: 5, label: "Pull B", [oct28])
        session(ctx, meso, day(11, 4), .planned, week: 6, label: "Pull B", [nov4])
        session(ctx, meso, day(11, 11), .completed, week: 7, label: "Pull B", [nov11])
        session(ctx, meso, day(11, 25), .planned, week: 9, label: "Pull B", [target])
        return target
    }

    func test_lateralRaiseNov25_staysAt30_viaTheSameLettersHeldLoad_fromOct14() throws {
        let (ctx, meso) = try context()
        let target = lateralRaise(ctx, meso)
        // Without (i) the Nov 11 35 x 12 sets would estimate about 25 for this 20-rep target.
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(target.suggestedLoad, 30)
        XCTAssertEqual(target.plannedLoadsBySet, [30, 30, 30])
        XCTAssertNil(target.coachNote, "a held load that already stands writes nothing")

        // The held load from Oct 14 also RAISES a stale target: the same letter's own evidence.
        target.suggestedLoad = 20; target.plannedLoadsBySet = [20, 20, 20]
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(changes.first?.newLoad, 30)
        guard case .earlierSameLetter(_, let weeks)? = changes.first?.reason else { return XCTFail("rule 2 (i)") }
        XCTAssertEqual(weeks, 3, "A/B/C: a 3-week rotation, a 6-week window")
    }

    func test_theSameLetterSessionOutsideTwoRotations_isNotUsed() throws {
        let (ctx, meso) = try context()
        let target = lateralRaise(ctx, meso)
        // One day past six weeks: Oct 13 is 43 days before Nov 25.
        for s in meso.sessions where s.date == day(10, 14) { s.date = day(10, 13) }
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "the 20-rep target is not estimated either: it stays 30")
        XCTAssertEqual(target.suggestedLoad, 30)
        // Its coach note: it was written since the block was created (Oct 15), so no placeholder note.
        XCTAssertNil(target.coachNote)
    }

    func test_hipThrustAndRDLDec1_stayEstimated_becauseSep29IsOutsideTwoRotations() throws {
        let (ctx, meso) = try context()
        let target = legsB(ctx, meso)
        // The last a-week performance is Sep 29: 63 days before Dec 1, outside the 42-day window. Block letters: a, b, c.
        let sep29 = item("romanian_deadlift", wave: "a", repMin: 6, repMax: 8, suggested: 300, actual: [300, 300, 300], reps: [8, 8, 8], rirs: [2, 2, 2])
        let nov3c = item("romanian_deadlift", wave: "c", repMin: 10, repMax: 12, suggested: 250)
        session(ctx, meso, day(9, 29), .completed, week: 1, label: "Legs B", [sep29])
        session(ctx, meso, day(11, 3), .planned, week: 6, label: "Legs B", [nov3c])
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(target.suggestedLoad, 325, "the Nov 17 cross-letter estimate (322.5, floored to its 325), not Sep 29's 300")
        guard case .estimated? = changes.first?.reason else { return XCTFail("rule 2 (ii)") }
    }

    func test_aHighRepTargetIsNeverEstimated() throws {
        let (ctx, meso) = try context()
        // A 15-20 rep target, a missed predecessor, and a fine 10-rep cross-letter source: still not estimated.
        let done = item("romanian_deadlift", wave: "a", repMin: 6, repMax: 8, suggested: 300, actual: [300, 300, 300], reps: [8, 8, 8], rirs: [2, 2, 2])
        let target = item("romanian_deadlift", wave: "c", repMin: 15, repMax: 20, suggested: 200)
        session(ctx, meso, day(11, 10), .completed, week: 7, label: "Legs B", [done])
        session(ctx, meso, day(12, 1), .planned, week: 10, label: "Legs B", [target])
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(target.suggestedLoad, 200)
        // A repMin of exactly 12 still estimates.
        let (ctx2, meso2) = try context()
        let t12 = item("romanian_deadlift", wave: "c", repMin: 12, repMax: 15, suggested: 100)
        let done2 = item("romanian_deadlift", wave: "a", repMin: 6, repMax: 8, suggested: 300, actual: [300, 300, 300], reps: [8, 8, 8], rirs: [2, 2, 2])
        session(ctx2, meso2, day(11, 10), .completed, week: 7, label: "Legs B", [done2])
        session(ctx2, meso2, day(12, 1), .planned, week: 10, label: "Legs B", [t12])
        XCTAssertEqual(PlaceholderRefresh.run(in: ctx2, now: now).count, 1)
    }

    /// Calf raise, Legs B Dec 1 (a, 10-12 reps, 330): every calf set the lifter logged was 13-15 reps, so (ii) has no source and
    /// the load is left; a target still at its block-setup value gets the one-time note.
    private func calf(_ ctx: ModelContext, _ meso: MesoBlock, updated: Date?) -> SessionItem {
        let missed = item("smith_machine_calves", wave: "a", repMin: 10, repMax: 12, suggested: 330)
        let done = item("smith_machine_calves", wave: "b", repMin: 12, repMax: 15, suggested: 301, actual: [301, 301, 301], reps: [15, 15, 15], rirs: [1, 1, 1])
        let target = item("smith_machine_calves", wave: "a", repMin: 10, repMax: 12, suggested: 330, updated: updated)
        session(ctx, meso, day(11, 10), .planned, week: 7, label: "Legs B", [missed])
        session(ctx, meso, day(11, 17), .completed, week: 8, label: "Legs B", [done])
        session(ctx, meso, day(12, 1), .planned, week: 10, label: "Legs B", [target])
        return target
    }

    func test_calfDec1_staysAt330_andGetsThePlaceholderNote_whenItWasNeverWrittenSinceTheBlockWasCreated() throws {
        let (ctx, meso) = try context()
        meso.createdAt = sep22
        let target = calf(ctx, meso, updated: sep22)
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].noteOnly)
        XCTAssertEqual(target.suggestedLoad, 330)
        XCTAssertEqual(target.plannedLoadsBySet, [330, 330, 330])
        XCTAssertEqual(target.coachNote, "No recent data for this week type — set 1 calibrates.")
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "one-time")
    }

    func test_aTargetWrittenSinceTheBlockWasCreated_getsNoPlaceholderNote() throws {
        let (ctx, meso) = try context()
        meso.createdAt = sep22
        let target = calf(ctx, meso, updated: day(10, 10))
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(target.suggestedLoad, 330)
        XCTAssertNil(target.coachNote)
    }

    func test_bodyweightAndFixedLoadExercisesAreLeftAlone() throws {
        let profile = UserProfile(); profile.setProgressionExempt(true, exerciseId: "romanian_deadlift")
        let (ctx, meso) = try context(profile: profile)
        let target = legsB(ctx, meso)
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "fixed-load")
        XCTAssertEqual(target.suggestedLoad, 280)
    }

    // MARK: Idempotence and the gate

    func test_runningItTwiceChangesNothingTheSecondTime() throws {
        let (ctx, meso) = try context()
        _ = tBar(ctx, meso)
        _ = legsB(ctx, meso)
        // Both targets share the day label only per exercise; they are separate chains.
        let first = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(first.count, 2)
        let snapshot = meso.sessions.flatMap(\.items).map { "\($0.suggestedLoad)|\($0.plannedLoadsBySet)|\($0.coachNote ?? "-")" }
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty)
        XCTAssertEqual(meso.sessions.flatMap(\.items).map { "\($0.suggestedLoad)|\($0.plannedLoadsBySet)|\($0.coachNote ?? "-")" }, snapshot)
    }

    func test_theAutomaticEntryPointsAreOnByDefault_andOffWhenTheGateIsClosed() throws {
        XCTAssertTrue(PlaceholderRefresh.isEnabled)
        let (ctx, meso) = try context()
        let (_, target) = tBar(ctx, meso)
        PlaceholderRefresh.isEnabled = false
        PlaceholderRefresh.afterCompletion(in: ctx, now: now)
        PlaceholderRefreshBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(target.suggestedLoad, 255, "gate closed: nothing is written")
        PlaceholderRefresh.isEnabled = true
        PlaceholderRefresh.afterCompletion(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 330)
    }
}

// MARK: - Blocks with no waves (a program the lifter wrote)

final class WavelessBlockTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))! }
    private var monday: Date { day(2026, 9, 7) }          // a Monday
    private var now: Date { day(2026, 9, 12) }            // after week 1 of a block that started Sep 7

    private func context() throws -> ModelContext {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        return ctx
    }

    /// A 4-day upper/lower program, five exercises a day. Bench and rows appear on two days: the chain must not mix them up.
    private func fourDay(weeks: Int = 6, deload: Bool = false) -> ProgramTemplate {
        func slots(_ ids: [(String, Bool)]) -> [WavelessSlot] { ids.map { WavelessSlot.defaults(exerciseId: $0.0, isCompound: $0.1) } }
        return .waveless(name: "My upper / lower", totalWeeks: weeks, deloadFinalWeek: deload, days: [
            WavelessDay(title: "Upper A", slots: slots([("bench_press", true), ("barbell_row", true), ("dumbbell_lateral_raise", false), ("cable_tricep_rope_pushdown", false), ("barbell_curl", false)])),
            WavelessDay(title: "Lower A", slots: slots([("barbell_back_squat", true), ("romanian_deadlift", true), ("leg_extension", false), ("seated_leg_curl", false), ("seated_calf_raise", false)])),
            WavelessDay(title: "Upper B", slots: slots([("bench_press", true), ("pull_up", true), ("cable_face_pull", false), ("hammer_curl", false), ("pec_deck", false)])),
            WavelessDay(title: "Lower B", slots: slots([("leg_press", true), ("lying_leg_curl", false), ("leg_extension", false), ("seated_calf_raise", false), ("cable_rope_crunch", false)])),
        ])
    }

    @discardableResult
    private func seed(_ ctx: ModelContext, _ template: ProgramTemplate, name: String = "Mine") throws -> MesoBlock {
        try DUPProgramSeeder.seed(startDate: monday, trainingWeekdays: [2, 3, 5, 6], context: ctx, template: template, calendar: cal,
                                  mesoName: name, mesoStatus: .active)
        return try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first { $0.name == name })
    }

    private func sessions(_ meso: MesoBlock, week: Int? = nil, label: String? = nil) -> [Session] {
        meso.sessions.filter { (week == nil || $0.weekIndex == week) && (label == nil || $0.dayLabel == label) }.sorted { $0.date < $1.date }
    }

    // MARK: Template and materializer

    func test_aFourDayBlockWithNoWavesSeeds_sessionsCarryNoLetter() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay(weeks: 6))
        XCTAssertEqual(block.sessions.count, 4 * 6)
        XCTAssertEqual(block.totalWeeks, 6)
        XCTAssertTrue(block.sessions.flatMap(\.items).allSatisfy { $0.waveRaw == nil }, "no wave letter on any item")
        XCTAssertEqual(Set(block.sessions.compactMap(\.dayLabel)), ["Upper A", "Lower A", "Upper B", "Lower B"])
        XCTAssertTrue(block.sessions.allSatisfy { !($0.sessionNotes ?? "").lowercased().contains("wave") })
        // One prescription per slot: compound 3 x 6-10 @2, isolation 3 x 10-15 @1-2, the same every week.
        let bench = try XCTUnwrap(sessions(block, week: 3, label: "Upper A").first?.items.first { $0.exerciseId == "bench_press" })
        XCTAssertEqual([bench.targetSets, bench.repMin, bench.repMax, bench.targetRIRMin, bench.targetRIRMax], [3, 6, 10, 2, 2])
        let lateral = try XCTUnwrap(sessions(block, week: 5, label: "Upper A").first?.items.first { $0.exerciseId == "dumbbell_lateral_raise" })
        XCTAssertEqual([lateral.targetSets, lateral.repMin, lateral.repMax, lateral.targetRIRMin, lateral.targetRIRMax], [3, 10, 15, 1, 2])
        XCTAssertTrue(block.sessions.allSatisfy { $0.mesoPhase != .deload }, "no deload unless asked")
        XCTAssertFalse(WavePrescriptionGuard.isWaveBasedBlock(try XCTUnwrap(block.sessions.first)))
    }

    func test_anOptionalDeloadInTheFinalWeek_isTheOnlyWaveValue() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay(weeks: 5, deload: true))
        for s in block.sessions {
            let expected: String? = s.weekIndex == 5 ? "deload" : nil
            XCTAssertTrue(s.items.allSatisfy { $0.waveRaw == expected }, "week \(s.weekIndex)")
        }
        let deloadBench = try XCTUnwrap(sessions(block, week: 5, label: "Upper A").first?.items.first { $0.exerciseId == "bench_press" })
        XCTAssertEqual(deloadBench.targetSets, 2, "half the sets")
        XCTAssertEqual(deloadBench.targetRIR, 4, "two more reps in reserve, capped at 4")
        XCTAssertTrue(sessions(block, week: 5).allSatisfy { $0.isDeloadWeek })
        XCTAssertTrue(sessions(block, week: 4).allSatisfy { !$0.isDeloadWeek })
    }

    func test_theBlockLengthIsFourToTwelveWeeks() {
        XCTAssertEqual(fourDay(weeks: 2).totalWeeks, 4)
        XCTAssertEqual(fourDay(weeks: 4).totalWeeks, 4)
        XCTAssertEqual(fourDay(weeks: 12).totalWeeks, 12)
        XCTAssertEqual(fourDay(weeks: 30).totalWeeks, 12)
        XCTAssertEqual(ProgramTemplate.wavelessDefaultWeeks, 8)
        XCTAssertTrue(fourDay().waveless)
        XCTAssertFalse(DUP10WeekTemplate.template.waveless)
        // The flag survives the fitter, the goal modifier and overrides.
        XCTAssertTrue(DUPProgramSeeder.applying(overrides: .empty, to: fourDay()).waveless)
        XCTAssertTrue(GoalModifier.apply(fourDay(), goal: .longevity).0.waveless)
    }

    // MARK: Carry-forward, week 1 -> week 2 on the same day

    private func perform(_ session: Session, load: Double, reps: Int, rir: Int = 2) {
        for item in session.items {
            item.suggestedLoad = load
            item.plannedLoadsBySet = Array(repeating: load, count: item.targetSets)
            item.actualLoads = Array(repeating: load, count: item.targetSets)
            item.actualReps = Array(repeating: reps, count: item.targetSets)
            item.actualRIRs = Array(repeating: rir, count: item.targetSets)
            item.isCompleted = true
        }
        session.status = .completed
        session.completedAt = session.date
    }

    func test_coachingCarriesWeek1ToWeek2OnTheSameDay_andNeverAcrossDays() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay())
        // Bench is on Upper A and Upper B. Give both days' week 1 a starting load; perform only Upper A.
        for s in sessions(block, week: 1) where s.dayLabel == "Upper B" { for i in s.items { i.suggestedLoad = 150; i.plannedLoadsBySet = [150, 150, 150] } }
        for s in sessions(block, week: 2) where s.dayLabel == "Upper B" { for i in s.items { i.suggestedLoad = 150; i.plannedLoadsBySet = [150, 150, 150] } }
        let week1A = try XCTUnwrap(sessions(block, week: 1, label: "Upper A").first)
        perform(week1A, load: 100, reps: 10)             // every set at the top of 6-10 at RIR 2: an increase is earned
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: week1A)

        let week2A = try XCTUnwrap(sessions(block, week: 2, label: "Upper A").first)
        let bench2A = try XCTUnwrap(week2A.items.first { $0.exerciseId == "bench_press" })
        XCTAssertGreaterThan(bench2A.suggestedLoad, 100, "the coach wrote week 2's Upper A bench from week 1's")
        XCTAssertEqual(bench2A.plannedLoadsBySet.first, bench2A.suggestedLoad)
        XCTAssertFalse(bench2A.planEdited)
        // The other day's bench, and every other week of Upper A past week 2, are not what week 1 wrote.
        let bench2B = try XCTUnwrap(sessions(block, week: 2, label: "Upper B").first?.items.first { $0.exerciseId == "bench_press" })
        XCTAssertEqual(bench2B.suggestedLoad, 150, "Upper B's bench is its own chain")
        let bench3A = try XCTUnwrap(sessions(block, week: 3, label: "Upper A").first?.items.first { $0.exerciseId == "bench_press" })
        XCTAssertEqual(bench3A.suggestedLoad, 0, "only the immediate next occurrence is written")
        XCTAssertNotNil(PlanMemoryEngine.nextTargetItem(for: try XCTUnwrap(week1A.items.first), after: week1A, in: block.sessions))
    }

    /// What really happens in the app: a block the lifter just wrote has NO planned load anywhere; week 1 is logged at loads typed on the
    /// day. Week 2 must show what the coach wrote from those sets.
    func test_firstWeekLoggedWithNoPlannedLoad_writesWeek2FromTheActualSets() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay())
        let week1A = try XCTUnwrap(sessions(block, week: 1, label: "Upper A").first)
        for item in week1A.items {
            XCTAssertEqual(item.suggestedLoad, 0, "a fresh block carries no load")
            item.actualLoads = Array(repeating: 100, count: item.targetSets)
            item.actualReps = Array(repeating: item.repMax ?? 10, count: item.targetSets)
            item.actualRIRs = Array(repeating: 2, count: item.targetSets)
            item.isCompleted = true
        }
        week1A.status = .completed; week1A.completedAt = week1A.date
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: week1A)
        let week2A = try XCTUnwrap(sessions(block, week: 2, label: "Upper A").first)
        let bench = try XCTUnwrap(week2A.items.first { $0.exerciseId == "bench_press" })
        XCTAssertGreaterThanOrEqual(bench.suggestedLoad, 100, "the coach wrote week 2's bench from week 1's 3 x 10 at 100")
        XCTAssertTrue(bench.plannedLoadsBySet.prefix(3).allSatisfy { $0 >= 100 })
    }

    /// A week already completed before the baseline fix: the startup backfill gives week 2 the held load of week 1's same-day session.
    func test_aCompletedWeekWhoseTargetWasNeverWritten_getsTheHeldLoadFromTheBackfill() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay())
        let week1A = try XCTUnwrap(sessions(block, week: 1, label: "Upper A").first)
        for item in week1A.items {
            item.actualLoads = Array(repeating: 100, count: item.targetSets); item.actualReps = Array(repeating: 10, count: item.targetSets)
            item.actualRIRs = Array(repeating: 2, count: item.targetSets); item.isCompleted = true
        }
        week1A.status = .completed; week1A.completedAt = week1A.date
        try ctx.save()
        let week2A = try XCTUnwrap(sessions(block, week: 2, label: "Upper A").first)
        let bench = try XCTUnwrap(week2A.items.first { $0.exerciseId == "bench_press" })
        XCTAssertEqual(bench.suggestedLoad, 0)
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(bench.suggestedLoad, 100)
        XCTAssertEqual(bench.plannedLoadsBySet, [100, 100, 100])
        XCTAssertEqual(changes.filter { $0.item === bench }.count, 1)
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "idempotent")
    }

    // MARK: The no-load baseline never touches what it must not

    /// Week 1 Upper A done with a performed bench at 100 and no planned load; `tweak` sets up the case under test. Returns the source and the week 2 target.
    private func baselineCase(profile: UserProfile? = nil, exercise: String = "bench_press",
                              _ tweak: (SessionItem, SessionItem) -> Void = { _, _ in }) throws -> (ModelContext, SessionItem, SessionItem, Session) {
        let ctx = try context()
        if let profile { ctx.insert(profile) }
        let block = try seed(ctx, fourDay())
        let week1A = try XCTUnwrap(sessions(block, week: 1, label: "Upper A").first)
        let source = try XCTUnwrap(week1A.items.first { $0.exerciseId == exercise })
        let target = try XCTUnwrap(sessions(block, week: 2, label: "Upper A").first?.items.first { $0.exerciseId == exercise })
        source.actualLoads = Array(repeating: 100, count: source.targetSets); source.actualReps = Array(repeating: 10, count: source.targetSets)
        source.actualRIRs = Array(repeating: 2, count: source.targetSets); source.isCompleted = true
        week1A.status = .completed; week1A.completedAt = week1A.date
        tweak(source, target)
        try ctx.save()
        return (ctx, source, target, week1A)
    }

    func test_baselineAndFillAt0_doWriteInTheOrdinaryCase() throws {
        let (ctx, source, target, week1A) = try baselineCase()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: week1A)
        XCTAssertEqual(source.suggestedLoad, 100, "the load lifted became its baseline")
        XCTAssertGreaterThan(target.suggestedLoad, 0)
        let (ctx2, _, target2, _) = try baselineCase()
        XCTAssertFalse(PlaceholderRefresh.run(in: ctx2, now: now).isEmpty)
        XCTAssertEqual(target2.suggestedLoad, 100)
    }

    func test_neverForABodyweightItem() throws {
        let bw = "push_up"
        XCTAssertTrue(ExerciseCatalog.isBodyweight(exerciseId: bw))
        func slotted() -> ProgramTemplate {
            .waveless(name: "BW", totalWeeks: 4, days: [WavelessDay(title: "A", slots: [.defaults(exerciseId: bw, isCompound: true)]),
                                                        WavelessDay(title: "B", slots: [.defaults(exerciseId: "bench_press", isCompound: true)])])
        }
        let ctx = try context()
        try DUPProgramSeeder.seed(startDate: monday, trainingWeekdays: [2, 5], context: ctx, template: slotted(), calendar: cal, mesoName: "BW", mesoStatus: .active)
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
        let wk1 = try XCTUnwrap(sessions(block, week: 1, label: "A").first)
        let source = try XCTUnwrap(wk1.items.first)
        source.actualLoads = [20, 20, 20]; source.actualReps = [10, 10, 10]; source.actualRIRs = [2, 2, 2]     // even a loaded set
        wk1.status = .completed; wk1.completedAt = wk1.date
        let target = try XCTUnwrap(sessions(block, week: 2, label: "A").first?.items.first)
        try ctx.save()
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: wk1)
        XCTAssertEqual(source.suggestedLoad, 0, "no baseline for a bodyweight item")
        XCTAssertEqual(target.suggestedLoad, 0)
        _ = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 0, "the fill-at-0 path leaves it too")
    }

    func test_neverForAPlanEditedItem() throws {
        // The source's plan was edited by hand (even to nothing): its baseline is the lifter's, not the coach's.
        let (ctx, source, target, week1A) = try baselineCase { source, _ in source.planEdited = true }
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: week1A)
        XCTAssertEqual(source.suggestedLoad, 0)
        // A hand-edited TARGET is left exactly as it is by both paths.
        let (ctx2, _, target2, week1B) = try baselineCase { _, target in
            target.planEdited = true; target.plannedLoadsBySet = [0, 0, 0]; target.suggestedLoad = 0
        }
        PlanMemoryEngine(context: ctx2).carryForwardPlans(from: week1B)
        XCTAssertEqual(target2.suggestedLoad, 0); XCTAssertEqual(target2.plannedLoadsBySet, [0, 0, 0])
        XCTAssertFalse(PlaceholderRefresh.run(in: ctx2, now: now).contains { $0.item === target2 }, "not even a note")
        XCTAssertEqual(target2.suggestedLoad, 0); XCTAssertEqual(target2.plannedLoadsBySet, [0, 0, 0]); XCTAssertTrue(target2.planEdited)
        _ = target
    }

    func test_neverForAFixedLoadExercise() throws {
        let profile = UserProfile()
        profile.setProgressionExempt(true, exerciseId: "bench_press")
        let (ctx, source, target, week1A) = try baselineCase(profile: profile)
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: week1A)
        XCTAssertEqual(source.suggestedLoad, 0, "no baseline adopted")
        XCTAssertEqual(target.suggestedLoad, 0)
        XCTAssertFalse(PlaceholderRefresh.run(in: ctx, now: now).contains { $0.item === target }, "left alone by the fill-at-0 path")
        XCTAssertEqual(target.suggestedLoad, 0)
    }

    func test_neverWhenTheSourceHasAPainFlag() throws {
        let (ctx, source, target, week1A) = try baselineCase { source, _ in
            source.setFeedbackBySet = ["", "pain", ""]
        }
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: week1A)
        XCTAssertEqual(source.suggestedLoad, 0, "pain: no baseline, no call")
        XCTAssertEqual(target.suggestedLoad, 0)
        XCTAssertFalse(PlaceholderRefresh.run(in: ctx, now: now).contains { $0.item === target }, "left alone by the fill-at-0 path")
        XCTAssertEqual(target.suggestedLoad, 0)
        XCTAssertEqual(target.plannedLoadsBySet, [0, 0, 0])
        XCTAssertFalse(target.coachNote?.contains("Held at") == true, "the pain warning stands; no held-load note")
    }

    func test_theBaselineIsAlsoSkippedForADeloadItem() {
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 4, suggestedLoad: 0, waveRaw: "deload",
                               plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [0, 0, 0],
                               actualReps: [8, 8, 8], actualLoads: [100, 100, 100], actualRIRs: [4, 4, 4])
        PlanMemoryEngine.adoptPerformedLoadAsBaseline(item)
        XCTAssertEqual(item.suggestedLoad, 0)
    }

    func test_theChainIsBlockAndDay_notChronological() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay())
        let week1A = try XCTUnwrap(sessions(block, week: 1, label: "Upper A").first)
        let bench = try XCTUnwrap(week1A.items.first { $0.exerciseId == "bench_press" })
        let target = try XCTUnwrap(PlanMemoryEngine.nextTargetItem(for: bench, after: week1A, in: block.sessions))
        let owner = try XCTUnwrap(block.sessions.first { $0.items.contains { $0 === target } })
        XCTAssertEqual(owner.dayLabel, "Upper A")
        XCTAssertEqual(owner.weekIndex, 2)
        // A deload week never anchors, and is skipped.
        let ctx2 = try context()
        let withDeload = try seed(ctx2, fourDay(weeks: 4, deload: true), name: "WithDeload")
        let week3 = try XCTUnwrap(sessions(withDeload, week: 3, label: "Upper A").first)
        let item3 = try XCTUnwrap(week3.items.first { $0.exerciseId == "bench_press" })
        XCTAssertNil(PlanMemoryEngine.nextTargetItem(for: item3, after: week3, in: withDeload.sessions), "the next occurrence is the deload: nothing to write")
    }

    // MARK: PlaceholderRefresh

    func test_placeholderRefreshChainsByBlockAndDay_whenThereIsNoLetter() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay())
        // Week 1 Upper A: only two of three bench sets were performed at 100. Week 2's bench still carries a stale 60.
        let week1A = try XCTUnwrap(sessions(block, week: 1, label: "Upper A").first)
        let b1 = try XCTUnwrap(week1A.items.first { $0.exerciseId == "bench_press" })
        b1.suggestedLoad = 100; b1.plannedLoadsBySet = [100, 100, 100]
        b1.actualLoads = [100, 100, 0]; b1.actualReps = [8, 8, 0]; b1.actualRIRs = [2, 2, -1]; b1.isCompleted = true
        week1A.status = .completed
        let b2 = try XCTUnwrap(sessions(block, week: 2, label: "Upper A").first?.items.first { $0.exerciseId == "bench_press" })
        b2.suggestedLoad = 60; b2.plannedLoadsBySet = [60, 60, 60]
        let otherDay = try XCTUnwrap(sessions(block, week: 2, label: "Upper B").first?.items.first { $0.exerciseId == "bench_press" })
        otherDay.suggestedLoad = 70; otherDay.plannedLoadsBySet = [70, 70, 70]
        try ctx.save()

        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(b2.suggestedLoad, 100, "the held load of week 1's same-day session")
        XCTAssertEqual(b2.plannedLoadsBySet, [100, 100, 100])
        // Upper B's bench is a different chain: it is not held at Upper A's 100. With no Upper B history it takes the last-priority
        // cross-day estimate from Upper A's 100 x 8 at RIR 2 (its stale 70 is replaced by 90).
        XCTAssertEqual(otherDay.suggestedLoad, 90)
        XCTAssertEqual(otherDay.coachNote, "Estimated from your Upper A sets — set 1 calibrates.")
        XCTAssertTrue(changes.contains { $0.item === b2 })
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "idempotent")
    }

    // MARK: Labels and next meso

    func test_noLabelsOnABlockWithoutWaves_aDeloadWeekStillSaysDeload() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay(weeks: 4, deload: true))
        XCTAssertTrue(WaveLabels.labels(meso: block).isEmpty)
        XCTAssertNil(WaveLabels.display(forRaw: nil, meso: block), "week headers show nothing")
        XCTAssertEqual(WaveLabels.display(forRaw: "deload", meso: block), "Deload")
        let first = try XCTUnwrap(sessions(block, week: 1).first)
        XCTAssertNil(first.items.first?.waveRaw)
    }

    func test_startNextMesoCopiesABlockWithNoWaves() throws {
        let ctx = try context()
        let block = try seed(ctx, fourDay(weeks: 4, deload: true))
        for s in block.sessions { perform(s, load: 100, reps: 8) }
        block.status = .archived
        try ctx.save()
        let plan = SessionItemEditService.planNextMeso(meso: block, name: "Mine (next)", startDate: day(2026, 12, 7), endOldMesoNow: false,
                                                       context: ctx, now: day(2026, 12, 1), calendar: cal)
        XCTAssertTrue(plan.refusals.isEmpty, "\(plan.refusals)")
        XCTAssertEqual(plan.weeks, 4)
        XCTAssertEqual(plan.sessions.count, 16)
        XCTAssertEqual(plan.firstWeek.count, 4)
        XCTAssertTrue(plan.sessions.filter { $0.weekIndex < 4 }.allSatisfy { $0.letter.isEmpty }, "no letters")
        XCTAssertTrue(plan.sessions.filter { $0.weekIndex == 4 }.allSatisfy { $0.letter == "deload" })
        let result = try SessionItemEditService.startNextMeso(plan, in: ctx)
        XCTAssertEqual(result.sessionsCreated, 16)
        XCTAssertTrue(result.meso.sessions.filter { $0.weekIndex < 4 }.flatMap(\.items).allSatisfy { $0.waveRaw == nil })
        XCTAssertEqual(Set(result.meso.sessions.compactMap(\.dayLabel)), ["Upper A", "Lower A", "Upper B", "Lower B"])
        // The planned volume of the copy needs no waves either.
        XCTAssertFalse(PlannedVolume.weeklyHardSets(plan: plan).isEmpty)
    }

    // MARK: Existing blocks are unchanged

    /// The chain rule as it was before waveless blocks: letters by meso + day + letter, no letter chronological.
    private func legacyNext(_ source: SessionItem, after session: Session, in sessions: [Session]) -> SessionItem? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: source.exerciseId)
        let ordered = sessions.sorted { $0.date < $1.date }
        guard let index = ordered.firstIndex(where: { $0.persistentModelID == session.persistentModelID }) else { return nil }
        let future = ordered.suffix(from: index + 1)
        func match(_ c: Session) -> SessionItem? { c.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical } }
        guard let wave = source.waveRaw?.lowercased(), !wave.isEmpty else {
            return future.lazy.compactMap { c -> SessionItem? in
                guard let i = match(c), i.waveRaw?.lowercased() != "deload" else { return nil }
                return i
            }.first
        }
        for c in future {
            guard c.meso?.persistentModelID == session.meso?.persistentModelID, SessionDayLabelMatcher.matches(c.dayLabel, session.dayLabel),
                  let i = match(c), i.waveRaw?.lowercased() == wave else { continue }
            return i
        }
        return nil
    }

    func test_goldenComparison_everyChainOfAWaveBlockIsUnchanged() throws {
        let ctx = try context()
        try DUPProgramSeeder.seed(startDate: monday, trainingWeekdays: [2, 3, 4, 5, 6, 7], context: ctx, template: DUP10WeekTemplate.template,
                                  calendar: cal, mesoName: "DUP", mesoStatus: .active)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        var compared = 0
        for s in all { for i in s.items {
            XCTAssertTrue(PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all) === legacyNext(i, after: s, in: all), "\(s.dayLabel ?? "") wk\(s.weekIndex) \(i.exerciseId)")
            compared += 1
        } }
        XCTAssertGreaterThan(compared, 300)
    }

    func test_goldenComparison_aNoWaveBlockWhereEachExerciseHasOneDay_isUnchanged() throws {
        // The shape of the App Store sample: a block and day names with no letters, every lift on one day only.
        let ctx = try context()
        let template = ProgramTemplate.waveless(name: "Sample", totalWeeks: 6, days: [
            WavelessDay(title: "Push A", slots: [.defaults(exerciseId: "bench_press", isCompound: true), .defaults(exerciseId: "dumbbell_lateral_raise", isCompound: false)]),
            WavelessDay(title: "Pull A", slots: [.defaults(exerciseId: "barbell_row", isCompound: true), .defaults(exerciseId: "hammer_curl", isCompound: false)]),
            WavelessDay(title: "Legs A", slots: [.defaults(exerciseId: "barbell_back_squat", isCompound: true), .defaults(exerciseId: "leg_extension", isCompound: false)]),
        ])
        try DUPProgramSeeder.seed(startDate: monday, trainingWeekdays: [2, 4, 6], context: ctx, template: template, calendar: cal, mesoName: "Sample", mesoStatus: .active)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        for s in all { for i in s.items {
            XCTAssertTrue(PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all) === legacyNext(i, after: s, in: all), "\(s.dayLabel ?? "") wk\(s.weekIndex)")
        } }
    }

    func test_handBuiltSessionsWithNoBlockOrDayName_stayChronological() throws {
        let ctx = try context()
        func item() -> SessionItem { SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100) }
        let a = Session(date: day(2026, 9, 1), status: .completed, weekIndex: 1, dayLabel: nil, items: [item()])
        let b = Session(date: day(2026, 9, 8), status: .planned, weekIndex: 2, dayLabel: nil, items: [item()])
        ctx.insert(a); ctx.insert(b)
        XCTAssertTrue(PlanMemoryEngine.nextTargetItem(for: a.items[0], after: a, in: [a, b]) === b.items[0])
    }

    // MARK: Backup

    func test_aBlockWithNoWavesSurvivesABackupRoundTrip() throws {
        let source = try context()
        let block = try seed(source, fourDay(weeks: 5, deload: true))
        for s in sessions(block, week: 1) { perform(s, load: 95, reps: 9) }
        try source.save()
        let target = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: target)
        let restored = ModelContext(target)
        let blocks = try restored.fetch(FetchDescriptor<MesoBlock>())
        XCTAssertEqual(blocks.count, 1)
        let sessions = try restored.fetch(FetchDescriptor<Session>())
        XCTAssertEqual(sessions.count, 20)
        XCTAssertTrue(sessions.filter { $0.weekIndex < 5 }.flatMap(\.items).allSatisfy { $0.waveRaw == nil }, "a nil wave stays nil")
        XCTAssertTrue(sessions.filter { $0.weekIndex == 5 }.flatMap(\.items).allSatisfy { $0.waveRaw == "deload" })
        XCTAssertEqual(Set(sessions.compactMap(\.dayLabel)), ["Upper A", "Lower A", "Upper B", "Lower B"])
        // Everything round-trips exactly, new rows included.
        XCTAssertEqual(NSDictionary(dictionary: try BackupTestSupport.exportJSON(source)), NSDictionary(dictionary: try BackupTestSupport.exportJSON(restored)))
    }
}

// MARK: - MesoBlock.scheduledDeload (blocks the lifter wrote)

final class ScheduledDeloadTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current

    func test_aBlockWithoutADeload_neverCallsAWeekDeloadByPosition_andAWaveBlockIsUnchanged() throws {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 9))!
        func template(deload: Bool) -> ProgramTemplate {
            .waveless(name: deload ? "D" : "N", totalWeeks: 10, deloadFinalWeek: deload,
                      days: [WavelessDay(title: "A", slots: [.defaults(exerciseId: "bench_press", isCompound: true)]),
                             WavelessDay(title: "B", slots: [.defaults(exerciseId: "barbell_row", isCompound: true)])])
        }
        try DUPProgramSeeder.seed(startDate: start, trainingWeekdays: [2, 5], context: ctx, template: template(deload: false), calendar: cal, mesoName: "N", mesoStatus: .active)
        try DUPProgramSeeder.seed(startDate: start, trainingWeekdays: [2, 5], context: ctx, template: template(deload: true), calendar: cal, mesoName: "D", mesoStatus: .active)
        let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>())
        let none = try XCTUnwrap(blocks.first { $0.name == "N" }), withDeload = try XCTUnwrap(blocks.first { $0.name == "D" })
        XCTAssertEqual(none.scheduledDeload, false)
        XCTAssertEqual(withDeload.scheduledDeload, true)
        XCTAssertTrue(none.sessions.allSatisfy { $0.mesoPhase != .deload }, "weeks 9 and 10 sit in the 90% band but are working weeks")
        XCTAssertTrue(none.sessions.filter { $0.weekIndex >= 9 }.allSatisfy { $0.mesoPhase == .late })
        XCTAssertEqual(withDeload.sessions.filter { $0.mesoPhase == .deload }.map(\.weekIndex).sorted(), [10, 10], "only the deload week, by its items")
        XCTAssertTrue(withDeload.sessions.filter { $0.weekIndex == 9 }.allSatisfy { $0.mesoPhase == .late })

        // A block with no value keeps the position band exactly as before (generated waves aside).
        let legacy = MesoBlock(name: "Legacy", startDate: start, status: .active, totalWeeks: 10)
        ctx.insert(legacy)
        let s10 = Session(date: start, weekIndex: 10, dayLabel: "A", items: [SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0)])
        s10.meso = legacy; ctx.insert(s10)
        XCTAssertNil(legacy.scheduledDeload)
        XCTAssertEqual(s10.mesoPhase, .deload, "position band, unchanged")
    }

    func test_scheduledDeload_survivesABackupRoundTrip_nilTrueAndFalse() throws {
        let source = ModelContext(try BackupTestSupport.makeContainer())
        for (name, value) in [("nil", Bool?.none), ("true", true), ("false", false)] {
            let b = MesoBlock(name: name, startDate: Date(), status: .archived, totalWeeks: 6)
            b.scheduledDeload = value
            source.insert(b)
        }
        try source.save()
        let target = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: target)
        let blocks = try ModelContext(target).fetch(FetchDescriptor<MesoBlock>())
        XCTAssertNil(blocks.first { $0.name == "nil" }?.scheduledDeload)
        XCTAssertEqual(blocks.first { $0.name == "true" }?.scheduledDeload, true)
        XCTAssertEqual(blocks.first { $0.name == "false" }?.scheduledDeload, false)
    }

    func test_anOldBackupWithoutTheKeyRestoresAsNil() throws {
        // The DTO field is optional with a nil default, so a backup written before it existed decodes.
        let json = #"{"name":"Old","startDate":0,"statusRaw":"archived","totalWeeks":6}"#
        let dto = try JSONDecoder().decode(MesoBlockBackupDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.scheduledDeload)
    }
}

// MARK: - "Use my own program"

final class OwnProgramTests: XCTestCase {

    private var parked: [ModelContainer] = []

    func test_theDefaultsAreTheDesignedOnes() {
        let c = OwnProgramBuilder.compoundDefault, i = OwnProgramBuilder.isolationDefault
        XCTAssertEqual([c.sets, c.repMin, c.repMax, c.rirMin, c.rirMax], [3, 6, 10, 2, 2])
        XCTAssertEqual([i.sets, i.repMin, i.repMax, i.rirMin, i.rirMax], [3, 10, 15, 1, 2])
        XCTAssertEqual(ProgramTemplate.wavelessDefaultWeeks, 8)
        let spec = OwnProgramSpec(days: [], totalWeeks: ProgramTemplate.wavelessDefaultWeeks)
        XCTAssertFalse(spec.deloadFinalWeek, "deload off by default")
        let bench = OwnProgramBuilder.newSlot(for: ExerciseCatalog.builtIn.first { $0.id == "bench_press" }!)
        let lateral = OwnProgramBuilder.newSlot(for: ExerciseCatalog.builtIn.first { $0.id == "dumbbell_lateral_raise" }!)
        XCTAssertTrue(bench.isCompound); XCTAssertEqual(bench.repMax, 10)
        XCTAssertFalse(lateral.isCompound); XCTAssertEqual(lateral.repMax, 15)
    }

    func test_copyDayMakesIndependentCopies_andIgnoresNonsense() {
        var days = OwnProgramBuilder.blankDays(count: 3, names: ["Upper", "Lower", "Upper"])
        days[0].slots = [.defaults(exerciseId: "bench_press", isCompound: true), .defaults(exerciseId: "hammer_curl", isCompound: false)]
        days[2].slots = [.defaults(exerciseId: "leg_press", isCompound: true)]
        let copied = OwnProgramBuilder.copyDay(days, from: 0, to: 2)
        XCTAssertEqual(copied[2].slots, days[0].slots)
        XCTAssertEqual(copied[2].title, "Upper", "the name stays")
        var edited = copied
        edited[2].slots[0].sets = 5
        XCTAssertEqual(copied[0].slots[0].sets, 3, "a copy is its own")
        XCTAssertEqual(OwnProgramBuilder.copyDay(days, from: 0, to: 0), days)
        XCTAssertEqual(OwnProgramBuilder.copyDay(days, from: 0, to: 9), days)
    }

    func test_repeatedNamesAreNumbered_distinctOnesAreLeftAlone() {
        XCTAssertEqual(OwnProgramBuilder.numberedNames(["Upper", "Lower", "Upper", "Lower", "Upper"]),
                       ["Upper A", "Lower A", "Upper B", "Lower B", "Upper C"])
        XCTAssertEqual(OwnProgramBuilder.numberedNames(["Push", "Pull", "Legs"]), ["Push", "Pull", "Legs"])
        XCTAssertEqual(OwnProgramBuilder.numberedNames(["Upper A", "Upper B"]), ["Upper A", "Upper B"])
        XCTAssertEqual(OwnProgramBuilder.numberedNames(["upper", "Upper"]), ["upper A", "Upper B"], "case does not hide a repeat")
        XCTAssertEqual(OwnProgramBuilder.suggestedNames(count: 5), ["Upper", "Lower", "Upper", "Lower", "Upper"])
    }

    func test_groupPrescriptionAppliesToOneKindOnly_andResizeKeepsWhatIsThere() {
        var days = OwnProgramBuilder.blankDays(count: 2, names: ["A", "B"])
        days[0].slots = [.defaults(exerciseId: "bench_press", isCompound: true), .defaults(exerciseId: "hammer_curl", isCompound: false)]
        var all = OwnProgramBuilder.compoundDefault; all.sets = 4; all.repMin = 5; all.repMax = 8; all.rirMin = 1; all.rirMax = 1
        let out = OwnProgramBuilder.applyPrescription(all, toCompounds: true, in: days)
        XCTAssertEqual([out[0].slots[0].sets, out[0].slots[0].repMin, out[0].slots[0].repMax, out[0].slots[0].rirMin], [4, 5, 8, 1])
        XCTAssertEqual(out[0].slots[1], days[0].slots[1], "isolations untouched")
        XCTAssertEqual(OwnProgramBuilder.resized(days, to: 4).count, 4)
        XCTAssertEqual(OwnProgramBuilder.resized(days, to: 4)[0].slots.count, 2)
        XCTAssertEqual(OwnProgramBuilder.resized(days, to: 4)[3].title, "Day 4")
        XCTAssertEqual(OwnProgramBuilder.resized(days, to: 2), days)
    }

    func test_validity() {
        var spec = OwnProgramSpec(days: OwnProgramBuilder.blankDays(count: 3, names: ["A", "B", "C"]))
        XCTAssertFalse(spec.isValid, "days need exercises")
        for i in spec.days.indices { spec.days[i].slots = [.defaults(exerciseId: "bench_press", isCompound: true)] }
        XCTAssertTrue(spec.isValid)
        spec.days[1].title = "  "
        XCTAssertFalse(spec.isValid, "a day needs a name")
        XCTAssertFalse(OwnProgramSpec(days: [WavelessDay(title: "Only", slots: [.defaults(exerciseId: "bench_press", isCompound: true)])]).isValid)
    }

    func test_theResultCarriesTheProgram_andOldResultsStillDecode() throws {
        var result = OnboardingDraft().result(startDate: Date(), weekdays: [2, 3, 5, 6])
        XCTAssertNil(result.ownProgram)
        result.ownProgram = OwnProgramSpec(name: "Mine", days: [WavelessDay(title: "Upper", slots: [.defaults(exerciseId: "bench_press", isCompound: true)])], totalWeeks: 6, deloadFinalWeek: true)
        let data = try JSONEncoder().encode(result)
        let back = try JSONDecoder().decode(OnboardingResult.self, from: data)
        XCTAssertEqual(back.ownProgram, result.ownProgram)
        // A result encoded before the field existed.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "ownProgram")
        let old = try JSONDecoder().decode(OnboardingResult.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.ownProgram)
    }

    func test_anAngelaCase_fiveDayUpperLower_seedsAsAWavelessBlock_throughTheSameApplyPath() throws {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        func day(_ title: String, _ ids: [String]) -> WavelessDay {
            WavelessDay(title: title, slots: ids.map { id in OwnProgramBuilder.newSlot(for: ExerciseCatalog.builtIn.first { $0.id == id }!) })
        }
        let spec = OwnProgramSpec(name: "Angela's split", days: [
            day("Upper A", ["bench_press", "barbell_row", "dumbbell_lateral_raise", "cable_tricep_rope_pushdown", "barbell_curl"]),
            day("Lower A", ["barbell_back_squat", "romanian_deadlift", "leg_extension", "seated_leg_curl", "seated_calf_raise"]),
            day("Upper B", ["machine_chest_press", "wide_grip_pulldown", "cable_face_pull", "hammer_curl", "pec_deck"]),
            day("Lower B", ["leg_press", "lying_leg_curl", "leg_extension", "seated_calf_raise", "cable_rope_crunch"]),
            day("Upper C", ["dumbbell_shoulder_press", "seated_cable_row", "incline_rear_delt_fly", "overhead_rope_tricep_extension", "incline_dumbbell_curl"]),
        ], totalWeeks: 8, deloadFinalWeek: false)
        XCTAssertTrue(spec.isValid)
        var result = OnboardingDraft().result(startDate: Calendar.current.startOfDay(for: Date()), weekdays: [2, 3, 4, 5, 6])
        result.ownProgram = spec
        result.daysPerWeek = 5
        result.trainingDaysOfWeek = [2, 3, 4, 5, 6]
        switch ProgramApplicationService.apply(result, context: ctx, startDate: result.startDate) {
        case .success: break
        case .failure(let e): return XCTFail(e.message)
        }
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first { $0.status == .active })
        XCTAssertEqual(block.name, "Angela's split")
        XCTAssertEqual(block.totalWeeks, 8)
        XCTAssertEqual(block.scheduledDeload, false)
        XCTAssertEqual(block.sessions.count, 40)
        XCTAssertTrue(block.sessions.flatMap(\.items).allSatisfy { $0.waveRaw == nil })
        XCTAssertEqual(Set(block.sessions.compactMap(\.dayLabel)), ["Upper A", "Lower A", "Upper B", "Lower B", "Upper C"])
        XCTAssertEqual(block.sessions.filter { $0.dayLabel == "Upper A" }.first?.items.count, 5, "exactly the five she chose; nothing fitted away")
        XCTAssertTrue(block.sessions.allSatisfy { $0.mesoPhase != .deload })
    }

    func test_bothEntryPointsAndTheSharedPickerAreWiredUp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func text(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let onboarding = try text("Features/Onboarding/OnboardingFlowView.swift")
        XCTAssertTrue(onboarding.contains("Use my own program"), "on the first page of onboarding, which Change program also opens")
        XCTAssertTrue(onboarding.contains("OwnProgramFlowView(base: currentBaseResult()"))
        XCTAssertTrue(onboarding.contains("submit(result, overrides: .empty)"), "the result goes through the same onComplete as every program")
        let home = try text("Features/Home/HomeView.swift")
        XCTAssertTrue(home.contains("OnboardingFlowView("), "Change program opens the onboarding flow")
        XCTAssertTrue(home.contains("Replace your upcoming sessions?"), "and still asks before replacing")
        let flow = try text("Features/Programs/OwnProgramFlowView.swift")
        XCTAssertTrue(flow.contains("ExercisePickerList(mode: .add"), "the shared picker")
        XCTAssertTrue(flow.contains("PlannedVolumeCard(input: .template("), "the preview has the volume card")
        XCTAssertTrue(flow.contains("Copy day"))
        let service = try text("Domain/Logic/ProgramApplicationService.swift")
        XCTAssertTrue(service.contains("result.ownProgram?.template ?? fittedProgram(for: result).template"))
    }
}

// MARK: - Startup backfills: dry run on a real backup

final class StartupBackfillsDryRunTests: XCTestCase {

    private func fp(_ item: SessionItem, _ s: Session) -> [String: String] {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        return [
            "exercise": item.exerciseId, "name": item.exerciseNameSnapshot ?? "-", "suggested": n(item.suggestedLoad),
            "planned loads": item.plannedLoadsBySet.map(n).joined(separator: "/"), "sets": "\(item.targetSets)",
            "reps": "\(item.repMin ?? -1)-\(item.repMax ?? -1)", "planEdited": "\(item.planEdited)", "coach note": item.coachNote ?? "-",
            "prescription note": item.prescriptionNotes ?? "-", "RIRs": item.actualRIRs.map(String.init).joined(separator: "/"),
            "wave": item.waveRaw ?? "-", "prescribed": item.prescribedSets.map(String.init) ?? "-",
        ]
    }

    private struct Snapshot { var items: [String: [String: String]]; var sessions: [String: [String: String]]; var blocks: [String: [String: String]]; var customs: [String: [String: String]] }

    private func snapshot(_ ctx: ModelContext) throws -> Snapshot {
        var items: [String: [String: String]] = [:], sessions: [String: [String: String]] = [:]
        let all = try ctx.fetch(FetchDescriptor<Session>())
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        for s in all {
            let key = s.id?.uuidString ?? "\(s.persistentModelID)"
            sessions[key] = ["date": f.string(from: s.date), "status": s.status.rawValue, "dayLabel": s.dayLabel ?? "-", "week": "\(s.weekIndex)",
                             "planned date": s.plannedDate.map { f.string(from: $0) } ?? "-", "block": s.meso?.name ?? "-"]
            for i in s.items { items["\(key)|\(i.id?.uuidString ?? "\(i.persistentModelID)")"] = fp(i, s).merging(["_where": "\(f.string(from: s.date)) wk\(s.weekIndex) \(s.dayLabel ?? "-")"]) { a, _ in a } }
        }
        let blocks = Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<MesoBlock>()).map {
            ($0.id?.uuidString ?? $0.name, ["name": $0.name, "start": f.string(from: $0.startDate), "status": $0.status.rawValue, "weeks": "\($0.totalWeeks ?? -1)", "maintenance": "\($0.isMaintenance)"])
        })
        var customs: [String: [String: String]] = [:]
        var seen: [String: Int] = [:]
        for c in try ctx.fetch(FetchDescriptor<CustomExercise>()) {
            seen[c.id, default: 0] += 1
            let key = seen[c.id] == 1 ? c.id : "\(c.id)#\(seen[c.id]!)"          // a duplicate record shows up as its own entry
            customs[key] = ["name": c.name, "compound": "\(c.isCompound.map(String.init) ?? "nil")", "fine": c.fineMuscleRaw ?? "-"]
        }
        return Snapshot(items: items, sessions: sessions, blocks: blocks, customs: customs)
    }

    private func diff(_ a: [String: [String: String]], _ b: [String: [String: String]], label: (String, [String: String]) -> String) -> [String] {
        var out: [String] = []
        for (k, new) in b.sorted(by: { $0.key < $1.key }) {
            guard let old = a[k] else { out.append("  + new \(label(k, new))"); continue }
            let changes = new.filter { $0.key != "_where" && old[$0.key] != $0.value }.sorted { $0.key < $1.key }
            if !changes.isEmpty { out.append("  \(label(k, new)): " + changes.map { "\($0.key) \(old[$0.key] ?? "-") -> \($0.value)" }.joined(separator: "; ")) }
        }
        for (k, old) in a where b[k] == nil { out.append("  - removed \(label(k, old))") }
        return out
    }

    /// LOCAL ONLY. Imports a real backup into an in-memory store, runs every REGISTERED startup backfill in order, and lists what each changed
    /// (old -> new). Nothing is saved anywhere else; the registration is not touched.
    func test_audit_everyRegisteredStartupBackfill_onTheLatestBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        // The device-local completion flags decide whether a one-shot runs: a real device that took this backup has them set for the
        // migrations it already ran. Clear none of them; this reports what a launch of this head would do on a device with fresh flags
        // for exactly the backfills that are idempotent, plus (separately) with every flag cleared.
        // EP_CLEAR_FLAGS=1: also forget every one-shot completion flag (what a store whose flags were lost would run), then restore them.
        var savedFlags: [String: Any] = [:]
        if ProcessInfo.processInfo.environment["EP_CLEAR_FLAGS"] == "1" {
            for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasSuffix(".completed") { savedFlags[k] = v; UserDefaults.standard.removeObject(forKey: k) }
        }
        defer { for (k, v) in savedFlags { UserDefaults.standard.set(v, forKey: k) } }
        var lines: [String] = ["STARTUP BACKFILL DRY RUN — in-memory copy of \((path as NSString).lastPathComponent); nothing was saved"]
        let start = try snapshot(ctx)
        lines.append("store: \(start.sessions.count) sessions, \(start.items.count) items, \(start.blocks.count) blocks, \(start.customs.count) custom exercises")
        var current = start
        var totalItemChanges = 0
        for backfill in StartupBackfills.registered {
            BackfillLog.collector = []
            backfill.run(ctx)
            let notes = BackfillLog.collector ?? []
            BackfillLog.collector = nil
            let after = try snapshot(ctx)
            let itemDiff = diff(current.items, after.items) { _, v in "\(v["_where"] ?? "?") \(ExerciseCatalog.displayName(for: v["exercise"] ?? ""))" }
            let sessionDiff = diff(current.sessions, after.sessions) { k, v in "session \(v["date"] ?? "?") \(v["dayLabel"] ?? "")" }
            let blockDiff = diff(current.blocks, after.blocks) { _, v in "block \(v["name"] ?? "?")" }
            let customDiff = diff(current.customs, after.customs) { _, v in "custom \(v["name"] ?? "?")" }
            lines.append("\n\(backfill.name): \(BackfillLog.result(from: notes)) — \(itemDiff.count) item change(s), \(sessionDiff.count) session, \(blockDiff.count) block, \(customDiff.count) custom")
            for l in itemDiff + sessionDiff + blockDiff + customDiff { lines.append(l) }
            totalItemChanges += itemDiff.count
            current = after
        }
        lines.append("\nTOTAL item changes across all registered backfills: \(totalItemChanges)")
        let text = lines.joined(separator: "\n")
        print(text)
        if let out = ProcessInfo.processInfo.environment["EP_AUDIT_REPORT_OUT"], !out.isEmpty { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

// MARK: - PlaceholderRefresh on Angela's backups (1.2.2 -> what a 1.3.1 first launch writes, against the actual 1.3.0 result)

/// LOCAL fixtures (health data, not committed). TEST_RUNNER_EP_ANGELA_122 = the 1.2.2 backup, TEST_RUNNER_EP_ANGELA_130 = the 1.3.0 backup that
/// first launch produced. Skipped when they are not set (`scripts/full_gate.sh` sets them when the files are in ~/Downloads).
final class PlaceholderRefreshAngelaFixtureTests: XCTestCase {

    struct Row: Equatable {
        var date: String, day: String, wave: String, name: String, exerciseId: String
        var planEdited: Bool, status: String
        var load: String, planned: String, coach: String, prescription: String
        var summary: String { "\(date) · \(day) · \(wave) · \(name)" }
    }

    private func path(_ key: String) throws -> String {
        guard let p = ProcessInfo.processInfo.environment[key], !p.isEmpty, FileManager.default.fileExists(atPath: p) else {
            throw XCTSkip("set TEST_RUNNER_\(key) to the Angela fixture")
        }
        return p
    }

    private func importStore(_ path: String) throws -> ModelContext {
        let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        keep.append(container)
        return ctx
    }
    private var keep: [ModelContainer] = []

    private func rows(_ ctx: ModelContext) throws -> [String: Row] {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        var out: [String: Row] = [:]
        for s in try ctx.fetch(FetchDescriptor<Session>()) {
            for i in s.items {
                out[i.id?.uuidString ?? "\(i.persistentModelID)"] = Row(
                    date: f.string(from: s.date), day: s.dayLabel ?? "-", wave: (i.waveRaw ?? "-").uppercased(),
                    name: i.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: i.exerciseId), exerciseId: i.exerciseId,
                    planEdited: i.planEdited, status: s.status.rawValue, load: n(i.suggestedLoad),
                    planned: i.plannedLoadsBySet.map(n).joined(separator: "/"), coach: i.coachNote ?? "", prescription: i.prescriptionNotes ?? "")
            }
        }
        return out
    }

    /// Imports the 1.2.2 backup, forgets the one-shot flags (a first launch of the new build), runs every registered startup backfill in order, and
    /// returns the resulting rows plus the refresh's own changes (with reasons) taken just before it ran.
    private func launch122() throws -> (rows: [String: Row], reasons: [String: String], ctx: ModelContext) {
        let ctx = try importStore(try path("EP_ANGELA_122"))
        var saved: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasSuffix(".completed") { saved[k] = v; UserDefaults.standard.removeObject(forKey: k) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        var reasons: [String: String] = [:]
        for b in StartupBackfills.registered {
            if b.name.contains("PlaceholderRefresh") {
                for c in PlaceholderRefresh.plan(in: ctx) { reasons[c.item.id?.uuidString ?? "\(c.item.persistentModelID)"] = c.reason.text }
            }
            b.run(ctx)
        }
        return (try rows(ctx), reasons, ctx)
    }

    func test_report_122ThroughTheChangedRefresh_versusTheActual130() throws {
        let r = try launch122()
        let actual = try rows(try importStore(try path("EP_ANGELA_130")))
        var lines = ["1.2.2 backup through this head's startup backfills, versus the 1.3.0 backup (the actual first-launch result)", ""]
        var n = 0
        for (k, new) in r.rows.sorted(by: { ($0.value.date, $0.value.day, $0.value.name) < ($1.value.date, $1.value.day, $1.value.name) }) {
            guard let old = actual[k], old != new else { continue }
            n += 1
            lines.append("\(new.summary) · load \(old.load) → \(new.load) · planned [\(old.planned)] → [\(new.planned)] · coach note: \(old.coach.isEmpty ? "-" : old.coach) → \(new.coach.isEmpty ? "-" : new.coach) · prescription note: \(old.prescription.isEmpty ? "-" : old.prescription) → \(new.prescription.isEmpty ? "-" : new.prescription)")
            if let why = r.reasons[k] { lines.append("    ↳ \(why)") }
        }
        lines.append("\n\(n) item(s) differ from the 1.3.0 backup")
        let text = lines.joined(separator: "\n"); print(text)
        if let out = ProcessInfo.processInfo.environment["EP_ANGELA_REPORT_OUT"], !out.isEmpty { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    }

    /// Angela's 1.3.0 backup (the actual first-launch result) through the refresh alone: the only change that is not a load write is the removal of the
    /// "set a load" note from her two Hanging Knee Raise items (Dec 3 and Dec 10), which the bodyweight classification made stale.
    func test_130_staleNoteIsRemovedFromTheHangingKneeRaiseItems_andNothingElseChangesBesideTheLoadWrites() throws {
        let ctx = try importStore(try path("EP_ANGELA_130"))
        let before = try rows(ctx)
        let changes = PlaceholderRefresh.run(in: ctx)
        let after = try rows(ctx)
        let cleared = changes.filter { $0.noteField == .clearNoHistory }
        XCTAssertEqual(Set(cleared.map { ($0.item.exerciseNameSnapshot ?? "", $0.session.dayLabel ?? "") }.map { "\($0.0)|\($0.1)" }), ["Hanging Knee Raise|Lower C"])
        XCTAssertEqual(cleared.count, 2, "Dec 3 and Dec 10")
        let differing = after.filter { before[$0.key] != nil && before[$0.key] != $0.value }
        let noteOnly = differing.filter { before[$0.key]?.load == $0.value.load && before[$0.key]?.planned == $0.value.planned && before[$0.key]?.coach == $0.value.coach }
        XCTAssertEqual(noteOnly.count, 2)
        for (k, new) in noteOnly {
            XCTAssertEqual(new.name, "Hanging Knee Raise"); XCTAssertEqual(new.prescription, "")
            XCTAssertTrue(before[k]?.prescription.contains(PlaceholderRefresh.noRecentHistoryNote) == true)
            XCTAssertEqual(["Dec 3", "Dec 10"].contains(new.date), true, new.summary)
        }
        XCTAssertEqual(differing.count - noteOnly.count, 12, "the rest are the hold / cross-day load writes")
        XCTAssertTrue(PlaceholderRefresh.plan(in: ctx).isEmpty, "a second pass changes nothing")
    }

    func test_122ThroughTheChangedRefresh_isTheActual130_plusExactlyTheHoldAndCrossDayWrites() throws {
        let r = try launch122()
        let actual = try rows(try importStore(try path("EP_ANGELA_130")))
        let differing = r.rows.filter { actual[$0.key] != nil && actual[$0.key] != $0.value }
        XCTAssertEqual(differing.count, 14, "every difference from the 1.3.0 backup is one of the writes pinned below")

        func row(_ date: String, _ day: String, _ name: String) -> Row? { r.rows.values.first { $0.date == date && $0.day == day && $0.name == name } }
        // Hold from the Nov 20 Lower A 15-rep sets (same day).
        for (date, wave) in [("Nov 27", "B"), ("Dec 4", "C")] {
            let press = try XCTUnwrap(row(date, "Lower A", "Single leg press")), abd = try XCTUnwrap(row(date, "Lower A", "Cable Abduction"))
            XCTAssertEqual(press.load, "145", date); XCTAssertEqual(press.wave, wave); XCTAssertEqual(abd.load, "42.5", date)
            XCTAssertEqual(press.coach, "Held from your recent A-week sets — set 1 calibrates.")
            XCTAssertEqual(abd.coach, "Held from your recent A-week sets — set 1 calibrates.")
            XCTAssertFalse(press.prescription.contains(PlaceholderRefresh.noRecentHistoryNote), "the stale note is gone"); XCTAssertFalse(abd.prescription.contains(PlaceholderRefresh.noRecentHistoryNote))
        }
        // Cross-day: Lower C has no history of its own, so the lifts come from the Nov 20 Lower A session. (Nov 26 Lower C is week 1 and
        // planEdited: it already plans these loads and is untouched.)
        for date in ["Dec 3", "Dec 10"] {
            XCTAssertEqual(row(date, "Lower C", "Single leg press")?.load, "145", date)
            XCTAssertEqual(row(date, "Lower C", "Cable Abduction")?.load, "42.5", date)
            XCTAssertEqual(row(date, "Lower C", "Seated Calf Raise")?.load, "151", date)
            XCTAssertEqual(row(date, "Lower C", "Seated Calf Raise")?.coach, "Estimated from your Lower A sets — set 1 calibrates.")
            XCTAssertEqual(row(date, "Lower C", "Single leg press")?.coach, "Held from your Lower A sets — set 1 calibrates.")
        }
        // Unchanged: the Nov 20 session, Dec 11, every planEdited item, Copenhagen.
        for (k, new) in r.rows {
            guard let old = actual[k] else { continue }
            if old.date == "Nov 20" || old.date == "Dec 11" || old.planEdited || old.name == "Copenhagen" {
                XCTAssertEqual(new, old, "\(old.summary) must not change")
            }
        }
        // Bodyweight classification: Hanging Knee Raise (built-in, bodyweight) loses "set a load"; the loadable ones keep it.
        for new in r.rows.values where new.name == "Hanging Knee Raise" && !new.planEdited { XCTAssertFalse(new.prescription.contains(PlaceholderRefresh.noRecentHistoryNote), new.summary) }
        var keptNote = 0
        for (k, new) in r.rows where ["Weighted Dead Bug", "Kettle Balance Abs", "Archer Pull"].contains(new.name) && !new.planEdited {
            guard actual[k]?.prescription.contains(PlaceholderRefresh.noRecentHistoryNote) == true else { continue }   // only the items 1.3.0 noted
            XCTAssertTrue(new.prescription.contains(PlaceholderRefresh.noRecentHistoryNote), new.summary); keptNote += 1
        }
        XCTAssertGreaterThan(keptNote, 0)
        // Idempotent: a second pass over the result changes nothing.
        let again = PlaceholderRefresh.plan(in: r.ctx)
        XCTAssertTrue(again.isEmpty, again.map { "\($0.session.dayLabel ?? "-") \($0.item.exerciseNameSnapshot ?? "-") \($0.oldLoad)->\($0.newLoad) \($0.reason.text)" }.joined(separator: " | "))
    }
}

// MARK: - PlaceholderRefresh: hold from a high-rep source, cross-day source, stale note, bodyweight classification

/// Angela's real shapes (Single leg press / Cable Abduction 15-rep sets, Seated Calf Raise, Copenhagen), rebuilt by hand. "Today" is Tue Nov 17 2026.
final class PlaceholderRefreshHoldAndCrossDayTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current
    private func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 9))! }
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 20))! }
    private let sep22 = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!

    private func context() throws -> (ModelContext, MesoBlock) {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        let meso = MesoBlock(name: "5-Day Upper / Lower + Pump", startDate: day(9, 25), status: .active, totalWeeks: 10)
        meso.createdAt = day(8, 1)
        ctx.insert(meso)
        return (ctx, meso)
    }

    @discardableResult
    private func session(_ ctx: ModelContext, _ meso: MesoBlock, _ date: Date, _ status: SessionStatus, week: Int, label: String, _ items: [SessionItem]) -> Session {
        let s = Session(date: date, status: status, weekIndex: week, dayLabel: label, items: items)
        s.meso = meso; ctx.insert(s); meso.sessions.append(s)
        return s
    }

    private func item(_ id: String, wave: String, sets: Int = 3, repMin: Int, repMax: Int, rir: Int = 2, suggested: Double = 0,
                      actual: [Double] = [], reps: [Int] = [], rirs: [Int] = [], edited: Bool = false) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: repMin, targetSets: sets, targetRIR: rir, suggestedLoad: suggested,
                            waveRaw: wave, priorityRaw: "standard", repMin: repMin, repMax: repMax, targetRIRMin: rir, targetRIRMax: rir,
                            plannedRepsBySet: Array(repeating: repMin, count: sets),
                            plannedLoadsBySet: Array(repeating: suggested, count: sets),
                            plannedRIRsBySet: Array(repeating: rir, count: sets),
                            actualReps: reps, actualLoads: actual, actualRIRs: rirs,
                            restPausePatternsBySet: Array(repeating: "", count: sets), setFeedbackBySet: Array(repeating: "", count: sets))
        i.planEdited = edited
        i.updatedAt = sep22
        return i
    }

    /// Nov 10 Lower A (a): leg press 145 x 15 at RIR 0, four sets.
    private func legPressSource(_ ctx: ModelContext, _ meso: MesoBlock, date: Date? = nil, load: Double = 145, reps: Int = 15, rir: Int = 0, label: String = "Lower A") {
        let done = item("leg_press", wave: "a", sets: 4, repMin: 12, repMax: 15, rir: 1, suggested: load,
                        actual: Array(repeating: load, count: 4), reps: Array(repeating: reps, count: 4), rirs: Array(repeating: rir, count: 4), edited: true)
        session(ctx, meso, date ?? day(11, 10), .completed, week: 1, label: label, [done])
    }

    // MARK: hold from a high-rep source

    func test_hold_aHighRepSourceIsHeldAtItsOwnLoad_ifItCoversTheTargetsRepMin() throws {
        let (ctx, meso) = try context()
        legPressSource(ctx, meso)
        let target = item("leg_press", wave: "b", repMin: 12, repMax: 15, rir: 2)
        session(ctx, meso, day(11, 24), .planned, week: 2, label: "Lower A", [target])
        let changes = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(target.suggestedLoad, 145, "15 reps - max(0, 2 - 0) = 13 >= 12: held, no estimate (15 reps is not a 12-rep source)")
        XCTAssertEqual(target.plannedLoadsBySet, [145, 145, 145])
        XCTAssertEqual(target.coachNote, "Held from your recent A-week sets — set 1 calibrates.")
        XCTAssertFalse(target.planEdited)
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "idempotent")
    }

    func test_hold_notWrittenWhenTheReserveCannotCoverTheRepMin() throws {
        let (ctx, meso) = try context()
        legPressSource(ctx, meso, reps: 13, rir: 0)                       // 13 - max(0, 2 - 0) = 11 < 12
        let target = item("leg_press", wave: "b", repMin: 12, repMax: 15, rir: 2)
        session(ctx, meso, day(11, 24), .planned, week: 2, label: "Lower A", [target])
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 0)
        XCTAssertEqual(target.prescriptionNotes, PlaceholderRefresh.noRecentHistoryNote)
        // The same source at RIR 2 has no reserve to spend (target RIR 2 - set RIR 2 = 0): 13 >= 12, held.
        let (ctx2, meso2) = try context()
        legPressSource(ctx2, meso2, reps: 13, rir: 2)
        let target2 = item("leg_press", wave: "b", repMin: 12, repMax: 15, rir: 2)
        session(ctx2, meso2, day(11, 24), .planned, week: 2, label: "Lower A", [target2])
        PlaceholderRefresh.run(in: ctx2, now: now)
        XCTAssertEqual(target2.suggestedLoad, 145)
    }

    func test_hold_usesTheMostRecentQualifyingSet_andNeverRaises() throws {
        let (ctx, meso) = try context()
        legPressSource(ctx, meso, date: day(11, 3), load: 150)            // older and heavier
        legPressSource(ctx, meso, date: day(11, 10), load: 145)
        let target = item("leg_press", wave: "b", repMin: 12, repMax: 15, rir: 2)
        session(ctx, meso, day(11, 24), .planned, week: 2, label: "Lower A", [target])
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.suggestedLoad, 145, "the most recent session's set, not the heavier older one")
    }

    func test_estimateStillWinsWhenASourceSetHasTwelveRepsOrFewer() throws {
        let (ctx, meso) = try context()
        let done = item("leg_press", wave: "a", sets: 3, repMin: 8, repMax: 12, rir: 1, suggested: 200,
                        actual: [200, 200, 200], reps: [10, 10, 10], rirs: [1, 1, 1], edited: true)
        session(ctx, meso, day(11, 10), .completed, week: 1, label: "Lower A", [done])
        let target = item("leg_press", wave: "b", repMin: 8, repMax: 12, rir: 2)
        session(ctx, meso, day(11, 24), .planned, week: 2, label: "Lower A", [target])
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.coachNote, "Estimated from your recent A-week sets — set 1 calibrates.")
    }

    // MARK: cross-day

    func test_crossDay_aLiftNeverDoneOnThisDayIsTakenFromTheDayItWasDone() throws {
        let (ctx, meso) = try context()
        legPressSource(ctx, meso)                                          // done on Lower A only
        let calfDone = item("seated_calf_raise", wave: "a", sets: 4, repMin: 12, repMax: 15, rir: 1, suggested: 151,
                            actual: [151, 151, 151, 151], reps: [15, 12, 12, 15], rirs: [0, 0, 0, 0], edited: true)
        session(ctx, meso, day(11, 11), .completed, week: 1, label: "Lower A", [calfDone])
        let press = item("leg_press", wave: "b", repMin: 8, repMax: 12, rir: 2)
        let calf = item("seated_calf_raise", wave: "b", repMin: 8, repMax: 12, rir: 2)
        session(ctx, meso, day(11, 25), .planned, week: 2, label: "Lower C", [press, calf])
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(press.suggestedLoad, 145, "15 reps - max(0, 2 - 0) = 13 >= 8: held from Lower A")
        XCTAssertEqual(press.coachNote, "Held from your Lower A sets — set 1 calibrates.")
        // e1RM 151 x (1 + 12/30) = 211.4; 12 reps at RIR 2: 211.4 / (1 + 14/30) x 0.95 = 136.9 -> 135 rounded down, floored to the 12-rep set's 151.
        XCTAssertEqual(calf.suggestedLoad, 151)
        XCTAssertEqual(calf.coachNote, "Estimated from your Lower A sets — set 1 calibrates.")
    }

    func test_crossDay_isLastPriority_aSameDaySourceWins() throws {
        let (ctx, meso) = try context()
        legPressSource(ctx, meso)                                          // Lower A: 145 x 15
        let c = item("leg_press", wave: "a", sets: 3, repMin: 8, repMax: 12, rir: 1, suggested: 100,
                     actual: [100, 100, 100], reps: [10, 10, 10], rirs: [1, 1, 1], edited: true)
        session(ctx, meso, day(11, 12), .completed, week: 1, label: "Lower C", [c])
        let press = item("leg_press", wave: "b", repMin: 8, repMax: 12, rir: 2)
        session(ctx, meso, day(11, 25), .planned, week: 2, label: "Lower C", [press])
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(press.coachNote, "Estimated from your recent A-week sets — set 1 calibrates.", "the same-day (Lower C) estimate, not the Lower A hold")
        XCTAssertLessThan(press.suggestedLoad, 145)
    }

    func test_crossDay_ignoresASourceOlderThanTwoRotations_andAnEditedTarget() throws {
        let (ctx, meso) = try context()
        legPressSource(ctx, meso, date: day(9, 1))                         // 12+ weeks before: outside two A/B/C rotations (letters a, b below)
        let press = item("leg_press", wave: "b", repMin: 8, repMax: 12, rir: 2)
        let edited = item("leg_press", wave: "b", repMin: 8, repMax: 12, rir: 2, edited: true)
        session(ctx, meso, day(11, 25), .planned, week: 2, label: "Lower C", [press])
        session(ctx, meso, day(11, 26), .planned, week: 2, label: "Lower D", [edited])
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(press.suggestedLoad, 0)
        XCTAssertEqual(press.prescriptionNotes, PlaceholderRefresh.noRecentHistoryNote)
        XCTAssertEqual(edited.suggestedLoad, 0)
        XCTAssertNil(edited.prescriptionNotes, "a planEdited item is never touched")
    }

    // MARK: the stale note

    func test_staleNote_refreshWritesIt_completingTheSourceSessionWritesTheLoadAndClearsIt() throws {
        let (ctx, meso) = try context()
        let source = item("cable_curl", wave: "a", sets: 3, repMin: 10, repMax: 12, rir: 2)
        let target = item("cable_curl", wave: "a", sets: 3, repMin: 10, repMax: 12, rir: 2)
        let sourceSession = session(ctx, meso, day(11, 10), .planned, week: 1, label: "Upper B", [source])   // missed so far: no history
        session(ctx, meso, day(11, 24), .planned, week: 4, label: "Upper B", [target])
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(target.prescriptionNotes, PlaceholderRefresh.noRecentHistoryNote)
        XCTAssertEqual(target.suggestedLoad, 0)

        // The source session is performed late: sets logged, session completed, carry-forward writes.
        source.actualLoads = [60, 60, 60]; source.actualReps = [12, 12, 12]; source.actualRIRs = [2, 2, 2]
        source.suggestedLoad = 60; source.plannedLoadsBySet = [60, 60, 60]
        sourceSession.status = .completed
        PlanMemoryEngine(context: ctx).carryForwardPlans(from: sourceSession)
        XCTAssertGreaterThan(target.suggestedLoad, 0, "carry-forward wrote a load")
        XCTAssertNil(target.prescriptionNotes, "the note no longer holds")
    }

    func test_staleNote_isRemovedOnEveryPass_fromAnyUneditedItemWithALoadOrOneTheRefreshNeverLoads() throws {
        let (ctx, meso) = try context()
        let note = PlaceholderRefresh.noRecentHistoryNote
        func noted(_ id: String, load: Double, edited: Bool = false, extra: String = "") -> SessionItem {
            let i = item(id, wave: "b", repMin: 8, repMax: 12, rir: 2, suggested: load, edited: edited)
            i.prescriptionNotes = (extra.isEmpty ? "" : extra + " ") + note
            return i
        }
        let loaded = noted("cable_curl", load: 40)                                    // has a load: stale
        let bodyweight = noted("hanging_knee_raise", load: 0, extra: "Strict.")       // never loaded: stale, other text stays
        let zero = noted("cable_curl", load: 0)                                        // loadable and empty: the note is true
        let edited = noted("cable_curl", load: 40, edited: true)                      // hand-edited: not touched
        session(ctx, meso, day(11, 25), .planned, week: 2, label: "Lower C", [loaded, bodyweight, zero, edited])
        // `zero` is a second cable_curl with no history: it keeps the note (and gets nothing to write)
        let first = PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertNil(loaded.prescriptionNotes)
        XCTAssertEqual(bodyweight.prescriptionNotes, "Strict.")
        XCTAssertEqual(edited.prescriptionNotes, note)
        XCTAssertGreaterThanOrEqual(first.filter { $0.noteField == .clearNoHistory }.count, 2)
        XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).filter { $0.noteField == .clearNoHistory }.isEmpty, "idempotent")
        _ = zero
    }

    func test_staleNote_onlyTheNoHistoryText_isRemoved_whenALoadIsWritten() throws {
        let i = item("cable_curl", wave: "a", repMin: 10, repMax: 12)
        i.prescriptionNotes = "Slow negatives. " + PlaceholderRefresh.noRecentHistoryNote
        PlaceholderRefresh.clearStaleNoHistoryNote(i)
        XCTAssertEqual(i.prescriptionNotes, "Slow negatives. " + PlaceholderRefresh.noRecentHistoryNote, "no load yet: the note stays")
        i.suggestedLoad = 40
        PlaceholderRefresh.clearStaleNoHistoryNote(i)
        XCTAssertEqual(i.prescriptionNotes, "Slow negatives.")
    }

    // MARK: bodyweight classification

    func test_bodyweight_eligibleKeysOnTheCatalogOrTheCustomExercisesFlag() throws {
        for id in ["hanging_knee_raise", "hanging_straight_leg_raise", "toes_to_bar", "pull_up", "push_up", "nordic_curl"] {
            XCTAssertTrue(ExerciseCatalog.isBodyweight(exerciseId: id), id)
        }
        for id in ["cable_rope_crunch", "dead_bug", "russian_twist", "leg_press"] { XCTAssertFalse(ExerciseCatalog.isBodyweight(exerciseId: id), id) }
        let (ctx, meso) = try context()
        let knee = item("hanging_knee_raise", wave: "b", repMin: 8, repMax: 12, rir: 2)
        let crunch = item("cable_rope_crunch", wave: "b", repMin: 8, repMax: 12, rir: 2)
        session(ctx, meso, day(11, 25), .planned, week: 2, label: "Lower C", [knee, crunch])
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertNil(knee.prescriptionNotes, "a truly bodyweight lift never gets \"set a load\"")
        XCTAssertEqual(crunch.prescriptionNotes, PlaceholderRefresh.noRecentHistoryNote, "a loadable one keeps the note")
    }
}

// MARK: - Duplicate custom exercise rows never trap a launch

/// A store with several rows for one custom id (what CustomExerciseStoreMigration leaves when a restore runs it again over existing rows)
/// used to crash CustomExerciseDedupMigration in `Dictionary(uniqueKeysWithValues:)` on every launch. Now the launch collapses them.
final class CustomExerciseDuplicateRowsTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current
    private func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 9))! }

    private func item(_ id: String, name: String) -> SessionItem {
        SessionItem(order: 1, exerciseId: id, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 40,
                    waveRaw: "a", priorityRaw: "standard", repMin: 8, repMax: 12, targetRIRMin: 2, targetRIRMax: 2,
                    plannedRepsBySet: [10, 10, 10], plannedLoadsBySet: [40, 40, 40], plannedRIRsBySet: [2, 2, 2],
                    actualReps: [10, 10, 10], actualLoads: [40, 40, 40], actualRIRs: [2, 2, 2],
                    restPausePatternsBySet: ["", "", ""], setFeedbackBySet: ["", "", ""])
    }

    /// Runs `body` with every completion flag and the custom-exercise mirror cleared (a first launch), and puts them back.
    private func withCleanDefaults(_ body: (_ clearFlags: () -> Void) throws -> Void) rethrows {
        let d = UserDefaults.standard
        func flagKeys() -> [String] { d.dictionaryRepresentation().keys.filter { $0.hasSuffix(".completed") } + ["custom_exercises_v2"] }
        var saved: [String: Any] = [:]
        for k in flagKeys() { if let v = d.object(forKey: k) { saved[k] = v } }
        defer { for k in flagKeys() { d.removeObject(forKey: k) }; for (k, v) in saved { d.set(v, forKey: k) } }
        for k in flagKeys() { d.removeObject(forKey: k) }
        try body({ for k in flagKeys() { d.removeObject(forKey: k) } })
    }

    func test_duplicateCustomIds_launch_dedupToOneRowPerId_andEveryItemKeepsItsExerciseId() throws {
        try withCleanDefaults { clearFlags in
            let c = try ModelContainer(for: AppSchema.makeSchema(),
                                       configurations: ModelConfiguration("dup-\(UUID().uuidString)", isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            parked.append(c)
            let ctx = ModelContext(c)
            func insertDuplicates() {
                // Archer Pull: three rows; the oldest (Jan 5) is the canonical one. Kettle: two rows with the SAME createdAt. Landmine Press:
                // two rows whose name is also a built-in (the migration remaps its items to the built-in id).
                ctx.insert(CustomExercise(id: "custom_archer", name: "Archer Pull", primaryMuscleRaw: "back", isCompound: true, createdAt: day(3, 1)))
                ctx.insert(CustomExercise(id: "custom_archer", name: "Archer Pull", primaryMuscleRaw: "back", isCompound: true, createdAt: day(1, 5)))
                ctx.insert(CustomExercise(id: "custom_archer", name: "Archer Pull", primaryMuscleRaw: "back", isCompound: true, createdAt: day(2, 1)))
                ctx.insert(CustomExercise(id: "custom_kettle", name: "Kettle Balance Abs", primaryMuscleRaw: "core", isCompound: false, createdAt: day(2, 2)))
                ctx.insert(CustomExercise(id: "custom_kettle", name: "Kettle Balance Abs", primaryMuscleRaw: "core", isCompound: false, createdAt: day(2, 2)))
                ctx.insert(CustomExercise(id: "custom_landmine", name: "Landmine Press", primaryMuscleRaw: "shoulders", isCompound: true, createdAt: day(1, 9)))
                ctx.insert(CustomExercise(id: "custom_landmine", name: "Landmine Press", primaryMuscleRaw: "shoulders", isCompound: true, createdAt: day(1, 9)))
            }
            insertDuplicates()
            let s = Session(date: day(2, 10), status: .completed, weekIndex: 1, dayLabel: "Upper A",
                            items: [item("custom_archer", name: "Archer Pull"), item("custom_kettle", name: "Kettle Balance Abs"), item("custom_landmine", name: "Landmine Press")])
            ctx.insert(s)
            try ctx.save()
            XCTAssertEqual(try ctx.fetch(FetchDescriptor<CustomExercise>()).count, 7)

            StartupBackfills.run(using: c)                                   // a launch: must not trap

            let rows = try ctx.fetch(FetchDescriptor<CustomExercise>())
            XCTAssertEqual(Dictionary(grouping: rows, by: \.id).mapValues(\.count), ["custom_archer": 1, "custom_kettle": 1, "custom_landmine": 1], "one row per id")
            XCTAssertEqual(rows.first { $0.id == "custom_archer" }?.createdAt, day(1, 5), "the oldest row survives")
            let ids = Set(rows.map(\.id))
            for i in try ctx.fetch(FetchDescriptor<SessionItem>()) {
                XCTAssertTrue(ids.contains(i.exerciseId) || ExerciseCatalog.builtIn.contains { $0.id == i.exerciseId },
                              "\(i.exerciseNameSnapshot ?? i.exerciseId) points at a row that exists")
            }
            let items = try ctx.fetch(FetchDescriptor<SessionItem>())
            XCTAssertEqual(items.first { $0.exerciseId == "custom_archer" }.map { _ in true }, true, "an unmatched custom keeps its id, now the survivor's")
            XCTAssertEqual(items.first { $0.exerciseNameSnapshot == "Landmine Press" || $0.exerciseId == "landmine_press" }?.exerciseId, "landmine_press",
                           "a custom that is also a built-in is remapped to the built-in, as before")

            // The same again with the flags lost (a restore that re-runs every one-shot) and the duplicates back: still no trap, still one row per id.
            insertDuplicates(); try ctx.save()
            clearFlags()
            StartupBackfills.run(using: c)
            let again = try ctx.fetch(FetchDescriptor<CustomExercise>())
            XCTAssertEqual(Dictionary(grouping: again, by: \.id).mapValues(\.count).values.max(), 1)
            XCTAssertEqual(again.count, 3)
            // idempotent
            XCTAssertEqual(CustomExerciseDedupMigration.collapseDuplicateRows(in: ctx), 0)
        }
    }

    // MARK: the migration is idempotent; the collapse says what it did

    private func memoryContext() throws -> ModelContext {
        let c = try ModelContainer(for: AppSchema.makeSchema(),
                                   configurations: ModelConfiguration("dup-\(UUID().uuidString)", isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        return ModelContext(c)
    }

    func test_storeMigration_insertsOnlyIdsNotInTheStore_andRunningItAgainInsertsNothing() throws {
        try withCleanDefaults { clearFlags in
            let ctx = try memoryContext()
            ctx.insert(CustomExercise(id: "custom_a", name: "A", primaryMuscleRaw: "back", isCompound: true, createdAt: day(1, 1)))
            ctx.insert(CustomExercise(id: "custom_b", name: "B", primaryMuscleRaw: "core", isCompound: false, createdAt: day(1, 2)))
            try ctx.save()
            func legacyList() throws -> Data {
                try JSONEncoder().encode([CatalogExercise(id: "custom_a", name: "A", primaryMuscle: .back, isCompound: true),
                                          CatalogExercise(id: "custom_b", name: "B", primaryMuscle: .core, isCompound: false),
                                          CatalogExercise(id: "custom_c", name: "C (only in the legacy list)", primaryMuscle: .chest, isCompound: true),
                                          CatalogExercise(id: "custom_c", name: "C again", primaryMuscle: .chest, isCompound: true)])
            }
            func ids() throws -> [String] { try ctx.fetch(FetchDescriptor<CustomExercise>()).map(\.id).sorted() }
            UserDefaults.standard.set(try legacyList(), forKey: "custom_exercises_v2")
            CustomExerciseStoreMigration.runIfNeeded(in: ctx)
            XCTAssertEqual(try ids(), ["custom_a", "custom_b", "custom_c"], "only the id the store lacked was inserted, once")
            // Again, any number of times, with the flag and the list put back: the same rows.
            for _ in 0..<3 {
                clearFlags()
                UserDefaults.standard.set(try legacyList(), forKey: "custom_exercises_v2")
                BackfillLog.collector = []
                CustomExerciseStoreMigration.runIfNeeded(in: ctx)
                let notes = BackfillLog.collector ?? []; BackfillLog.collector = nil
                XCTAssertTrue(notes.joined().contains("migrated 0 custom exercises"), notes.joined())
                XCTAssertEqual(try ids(), ["custom_a", "custom_b", "custom_c"])
            }
            XCTAssertEqual(CustomExerciseDedupMigration.collapseDuplicateRows(in: ctx), 0, "nothing for the safety net to delete")
        }
    }

    func test_collapse_logsOneLinePerCollapsedId_withTheFieldsTheRowsDifferedIn_andKeepsTheOldest() throws {
        let ctx = try memoryContext()
        let oldest = CustomExercise(id: "custom_x", name: "Archer Pull", primaryMuscleRaw: "back", isCompound: true, createdAt: day(1, 1))
        let newer = CustomExercise(id: "custom_x", name: "Archer Pulls", primaryMuscleRaw: "biceps", isCompound: false, createdAt: day(2, 1), isBodyweight: true)
        newer.fineMuscleRaw = "lats"
        let same1 = CustomExercise(id: "custom_y", name: "Copenhagen", primaryMuscleRaw: "core", isCompound: false, createdAt: day(1, 1))
        let same2 = CustomExercise(id: "custom_y", name: "Copenhagen", primaryMuscleRaw: "core", isCompound: false, createdAt: day(1, 3))
        for r in [newer, oldest, same2, same1] { ctx.insert(r) }
        try ctx.save()

        BackfillLog.collector = []
        let deleted = CustomExerciseDedupMigration.collapseDuplicateRows(in: ctx)
        let notes = BackfillLog.collector ?? []; BackfillLog.collector = nil
        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(notes.count, 2, "one line per id: \(notes)")
        let x = try XCTUnwrap(notes.first { $0.contains("custom_x") }), y = try XCTUnwrap(notes.first { $0.contains("custom_y") })
        XCTAssertTrue(x.contains("deleted 1 duplicate row(s)"), x)
        for field in ["name 'Archer Pull' vs 'Archer Pulls'", "primaryMuscle back vs biceps", "fineShares", "isCompound true vs false", "isBodyweight false vs true"] {
            XCTAssertTrue(x.contains(field), "\(field) in \(x)")
        }
        XCTAssertTrue(y.contains("identical"), y)
        let rows = try ctx.fetch(FetchDescriptor<CustomExercise>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id == "custom_x" }?.name, "Archer Pull", "the oldest is kept")
        XCTAssertEqual(rows.first { $0.id == "custom_y" }?.createdAt, day(1, 1))
    }

    func test_dedupLaunchLine_showsTheCollapse_notJustNotNeeded() throws {
        try withCleanDefaults { _ in
            let ctx = try memoryContext()
            UserDefaults.standard.set(true, forKey: "customExerciseDedupMigration.v1.completed")    // the one-shot is done
            ctx.insert(CustomExercise(id: "custom_x", name: "X", primaryMuscleRaw: "back", isCompound: true, createdAt: day(1, 1)))
            ctx.insert(CustomExercise(id: "custom_x", name: "X", primaryMuscleRaw: "back", isCompound: true, createdAt: day(1, 2)))
            try ctx.save()
            BackfillLog.collector = []
            CustomExerciseDedupMigration.runIfNeeded(in: ctx)
            let line = BackfillLog.result(from: BackfillLog.collector ?? []); BackfillLog.collector = nil
            XCTAssertTrue(line.contains("custom_x: deleted 1 duplicate row(s)"), line)
            XCTAssertFalse(line.contains("not needed"))
        }
    }

    func test_theCanonicalRow_isTheOldestCreatedAt_thenAStableTieBreak_whateverTheOrder() throws {
        let c = try ModelContainer(for: AppSchema.makeSchema(),
                                   configurations: ModelConfiguration("dup-\(UUID().uuidString)", isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        let rows = [CustomExercise(id: "x", name: "X", primaryMuscleRaw: "back", isCompound: true, createdAt: day(3, 1)),
                    CustomExercise(id: "x", name: "X", primaryMuscleRaw: "back", isCompound: true, createdAt: day(1, 1)),
                    CustomExercise(id: "x", name: "X", primaryMuscleRaw: "back", isCompound: true, createdAt: day(1, 1)),
                    CustomExercise(id: "a", name: "A", primaryMuscleRaw: "back", isCompound: true, createdAt: day(5, 1))]
        for r in rows { ctx.insert(r) }
        try ctx.save()
        let first = CustomExerciseDedupMigration.canonicalRows(rows)
        let reversed = CustomExerciseDedupMigration.canonicalRows(rows.reversed())
        XCTAssertEqual(first.map(\.persistentModelID), reversed.map(\.persistentModelID), "the choice does not depend on the order")
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first { $0.id == "x" }?.createdAt, day(1, 1))
    }
}

// MARK: - Restore paths leave the custom exercise rows alone (fixture backups)

/// The two restore paths that used to double the custom exercise rows, on real backups (skipped without them: TEST_RUNNER_EP_BACKUP_FIXTURE
/// and TEST_RUNNER_EP_ANGELA_122). c2: a gate restore into an empty store runs the backfills straight away with every flag unset and the legacy
/// list rebuilt by the import. c4: the store and the list are there, the flags are not. The migration must insert 0 rows and the collapse delete 0.
final class RestorePathCustomRowsFixtureTests: XCTestCase {

    private var parked: [ModelContainer] = []

    private func paths() throws -> [(String, String)] {
        let env = ProcessInfo.processInfo.environment
        let found = [("EP_BACKUP_FIXTURE", "the gate fixture"), ("EP_ANGELA_122", "Angela 1.2.2")].compactMap { k, label in
            env[k].flatMap { FileManager.default.fileExists(atPath: $0) ? ($0, label) : nil }
        }
        if found.isEmpty { throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE / TEST_RUNNER_EP_ANGELA_122") }
        return found
    }

    private func isolated(_ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        func keys() -> [String] { d.dictionaryRepresentation().keys.filter { $0.hasSuffix(".completed") || $0 == "custom_exercises_v2" || $0 == "prIndexRuleVersion" } }
        var saved: [String: Any] = [:]
        for k in keys() { if let v = d.object(forKey: k) { saved[k] = v } }
        defer { for k in keys() { d.removeObject(forKey: k) }; for (k, v) in saved { d.set(v, forKey: k) } }
        for k in keys() { d.removeObject(forKey: k) }
        try body()
    }

    private func container() throws -> ModelContainer {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration("rp-\(UUID().uuidString)", isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c); return c
    }

    private func rows(_ c: ModelContainer) throws -> [String: Int] {
        Dictionary(grouping: try ModelContext(c).fetch(FetchDescriptor<CustomExercise>()), by: \.id).mapValues(\.count)
    }

    /// A launch; returns the lines the custom-exercise backfills logged.
    private func launch(_ c: ModelContainer) -> [String] {
        var lines: [String] = []
        BackfillLog.lineSink = { if $0.contains("CustomExercise") || $0.contains("Custom exercise") { lines.append($0) } }
        StartupBackfills.run(using: c)
        BackfillLog.lineSink = nil
        return lines
    }

    private func assertSteady(_ c: ModelContainer, expected: Int, _ lines: [String], _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try rows(c)
        XCTAssertEqual(r.count, expected, "\(what): rows", file: file, line: line)
        XCTAssertEqual(r.values.max() ?? 1, 1, "\(what): every id once", file: file, line: line)
        XCTAssertFalse(lines.contains { $0.contains("deleted") }, "\(what): the collapse deleted nothing: \(lines)", file: file, line: line)
        XCTAssertFalse(lines.contains { $0.contains("migrated") && !$0.contains("migrated 0 custom exercises") }, "\(what): the migration inserted nothing: \(lines)", file: file, line: line)
    }

    func test_c2_gateRestoreRunsTheBackfillsWithFlagsUnset_andTheCountsStay() throws {
        for (path, label) in try paths() {
            try isolated {
                let c = try container()
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rp-snap-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _ = try BackupRestoreCoordinator.restore(from: URL(fileURLWithPath: path), container: c, snapshotDirectory: dir,
                                                         sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "rp.fixture")!))
                let expected = try rows(c).count
                XCTAssertGreaterThan(expected, 0, label)
                try assertSteady(c, expected: expected, launch(c), "\(label): backfills straight after the restore")
                try assertSteady(c, expected: expected, launch(c), "\(label): next launch")
                for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasSuffix(".completed") { UserDefaults.standard.removeObject(forKey: k) }
                try assertSteady(c, expected: expected, launch(c), "\(label): flags lost again")
            }
        }
    }

    func test_c4_storeAndListPresent_flagsLost_andTheCountsStay() throws {
        for (path, label) in try paths() {
            try isolated {
                let c = try container()
                _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: c)
                let expected = try rows(c).count
                XCTAssertGreaterThan(expected, 0, label)
                try assertSteady(c, expected: expected, launch(c), "\(label): first launch")
                try assertSteady(c, expected: expected, launch(c), "\(label): relaunch")
                for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasSuffix(".completed") { UserDefaults.standard.removeObject(forKey: k) }
                try assertSteady(c, expected: expected, launch(c), "\(label): flags lost again")
            }
        }
    }
}

// MARK: - Custom exercise library (rename / collisions / delete guard)

@MainActor
final class CustomExerciseLibraryTests: XCTestCase {

    private var parked: [ModelContainer] = []

    private func isolated(_ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        func keys() -> [String] { d.dictionaryRepresentation().keys.filter { $0.hasSuffix(".completed") || $0 == "custom_exercises_v2" || $0 == "prIndexRuleVersion" || $0 == ExercisePickerRecents.key } }
        var saved: [String: Any] = [:]
        for k in keys() { if let v = d.object(forKey: k) { saved[k] = v } }
        defer { for k in keys() { d.removeObject(forKey: k) }; for (k, v) in saved { d.set(v, forKey: k) } }
        for k in keys() { d.removeObject(forKey: k) }
        try body()
    }

    private func container() throws -> ModelContainer {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration("lib-\(UUID().uuidString)", isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c); return c
    }

    private struct World { let c: ModelContainer; let ctx: ModelContext; let id: String; let doneId: UUID; let plannedId: UUID }

    /// One custom exercise "Cable Hold" used by a completed session (with history + PR) and a planned one.
    private func world() throws -> World {
        let c = try container(); let ctx = ModelContext(c)
        let ex = ExerciseCatalog.addCustomExercise(name: "Cable Hold", primaryMuscle: .core, isCompound: false, in: ctx)
        let done = Session(date: Date(timeIntervalSince1970: 1_790_000_000), status: .completed, weekIndex: 1, dayLabel: "A",
                           items: [BackupTestSupport.item(1, ex.id, name: "Cable Hold", reps: [10, 10], loads: [20, 20])])
        let plan = Session(date: Date(timeIntervalSince1970: 1_800_000_000), status: .planned, weekIndex: 2, dayLabel: "A",
                           items: [BackupTestSupport.item(1, ex.id, name: "Cable Hold")])
        ctx.insert(done); ctx.insert(plan)
        ctx.insert(SessionHistory(date: done.date, weekIndex: 1, title: "A", subtitle: "", totalExercises: 1, totalSets: 2, totalVolume: 400,
                                  sessionId: done.id, exercises: [SessionHistoryExercise(name: "Cable Hold", primaryMuscle: "abs", sets: 2, reps: 20, volume: 400)]))
        // a history of an unrelated session that carries the same name must NOT be renamed
        ctx.insert(SessionHistory(date: done.date, weekIndex: 1, title: "B", subtitle: "", totalExercises: 1, totalSets: 1, totalVolume: 1,
                                  sessionId: UUID(), exercises: [SessionHistoryExercise(name: "Cable Hold", primaryMuscle: "abs", sets: 1, reps: 1, volume: 1)]))
        ctx.insert(PRIndex(exerciseId: ex.id, exerciseName: "Cable Hold", bestSetVolume: 200, bestLoad: 20, bestReps: 10))
        try ctx.save()
        return World(c: c, ctx: ctx, id: ex.id, doneId: done.id!, plannedId: plan.id!)
    }

    private func edit(_ name: String, compound: Bool = false, bw: Bool = false) -> CustomExerciseLibrary.Edit {
        .init(name: name, primaryMuscle: .core, isCompound: compound, isBodyweight: bw)
    }

    private func snapshotNames(_ ctx: ModelContext, _ id: String) throws -> Set<String> {
        Set(try ctx.fetch(FetchDescriptor<Session>()).flatMap(\.items).filter { $0.exerciseId == id }.compactMap(\.exerciseNameSnapshot))
    }

    private func assertRenamed(_ ctx: ModelContext, id: String, to name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<CustomExercise>()).filter { $0.id == id }.map(\.name), [name], file: file, line: line)
        XCTAssertEqual(try snapshotNames(ctx, id), [name], "planned and completed snapshots", file: file, line: line)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PRIndex>()).first { $0.exerciseId == id }?.exerciseName, name, file: file, line: line)
        let hist = try ctx.fetch(FetchDescriptor<SessionHistory>())
        XCTAssertEqual(hist.first { $0.title == "A" }?.exercises.map(\.name), [name], file: file, line: line)
        XCTAssertEqual(ExerciseCatalog.displayName(for: id), name, "mirror", file: file, line: line)
    }

    // MARK: normalizer

    func test_normalizer_isFixedLocale_foldsCaseDiacriticsAndWhitespace() {
        XCTAssertEqual(ExerciseNameRules.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(ExerciseNameRules.normalized("  ÉCLAIR Press "), ExerciseNameRules.normalized("eclair press"))
        XCTAssertTrue(ExerciseNameRules.areEqual("Crème Curl", "creme CURL"))
        XCTAssertFalse(ExerciseNameRules.areEqual("Curl", "Curls"))
    }

    // MARK: rename

    func test_rename_updatesMirrorSnapshotsHistoryAndPR_andLeavesOtherHistoriesAlone() throws {
        try isolated {
            let w = try world()
            XCTAssertEqual(CustomExerciseLibrary.update(id: w.id, edit: edit("Cable Plank Hold"), in: w.ctx), .saved)
            try assertRenamed(w.ctx, id: w.id, to: "Cable Plank Hold")
            XCTAssertEqual(try w.ctx.fetch(FetchDescriptor<SessionHistory>()).first { $0.title == "B" }?.exercises.map(\.name), ["Cable Hold"])
            XCTAssertEqual(try w.ctx.fetch(FetchDescriptor<Session>()).flatMap(\.items).filter { $0.exerciseId == w.id }.count, 2, "ids unchanged")
        }
    }

    func test_caseOnlyRename_ofYourOwnExercise_isAllowed() throws {
        try isolated {
            let w = try world()
            XCTAssertEqual(CustomExerciseLibrary.update(id: w.id, edit: edit("CABLE HOLD"), in: w.ctx), .saved)
            try assertRenamed(w.ctx, id: w.id, to: "CABLE HOLD")
            XCTAssertEqual(CustomExerciseLibrary.update(id: w.id, edit: edit("Cáble hold"), in: w.ctx), .saved, "own name, other case + diacritics")
            try assertRenamed(w.ctx, id: w.id, to: "Cáble hold")
        }
    }

    func test_rename_toABuiltInOrAnotherCustomName_isBlocked_anyCaseOrDiacritics() throws {
        try isolated {
            let w = try world()
            _ = ExerciseCatalog.addCustomExercise(name: "Zercher Hold", primaryMuscle: .core, isCompound: false, in: w.ctx)
            let builtInName = try XCTUnwrap(ExerciseCatalog.builtIn.first { $0.name.contains("Bench") }).name
            let variants = [builtInName, builtInName.uppercased(), builtInName.lowercased(), "  \(builtInName)  ",
                            builtInName.replacingOccurrences(of: "e", with: "é"),
                            "Zercher Hold", "ZERCHER HOLD", "zérchér hold"]
            for v in variants {
                let r = CustomExerciseLibrary.update(id: w.id, edit: edit(v), in: w.ctx)
                guard case .invalidName(let check) = r else { XCTFail("“\(v)” must be blocked, got \(r)"); continue }
                XCTAssertNotNil(check.message, v)
            }
            try assertRenamed(w.ctx, id: w.id, to: "Cable Hold")   // nothing changed
            XCTAssertEqual(CustomExerciseLibrary.checkName("", forId: w.id, in: w.ctx), .empty)
        }
    }

    func test_bodyweightAndCompound_areForwardOnly_noStoredSetChanges() throws {
        try isolated {
            let w = try world()
            XCTAssertEqual(CustomExerciseLibrary.update(id: w.id, edit: edit("Cable Hold", compound: true, bw: true), in: w.ctx), .saved)
            XCTAssertTrue(ExerciseCatalog.isBodyweight(exerciseId: w.id))
            let loads = try w.ctx.fetch(FetchDescriptor<Session>()).first { $0.status == .completed }?.items.first?.actualLoads
            XCTAssertEqual(loads, [20, 20])
        }
    }

    // MARK: restore with flags cleared (c2 / c4) and backup round trip

    private func launch(_ c: ModelContainer) -> [String] {
        var lines: [String] = []
        BackfillLog.lineSink = { lines.append($0) }
        StartupBackfills.run(using: c)
        BackfillLog.lineSink = nil
        return lines
    }

    private func clearFlags() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasSuffix(".completed") { UserDefaults.standard.removeObject(forKey: k) }
        UserDefaults.standard.removeObject(forKey: "prIndexRuleVersion")
    }

    func test_c2_renameThenRestoreIntoEmptyStore_flagsCleared_noRemap_idsUnchanged_newNameKept() throws {
        try isolated {
            let w = try world()
            XCTAssertEqual(CustomExerciseLibrary.update(id: w.id, edit: edit("Cable Plank Hold"), in: w.ctx), .saved)
            let file = try BackupTestSupport.exportFile(w.ctx)
            UserDefaults.standard.removeObject(forKey: "custom_exercises_v2"); clearFlags()

            let target = try container()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-snap-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try BackupRestoreCoordinator.restore(from: file, container: target, snapshotDirectory: dir,
                                                     sentinel: DataSentinelStore(defaults: UserDefaults(suiteName: "lib.fixture")!))
            for pass in 1...2 {
                _ = launch(target)
                let ctx = ModelContext(target)
                try assertRenamed(ctx, id: w.id, to: "Cable Plank Hold")
                XCTAssertEqual(try ctx.fetch(FetchDescriptor<CustomExercise>()).count, 1, "pass \(pass): one row, no remap")
                XCTAssertEqual(try ctx.fetch(FetchDescriptor<Session>()).flatMap(\.items).map(\.exerciseId).filter { $0 != w.id }, [], "pass \(pass): ids unchanged")
                clearFlags()
            }
        }
    }

    func test_c4_renameThenStoreAndListPresent_flagsLost_noRemap_idsUnchanged_newNameKept() throws {
        try isolated {
            let w = try world()
            XCTAssertEqual(CustomExerciseLibrary.update(id: w.id, edit: edit("Cable Plank Hold"), in: w.ctx), .saved)
            let file = try BackupTestSupport.exportFile(w.ctx)
            UserDefaults.standard.removeObject(forKey: "custom_exercises_v2"); clearFlags()

            let target = try container()
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: file, modelContainer: target)
            for pass in 1...2 {
                clearFlags()
                _ = launch(target)
                let ctx = ModelContext(target)
                try assertRenamed(ctx, id: w.id, to: "Cable Plank Hold")
                XCTAssertEqual(try ctx.fetch(FetchDescriptor<CustomExercise>()).count, 1, "pass \(pass)")
            }
        }
    }

    func test_rename_thenBackupRoundTrip_keepsTheNewNameEverywhere() throws {
        try isolated {
            let w = try world()
            XCTAssertEqual(CustomExerciseLibrary.update(id: w.id, edit: edit("Cable Plank Hold", compound: true, bw: true), in: w.ctx), .saved)
            let file = try BackupTestSupport.exportFile(w.ctx)
            let target = try container()
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: file, modelContainer: target)
            let ctx = ModelContext(target)
            try assertRenamed(ctx, id: w.id, to: "Cable Plank Hold")
            let row = try XCTUnwrap(ctx.fetch(FetchDescriptor<CustomExercise>()).first)
            XCTAssertEqual(row.isBodyweight, true)
            XCTAssertEqual(row.isCompound, true)
        }
    }

    // MARK: delete guard

    func test_delete_blockedWhileUsed_withTheExactMessage_andNothingChanges() throws {
        try isolated {
            let w = try world()
            let u = CustomExerciseLibrary.usage(of: w.id, in: w.ctx)
            XCTAssertEqual(u, .init(sessions: 2, planned: 1, loggedSets: 2))
            XCTAssertEqual(CustomExerciseLibrary.delete(id: w.id, in: w.ctx), .blocked(u))
            XCTAssertEqual(u.deleteBlockMessage, "Used in 2 sessions (1 planned). Swap it out of your program first.")
            XCTAssertEqual(try w.ctx.fetch(FetchDescriptor<CustomExercise>()).count, 1)
            XCTAssertEqual(ExerciseCatalog.displayName(for: w.id), "Cable Hold")
        }
    }

    func test_delete_whenUnused_removesRecordMirrorNoteSettingsAndRecent() throws {
        try isolated {
            let c = try container(); let ctx = ModelContext(c)
            let ex = ExerciseCatalog.addCustomExercise(name: "Loose Curl", primaryMuscle: .biceps, isCompound: false, in: ctx)
            ctx.insert(ExerciseNote(exerciseId: ex.id, note: "slow"))
            let profile = UserProfile()
            profile.loadStepByExercise = [ex.id: 2.5, "bench_press": 5]
            profile.maxLoadByExercise = [ex.id: 50]
            ctx.insert(profile)
            try ctx.save()
            let recents = ExercisePickerRecents(); recents.record(ex.id)
            XCTAssertEqual(CustomExerciseLibrary.delete(id: ex.id, in: ctx), .deleted)
            XCTAssertTrue(try ctx.fetch(FetchDescriptor<CustomExercise>()).isEmpty)
            XCTAssertTrue(try ctx.fetch(FetchDescriptor<ExerciseNote>()).isEmpty)
            XCTAssertEqual(profile.loadStepByExercise, ["bench_press": 5])
            XCTAssertNil(profile.maxLoadByExercise[ex.id])
            XCTAssertFalse(recents.ids.contains(ex.id))
            XCTAssertFalse(ExerciseCatalog.all.contains { $0.id == ex.id })
        }
    }

    func test_delete_aBuiltIn_isRefused() throws {
        try isolated {
            let c = try container()
            XCTAssertEqual(CustomExerciseLibrary.delete(id: "bench_press", in: ModelContext(c)), .notFound)
        }
    }
}
