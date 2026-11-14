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
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep_snap_\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
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
        let gate = StartupGate(directory: dir, runBackfills: { _ in backfillRuns += 1 })
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
        let gate = StartupGate(directory: dir, runBackfills: { _ in backfillRuns += 1 })
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
        let gate = StartupGate(directory: dir, runBackfills: { _ in runs += 1 })
        gate.begin(container: container)
        XCTAssertEqual(runs, 1); XCTAssertNil(gate.interrupted)
        try InterruptedImportMarker.write(snapshot: dir.appendingPathComponent("pre-import-gone.json"), startedAt: Date(), in: dir)
        let gate2 = StartupGate(directory: dir, runBackfills: { _ in runs += 1 })
        gate2.begin(container: container)
        XCTAssertEqual(runs, 2); XCTAssertNil(gate2.interrupted)
        XCTAssertFalse(InterruptedImportMarker.exists(in: dir))
        XCTAssertTrue(gate2.showsMissingSnapshotNotice, "the user is told once, not silently")
        XCTAssertTrue(StartupGate.missingSnapshotMessage.hasPrefix("A restore was interrupted and its safety copy is missing."))
        XCTAssertTrue(StartupGate.missingSnapshotMessage.hasSuffix("import your latest export from Files."))
        gate2.showsMissingSnapshotNotice = false
        let gate3 = StartupGate(directory: dir, runBackfills: { _ in runs += 1 })
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
