import XCTest
import SwiftData
@testable import ElitePerformance

/// Restore must leave derived and mirrored state consistent with what was restored.
final class BackupRestorePRIndexTests: XCTestCase {

    private var sandbox: DefaultsSandbox!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    private let early = BackupTestSupport.date(1_000_000)
    private let late = BackupTestSupport.date(2_000_000)

    /// bench: 200x5 (1000) early, then 150x5 (750) late; row: 100x10 (1000) late; one planned session is ignored.
    private func seedSource() throws -> ModelContext {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let s1 = Session(date: early, status: .completed, weekIndex: 1, dayLabel: "A", items: [
            BackupTestSupport.item(1, "bench_press", name: "Bench Press", reps: [5, 4], loads: [200, 190])
        ])
        let s2 = Session(date: late, status: .completed, weekIndex: 2, dayLabel: "A", items: [
            BackupTestSupport.item(1, "bench_press", name: "Bench Press", reps: [5], loads: [150]),
            BackupTestSupport.item(2, "barbell_row", name: "Barbell Row", reps: [10], loads: [100])
        ])
        let planned = Session(date: BackupTestSupport.date(3_000_000), status: .planned, weekIndex: 3, dayLabel: "A", items: [
            BackupTestSupport.item(1, "bench_press", name: "Bench Press", reps: [5], loads: [500])
        ])
        [s1, s2, planned].forEach(ctx.insert)
        try ctx.save()
        return ctx
    }

    private func prs(_ ctx: ModelContext) throws -> [String: PRIndex] {
        Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<PRIndex>()).map { ($0.exerciseId, $0) })
    }

    func test_restore_rebuildsPRIndex_fromCompletedSessions_withSessionDates() throws {
        let source = try seedSource()
        let target = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: target)

        let rebuilt = try prs(ModelContext(target))
        XCTAssertEqual(Set(rebuilt.keys), ["bench_press", "barbell_row"])
        let bench = try XCTUnwrap(rebuilt["bench_press"])
        XCTAssertEqual(bench.bestSetVolume, 1000)
        XCTAssertEqual(bench.bestLoad, 200)
        XCTAssertEqual(bench.bestReps, 5)
        XCTAssertEqual(bench.bestDate, early, "bestDate is the date of the session that set the PR, not the rebuild time")
        let row = try XCTUnwrap(rebuilt["barbell_row"])
        XCTAssertEqual(row.bestSetVolume, 1000)
        XCTAssertEqual(row.bestDate, late)

        // A second rebuild changes nothing.
        let ctx = ModelContext(target)
        try PRRebuildService.rebuild(in: ctx)
        let again = try prs(ctx)
        XCTAssertEqual(again.mapValues(\.bestSetVolume), rebuilt.mapValues(\.bestSetVolume))
        XCTAssertEqual(again.mapValues(\.bestDate), rebuilt.mapValues(\.bestDate))
    }

    func test_firstLiftAfterRestore_isNotAFalsePR() throws {
        let source = try seedSource()
        let target = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: target)
        let ctx = ModelContext(target)

        let lighter = BackupTestSupport.item(1, "bench_press", name: "Bench Press", reps: [5], loads: [180])
        PRService.updatePR(for: lighter, in: ctx)
        XCTAssertFalse(lighter.isPR, "180x5 does not beat the restored 200x5")

        let heavier = BackupTestSupport.item(1, "bench_press", name: "Bench Press", reps: [5], loads: [210])
        PRService.updatePR(for: heavier, in: ctx)
        XCTAssertTrue(heavier.isPR)
    }

    func test_restoreOntoNonEmptyInstall_replacesStalePRs() throws {
        let source = try seedSource()
        let target = try BackupTestSupport.makeContainer()
        let existing = ModelContext(target)
        existing.insert(PRIndex(exerciseId: "bench_press", exerciseName: "Bench Press", bestSetVolume: 99_999,
                                bestLoad: 999, bestReps: 100, bestDate: late))
        existing.insert(PRIndex(exerciseId: "ghost_exercise", exerciseName: "Ghost", bestSetVolume: 1,
                                bestLoad: 1, bestReps: 1, bestDate: late))
        try existing.save()

        try BackupTestSupport.restore(from: source, into: target)

        let after = try prs(ModelContext(target))
        XCTAssertNil(after["ghost_exercise"], "a PR with no completed session behind it is dropped")
        XCTAssertEqual(try XCTUnwrap(after["bench_press"]).bestSetVolume, 1000, "the stale 99,999 is replaced")
    }
}

// MARK: - Custom-exercise UserDefaults mirror

final class BackupRestoreCustomMirrorTests: XCTestCase {

    private var sandbox: DefaultsSandbox!
    let mirrorKey = "custom_exercises_v2"

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
        UserDefaults.standard.removeObject(forKey: mirrorKey)
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    func mirror() throws -> [CatalogExercise] {
        guard let data = UserDefaults.standard.data(forKey: mirrorKey) else { return [] }
        return try JSONDecoder().decode([CatalogExercise].self, from: data)
    }

    func test_restore_rebuildsMirrorWithEveryField_includingIsBodyweight() throws {
        let source = ModelContext(try BackupTestSupport.makeContainer())
        let pull = ExerciseCatalog.addCustomExercise(name: "Rope Climb Probe", primaryMuscle: .back,
                                                     isCompound: true, isBodyweight: true, in: source)
        let curl = ExerciseCatalog.addCustomExercise(name: "Wrist Roller Probe", primaryMuscle: .biceps,
                                                     isCompound: false, isBodyweight: false, in: source)
        let expected = Set([pull, curl])

        // A fresh install: SwiftData is restored from the file, the UserDefaults mirror starts empty.
        UserDefaults.standard.removeObject(forKey: mirrorKey)
        let target = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: target)

