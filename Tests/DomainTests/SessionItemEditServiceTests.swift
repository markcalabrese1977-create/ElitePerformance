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
            $0.dayLabel == p.day && $0.date >= Calendar.current.startOfDay(for: now) && item($0, p.x) != nil
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
        victim.item.actualLoads = [135]; victim.item.actualReps = [5]   // logged -> no longer safe to edit
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

    // MARK: - C4b: rollback, today boundary, in-progress

    /// Every stored field of every session and item in the store, as one comparable string.
    private func fullSnapshot(_ ctx: ModelContext) throws -> [String] {
        var out: [String] = []
        let all = try ctx.fetch(FetchDescriptor<Session>()).sorted { ($0.date, $0.weekIndex, $0.dayLabel ?? "") < ($1.date, $1.weekIndex, $1.dayLabel ?? "") }
        for s in all {
            out.append("S|\(s.date.timeIntervalSince1970)|\(s.status.rawValue)|\(s.weekIndex)|\(s.dayLabel ?? "")|\(s.programIndex.map(String.init) ?? "")|\(s.sessionNotes ?? "")|\(s.items.count)")
            for i in s.items.sorted(by: { ($0.order, $0.exerciseId) < ($1.order, $1.exerciseId) }) {
                let opt: (Int?) -> String = { $0.map(String.init) ?? "-" }
                out.append([
                    "I", i.id?.uuidString ?? "", "\(i.order)", i.exerciseId, i.exerciseNameSnapshot ?? "-",
                    "\(i.targetReps)", "\(i.targetSets)", "\(i.targetRIR)", "\(i.suggestedLoad)",
                    i.waveRaw ?? "-", i.priorityRaw ?? "-", opt(i.setMin), opt(i.setMax), opt(i.repMin), opt(i.repMax),
                    opt(i.targetRIRMin), opt(i.targetRIRMax), i.intensifierRaw ?? "-", i.intensifierNotes ?? "-", i.prescriptionNotes ?? "-",
                    "\(i.logs.count)", "\(i.plannedRepsBySet)", "\(i.plannedLoadsBySet)", "\(i.plannedRIRsBySet)", "\(i.planEdited)",
                    "\(i.actualReps)", "\(i.actualLoads)", "\(i.actualRIRs)", "\(i.usedRestPauseFlags)", "\(i.restPausePatternsBySet)",
                    "\(i.dropSetPatternsBySet)", "\(i.setFeedbackBySet)", "\(i.pumpRatingsBySet)", "\(i.isCompleted)", "\(i.isPR)",
                    i.coachNote ?? "-", i.loadOverrideReasonRaw ?? "-", i.nextSuggestedLoad.map { "\($0)" } ?? "-",
                ].joined(separator: "|"))
            }
        }
        return out
    }

    /// Dirties the planned targets with state the replace is supposed to reset, without making them "logged".
    private func dirty(_ result: Service.ReplacePlan) {
        for t in result.targets {
            t.item.planEdited = true; t.item.isPR = true; t.item.coachNote = "keep"; t.item.prescriptionNotes = "note"
            t.item.intensifierNotes = "int"; t.item.nextSuggestedLoad = 321; t.item.suggestedLoad = 150
            t.item.plannedLoadsBySet = Array(repeating: 150, count: t.item.targetSets + 1)
            t.item.loadOverrideReasonRaw = LoadOverrideReason.allCases.first?.rawValue
        }
    }

    func test_forcedVerificationFailure_throwsAndLeavesEveryFieldUnchanged() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let result = plan(block, ctx, p, now: date(2026, 9, 1))
        dirty(result)
        try ctx.save()
        let before = try fullSnapshot(ctx)

        XCTAssertThrowsError(try Service.apply(result, in: ctx, hooks: .init(forceVerificationFailure: true))) {
            guard case Service.ReplaceError.verificationFailed(let problems) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(problems.contains { $0.contains("forced") }, "\(problems)")
        }
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(try fullSnapshot(ctx), before)
        XCTAssertTrue(result.targets.allSatisfy { $0.item.exerciseId == p.x })

        // The store is still usable: the same plan applies cleanly afterwards.
        XCTAssertNoThrow(try Service.apply(result, in: ctx))
        XCTAssertTrue(result.targets.allSatisfy { $0.item.exerciseId == p.y })
    }

    func test_forcedSaveFailure_throwsAndLeavesEveryFieldUnchanged() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let result = plan(block, ctx, p, now: date(2026, 9, 1))
        dirty(result)
        try ctx.save()
        let before = try fullSnapshot(ctx)

        XCTAssertThrowsError(try Service.apply(result, in: ctx, hooks: .init(forceSaveFailure: true))) {
            guard case Service.ReplaceError.saveFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(try fullSnapshot(ctx), before)
    }

    func test_pendingCallerChanges_areSavedBeforeApply_soARollbackIsExact() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let result = plan(block, ctx, p, now: date(2026, 9, 1))
        let bystander = try XCTUnwrap(sessions(block).first { $0.dayLabel != p.day }?.items.first)
        bystander.coachNote = "unsaved caller edit"
        XCTAssertTrue(ctx.hasChanges)

        XCTAssertThrowsError(try Service.apply(result, in: ctx, hooks: .init(forceVerificationFailure: true)))
        XCTAssertEqual(bystander.coachNote, "unsaved caller edit", "the caller's pending edit survives the rollback")
        XCTAssertTrue(result.targets.allSatisfy { $0.item.exerciseId == p.x })
    }

    func test_apply_refusesWhileAnySessionInTheMesoIsInProgress() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let result = plan(block, ctx, p, now: date(2026, 9, 1))
        let other = try XCTUnwrap(sessions(block).first { $0.dayLabel != p.day })
        other.status = .inProgress
        try ctx.save()
        let before = try fullSnapshot(ctx)

        XCTAssertThrowsError(try Service.apply(result, in: ctx)) { XCTAssertEqual($0 as? Service.ReplaceError, .sessionInProgress) }
        XCTAssertEqual(try fullSnapshot(ctx), before)

        other.status = .planned
        XCTAssertNoThrow(try Service.apply(result, in: ctx))
    }

    func test_remaining_includesAPlannedSessionDatedEarlierTodayButNotYesterday() throws {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        let meso = MesoBlock(name: "Block", startDate: Date(), status: .active, totalWeeks: 4)
        ctx.insert(meso)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(dayOffset: Int, hour: Int) -> Date {
            calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: dayOffset, to: today)!)!
        }
        func make(_ date: Date) -> Session {
            let it = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0,
                                 plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [0, 0, 0], plannedRIRsBySet: [2, 2, 2])
            let s = Session(date: date, status: .planned, weekIndex: 1, dayLabel: "Day A", items: [it])
            s.meso = meso
            ctx.insert(s)
            return s
        }
        let yesterday = make(at(dayOffset: -1, hour: 6))
        let earlierToday = make(at(dayOffset: 0, hour: 6))
        let tomorrow = make(at(dayOffset: 1, hour: 6))
        try ctx.save()

        let result = Service.planReplace(meso: meso, dayLabel: "Day A", from: "bench_press", to: "machine_chest_press",
                                         scope: .allRemaining, context: ctx, now: at(dayOffset: 0, hour: 15))
        let ids = Set(result.targets.map { $0.session.persistentModelID })
        XCTAssertTrue(ids.contains(earlierToday.persistentModelID), "today 06:00 is remaining at 15:00")
        XCTAssertTrue(ids.contains(tomorrow.persistentModelID))
        XCTAssertFalse(ids.contains(yesterday.persistentModelID), "a missed session from before today is history")
    }

    /// Prints the 12-week-fixture seed for a lift with RIR-2 history, before (reps only) and after (C3b).
    func test_report_12weekSeed_forRIR2History_beforeVsAfter() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let all = sessions(block)
        let other = try XCTUnwrap(all.first { $0.dayLabel != p.day })
        other.items.append(SessionItem(order: 99, exerciseId: p.y, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 0,
                                       actualReps: [9, 9, 9], actualLoads: [130, 130, 130], actualRIRs: [2, 2, 2]))
        other.status = .completed
        try ctx.save()
        let now = other.date.addingTimeInterval(86400)
        let result = plan(block, ctx, p, now: now)

        var lines: [String] = []
        for letter in ["a", "b", "c"] {
            let t = try XCTUnwrap(result.targets.first { $0.waveRaw?.lowercased() == letter })
            let reps = t.item.targetReps, rir = t.item.targetRIR
            // C3 formula: e1RM from reps only.
            let oldE1 = E1RMCalculator.e1RM(load: 130, reps: 9)
            let old = E1RMCalculator.rounded(E1RMCalculator.load(for: oldE1, reps: reps, targetRIR: rir), increment: 2.5)
            let new = try XCTUnwrap(t.seedLoad)
            lines.append("wave \(letter.uppercased()) (\(reps) reps @ RIR \(rir)): C3 \(old) -> C3b \(new)")
            XCTAssertGreaterThan(new, old)
        }
        print("SEED_COMPARE 130x9@RIR2 history, 12-week fixture\n" + lines.joined(separator: "\n"))
    }

    // MARK: - Change prescription (P1)

    private func planChange(
        _ block: MesoBlock, _ ctx: ModelContext, day: String, exercise: String,
        letters: Set<String>? = nil, includeDeload: Bool = false,
        scope: Service.ReplaceScope = .allRemaining, change: PrescriptionChange, now: Date = Date(timeIntervalSince1970: 0)
    ) -> Service.ChangePlan {
        Service.planChangePrescription(meso: block, dayLabel: day, exerciseId: exercise, letters: letters,
                                       includeDeload: includeDeload, scope: scope, change: change, now: now)
    }

    private func letter(_ i: SessionItem) -> String { i.waveRaw?.lowercased() ?? "" }

    func test_change_aOnly_leavesBAndCUntouched() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let before = Dictionary(uniqueKeysWithValues: block.sessions.flatMap(\.items).map { ($0.persistentModelID, prescriptionFingerprint($0)) })

        let result = planChange(block, ctx, day: p.day, exercise: p.x, letters: ["a"], change: PrescriptionChange(setDelta: 1))
        XCTAssertFalse(result.targets.isEmpty)
        XCTAssertTrue(result.targets.allSatisfy { letter($0.item) == "a" })
        let applied = try Service.applyChange(result, in: ctx)
        XCTAssertEqual(applied.sessionsChanged, result.targets.count)

        let changedIDs = Set(result.targets.map { $0.item.persistentModelID })
        for item in block.sessions.flatMap(\.items) where !changedIDs.contains(item.persistentModelID) {
            XCTAssertEqual(prescriptionFingerprint(item), before[item.persistentModelID], "B, C and other exercises untouched")
        }
        for t in result.targets { XCTAssertEqual(t.item.targetSets, t.before.sets + 1) }
    }

    func test_change_deloadIsSkippedByDefault_andIncludedOnRequest() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let skipped = planChange(block, ctx, day: p.day, exercise: p.x, change: PrescriptionChange(setDelta: 1))
        XCTAssertTrue(skipped.targets.allSatisfy { letter($0.item) != "deload" })
        XCTAssertTrue(skipped.refusals.contains { $0.reason == .deload }, "the deload week is reported, not silently dropped")

        let included = planChange(block, ctx, day: p.day, exercise: p.x, includeDeload: true, change: PrescriptionChange(setDelta: 1))
        XCTAssertTrue(included.targets.contains { letter($0.item) == "deload" })
        XCTAssertEqual(included.targets.count, skipped.targets.count + skipped.refusals.filter { $0.reason == .deload }.count)
    }

    func test_change_plusOneOnARampedExercise_keepsTheRelativeShape() throws {
        let (ctx, block) = try makeBlock()
        // Find an exercise whose per-week set counts ramp (a week with more sets than the one before).
        let all = sessions(block)
        var chosen: (day: String, x: String)?
        for first in all.prefix(6) {
            guard let day = first.dayLabel else { continue }
            for it in first.items where !ExerciseCatalog.isBodyweight(exerciseId: it.exerciseId) {
                let weeks = all.filter { $0.dayLabel == day }.compactMap { s in item(s, it.exerciseId).map { (s.weekIndex, $0.targetSets) } }
                if zip(weeks, weeks.dropFirst()).contains(where: { $1.1 > $0.1 }) { chosen = (day, it.exerciseId); break }
            }
            if chosen != nil { break }
        }
        let c = try XCTUnwrap(chosen, "the DUP10 template ramps sets in week 8")
        let result = planChange(block, ctx, day: c.day, exercise: c.x, change: PrescriptionChange(setDelta: 1))
        let beforeByWeek = Dictionary(uniqueKeysWithValues: result.targets.map { ($0.weekIndex, $0.before.sets) })
        try Service.applyChange(result, in: ctx)
        let afterByWeek = Dictionary(uniqueKeysWithValues: result.targets.map { ($0.weekIndex, $0.item.targetSets) })

        let weeks = beforeByWeek.keys.sorted()
        for (a, b) in zip(weeks, weeks.dropFirst()) {
            XCTAssertEqual(afterByWeek[b]! - afterByWeek[a]!, beforeByWeek[b]! - beforeByWeek[a]!, "wk\(a)->wk\(b) step preserved")
        }
        XCTAssertTrue(afterByWeek.allSatisfy { $0.value == beforeByWeek[$0.key]! + 1 })
    }

    func test_change_setCount_resizesLoadsRepsAndRIRArrays_bothDirections() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let target = try XCTUnwrap(sessions(block).last { $0.dayLabel == p.day && item($0, p.x) != nil })
        let it = try XCTUnwrap(item(target, p.x))
        it.targetSets = 3
        it.targetReps = 8; it.targetRIR = 2
        it.plannedLoadsBySet = [50, 60, 70]; it.plannedRepsBySet = [8, 8, 8]; it.plannedRIRsBySet = [2, 2, 2]
        it.waveRaw = "a"
        try ctx.save()

        func run(_ delta: Int) throws {
            let result = planChange(block, ctx, day: p.day, exercise: p.x, scope: .thisSession(target), change: PrescriptionChange(setDelta: delta))
            try Service.applyChange(result, in: ctx)
        }
        try run(+1)
        XCTAssertEqual(it.targetSets, 4)
        XCTAssertEqual(it.plannedLoadsBySet, [50, 60, 70, 70], "grow repeats the last load")
        XCTAssertEqual(it.plannedRepsBySet, [8, 8, 8, 8]); XCTAssertEqual(it.plannedRIRsBySet, [2, 2, 2, 2])
        try run(-1)
        XCTAssertEqual(it.targetSets, 3)
        XCTAssertEqual(it.plannedLoadsBySet, [50, 60, 70], "shrink keeps the first N")
        XCTAssertEqual(it.plannedRepsBySet.count, 3); XCTAssertEqual(it.plannedRIRsBySet.count, 3)

        it.plannedLoadsBySet = []
        try run(+1)
        XCTAssertEqual(it.plannedLoadsBySet, [0, 0, 0, 0], "empty -> zeros")
    }

    func test_change_repAndRIRRanges_writeTheRangesAndTheFlattenedDefaults() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let result = planChange(block, ctx, day: p.day, exercise: p.x, letters: ["b"],
                                change: PrescriptionChange(repRange: 6...8, rirRange: 1...2))
        try Service.applyChange(result, in: ctx)
        for t in result.targets {
            let i = t.item
            XCTAssertEqual(i.repMin, 6); XCTAssertEqual(i.repMax, 8); XCTAssertEqual(i.targetReps, 6)
            XCTAssertEqual(i.targetRIRMin, 1); XCTAssertEqual(i.targetRIRMax, 2); XCTAssertEqual(i.targetRIR, 2)
            XCTAssertEqual(i.plannedRepsBySet, Array(repeating: 6, count: i.targetSets))
            XCTAssertEqual(i.plannedRIRsBySet, Array(repeating: 2, count: i.targetSets))
            XCTAssertEqual(t.after.text, "\(t.before.sets) x 6-8 @ RIR 1-2")
        }
    }

    func test_change_neverTouchesPlanEdited_loadValues_orActuals() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let targets = sessions(block).filter { $0.dayLabel == p.day && item($0, p.x) != nil }.suffix(4)
        let items = targets.compactMap { item($0, p.x) }
        items[0].planEdited = true; items[1].planEdited = false; items[2].planEdited = true; items[3].planEdited = false
        for i in items { i.suggestedLoad = 120; i.plannedLoadsBySet = Array(repeating: 120.0, count: i.targetSets) }
        let flags = items.map(\.planEdited)
        let result = planChange(block, ctx, day: p.day, exercise: p.x, change: PrescriptionChange(setDelta: 1, repRange: 5...7))
        try Service.applyChange(result, in: ctx)
        XCTAssertEqual(items.map(\.planEdited), flags, "true stays true, false stays false")
        for i in items {
            XCTAssertEqual(i.suggestedLoad, 120)
            XCTAssertTrue(i.plannedLoadsBySet.allSatisfy { $0 == 120 }, "values unchanged; only the length follows the set count")
            XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets)
        }
    }

    func test_change_refusals_unsafe_noChange_invalid_inProgress() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let days = sessions(block).filter { $0.dayLabel == p.day && item($0, p.x) != nil }
        item(days[1], p.x)!.actualLoads = [135]; item(days[1], p.x)!.actualReps = [5]      // logged -> unsafe
        item(days[2], p.x)!.targetSets = 1                                                    // -1 would not change it
        try ctx.save()

        let result = planChange(block, ctx, day: p.day, exercise: p.x, letters: nil, includeDeload: true, change: PrescriptionChange(setDelta: -1))
        XCTAssertEqual(result.refusals.first { $0.session === days[1] }?.reason, .unsafe)
        XCTAssertEqual(result.refusals.first { $0.session === days[2] }?.reason, .noChange)
        XCTAssertFalse(result.targets.contains { $0.session === days[1] || $0.session === days[2] })

        XCTAssertTrue(planChange(block, ctx, day: p.day, exercise: p.x, change: PrescriptionChange()).targets.isEmpty, "an empty change plans nothing")
        XCTAssertTrue(planChange(block, ctx, day: p.day, exercise: p.x, change: PrescriptionChange(repRange: 0...5)).targets.isEmpty, "out-of-bounds rep range is invalid")

        let ok = planChange(block, ctx, day: p.day, exercise: p.x, change: PrescriptionChange(setDelta: 1))
        days[0].status = .inProgress
        XCTAssertThrowsError(try Service.applyChange(ok, in: ctx)) { XCTAssertEqual($0 as? Service.ReplaceError, .sessionInProgress) }
    }

    func test_change_forcedFailures_leaveEveryFieldUnchanged() throws {
        for hooks in [Service.ApplyHooks(forceVerificationFailure: true), Service.ApplyHooks(forceSaveFailure: true)] {
            let (ctx, block) = try makeBlock()
            let p = try pick(block)
            let result = planChange(block, ctx, day: p.day, exercise: p.x,
                                    change: PrescriptionChange(setDelta: 1, repRange: 5...7, rirRange: 0...1))
            try ctx.save()
            let before = try fullSnapshot(ctx)
            XCTAssertThrowsError(try Service.applyChange(result, in: ctx, hooks: hooks))
            XCTAssertFalse(ctx.hasChanges)
            XCTAssertEqual(try fullSnapshot(ctx), before, "targetSets, ranges, defaults and per-set arrays all restored")
            XCTAssertNoThrow(try Service.applyChange(result, in: ctx), "the same plan still applies afterwards")
        }
    }

    func test_change_nonWaveBlock_appliesToEverySession_andLetterFilterUsesTheEmptyLetter() throws {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let ctx = ModelContext(c)
        let meso = MesoBlock(name: "My Own Plan", startDate: date(2026, 10, 5), status: .active, totalWeeks: 4)
        ctx.insert(meso)
        var sess: [Session] = []
        for w in 1...4 {
            let it = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 100,
                                 plannedRepsBySet: [10, 10, 10], plannedLoadsBySet: [100, 100, 100], plannedRIRsBySet: [2, 2, 2])
            let s = Session(date: date(2026, 10, 5 + (w - 1) * 7), status: .planned, weekIndex: w, dayLabel: "Day A", items: [it])
            s.meso = meso; ctx.insert(s); sess.append(s)
        }
        try ctx.save()
        let now = date(2026, 10, 1)
        let none = Service.planChangePrescription(meso: meso, dayLabel: "Day A", exerciseId: "bench_press", letters: ["a"],
                                                  change: PrescriptionChange(setDelta: 1), now: now)
        XCTAssertTrue(none.targets.isEmpty, "no session has wave A")
        let all = Service.planChangePrescription(meso: meso, dayLabel: "Day A", exerciseId: "bench_press", letters: [""],
                                                 change: PrescriptionChange(setDelta: 1, repRange: 8...12, rirRange: 2...3), now: now)
        XCTAssertEqual(all.targets.count, 4)
        try Service.applyChange(all, in: ctx)
        for s in sess {
            let i = s.items[0]
            XCTAssertEqual(i.targetSets, 4); XCTAssertEqual(i.plannedLoadsBySet, [100, 100, 100, 100])
            XCTAssertEqual(i.repMin, 8); XCTAssertEqual(i.repMax, 12); XCTAssertEqual(i.targetReps, 8)
            XCTAssertEqual(i.targetRIRMin, 2); XCTAssertEqual(i.targetRIRMax, 3); XCTAssertEqual(i.targetRIR, 3)
        }
        for (a, b) in zip(sess, sess.dropFirst()) {
            XCTAssertTrue(PlanMemoryEngine.nextTargetItem(for: a.items[0], after: a, in: sess) === b.items[0], "chain intact")
        }
    }

    func test_change_journey_completedACarriesForwardIntoAResizedNextA() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let result = planChange(block, ctx, day: p.day, exercise: p.x, letters: ["a"], change: PrescriptionChange(setDelta: 1))
        let aTargets = result.targets.sorted { $0.date < $1.date }
        XCTAssertGreaterThanOrEqual(aTargets.count, 3)
        try Service.applyChange(result, in: ctx)

        let first = aTargets[0], next = aTargets[1]
        XCTAssertEqual(next.item.targetSets, next.before.sets + 1)
        XCTAssertEqual(next.item.suggestedLoad, 0, "empty target before carry-forward")
        first.item.suggestedLoad = 100
        first.item.plannedLoadsBySet = Array(repeating: 100.0, count: first.item.targetSets)
        complete(first.session, item: first.item, load: 100, reps: first.item.targetReps)
        try ctx.save()

        PlanMemoryEngine(context: ctx).carryForwardPlans(from: first.session)

        XCTAssertEqual(next.item.exerciseId, ExerciseCatalog.canonicalExerciseId(for: p.x))
        XCTAssertGreaterThan(next.item.suggestedLoad, 0, "the result reaches the resized next A")
        XCTAssertEqual(next.item.plannedLoadsBySet.count, next.item.targetSets, "carried loads follow the new set count")
    }

    func test_change_setBand_widensToIncludeTheNewCount_andNeverNarrows() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let days = sessions(block).filter { $0.dayLabel == p.day && item($0, p.x) != nil }
        let a = try XCTUnwrap(item(days[0], p.x)), b = try XCTUnwrap(item(days[1], p.x)), c = try XCTUnwrap(item(days[2], p.x))
        for (it, sets) in [(a, 3), (b, 4), (c, 3)] {
            it.targetSets = sets; it.plannedLoadsBySet = Array(repeating: 50.0, count: sets)
        }
        a.setMin = 3; a.setMax = 4        // +1 -> 4: inside the band, unchanged
        b.setMin = 3; b.setMax = 4        // +1 -> 5: setMax follows
        c.setMin = 3; c.setMax = 4        // -1 -> 2: setMin follows, setMax stays
        try ctx.save()

        func run(_ session: Session, _ delta: Int) throws {
            let plan = planChange(block, ctx, day: p.day, exercise: p.x, scope: .thisSession(session), change: PrescriptionChange(setDelta: delta))
            try Service.applyChange(plan, in: ctx)
        }
        try run(days[0], 1); try run(days[1], 1); try run(days[2], -1)
        XCTAssertEqual([a.targetSets, a.setMin, a.setMax].compactMap { $0 }, [4, 3, 4])
        XCTAssertEqual([b.targetSets, b.setMin, b.setMax].compactMap { $0 }, [5, 3, 5])
        XCTAssertEqual([c.targetSets, c.setMin, c.setMax].compactMap { $0 }, [2, 2, 4])

        // A reps-only change leaves the band alone.
        let reps = planChange(block, ctx, day: p.day, exercise: p.x, scope: .thisSession(days[0]), change: PrescriptionChange(repRange: 5...6))
        try Service.applyChange(reps, in: ctx)
        XCTAssertEqual(a.setMin, 3); XCTAssertEqual(a.setMax, 4)
    }
}
