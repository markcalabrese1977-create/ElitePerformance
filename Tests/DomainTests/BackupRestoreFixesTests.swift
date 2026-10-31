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