        XCTAssertEqual(Set(try mirror()), expected, "every CatalogExercise field survives, not just id/name/muscle/compound")
        XCTAssertTrue(ExerciseCatalog.isBodyweight(exerciseId: pull.id), "a restored bodyweight custom is still bodyweight")
        XCTAssertFalse(ExerciseCatalog.isBodyweight(exerciseId: curl.id))
    }
}

extension BackupRestoreCustomMirrorTests {
    func test_restoreOfBackupWithNoCustoms_clearsAStaleMirror() throws {
        let stale = [CatalogExercise(id: "stale_probe_id", name: "Stale Probe", primaryMuscle: .chest, isCompound: false)]
        UserDefaults.standard.set(try JSONEncoder().encode(stale), forKey: mirrorKey)
        XCTAssertEqual(try mirror().count, 1, "precondition: a stale entry is mirrored")

        let source = ModelContext(try BackupTestSupport.makeContainer())
        let target = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: target)

        XCTAssertTrue(try mirror().isEmpty, "the mirror follows the restored SwiftData, which has no customs")
        XCTAssertFalse(ExerciseCatalog.all.contains { $0.id == "stale_probe_id" })
    }
}

// MARK: - Legacy exerciseNotes.v1.<id> keys

final class LegacyExerciseNotesBackfillTests: XCTestCase {

    private var sandbox: DefaultsSandbox!
    private let ids = ["bench_press", "plank", "barbell_row", "hammer_curl"]

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
        ids.forEach { ExerciseNotesStore.clear(exerciseId: $0) }
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    private func notes(_ ctx: ModelContext) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<ExerciseNote>()).map { ($0.exerciseId, $0.note) })
    }

    func test_movesEveryLegacyKey_intoExerciseNote_andTheExportIncludesThem() throws {
        ExerciseNotesStore.save(exerciseId: "bench_press", note: "  pause the first rep  ")
        ExerciseNotesStore.save(exerciseId: "plank", note: "squeeze glutes")
        let ctx = ModelContext(try BackupTestSupport.makeContainer())

        LegacyExerciseNotesBackfill.runIfNeeded(in: ctx)

        XCTAssertEqual(try notes(ctx), ["bench_press": "pause the first rep", "plank": "squeeze glutes"])
        XCTAssertTrue(ExerciseNotesStore.legacyEntries().isEmpty, "legacy keys are deleted once the save succeeded")
        let exported = try XCTUnwrap(BackupTestSupport.exportJSON(ctx)["exerciseNotes"] as? [[String: Any]])
        XCTAssertEqual(Set(exported.compactMap { $0["exerciseId"] as? String }), ["bench_press", "plank"])

        // Idempotent: a second run adds nothing.
        LegacyExerciseNotesBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ExerciseNote>()).count, 2)
    }

    func test_neverOverwritesAnExistingNote_andKeepsItsLegacyKey() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        ctx.insert(ExerciseNote(exerciseId: "barbell_row", note: "newer note in SwiftData"))
        try ctx.save()
        ExerciseNotesStore.save(exerciseId: "barbell_row", note: "older legacy text")
        ExerciseNotesStore.save(exerciseId: "hammer_curl", note: "neutral grip")

        LegacyExerciseNotesBackfill.runIfNeeded(in: ctx)

        XCTAssertEqual(try notes(ctx), ["barbell_row": "newer note in SwiftData", "hammer_curl": "neutral grip"])
        XCTAssertEqual(ExerciseNotesStore.legacyEntries().map(\.exerciseId), ["barbell_row"],
                       "the conflicting legacy text is not discarded")
    }

    func test_blankLegacyKeys_createNoNote_andAreRemoved() throws {
        ExerciseNotesStore.save(exerciseId: "plank", note: "   \n ")
        let ctx = ModelContext(try BackupTestSupport.makeContainer())

        LegacyExerciseNotesBackfill.runIfNeeded(in: ctx)

        XCTAssertTrue(try notes(ctx).isEmpty)
        XCTAssertTrue(ExerciseNotesStore.legacyEntries().isEmpty)
    }
}

// MARK: - App Group mechanicalLoad.* projection

final class BackupRestoreMechanicalLoadTests: XCTestCase {

    private var sandbox: DefaultsSandbox!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox()
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    func test_restore_rebuildsTheAppGroupProjection() throws {
        guard let group = UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID) else {
            throw XCTSkip("App Group defaults unavailable in this environment")
        }
        let day = BackupTestSupport.date(1_000_000)
        let source = ModelContext(try BackupTestSupport.makeContainer())
        source.insert(SessionHistory(date: day, weekIndex: 1, title: "A", subtitle: "Week 1", totalExercises: 1,
                                     totalSets: 3, totalVolume: 100, mechanicalLoad: 4321, exercises: []))
        try source.save()

        // Left behind by whatever was on the device before: a day the restored history does not have.
        let staleKey = MechanicalLoadSharedStore.keyPrefix + "1900-01-01"
        group.set(777.0, forKey: staleKey)
        group.removeObject(forKey: MechanicalLoadSharedStore.keyPrefix + Self.dateKey(day))
        XCTAssertEqual(group.double(forKey: staleKey), 777, "precondition: the group store is writable here")

        try BackupTestSupport.restore(from: source, into: try BackupTestSupport.makeContainer())

        XCTAssertEqual(MechanicalLoadSharedStore.read(for: day), 4321, "the restored day is projected")
        XCTAssertEqual(group.double(forKey: staleKey), 0, "a projection with no history behind it is cleared")
    }

    private static func dateKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Calendar.current.startOfDay(for: date))
    }
}
