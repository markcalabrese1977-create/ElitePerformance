import XCTest
import SwiftData
@testable import ElitePerformance

/// Day-in-week numbering is the session's date-order position within its meso week,
/// not programIndex % 6; and the chronological (wave-nil) carry-forward path never
/// lands on a deload item.
final class WeekDayNumberingTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        return ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Date())! }

    /// weeks x perWeek sessions, programIndex 1...N in date order.
    private func block(_ ctx: ModelContext, weeks: Int, perWeek: Int) throws -> [Session] {
        let blk = MesoBlock(name: "B", startDate: day(0), status: .active, totalWeeks: weeks)
        ctx.insert(blk)
        var out: [Session] = []
        var pi = 1
        for w in 1...weeks {
            for d in 0..<perWeek {
                let s = Session(date: day((w - 1) * 7 + d), status: .planned, weekIndex: w,
                                dayLabel: "Day \(d + 1)", programIndex: pi)
                s.meso = blk
                ctx.insert(s)
                out.append(s)
                pi += 1
            }
        }
        try ctx.save()
        return out
    }

    private func assertNumbering(perWeek: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let ctx = try makeContext()
        let sessions = try block(ctx, weeks: 4, perWeek: perWeek)
        for (i, s) in sessions.enumerated() {
            let expectedDay = (i % perWeek) + 1
            let expectedWeek = (i / perWeek) + 1
            XCTAssertEqual(s.dayNumberInWeek, expectedDay, file: file, line: line)
            XCTAssertEqual(s.weekDayLabel, "W\(expectedWeek)D\(expectedDay)", file: file, line: line)
        }
    }

    func test_twoDayBlock() throws { try assertNumbering(perWeek: 2) }
    func test_threeDayBlock() throws { try assertNumbering(perWeek: 3) }
    func test_fourDayBlock() throws { try assertNumbering(perWeek: 4) }
    func test_sixDayBlock() throws { try assertNumbering(perWeek: 6) }

    func test_numberingIgnoresProgramIndexGaps() throws {
        let ctx = try makeContext()
        let sessions = try block(ctx, weeks: 2, perWeek: 3)
        // Renumber programIndex with a shift (as an inserted week would); labels must not move.
        for s in sessions { s.programIndex = (s.programIndex ?? 0) + 7 }
        XCTAssertEqual(sessions[4].weekDayLabel, "W2D2")
    }

    func test_chronologicalCarryForward_skipsDeloadItem() throws {
        let ctx = try makeContext()
        let blk = MesoBlock(name: "NonWave", startDate: day(0), status: .active, totalWeeks: 3)
        ctx.insert(blk)
        func item(_ wave: String?) -> SessionItem {
            SessionItem(order: 1, exerciseId: "leg_extension", targetReps: 10, targetSets: 3,
                        targetRIR: 2, suggestedLoad: 100, waveRaw: wave, repMin: 8, repMax: 12)
        }
        let src = item(nil), deload = item("deload"), working = item(nil)
        let s1 = Session(date: day(0), status: .completed, weekIndex: 1, dayLabel: "Legs", items: [src])
        let s2 = Session(date: day(7), status: .planned, weekIndex: 2, dayLabel: "Legs", items: [deload])
        let s3 = Session(date: day(14), status: .planned, weekIndex: 3, dayLabel: "Legs", items: [working])
        for s in [s1, s2, s3] { s.meso = blk; ctx.insert(s) }
        try ctx.save()
        let target = PlanMemoryEngine.nextTargetItem(for: src, after: s1, in: [s1, s2, s3])
        XCTAssertTrue(target === working, "working must feed working, never the deload item")
    }
}
