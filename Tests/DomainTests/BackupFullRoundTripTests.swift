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
}
