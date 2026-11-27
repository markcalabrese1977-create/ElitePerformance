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

// MARK: - Readiness prompt ("How are you today?"): a note only, never a load

final class ReadinessPromptTests: XCTestCase {

    private func make(_ status: SessionStatus = .planned) throws -> (SessionScreenViewModel, Session, ModelContext) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let ctx = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let s = Session(date: Date(), status: status, weekIndex: 1, items: [])
        ctx.insert(s)
        return (SessionScreenViewModel(session: s), s, ctx)
    }

    func test_rowShowsOnlyOnAnUnstartedUnansweredPlannedSession_whenAsking() throws {
        let (vm, s, _) = try make()
        XCTAssertTrue(vm.shouldShowReadinessRow(asks: true))
        XCTAssertFalse(vm.shouldShowReadinessRow(asks: false), "toggle off")
        s.startedAt = Date()
        XCTAssertFalse(vm.shouldShowReadinessRow(asks: true), "started")
        s.startedAt = nil
        s.skippedAt = Date()
        XCTAssertFalse(vm.shouldShowReadinessRow(asks: true), "skipped")
        s.skippedAt = nil
        s.readinessReasonsRaw = []
        XCTAssertFalse(vm.shouldShowReadinessRow(asks: true), "already answered")
        let (done, _, _) = try make(.completed)
        XCTAssertFalse(done.shouldShowReadinessRow(asks: true), "completed")
        let (hist, _, _) = try make()
        hist.allowsReadinessPrompt = false
        XCTAssertFalse(hist.shouldShowReadinessRow(asks: true), "opened from History")
    }

    func test_normal_savesEmptyAnswer_clearsReasons_leavesShortOnTime() throws {
        let (vm, s, ctx) = try make()
        vm.toggle(.stressed); vm.toggle(.poorSleep); vm.pendingShortOnTime = true
        vm.answerNormal(using: ctx)
        XCTAssertEqual(s.readinessReasonsRaw, [])
        XCTAssertTrue(vm.pendingReasons.isEmpty)
        XCTAssertEqual(s.shortOnTime, true, "Short on time is independent of Normal")
        XCTAssertFalse(vm.shouldShowReadinessRow(asks: true), "collapses at once")
    }

    func test_toggles_stayOpen_thenFirstSetSavesAndCollapses() throws {
        let (vm, s, _) = try make()
        vm.toggle(.poorSleep); vm.pendingShortOnTime = true
        XCTAssertTrue(vm.shouldShowReadinessRow(asks: true))
        XCTAssertNil(s.readinessReasonsRaw, "nothing saved before the first set")
        vm.commitPendingReadiness()
        XCTAssertEqual(s.readinessReasonsRaw, ["poorSleep"])
        XCTAssertEqual(s.shortOnTime, true)
        XCTAssertFalse(vm.shouldShowReadinessRow(asks: true))
    }

    func test_shortOnTimeAlone_doesNotAnswerTheReadinessQuestion() throws {
        let (vm, s, _) = try make()
        vm.pendingShortOnTime = true
        vm.commitPendingReadiness()
        XCTAssertNil(s.readinessReasonsRaw)
        XCTAssertEqual(s.shortOnTime, true)
    }

    func test_dismiss_leavesNil_andCollapses() throws {
        let (vm, s, _) = try make()
        vm.toggle(.stressed)
        vm.dismissReadiness()
        vm.commitPendingReadiness()
        XCTAssertNil(s.readinessReasonsRaw)
        XCTAssertNil(s.shortOnTime)
        XCTAssertFalse(vm.shouldShowReadinessRow(asks: true))
    }

    func test_answering_isNotLoggedWork_andDoesNotTouchAnyLoad() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self]),
                                                  configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        item.plannedRepsBySet = [8, 8, 8]; item.actualReps = [0, 0, 0]; item.actualLoads = [0, 0, 0]; item.actualRIRs = [0, 0, 0]
        item.setFeedbackBySet = ["", "", ""]; item.pumpRatingsBySet = [0, 0, 0]; item.restPausePatternsBySet = ["", "", ""]
        let s = Session(date: Date(), status: .planned, weekIndex: 1, items: [item])
        ctx.insert(s)
        let vm = SessionScreenViewModel(session: s)
        vm.toggle(.stressed); vm.toggle(.poorSleep); vm.pendingShortOnTime = true
        vm.commitPendingReadiness()
        XCTAssertFalse(SessionEditSafety.hasLoggedData(s))
        XCTAssertTrue(SessionEditSafety.isSafeToModify(s))
        XCTAssertEqual(item.suggestedLoad, 100)
        XCTAssertEqual(item.targetSets, 3)
        XCTAssertEqual(item.targetReps, 8)
    }

    func test_recapWording() {
        XCTAssertNil(ReadinessText.recapLine(reasons: [], shortOnTime: false))
        XCTAssertEqual(ReadinessText.recapLine(reasons: [.poorSleep], shortOnTime: false),
                       "You flagged poor sleep — the plan didn't change for it.")
        let two = ReadinessText.recapLine(reasons: [.stressed, .poorSleep], shortOnTime: true) ?? ""
        XCTAssertTrue(two.contains("stress") && two.contains("poor sleep") && two.contains("short on time"), two)
        XCTAssertTrue(two.hasSuffix("the plan didn't change for them."), two)
        for line in [two, ReadinessText.recapLine(reasons: [], shortOnTime: true) ?? ""] {
            XCTAssertFalse(line.lowercased().contains("lighter") || line.lowercased().contains("reduced") || line.lowercased().contains("adjust"), line)
        }
        XCTAssertNil(ReadinessText.historySuffix(reasons: [], shortOnTime: false))
        XCTAssertEqual(ReadinessText.historySuffix(reasons: [.poorSleep], shortOnTime: true), "· Poor sleep · Short on time")
    }

    func test_backup_roundTripsTheNewFields_andOldBackupsDecodeToNil() throws {
        let src = ModelContext(try BackupTestSupport.makeContainer())
        let s = Session(date: Date(), status: .planned, weekIndex: 1, items: [])
        s.readinessReasonsRaw = ["stressed"]; s.shortOnTime = true
        src.insert(s)
        let profile = UserProfile(); profile.asksReadiness = false
        src.insert(profile)
        try src.save()
        let fresh = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: src, into: fresh)
        let ctx = ModelContext(fresh)
        let back = try XCTUnwrap(ctx.fetch(FetchDescriptor<Session>()).first)
        XCTAssertEqual(back.readinessReasonsRaw, ["stressed"])
        XCTAssertEqual(back.shortOnTime, true)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<UserProfile>()).first?.asksReadiness, false)

        // A 1.3.x backup has none of the three keys, and still carries readinessStars.
        var json = try BackupTestSupport.exportJSON(src)
        var sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertNotNil(sessions[0]["readinessStars"], "readinessStars is still exported for 1.3.3")
        sessions[0].removeValue(forKey: "readinessReasonsRaw"); sessions[0].removeValue(forKey: "shortOnTime")
        json["sessions"] = sessions
        json["exportedAt"] = "2026-01-01T00:00:00Z"
        let data = try JSONSerialization.data(withJSONObject: sessions[0])
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let dto = try dec.decode(SessionBackupDTO.self, from: data)
        XCTAssertNil(dto.readinessReasonsRaw)
        XCTAssertNil(dto.shortOnTime)
    }

    func test_profileDefault_asksReadiness() {
        let p = UserProfile()
        XCTAssertNil(p.asksReadiness)
        XCTAssertTrue(p.asksReadinessOn)
        p.asksReadiness = false
        XCTAssertFalse(p.asksReadinessOn)
    }
}
