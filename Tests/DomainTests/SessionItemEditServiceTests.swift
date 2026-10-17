import XCTest
import SwiftData
@testable import ElitePerformance

final class SessionItemEditServiceTests: XCTestCase {

    private typealias Service = SessionItemEditService

    private var container: ModelContainer!   // keeps the in-memory store alive for the test

    // MARK: - Fixtures

    private func cal() -> Calendar { Calendar(identifier: .gregorian) }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal().date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The real 10-week DUP block (Fri Sep 25 2026 start, six days a week). `convert12` runs the
    /// production 10 -> 12 week conversion on it.
    private func makeBlock(convert12: Bool = false) throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        try DUPProgramSeeder.seed(
            startDate: date(2026, 9, 25), trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
            template: DUP10WeekTemplate.template, calendar: cal(),
            mesoName: "10-Week DUP Meso", mesoStatus: .active
        )
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
        if convert12 {
            for k in [TwelveWeekMesoConversionMigration.completionKey, TwelveWeekMesoConversionMigration.dryRunLoggedKey,
                      TwelveWeekMesoConversionMigration.reportKey, TwelveWeekMesoConversionMigration.shapeWarnedKey] {
                UserDefaults.standard.removeObject(forKey: k)
            }
            try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
            XCTAssertEqual(block.totalWeeks, 12)
        }
        try ctx.save()
        return (ctx, block)
    }

    private func sessions(_ block: MesoBlock) -> [Session] { block.sessions.sorted { $0.date < $1.date } }

    /// A day type + exercise that recurs through the block, and a replacement the block never uses.
    private func pick(_ block: MesoBlock) throws -> (day: String, x: String, y: String) {
        let first = try XCTUnwrap(sessions(block).first)
        let day = try XCTUnwrap(first.dayLabel)
        let x = try XCTUnwrap(first.items.sorted { $0.order < $1.order }.first {
            !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId)
        }).exerciseId
        let used = Set(block.sessions.flatMap(\.items).map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        let y = try XCTUnwrap(ExerciseCatalog.all.first {
            !used.contains($0.id) && !ExerciseCatalog.isBodyweight(exerciseId: $0.id)
        }).id
        return (day, x, y)
    }

    private func item(_ s: Session, _ id: String) -> SessionItem? {
        s.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: id) }
    }

    /// Writes a finished performance onto `item` and completes its session.
    private func complete(_ s: Session, item: SessionItem, load: Double, reps: Int = 8) {
        let n = max(1, item.targetSets)
        item.actualLoads = Array(repeating: load, count: n)
        item.actualReps = Array(repeating: reps, count: n)
        item.actualRIRs = Array(repeating: 2, count: n)
        item.isCompleted = true
        s.status = .completed
    }

    private func prescriptionFingerprint(_ i: SessionItem) -> String {
        "\(i.waveRaw ?? "")|\(i.priorityRaw ?? "")|\(i.intensifierRaw ?? "")|\(i.order)|\(i.targetReps)|\(i.targetSets)|\(i.targetRIR)"
        + "|\(i.setMin.map(String.init) ?? "")|\(i.setMax.map(String.init) ?? "")|\(i.repMin.map(String.init) ?? "")|\(i.repMax.map(String.init) ?? "")"
        + "|\(i.targetRIRMin.map(String.init) ?? "")|\(i.targetRIRMax.map(String.init) ?? "")|\(i.plannedRepsBySet)|\(i.plannedRIRsBySet)"
    }

    private func plan(_ block: MesoBlock, _ ctx: ModelContext, _ p: (day: String, x: String, y: String),
                      scope: Service.ReplaceScope = .allRemaining, now: Date) -> Service.ReplacePlan {
        Service.planReplace(meso: block, dayLabel: p.day, from: p.x, to: p.y, scope: scope, context: ctx, now: now)
    }

    // MARK: - Plan

    func test_plan_targetsAreRemainingPlannedSessionsOfTheDayLabelThatHoldX_andWritesNothing() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let now = date(2026, 10, 1)   // week 1 is past
        let before = block.sessions.flatMap(\.items).map { "\($0.exerciseId)|\($0.suggestedLoad)|\(prescriptionFingerprint($0))" }

        let result = plan(block, ctx, p, now: now)

        let expected = sessions(block).filter {
            $0.dayLabel == p.day && $0.date > now && item($0, p.x) != nil
        }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(result.targets.map { $0.session.persistentModelID }, expected.map(\.persistentModelID))
        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(Set(result.seedLoadByWave.keys), ["a", "b", "c"])
        XCTAssertEqual(block.sessions.flatMap(\.items).map { "\($0.exerciseId)|\($0.suggestedLoad)|\(prescriptionFingerprint($0))" }, before,
                       "planning is pure")
        for t in result.targets { XCTAssertTrue(t.prescription.contains(" x "), t.prescription) }
    }

    // MARK: - Apply: preservation and reset

    func test_apply_12weekBlock_preservesPrescriptionsAndOnlyTouchesRemainingPlannedSessionsOfThatDay() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let all = sessions(block)

        // Week 1's session of this day is done and logged; it must stay exactly as it is.
        let done = try XCTUnwrap(all.first { $0.dayLabel == p.day })
        let doneItem = try XCTUnwrap(item(done, p.x))
        complete(done, item: doneItem, load: 135)
        try ctx.save()
        let now = done.date.addingTimeInterval(3600)

        let fingerprints = Dictionary(uniqueKeysWithValues: all.flatMap { s in
            s.items.map { ($0.persistentModelID, prescriptionFingerprint($0)) }
        })
        let others = all.filter { $0.dayLabel != p.day }.flatMap(\.items).map { "\($0.persistentModelID)|\($0.exerciseId)|\($0.suggestedLoad)|\($0.plannedLoadsBySet)" }

        let result = plan(block, ctx, p, now: now)
        let applied = try Service.apply(result, in: ctx)
        XCTAssertEqual(applied.sessionsChanged, result.targets.count)
        XCTAssertGreaterThan(result.targets.count, 3)

        let yName = ExerciseCatalog.displayName(for: p.y)
        for t in result.targets {
            XCTAssertEqual(t.item.exerciseId, p.y)
            XCTAssertEqual(t.item.exerciseNameSnapshot, yName)
            XCTAssertEqual(prescriptionFingerprint(t.item), fingerprints[t.item.persistentModelID], "prescription untouched")
            XCTAssertEqual(t.item.plannedLoadsBySet.count, t.item.targetSets)
            XCTAssertEqual(t.item.actualLoads.count, t.item.targetSets)
            XCTAssertEqual(t.item.actualReps.count, t.item.targetSets)
            XCTAssertEqual(t.item.actualRIRs.count, t.item.targetSets)
        }
        XCTAssertEqual(doneItem.exerciseId, p.x, "completed session untouched")
        XCTAssertEqual(doneItem.actualLoads.first, 135)
        XCTAssertEqual(all.filter { $0.dayLabel != p.day }.flatMap(\.items).map { "\($0.persistentModelID)|\($0.exerciseId)|\($0.suggestedLoad)|\($0.plannedLoadsBySet)" },
                       others, "other day labels untouched")
        // No planned later session of this day still holds X.
        for s in all where s.dayLabel == p.day && s.date > now { XCTAssertNil(item(s, p.x)) }
    }

    func test_apply_resetsPerExerciseStateAndClearsPlanEdited() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let target = try XCTUnwrap(sessions(block).last { $0.dayLabel == p.day && item($0, p.x) != nil })
        let i = try XCTUnwrap(item(target, p.x))
        i.planEdited = true; i.isPR = true; i.isCompleted = false
        i.coachNote = "hold"; i.prescriptionNotes = "n"; i.intensifierNotes = "i"
        i.loadOverrideReasonRaw = LoadOverrideReason.allCases.first?.rawValue
        i.nextSuggestedLoad = 222
        i.suggestedLoad = 150; i.plannedLoadsBySet = [150, 150, 150, 150, 150, 150, 150]
        i.actualLoads = []; i.actualReps = []
        i.usedRestPauseFlags = [false]; i.restPausePatternsBySet = [""]
        let wave = i.waveRaw, sets = i.targetSets
        try ctx.save()

        let result = plan(block, ctx, p, scope: .thisSession(target), now: date(2026, 9, 1))
        XCTAssertEqual(result.targets.count, 1)
        try Service.apply(result, in: ctx)

        XCTAssertEqual(i.exerciseId, p.y)
        XCTAssertFalse(i.planEdited); XCTAssertFalse(i.isPR); XCTAssertFalse(i.isCompleted)
        XCTAssertNil(i.coachNote); XCTAssertNil(i.prescriptionNotes); XCTAssertNil(i.intensifierNotes)
        XCTAssertNil(i.loadOverrideReasonRaw); XCTAssertNil(i.nextSuggestedLoad)
        XCTAssertTrue(i.logs.isEmpty)
        XCTAssertEqual(i.waveRaw, wave)
        XCTAssertEqual(i.targetSets, sets)
        XCTAssertEqual(i.plannedLoadsBySet, Array(repeating: 0.0, count: sets), "no history -> 0, sized to targetSets")
        XCTAssertEqual(i.suggestedLoad, 0)
        for arr in [i.actualReps.map(Double.init), i.actualLoads, i.actualRIRs.map(Double.init), i.pumpRatingsBySet.map(Double.init)] {
            XCTAssertEqual(arr.count, sets)
            XCTAssertTrue(arr.allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(i.usedRestPauseFlags, Array(repeating: false, count: sets))
        XCTAssertEqual(i.restPausePatternsBySet, Array(repeating: "", count: sets))
        XCTAssertEqual(i.dropSetPatternsBySet, Array(repeating: "", count: sets))
        XCTAssertEqual(i.setFeedbackBySet, Array(repeating: "", count: sets))
    }

    func test_thisSessionScope_writesOnlyThatSession() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let days = sessions(block).filter { $0.dayLabel == p.day && item($0, p.x) != nil }
        let chosen = days[2]
        let result = plan(block, ctx, p, scope: .thisSession(chosen), now: date(2026, 9, 1))
        try Service.apply(result, in: ctx)
        for s in days {
            XCTAssertEqual(item(s, p.x) != nil, s !== chosen, "only the chosen session lost X")
        }
        XCTAssertNotNil(item(chosen, p.y))
    }

    // MARK: - Seeding

    func test_seed_comesFromCompletedHistoryOnly_perWave() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let all = sessions(block)

        // Completed history of Y in an earlier session of ANOTHER day: 100 x 10.
        let other = try XCTUnwrap(all.first { $0.dayLabel != p.day })
        other.items.append(SessionItem(order: 99, exerciseId: p.y, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0,
                                       actualReps: [10, 10, 10], actualLoads: [100, 100, 100]))
        other.status = .completed
        // A planned future session claiming a huge suggested load for Y must not matter.
        let decoy = try XCTUnwrap(all.last { $0.dayLabel != p.day })
        decoy.items.append(SessionItem(order: 99, exerciseId: p.y, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 999,
                                       plannedLoadsBySet: [999, 999, 999], actualReps: [10], actualLoads: [999]))
        try ctx.save()

        let now = other.date.addingTimeInterval(86400)
        let result = plan(block, ctx, p, now: now)
        let expected = try XCTUnwrap(HistorySeedLoad.load(
            for: p.y, goalReps: try XCTUnwrap(result.targets.first).item.targetReps,
            targetRIR: try XCTUnwrap(result.targets.first).item.targetRIR,
            in: (try ctx.fetch(FetchDescriptor<Session>())), loadIncrement: 2.5, referenceDate: now))
        XCTAssertGreaterThan(expected, 0)
        XCTAssertLessThan(expected, 200, "the 999 decoy never contributes")

        try Service.apply(result, in: ctx)
        for t in result.targets {
            let seed = try XCTUnwrap(t.seedLoad)
            XCTAssertEqual(t.item.suggestedLoad, seed)
            XCTAssertEqual(t.item.plannedLoadsBySet, Array(repeating: seed, count: t.item.targetSets))
            XCTAssertLessThan(seed, 200)
        }
    }

    // MARK: - Refusals

    func test_refusals_unsafe_alreadyContainsReplacement_inactiveMeso_sameExercise() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let days = sessions(block).filter { $0.dayLabel == p.day && item($0, p.x) != nil }
        let now = date(2026, 9, 1)

        // Planned but already logged -> unsafe.
        let logged = try XCTUnwrap(item(days[1], p.x))
        logged.actualLoads = [135]; logged.actualReps = [5]
        // Already holds Y -> refused.
        days[2].items.append(SessionItem(order: 98, exerciseId: p.y, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0))
        try ctx.save()

        var result = plan(block, ctx, p, now: now)
        XCTAssertEqual(result.refusals.first { $0.session === days[1] }?.reason, .unsafe)
        XCTAssertEqual(result.refusals.first { $0.session === days[2] }?.reason, .alreadyContainsReplacement)
        XCTAssertFalse(result.targets.contains { $0.session === days[1] || $0.session === days[2] })
        XCTAssertTrue(result.targets.contains { $0.session === days[0] })

        try Service.apply(result, in: ctx)
        XCTAssertNotNil(item(days[1], p.x), "unsafe session untouched")
        XCTAssertNotNil(item(days[2], p.x), "duplicate-Y session untouched")
        XCTAssertEqual(logged.actualLoads, [135])

        block.status = .archived
        result = plan(block, ctx, p, now: now)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertTrue(result.refusals.allSatisfy { $0.reason == .inactiveMeso })
        XCTAssertThrowsError(try Service.apply(result, in: ctx)) { XCTAssertEqual($0 as? Service.ReplaceError, .nothingToReplace) }

        block.status = .active
        result = Service.planReplace(meso: block, dayLabel: p.day, from: p.x, to: p.x, scope: .allRemaining, context: ctx, now: now)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertTrue(result.refusals.allSatisfy { $0.reason == .sameExercise })
    }

    func test_apply_abortsWhenTheLiveTargetSetNoLongerMatchesThePlan_andWritesNothing() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let result = plan(block, ctx, p, now: date(2026, 9, 1))
        XCTAssertGreaterThan(result.targets.count, 2)

        // Between preview and apply the lifter starts one of the target sessions.
        let victim = result.targets[1]
        victim.item.actualLoads = [135]; victim.item.actualReps = [5]
        victim.session.status = .inProgress
        let snapshot = result.targets.map { "\($0.item.exerciseId)|\($0.item.suggestedLoad)" }

        XCTAssertThrowsError(try Service.apply(result, in: ctx)) {
            XCTAssertEqual($0 as? Service.ReplaceError, .planStale(planned: result.targets.count, live: result.targets.count - 1))
        }
        XCTAssertEqual(result.targets.map { "\($0.item.exerciseId)|\($0.item.suggestedLoad)" }, snapshot, "nothing written")
        XCTAssertTrue(result.targets.allSatisfy { $0.item.exerciseId != p.y })
    }

    // MARK: - Carry-forward

    func test_journey_replaceThenCompleteNextB_carryForwardWritesTheNextBWithY() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let result = plan(block, ctx, p, now: date(2026, 9, 1))
        try Service.apply(result, in: ctx)

        // Every letter chain resolves to Y at each hop.
        let all = sessions(block)
        let bs = result.targets.filter { $0.waveRaw?.lowercased() == "b" }.sorted { $0.date < $1.date }
        XCTAssertGreaterThanOrEqual(bs.count, 3)
        for (cur, nxt) in zip(bs, bs.dropFirst()) {
            XCTAssertTrue(PlanMemoryEngine.nextTargetItem(for: cur.item, after: cur.session, in: all) === nxt.item)
        }

        // The lifter enters a load on the first B, trains it, and carry-forward runs.
        let firstB = bs[0], nextB = bs[1]
        firstB.item.suggestedLoad = 100
        firstB.item.plannedLoadsBySet = Array(repeating: 100.0, count: firstB.item.targetSets)
        complete(firstB.session, item: firstB.item, load: 100, reps: firstB.item.targetReps)
        try ctx.save()
        XCTAssertEqual(nextB.item.suggestedLoad, 0)

        PlanMemoryEngine(context: ctx).carryForwardPlans(from: firstB.session)

        XCTAssertEqual(nextB.item.exerciseId, p.y)
        XCTAssertGreaterThan(nextB.item.suggestedLoad, 0, "result on Y reaches the next B's Y")
        XCTAssertEqual(nextB.item.waveRaw?.lowercased(), "b")
    }

    func test_nonWaveMaintenanceBlock_chronologicalChainResolvesToY() throws {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        let meso = MesoBlock(name: "Maintenance Block", startDate: date(2026, 10, 5), status: .active, totalWeeks: 4, isMaintenance: true)
        ctx.insert(meso)
        var sess: [Session] = []
        for w in 1...4 {
            let it = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 10, targetSets: 2, targetRIR: 3, suggestedLoad: 100,
                                 plannedRepsBySet: [10, 10], plannedLoadsBySet: [100, 100], plannedRIRsBySet: [3, 3])
            let s = Session(date: date(2026, 10, 5 + (w - 1) * 7), status: .planned, weekIndex: w, dayLabel: "Day A", items: [it])
            s.meso = meso
            ctx.insert(s)
            sess.append(s)
        }
        try ctx.save()
        XCTAssertFalse(WavePrescriptionGuard.isWaveBasedBlock(sess[0]))

        let result = Service.planReplace(meso: meso, dayLabel: "Day A", from: "bench_press", to: "machine_chest_press",
                                         scope: .allRemaining, context: ctx, now: date(2026, 10, 1))
        XCTAssertEqual(result.targets.count, 4)
        try Service.apply(result, in: ctx)

        for s in sess { XCTAssertEqual(s.items[0].exerciseId, "machine_chest_press") }
        for (a, b) in zip(sess, sess.dropFirst()) {
            XCTAssertTrue(PlanMemoryEngine.nextTargetItem(for: a.items[0], after: a, in: sess) === b.items[0],
                          "no wave -> next chronological occurrence")
        }
        XCTAssertEqual(sess[3].items[0].plannedRepsBySet, [10, 10])
    }
}
