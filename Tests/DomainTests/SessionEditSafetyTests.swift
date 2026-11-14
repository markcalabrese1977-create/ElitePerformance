import XCTest
import SwiftData
@testable import ElitePerformance

final class SessionEditSafetyTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
            UserProfile.self, User.self, CustomExercise.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: config))
    }

    private func cleanItem() -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        i.plannedRepsBySet = [8, 8, 8]
        i.actualReps = [0, 0, 0]
        i.actualLoads = [0, 0, 0]
        i.actualRIRs = [0, 0, 0]
        i.setFeedbackBySet = ["", "", ""]
        i.pumpRatingsBySet = [0, 0, 0]
        i.restPausePatternsBySet = ["", "", ""]
        return i
    }

    private func session(_ status: SessionStatus = .planned, item: SessionItem) throws -> (Session, ModelContext) {
        let ctx = try makeContext()
        let s = Session(date: Date(), status: status, weekIndex: 1, items: [item])
        ctx.insert(s)
        return (s, ctx)
    }

    func test_cleanPlannedSession_isSafe() throws {
        let (s, _) = try session(item: cleanItem())
        XCTAssertFalse(SessionEditSafety.hasLoggedData(s))
        XCTAssertTrue(SessionEditSafety.isSafeToModify(s))
    }

    func test_nonPlannedStatus_isNeverSafe() throws {
        for status in [SessionStatus.inProgress, .completed] {
            let (s, _) = try session(status, item: cleanItem())
            XCTAssertFalse(SessionEditSafety.isSafeToModify(s), "\(status)")
        }
    }

    func test_eachLoggedSignal_makesTheSessionUnsafe() throws {
        let mutations: [(String, (SessionItem) -> Void)] = [
            ("isCompleted", { $0.isCompleted = true }),
            ("actualLoads", { $0.actualLoads = [0, 135, 0] }),
            ("actualReps", { $0.actualReps = [0, 0, 5] }),
            ("logs", { $0.logs = [SetLog(setNumber: 1, targetReps: 8, targetRIR: 2, targetLoad: 100, actualReps: 0, actualRIR: 0, actualLoad: 0)] }),
            ("setFeedbackBySet", { $0.setFeedbackBySet = ["", "good", ""] }),
            ("pumpRatingsBySet", { $0.pumpRatingsBySet = [0, 0, 3] }),
            ("skip marker", { $0.restPausePatternsBySet = ["", "SKIP", ""] }),
        ]
        for (name, mutate) in mutations {
            let item = cleanItem()
            mutate(item)
            let (s, _) = try session(item: item)
            XCTAssertTrue(SessionEditSafety.hasLoggedData(s), name)
            XCTAssertFalse(SessionEditSafety.isSafeToModify(s), name)
        }
    }

    func test_restPausePatternWithoutSkip_isNotLoggedData() throws {
        let item = cleanItem()
        item.restPausePatternsBySet = ["", "5+3", ""]
        let (s, _) = try session(item: item)
        XCTAssertFalse(SessionEditSafety.hasLoggedData(s))
    }

    func test_dayLabelMatcher_isExactEquality_likeNextTargetItem() {
        XCTAssertTrue(SessionDayLabelMatcher.matches("Pull B", "Pull B"))
        XCTAssertTrue(SessionDayLabelMatcher.matches(nil, nil))
        XCTAssertFalse(SessionDayLabelMatcher.matches("Pull B", "Pull A"))
        XCTAssertFalse(SessionDayLabelMatcher.matches("Pull B", nil))
        XCTAssertFalse(SessionDayLabelMatcher.matches("Pull B", "Pull B "), "no trimming — same rule as carry-forward")
        XCTAssertFalse(SessionDayLabelMatcher.matches("pull b", "Pull B"), "case-sensitive")
    }
}
