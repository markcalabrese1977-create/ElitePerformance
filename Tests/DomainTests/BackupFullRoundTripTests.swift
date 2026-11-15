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

// MARK: - XX: missed-source seeding

final class MissedSourceSeedingTests: XCTestCase {

    private let cal = Calendar.current
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: Date()))! }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
    }

    private func item(_ wave: String, reps: [Int] = [], loads: [Double] = [], rirs: [Int] = [], planned: Bool) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: "barbell_row", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0, waveRaw: wave)
        i.plannedRepsBySet = [10, 10, 10]; i.plannedRIRsBySet = [2, 2, 2]
        i.plannedLoadsBySet = [0, 0, 0]
        if !planned { i.actualReps = reps; i.actualLoads = loads; i.actualRIRs = rirs; i.suggestedLoad = loads.first ?? 0; i.plannedLoadsBySet = loads }
        return i
    }

    /// Pull A (wk4, done) -> Pull B (wk5, MISSED) -> Pull C (wk6, done) -> Pull B again wk8 target at 0 load.
    private func block(_ ctx: ModelContext, otherMeso: Bool = false) -> (target: SessionItem, targetSession: Session) {
        let meso = MesoBlock(name: "M", startDate: day(-40), totalWeeks: 8)
        ctx.insert(meso)
        let a = Session(date: day(-20), status: .completed, weekIndex: 4, dayLabel: "Pull", items: [item("a", reps: [10, 10, 9], loads: [100, 100, 100], rirs: [2, 2, 2], planned: false)])
        let missed = Session(date: day(-13), status: .planned, weekIndex: 5, dayLabel: "Pull", items: [item("b", planned: true)])
        let c = Session(date: day(-6), status: .completed, weekIndex: 6, dayLabel: "Pull", items: [item("c", reps: [10, 10, 10], loads: [110, 110, 110], rirs: [2, 2, 2], planned: false)])
        let tItem = item("b", planned: true)
        let target = Session(date: day(8), status: .planned, weekIndex: 8, dayLabel: "Pull", items: [tItem])
        for s in [a, missed, c, target] { s.meso = meso; ctx.insert(s); meso.sessions.append(s) }
        return (tItem, target)
    }

    func test_aZeroLoadTarget_isSeededFromTheLatestCompletedSameDaySession_converted_minus2_5Percent_andNoted() throws {
        let ctx = try context()
        let (t, _) = block(ctx)
        let seeds = MissedSourceSeeding.run(in: ctx)
        XCTAssertEqual(seeds.count, 1)
        // reps-only e1RM of 110 x 10 = 146.67; at 10 reps RIR 2: 146.67/(1+10/30)*0.95 = 104.5; x 0.975 = 101.9 -> down to 2.5: 100
        XCTAssertEqual(t.plannedLoadsBySet, [100, 100, 100])
        XCTAssertEqual(t.suggestedLoad, 100)
        XCTAssertTrue(t.prescriptionNotes?.contains("Seeded from") == true && t.prescriptionNotes?.contains("was missed") == true, t.prescriptionNotes ?? "nil")
        XCTAssertFalse(t.planEdited)
        XCTAssertTrue(MissedSourceSeeding.run(in: ctx).isEmpty, "idempotent: a seeded target is no longer a candidate")
    }

    // PPP: only a target whose same-meso, same-dayLabel, same-wave predecessor is dated before today and was not completed.
    func test_PPP_onlyAMissedPredecessorSeeds_upcomingCompletedOrMissingPredecessorsLeaveTheTargetToCarryForward() throws {
        func scenario(predecessor: SessionStatus?, at days: Int, wave: String = "b", dayLabel: String = "Pull", otherMeso: Bool = false) throws -> SessionItem {
            let ctx = try context()
            let meso = MesoBlock(name: "M", startDate: day(-40), totalWeeks: 8), other = MesoBlock(name: "O", startDate: day(-40), totalWeeks: 8)
            ctx.insert(meso); ctx.insert(other)
            let history = Session(date: day(-20), status: .completed, weekIndex: 4, dayLabel: "Pull", items: [item("a", reps: [10, 10, 10], loads: [100, 100, 100], rirs: [2, 2, 2], planned: false)])
            history.meso = meso
            let t = item("b", planned: true)
            let target = Session(date: day(8), status: .planned, weekIndex: 8, dayLabel: "Pull", items: [t]); target.meso = meso
            for s in [history, target] { ctx.insert(s); s.meso!.sessions.append(s) }
            if let predecessor {
                let p = item(wave, planned: true)
                let ps = Session(date: day(days), status: predecessor, weekIndex: 5, dayLabel: dayLabel, items: [p])
                ps.meso = otherMeso ? other : meso
                ctx.insert(ps); ps.meso!.sessions.append(ps)
            }
            _ = MissedSourceSeeding.run(in: ctx)
            return t
        }
        XCTAssertGreaterThan(try scenario(predecessor: .planned, at: -13).suggestedLoad, 0, "predecessor before today, never completed: seeded")
        XCTAssertGreaterThan(try scenario(predecessor: .inProgress, at: -2).suggestedLoad, 0, "started and abandoned counts as not completed")
        XCTAssertEqual(try scenario(predecessor: .planned, at: 3).suggestedLoad, 0, "predecessor still upcoming: carry-forward owns it")
        XCTAssertEqual(try scenario(predecessor: .planned, at: 0).suggestedLoad, 0, "today is not before today")
        XCTAssertEqual(try scenario(predecessor: .completed, at: -6).suggestedLoad, 0, "predecessor completed: carry-forward owns it")
        XCTAssertEqual(try scenario(predecessor: nil, at: 0).suggestedLoad, 0, "no predecessor (a first exposure): not seeded")
        XCTAssertEqual(try scenario(predecessor: .planned, at: -13, wave: "a").suggestedLoad, 0, "a different wave letter is not the predecessor")
        XCTAssertEqual(try scenario(predecessor: .planned, at: -13, dayLabel: "Push").suggestedLoad, 0, "a different dayLabel is not the predecessor")
        XCTAssertEqual(try scenario(predecessor: .planned, at: -13, otherMeso: true).suggestedLoad, 0, "another meso is not the predecessor")
    }

    func test_anEditedTarget_aTargetWithALoad_aBodyweightLift_andPastTargets_areLeftAlone() throws {
        let ctx = try context()
        let (t, session) = block(ctx)
        t.planEdited = true
        XCTAssertTrue(MissedSourceSeeding.run(in: ctx).isEmpty)
        XCTAssertEqual(t.plannedLoadsBySet, [0, 0, 0])
        t.planEdited = false
        session.date = day(-1)
        XCTAssertTrue(MissedSourceSeeding.run(in: ctx).isEmpty, "a session already in the past is not seeded")
        session.date = day(8)
        t.plannedLoadsBySet = [95, 95, 95]; t.suggestedLoad = 95
        XCTAssertTrue(MissedSourceSeeding.run(in: ctx).isEmpty, "a target with a load is never overwritten")
    }

    func test_anyBlockFallback_usesOnlyTheLast12Weeks_olderOrNoneLeavesZeroWithTheNote() throws {
        func scenario(daysAgo: Int) throws -> SessionItem {
            let ctx = try context()
            let old = MesoBlock(name: "Old", startDate: day(-daysAgo - 60), totalWeeks: 8)
            let cur = MesoBlock(name: "Cur", startDate: day(-3), totalWeeks: 8)
            ctx.insert(old); ctx.insert(cur)
            let done = Session(date: day(-daysAgo), status: .completed, weekIndex: 3, dayLabel: "Pull", items: [item("a", reps: [10, 10, 10], loads: [90, 90, 90], rirs: [2, 2, 2], planned: false)])
            done.meso = old
            let tItem = item("a", planned: true)
            let target = Session(date: day(4), status: .planned, weekIndex: 1, dayLabel: "Pull", items: [tItem]); target.meso = cur
            let missed = Session(date: day(-2), status: .planned, weekIndex: 1, dayLabel: "Pull", items: [item("a", planned: true)]); missed.meso = cur  // its predecessor, never done
            for s in [done, target, missed] { ctx.insert(s) }
            old.sessions.append(done); cur.sessions.append(target); cur.sessions.append(missed)
            _ = MissedSourceSeeding.run(in: ctx)
            XCTAssertTrue(MissedSourceSeeding.run(in: ctx).isEmpty, "idempotent")
            return tItem
        }
        let recent = try scenario(daysAgo: 60)
        XCTAssertGreaterThan(recent.suggestedLoad, 0, "another block, 60 days ago: still seeds")
        XCTAssertTrue(recent.prescriptionNotes?.contains("was missed") == true)

        let stale = try scenario(daysAgo: 13 * 7)
        XCTAssertEqual(stale.suggestedLoad, 0, "13 weeks old: not used")
        XCTAssertEqual(stale.plannedLoadsBySet, [0, 0, 0])
        XCTAssertEqual(stale.prescriptionNotes, "No recent history — set a load.")

        let empty = try context()
        let m = MesoBlock(name: "E", startDate: day(-3), totalWeeks: 8); empty.insert(m)
        let lone = item("a", planned: true)
        let s = Session(date: day(2), status: .planned, weekIndex: 1, dayLabel: "Pull", items: [lone]); s.meso = m; empty.insert(s); m.sessions.append(s)
        let miss = Session(date: day(-1), status: .planned, weekIndex: 1, dayLabel: "Pull", items: [item("a", planned: true)]); miss.meso = m; empty.insert(miss); m.sessions.append(miss)
        _ = MissedSourceSeeding.run(in: empty)
        XCTAssertEqual(lone.suggestedLoad, 0)
        XCTAssertEqual(lone.prescriptionNotes, "No recent history — set a load.", "no history at all: the same note")
    }

    // LOCAL ONLY, READ-ONLY: what the seeding would write on a real backup.
    func test_audit_whatTheSeedingWouldWriteOnTheLatestBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let container = try ModelContainer(
            for: AppSchema.makeSchema(),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let profile = try? ctx.fetch(FetchDescriptor<UserProfile>()).first
        let custom = (try? ctx.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let seeds = MissedSourceSeeding.plan(in: ctx, ctx: .init(profile: profile, customExercises: custom))
        let fmt = DateFormatter(); fmt.dateFormat = "EEE MMM d"
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        var lines = ["MISSED-SOURCE SEEDING DRY RUN — \(seeds.filter { !$0.isNoRecentHistory }.count) planned exercises would be seeded, \(seeds.filter { $0.isNoRecentHistory }.count) would get the no-recent-history note (nothing was saved)"]
        for s in seeds.sorted(by: { ($0.session.date, $0.item.order) < ($1.session.date, $1.item.order) }) {
            lines.append("\(fmt.string(from: s.session.date)) wk\(s.session.weekIndex) \(s.session.dayLabel ?? "-") · \(s.item.exerciseId) (\(s.item.waveRaw ?? "-")): " + (s.isNoRecentHistory ? "stays 0 · \(s.note)" : "0 -> \(s.loads.map(n).joined(separator: "/")) · \(s.note)"))
        }
        let zeroLeft = try ctx.fetch(FetchDescriptor<Session>()).filter { $0.status == .planned && $0.date >= Calendar.current.startOfDay(for: Date()) }
            .flatMap { s in s.items.filter { $0.suggestedLoad <= 0 && $0.plannedLoadsBySet.allSatisfy { $0 <= 0 } }.map { (s, $0) } }
        let seededIds = Set(seeds.filter { !$0.isNoRecentHistory }.map { ObjectIdentifier($0.item) })
        let staying = zeroLeft.filter { !seededIds.contains(ObjectIdentifier($0.1)) }
        lines.append("planned future exercises at 0 load that would STAY at 0: \(staying.count) (bodyweight, deload, edited, exempt or no history)")
        for (sess, it) in staying { lines.append("  stays 0: \(fmt.string(from: sess.date)) wk\(sess.weekIndex) \(sess.dayLabel ?? "-") · \(it.exerciseId) (\(it.waveRaw ?? "-")) edited=\(it.planEdited)") }
        let text = lines.joined(separator: "\n")
        print(text)
        if let out = ProcessInfo.processInfo.environment["EP_AUDIT_REPORT_OUT"], !out.isEmpty { try text.write(toFile: out, atomically: true, encoding: .utf8) }
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
        for action in ["Change program…", "Start next meso from this one", "Insert deload week"] {
            XCTAssertTrue(menu.contains(action), "\(action) is in the menu")
            XCTAssertEqual(card.components(separatedBy: action).count - 1, 1, "and only there: \(action)")
        }
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
}
