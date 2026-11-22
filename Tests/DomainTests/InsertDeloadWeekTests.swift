import XCTest
import SwiftData
@testable import ElitePerformance

final class InsertDeloadWeekTests: XCTestCase {

    private typealias Service = SessionItemEditService

    private var container: ModelContainer!
    private let scheduledKey = "meso.scheduledStartDateEpoch"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: scheduledKey)
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: scheduledKey)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func cal() -> Calendar { Calendar.current }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal().date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func day(_ d: Date) -> Date { cal().startOfDay(for: d) }
    private func plus(_ d: Date, _ n: Int) -> Date { cal().date(byAdding: .day, value: n, to: d)! }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = c
        return ModelContext(c)
    }

    /// The real 10-week DUP block converted to 12 weeks (Fri Sep 25 2026 start, six days a week).
    private func makeDUPBlock() throws -> (ModelContext, MesoBlock) {
        let ctx = try makeContext()
        ctx.insert(User(units: .lb, progressionEnabled: true))
        try DUPProgramSeeder.seed(
            startDate: date(2026, 9, 25), trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
            template: DUP10WeekTemplate.template, calendar: cal(),
            mesoName: "10-Week DUP Meso", mesoStatus: .active
        )
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
        try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertEqual(block.totalWeeks, 12)
        try ctx.save()
        return (ctx, block)
    }

    private func sorted(_ block: MesoBlock) -> [Session] { block.sessions.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) } }
    private func week(_ block: MesoBlock, _ w: Int) -> [Session] { sorted(block).filter { $0.weekIndex == w } }

    private func finish(_ s: Session, load: Double, reps: Int = 10) {
        for i in s.items {
            let n = max(1, i.targetSets)
            i.actualLoads = Array(repeating: load, count: n)
            i.actualReps = Array(repeating: reps, count: n)
            i.actualRIRs = Array(repeating: 2, count: n)
            i.isCompleted = true
        }
        s.status = .completed
    }

    /// Completes weeks 1-4 of the DUP block and returns `now` = the first day of week 5.
    private func completeFirstFourWeeks(_ block: MesoBlock, load: Double = 100) -> Date {
        for w in 1...4 { for s in week(block, w) { finish(s, load: load) } }
        return day(week(block, 5).map(\.date).min()!)
    }

    private func item(_ i: Int, _ id: String, wave: String? = nil, sets: Int = 4, reps: ClosedRange<Int> = 8...10) -> SessionItem {
        SessionItem(order: i, exerciseId: id, targetReps: reps.lowerBound, targetSets: sets, targetRIR: 2, suggestedLoad: 0,
                    waveRaw: wave, setMin: sets - 1, setMax: sets + 1, repMin: reps.lowerBound, repMax: reps.upperBound,
                    targetRIRMin: 1, targetRIRMax: 2,
                    plannedRepsBySet: Array(repeating: reps.lowerBound, count: sets),
                    plannedLoadsBySet: Array(repeating: 0, count: sets),
                    plannedRIRsBySet: Array(repeating: 2, count: sets))
    }

    /// A non-wave block: `weeks` weeks of one session each, `start` + 7 * (week - 1).
    private func makeSimpleBlock(_ ctx: ModelContext, weeks: Int, start: Date, ids: [String] = ["leg_extension"],
                                 status: MesoStatus = .active) throws -> MesoBlock {
        let block = MesoBlock(name: "Simple", startDate: start, status: status, totalWeeks: weeks)
        ctx.insert(block)
        for w in 1...weeks {
            let s = Session(date: plus(start, 7 * (w - 1)), status: .planned, weekIndex: w, dayLabel: "Legs",
                            items: ids.enumerated().map { item($0.offset + 1, $0.element) }, programIndex: w)
            s.meso = block
            ctx.insert(s)
        }
        try ctx.save()
        return block
    }

    private func snapshot(_ ctx: ModelContext) throws -> [String] {
        var out: [String] = []
        for s in try ctx.fetch(FetchDescriptor<Session>()).sorted(by: { ($0.date, $0.dayLabel ?? "", $0.id?.uuidString ?? "") < ($1.date, $1.dayLabel ?? "", $1.id?.uuidString ?? "") }) {
            out.append("S|\(s.id?.uuidString ?? "")|\(s.date.timeIntervalSince1970)|\(s.status.rawValue)|\(s.weekIndex)|\(s.programIndex.map(String.init) ?? "-")|\(s.insertedDeload.map(String.init) ?? "-")|\(s.items.count)")
            for i in s.items.sorted(by: { ($0.order, $0.exerciseId) < ($1.order, $1.exerciseId) }) {
                out.append("I|\(i.id?.uuidString ?? "")|\(i.exerciseId)|\(i.waveRaw ?? "-")|\(i.targetSets)|\(i.suggestedLoad)|\(i.plannedLoadsBySet)|\(i.actualLoads)")
            }
        }
        for m in try ctx.fetch(FetchDescriptor<MesoBlock>()) { out.append("M|\(m.totalWeeks.map(String.init) ?? "-")|\(m.sessions.count)") }
        return out
    }

    // MARK: - Plan

    func test_plan_12weekBlock_insertAtWeek5_isReadOnlyAndCountsMatch() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        try ctx.save()
        let w5 = week(block, 5)
        XCTAssertEqual(w5.count, 6)

        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.weekIndex, 5)
        XCTAssertEqual(plan.deloadSessions.count, 6)
        XCTAssertEqual(plan.deloadSessions.map(\.date), w5.map(\.date))
        XCTAssertEqual(plan.shifted.count, sorted(block).filter { $0.weekIndex >= 5 }.count)
        XCTAssertEqual(plan.blockEndAfter, plus(try XCTUnwrap(plan.blockEndBefore), 7))
        XCTAssertFalse(ctx.hasChanges, "planning never writes")
        XCTAssertEqual(block.totalWeeks, 12)
    }

    // MARK: - Apply: 12-week DUP fixture

    func test_apply_12weekBlock_insertAtWeek5() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        try ctx.save()
        let w5Before = week(block, 5)
        let w5Dates = w5Before.map(\.date)
        let w5Labels = w5Before.map { $0.dayLabel }
        let laterBefore = sorted(block).filter { $0.weekIndex >= 5 }
        let totalBefore = block.sessions.count
        let sourceTargets = week(block, 4).flatMap { s in s.items.map { (s, $0) } }
            .map { src in (src, PlanMemoryEngine.nextTargetItem(for: src.1, after: src.0, in: sorted(block))) }

        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        let result = try Service.insertDeloadWeek(plan, in: ctx)

        XCTAssertEqual(result.deloadSessionsCreated, plan.deloadSessions.count)
        XCTAssertEqual(result.sessionsShifted, plan.shifted.count)
        XCTAssertEqual(block.sessions.count, totalBefore + 6)
        XCTAssertEqual(block.totalWeeks, 13)

        let inserted = sorted(block).filter { $0.insertedDeload == true }
        XCTAssertEqual(inserted.count, 6)
        XCTAssertEqual(inserted.map(\.date), w5Dates, "deload sits on the old week-5 dates")
        XCTAssertEqual(inserted.map { $0.dayLabel }, w5Labels)
        XCTAssertTrue(inserted.allSatisfy { $0.weekIndex == 5 && $0.status == .planned })
        XCTAssertTrue(inserted.allSatisfy { $0.items.allSatisfy { $0.waveRaw == "deload" } })
        XCTAssertTrue(sorted(block).filter { $0.insertedDeload != true }.allSatisfy { $0.insertedDeload == nil })

        // Weeks 5-12 are now 6-13, a week later.
        XCTAssertEqual(Set(block.sessions.map(\.weekIndex)), Set(1...13))
        XCTAssertEqual(week(block, 6).map(\.date), w5Dates.map { plus($0, 7) })
        XCTAssertEqual(sorted(block).filter { $0.insertedDeload != true && $0.weekIndex >= 6 }.count, laterBefore.count)

        // programIndex runs 1...N in date order.
        let indices = sorted(block).compactMap(\.programIndex)
        XCTAssertEqual(indices.count, block.sessions.count)
        XCTAssertEqual(indices, Array(1...indices.count))

        // Chains: every week-4 result still flows to the same target, now a week later, never a deload item.
        for (src, before) in sourceTargets {
            let after = PlanMemoryEngine.nextTargetItem(for: src.1, after: src.0, in: sorted(block))
            XCTAssertTrue(after === before, "\(src.1.exerciseId) chain moved")
            XCTAssertNotEqual(after?.waveRaw, "deload")
        }

        // Day labels still count 1...6 within every week.
        for w in 1...13 { XCTAssertEqual(week(block, w).map(\.dayNumberInWeek), Array(1...6), "week \(w)") }
    }

    func test_apply_deloadPrescription_halfSets_sameReps_RIR34_widenedBands_loadsFromHistory_arraysSized() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        let sources = week(block, 5)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        try Service.insertDeloadWeek(plan, in: ctx)

        let inserted = sorted(block).filter { $0.insertedDeload == true }
        for (dep, src) in zip(inserted, sources) {
            XCTAssertEqual(dep.items.count, src.items.count)
            for (d, s) in zip(dep.items.sorted { $0.order < $1.order }, src.items.sorted { $0.order < $1.order }) {
                let n = max(1, Int((Double(s.targetSets) / 2).rounded(.up)))
                XCTAssertEqual(d.exerciseId, s.exerciseId)
                XCTAssertEqual(d.order, s.order)
                XCTAssertEqual(d.targetSets, n)
                XCTAssertEqual(d.repMin, s.repMin ?? s.targetReps)
                XCTAssertEqual(d.repMax, s.repMax ?? s.targetReps)
                XCTAssertEqual(d.targetReps, d.repMin)
                XCTAssertEqual([d.targetRIRMin, d.targetRIRMax, d.targetRIR], [3, 4, 4])
                if let lo = d.setMin { XCTAssertLessThanOrEqual(lo, n) }
                if let hi = d.setMax { XCTAssertGreaterThanOrEqual(hi, n) }
                for count in [d.plannedRepsBySet.count, d.plannedLoadsBySet.count, d.plannedRIRsBySet.count, d.actualLoads.count,
                              d.actualReps.count, d.actualRIRs.count, d.usedRestPauseFlags.count, d.restPausePatternsBySet.count,
                              d.dropSetPatternsBySet.count, d.setFeedbackBySet.count, d.pumpRatingsBySet.count] {
                    XCTAssertEqual(count, n)
                }
                if ExerciseCatalog.isBodyweight(exerciseId: d.exerciseId) {
                    XCTAssertEqual(d.suggestedLoad, 0)
                } else {
                    XCTAssertGreaterThan(d.suggestedLoad, 0, "history at 100 -> a positive seed")
                    let done = sorted(block).filter { $0.status == .completed }
                    let rirAtRepMin = try XCTUnwrap(HistorySeedLoad.load(
                        for: d.exerciseId, goalReps: d.repMin ?? d.targetReps, targetRIR: 4,
                        in: done, loadIncrement: 2.5, referenceDate: now))
                    XCTAssertEqual(d.suggestedLoad, min(rirAtRepMin, 95), "min(RIR-4 sizing at repMin, 0.95 x the working load of 100)")
                    XCTAssertLessThanOrEqual(d.suggestedLoad, 95)
                    XCTAssertEqual(d.suggestedLoad.truncatingRemainder(dividingBy: 2.5), 0, accuracy: 1e-9, "rounded down to the increment")
                }
                XCTAssertFalse(d.planEdited)
                XCTAssertFalse(SessionEditSafety.hasLoggedData(d))
            }
        }
    }

    // MARK: - Apply: non-wave block, loads

    func test_apply_nonWaveBlock_workingFeedsWorking_notTheDeload() throws {
        let ctx = try makeContext()
        let now = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: now)
        let s1 = week(block, 1)[0]
        finish(s1, load: 100)
        try ctx.save()
        let target = PlanMemoryEngine.nextTargetItem(for: s1.items[0], after: s1, in: sorted(block))
        XCTAssertEqual(target?.waveRaw, nil)
        let owner = block.sessions.first(where: { s in s.items.contains(where: { $0 === target }) })
        XCTAssertEqual(owner?.weekIndex, 2)

        // Today = week 2's day, so week 2 is the first not-started week.
        let insertNow = plus(now, 7)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: insertNow)
        XCTAssertEqual(plan.weekIndex, 2)
        try Service.insertDeloadWeek(plan, in: ctx)

        XCTAssertEqual(block.totalWeeks, 5)
        XCTAssertEqual(week(block, 2).first?.insertedDeload, true)
        XCTAssertEqual(week(block, 2).first?.items.first?.waveRaw, "deload")
        let after = try XCTUnwrap(PlanMemoryEngine.nextTargetItem(for: s1.items[0], after: s1, in: sorted(block)))
        XCTAssertTrue(after === target, "same working session as before")
        XCTAssertEqual(block.sessions.first(where: { s in s.items.contains(where: { $0 === after }) })?.weekIndex, 3)
        XCTAssertNotEqual(after.waveRaw, "deload")
    }

    func test_apply_earlierOriginalDeload_doesNotBlockTheInsert() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 6, start: start)
        // Weeks 2 and 5 were generated as deloads; the lifter inserts another at week 3.
        for w in [2, 5] { for i in week(block, w).flatMap(\.items) { i.waveRaw = "deload" } }
        try ctx.save()
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(start, 14))
        XCTAssertEqual(plan.weekIndex, 3)
        XCTAssertNoThrow(try Service.insertDeloadWeek(plan, in: ctx), "the week-2 deload now chains to the inserted deload; that is not a problem")
        XCTAssertEqual(block.totalWeeks, 7)
        XCTAssertEqual(week(block, 3).first?.insertedDeload, true)
    }

    func test_apply_fixedLoadExercise_holdsLastCompletedLoad() throws {
        let ctx = try makeContext()
        let profile = UserProfile()
        profile.setProgressionExempt(true, exerciseId: "leg_extension")
        ctx.insert(profile)
        let now = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: now)
        finish(week(block, 1)[0], load: 135)
        try ctx.save()
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(now, 7))
        try Service.insertDeloadWeek(plan, in: ctx)
        let dep = try XCTUnwrap(week(block, 2).first)
        XCTAssertEqual(dep.items[0].suggestedLoad, 135)
        XCTAssertEqual(dep.items[0].plannedLoadsBySet, [135, 135])
    }

    func test_apply_bodyweightExercise_isZero_andNoHistoryIsZero() throws {
        let ctx = try makeContext()
        let bw = try XCTUnwrap(ExerciseCatalog.all.first(where: { $0.isBodyweight })).id
        let now = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: now, ids: [bw, "leg_extension"])
        finish(week(block, 1)[0], load: 25)   // bodyweight and leg extension both have history here...
        try ctx.save()
        let loaded = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(now, 7))
        try Service.insertDeloadWeek(loaded, in: ctx)
        let dep = try XCTUnwrap(week(block, 2).first)
        let byId = Dictionary(uniqueKeysWithValues: dep.items.map { ($0.exerciseId, $0) })
        XCTAssertEqual(byId[bw]?.suggestedLoad, 0)
        XCTAssertGreaterThan(byId["leg_extension"]?.suggestedLoad ?? 0, 0)

        // A different lift with no history at all starts at 0.
        let ctx2 = try makeContext()
        let block2 = try makeSimpleBlock(ctx2, weeks: 2, start: now)
        let plan2 = Service.planInsertDeloadWeek(meso: block2, context: ctx2, now: now)
        try Service.insertDeloadWeek(plan2, in: ctx2)
        XCTAssertEqual(week(block2, 1).first?.items.first?.suggestedLoad, 0)
        XCTAssertEqual(week(block2, 1).first?.items.first?.plannedLoadsBySet, [0, 0])
    }

    // MARK: - Refusals

    func test_refuses_whenASessionIsInProgress() throws {
        let ctx = try makeContext()
        let now = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: now)
        week(block, 1)[0].status = .inProgress
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertEqual(plan.refusal, .sessionInProgress)
        XCTAssertFalse(plan.isApplicable)
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.InsertDeloadError, .refused(.sessionInProgress))
        }
    }

    func test_refuses_whenNoWeekIsEligible() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: start)
        // Everything is in the past.
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(start, 60))
        XCTAssertEqual(plan.refusal, .noEligibleWeek)
        // A week with a logged session is not eligible either; the next one is.
        let ctx2 = try makeContext()
        let b2 = try makeSimpleBlock(ctx2, weeks: 3, start: start)
        week(b2, 1)[0].items[0].actualLoads = [50]
        XCTAssertEqual(Service.planInsertDeloadWeek(meso: b2, context: ctx2, now: start).weekIndex, 2)
    }

    func test_refuses_inactiveBlock_andLaterCompletedSession() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let done = try makeSimpleBlock(ctx, weeks: 3, start: start, status: .archived)
        XCTAssertEqual(Service.planInsertDeloadWeek(meso: done, context: ctx, now: start).refusal, .inactiveMeso)

        let ctx2 = try makeContext()
        let b = try makeSimpleBlock(ctx2, weeks: 4, start: start)
        finish(week(b, 3)[0], load: 100)   // a later week was trained out of order
        let plan = Service.planInsertDeloadWeek(meso: b, context: ctx2, now: start)
        XCTAssertEqual(plan.refusal, .laterSessionCompleted)
    }

    func test_refuses_andListsCollisionsWithAnotherBlocksSession() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: start)
        let other = MesoBlock(name: "Other", startDate: start, status: .archived, totalWeeks: 1)
        ctx.insert(other)
        // Week 2's session (Nov 9) moves to Nov 16; park another block's session there.
        let blocker = Session(date: plus(start, 14), status: .completed, weekIndex: 1, dayLabel: "Old")
        blocker.meso = other
        ctx.insert(blocker)
        try ctx.save()
        let before = try snapshot(ctx)

        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(start, 7))
        XCTAssertEqual(plan.refusal, .dateCollision)
        XCTAssertEqual(plan.collisions.count, 1)
        XCTAssertTrue(plan.collisions[0].occupant === blocker)
        XCTAssertEqual(plan.collisions[0].date, plus(start, 14))
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx))
        XCTAssertEqual(try snapshot(ctx), before)
    }

    func test_stalePlan_isRefusedWithoutWriting() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: start)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: start)
        XCTAssertEqual(plan.weekIndex, 1)
        week(block, 1)[0].items[0].actualLoads = [50]   // week 1 got logged after the preview
        try ctx.save()
        let before = try snapshot(ctx)
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.InsertDeloadError, .planStale)
        }
        XCTAssertEqual(try snapshot(ctx), before)
    }

    // MARK: - Rollback

    func test_forcedVerificationFailure_leavesEveryFieldUnchanged() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        try ctx.save()
        let before = try snapshot(ctx)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx, hooks: .init(forceVerificationFailure: true))) {
            guard case .verificationFailed(let problems)? = $0 as? Service.InsertDeloadError else { return XCTFail("\($0)") }
            XCTAssertEqual(problems.count, 1, "only the forced failure: \(problems)")
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertEqual(block.totalWeeks, 12)
        XCTAssertFalse(ctx.hasChanges)
    }

    func test_forcedSaveFailure_leavesEveryFieldUnchanged_andNextMesoDateAlone() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        try ctx.save()
        let next = date(2027, 1, 4)
        MesoLifecycle.scheduleNextMeso(on: next)
        let before = try snapshot(ctx)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx, hooks: .init(forceSaveFailure: true))) {
            guard case .saveFailed? = $0 as? Service.InsertDeloadError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, day(next))
        // And the same plan still applies afterwards.
        XCTAssertNoThrow(try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now), in: ctx))
    }

    // MARK: - Next block start

    func test_scheduledNextMeso_movesAWeekLater_andIsLeftAloneWhenUnset() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: start)
        MesoLifecycle.scheduleNextMeso(on: date(2027, 1, 4))
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: start), in: ctx)
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, day(date(2027, 1, 11)))

        UserDefaults.standard.removeObject(forKey: scheduledKey)
        let ctx2 = try makeContext()
        let b2 = try makeSimpleBlock(ctx2, weeks: 3, start: start)
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: b2, context: ctx2, now: start), in: ctx2)
        XCTAssertNil(MesoLifecycle.scheduledStartDate)
    }

    // MARK: - Choosing the week

    func test_explicitWeek_planFollowsTheChoice_andNilIsTheFirstEligible() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 5, start: start)
        let now = plus(start, 7)                       // week 1 is past
        XCTAssertEqual(Service.eligibleDeloadWeeks(meso: block, now: now), [2, 3, 4, 5])
        XCTAssertEqual(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now).weekIndex, 2)

        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now, week: 4)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.weekIndex, 4)
        XCTAssertEqual(plan.deloadSessions.map(\.date), week(block, 4).map(\.date))
        XCTAssertEqual(plan.shifted.count, 2, "weeks 4 and 5 move")

        try Service.insertDeloadWeek(plan, in: ctx)
        XCTAssertEqual(block.totalWeeks, 6)
        XCTAssertEqual(week(block, 4).first?.insertedDeload, true)
        XCTAssertNil(week(block, 3).first?.insertedDeload, "earlier weeks untouched")
        XCTAssertEqual(week(block, 3).first?.date, plus(start, 14))
        XCTAssertEqual(week(block, 5).first?.date, plus(start, 28))
        XCTAssertEqual(week(block, 6).first?.date, plus(start, 35))
    }

    func test_explicitIneligibleWeek_isRefusedWithAReason() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: start)
        week(block, 3).first?.items[0].waveRaw = "deload"
        week(block, 4).first?.items[0].actualLoads = [50]
        let now = plus(start, 7)
        for w in [1, 3, 4, 9] {
            let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now, week: w)
            XCTAssertEqual(plan.refusal, .weekNotEligible, "week \(w)")
            XCTAssertFalse(plan.isApplicable)
        }
        XCTAssertEqual(Service.eligibleDeloadWeeks(meso: block, now: now), [2])
    }

    func test_removeCanTargetASpecificInsertedWeek() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 5, start: start)
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: start, week: 2), in: ctx)
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: start, week: 5), in: ctx)
        XCTAssertEqual(block.sessions.filter { $0.insertedDeload == true }.map(\.weekIndex).sorted(), [2, 5])
        let plan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start, week: 5)
        XCTAssertEqual(plan.weekIndex, 5)
        try Service.removeInsertedDeloadWeek(plan, in: ctx)
        XCTAssertEqual(block.sessions.filter { $0.insertedDeload == true }.map(\.weekIndex), [2])
        XCTAssertEqual(Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start, week: 3).refusal, .noInsertedDeload)
    }

    // MARK: - Top set

    /// A deload is straight sets: the top set is dropped, and the sets and load come from the back-offs only.
    func test_apply_deloadDropsTheTopSet_workingWeeksKeepIt() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        for w in [5, 6] {
            for s in week(block, w) {
                for i in s.items {
                    let n = i.targetSets
                    i.setRolesBySet = SessionItem.roles(backOffs: n, tops: 1)
                    i.topRepMin = 4; i.topRepMax = 6; i.topRIR = 2
                    i.plannedLoadsBySet = Array(i.plannedLoadsBySet.prefix(n)) + [315]
                    i.plannedRepsBySet = Array(i.plannedRepsBySet.prefix(n)) + [4]
                    i.plannedRIRsBySet = Array(i.plannedRIRsBySet.prefix(n)) + [2]
                }
            }
        }
        try ctx.save()
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        try Service.insertDeloadWeek(plan, in: ctx)
        let deload = sorted(block).filter { $0.insertedDeload == true }
        XCTAssertFalse(deload.isEmpty)
        for s in deload {
            for i in s.items {
                XCTAssertNil(i.setRolesBySet, "a deload item carries no top set")
                XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets)
                XCTAssertFalse(i.hasTopSet)
            }
        }
        // The shifted working week keeps its top set.
        let shifted = sorted(block).filter { $0.weekIndex == 6 && $0.insertedDeload != true }
        XCTAssertTrue(shifted.flatMap(\.items).allSatisfy { $0.hasTopSet })
    }

    func test_lastCompletedLoad_readsBackOffsNotTheTopSet() {
        let item = SessionItem(order: 1, exerciseId: "leg_extension", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        item.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        item.actualLoads = [100, 100, 100, 140]; item.actualReps = [8, 8, 8, 5]
        let s = Session(date: Date(timeIntervalSince1970: 1_000), status: .completed, weekIndex: 1, items: [item])
        XCTAssertEqual(Service.lastCompletedLoad(for: "leg_extension", in: [s]), 100)
    }

    // MARK: - Max load

    /// Deload loads solve from history; a max load caps them like every other seed.
    func test_deloadLoads_areClampedToTheMax() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block, load: 100)
        let target = try XCTUnwrap(week(block, 5).flatMap(\.items).first { !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId) }).exerciseId
        let canonical = ExerciseCatalog.canonicalExerciseId(for: target)
        func loads(_ plan: Service.InsertDeloadPlan) -> [Double] {
            plan.deloadSessions.flatMap(\.items).filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }.map(\.load)
        }
        let free = loads(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now))
        XCTAssertFalse(free.isEmpty)
        XCTAssertTrue(free.allSatisfy { $0 > 40 }, "\(free)")
        let profile = UserProfile(); profile.setMaxLoad(40, exerciseId: target); ctx.insert(profile)
        try ctx.save()
        let capped = loads(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now))
        XCTAssertTrue(capped.allSatisfy { $0 == 40 }, "\(capped)")
    }
}

// MARK: - DeloadRule

/// The one deload rule: half the sets, RIR 4, planned reps = repMin, load = min(RIR-4 sizing at repMin,
/// 0.95 x the latest non-deload working load), rounded down to the step.
final class DeloadRuleTests: XCTestCase {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

    private func session(_ n: Int, _ id: String = "bench_press", load: Double, reps: Int, rir: Int = 1, sets: Int = 3,
                         wave: String? = "a", inserted: Bool = false) -> Session {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: reps, targetSets: sets, targetRIR: 2, suggestedLoad: load, waveRaw: wave)
        i.actualLoads = Array(repeating: load, count: sets)
        i.actualReps = Array(repeating: reps, count: sets)
        i.actualRIRs = Array(repeating: rir, count: sets)
        let s = Session(date: day(n), status: .completed, weekIndex: n, items: [i])
        s.insertedDeload = inserted ? true : nil
        return s
    }

    private func sizing(_ id: String = "bench_press", repMin: Int, _ sessions: [Session], step: Double = 2.5,
                        exempt: [String]? = nil) -> DeloadRule.Sizing {
        let profile = UserProfile()
        profile.minLoadIncrement = step
        if let exempt { profile.exemptExerciseIds = exempt }
        return DeloadRule.sizing(exerciseId: id, repMin: repMin, in: sessions, profile: profile, unit: .lb,
                                 customExercises: [], referenceDate: day(100))
    }

    func test_sets_halfRoundedUp_atLeastOne() {
        XCTAssertEqual([1, 2, 3, 4, 5, 6].map(DeloadRule.sets(forPlanned:)), [1, 1, 2, 2, 3, 3])
    }

    func test_load_isNeverAboveNinetyFivePercentOfWorkingLoad_acrossTheRepBands() {
        for band in [(6, 8), (8, 10), (10, 12), (12, 15)] {
            for working in [20.0, 45, 100, 135, 225, 315] {
                // Trained at the top of the band, hard (RIR 0): the e1RM points high.
                let z = sizing(repMin: band.0, [session(1, load: working, reps: band.1, rir: 0)])
                XCTAssertLessThanOrEqual(z.load, working * 0.95 + 1e-9, "\(band) @ \(working): \(z)")
                XCTAssertGreaterThan(z.load, working * 0.5, "\(band) @ \(working): a deload is light, not absent: \(z)")
                XCTAssertEqual(z.load.truncatingRemainder(dividingBy: 2.5), 0, accuracy: 1e-9, "rounded to the step")
                XCTAssertEqual(z.load, min(z.rirLoad ?? .infinity, z.capLoad ?? .infinity), "load is the min of the two sides")
                XCTAssertEqual(z.workingLoad, working)
            }
        }
    }

    func test_capSide_whenTheEstimatePointsAboveTheLastWorkingLoad() {
        // 100 x 15 at RIR 0 estimates about 150; RIR-4 sizing at 6 reps is ~112, above 0.95 x 100.
        let z = sizing(repMin: 6, [session(1, load: 100, reps: 15, rir: 0)])
        XCTAssertEqual(z.basis, .cap)
        XCTAssertEqual(z.load, 95)
        XCTAssertGreaterThan(z.rirLoad ?? 0, 95)
    }

    func test_rirSide_whenTheEstimateIsBelowTheCap() {
        // 100 x 3 at RIR 0 estimates about 110; RIR-4 sizing at 8 reps is ~78.
        let z = sizing(repMin: 8, [session(1, load: 100, reps: 3, rir: 0)])
        XCTAssertEqual(z.basis, .rir)
        XCTAssertLessThan(z.load, 95)
        XCTAssertEqual(z.load, z.rirLoad)
    }

    func test_cap_roundsDownToTheStep() {
        // 0.95 x 100 = 95 on a 5 lb step is exactly 95; 0.95 x 101 = 95.95 -> 95; 0.95 x 120 = 114 -> 110.
        XCTAssertEqual(sizing(repMin: 6, [session(1, load: 120, reps: 15, rir: 0)], step: 5).load, 110)
        XCTAssertEqual(sizing(repMin: 6, [session(1, load: 100, reps: 15, rir: 0)], step: 5).load, 95)
    }

    func test_workingLoad_isTheLatestNonDeloadSession_notTheHeaviest() {
        let older = session(1, load: 200, reps: 8)
        let newer = session(5, load: 150, reps: 8)
        let deload = session(6, load: 90, reps: 8, wave: "deload")
        let insertedDeload = session(7, load: 80, reps: 8, wave: "a", inserted: true)
        XCTAssertEqual(DeloadRule.latestWorkingLoad(for: "bench_press", in: [older, newer, deload, insertedDeload]), 150)
    }

    func test_bodyweight_carriesNoLoad() {
        let z = sizing("pull_up", repMin: 8, [session(1, "pull_up", load: 0, reps: 8)])
        XCTAssertEqual(z.basis, .bodyweight)
        XCTAssertEqual(z.load, 0)
    }

    func test_fixedLoadLift_holdsItsLastLoad() {
        let z = sizing("bench_press", repMin: 8, [session(1, load: 120, reps: 8)], exempt: ["bench_press"])
        XCTAssertEqual(z.basis, .exempt)
        XCTAssertEqual(z.load, 120)
    }

    func test_noHistory_isZeroAndSaysSo() {
        let z = sizing(repMin: 8, [])
        XCTAssertEqual(z.basis, .noHistory)
        XCTAssertEqual(z.load, 0)
        XCTAssertNil(z.workingLoad)
    }

    func test_deloadItemsAreNotHistory() {
        let z = sizing(repMin: 8, [session(1, load: 100, reps: 8, wave: "deload")])
        XCTAssertEqual(z.basis, .noHistory)
    }
}

// MARK: - WaveSlotRestore (re-adding an exercise to a wave session)

final class WaveSlotRestoreTests: XCTestCase {

    private func ctx() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        return ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
    }

    private func item(_ id: String, wave: String?, sets: Int = 3, reps: ClosedRange<Int> = 10...12, rir: Int = 3) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: reps.lowerBound, targetSets: sets, targetRIR: rir, suggestedLoad: 0,
                            waveRaw: wave, priorityRaw: "standard", setMin: sets, setMax: sets, repMin: reps.lowerBound, repMax: reps.upperBound,
                            targetRIRMin: rir, targetRIRMax: rir)
        i.plannedRepsBySet = Array(repeating: reps.lowerBound, count: 4)
        i.plannedLoadsBySet = Array(repeating: 0, count: 4)
        return i
    }

    /// The generic item the add flows build: waveless, 3 x 10, RIR 2, four array slots.
    private func fresh(_ id: String) -> SessionItem {
        let i = SessionItem(order: 9, exerciseId: id, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        i.plannedRepsBySet = [10, 10, 10, 10]; i.plannedLoadsBySet = [0, 0, 0, 0]; i.plannedRIRsBySet = [2, 2, 2, 2]
        i.actualReps = [0, 0, 0, 0]; i.actualLoads = [0, 0, 0, 0]; i.actualRIRs = RIREntry.unsetArray(count: 4)
        return i
    }

    private func block(_ c: ModelContext, weeks: [(Int, String, [SessionItem])]) -> (MesoBlock, [Session]) {
        let meso = MesoBlock(name: "12-Week DUP Meso", startDate: Date(timeIntervalSince1970: 1_800_000_000), status: .active, totalWeeks: 12)
        c.insert(meso)
        var out: [Session] = []
        for (w, _, items) in weeks {
            let s = Session(date: Date(timeIntervalSince1970: 1_800_000_000 + Double(w) * 7 * 86_400), status: .planned,
                            weekIndex: w, dayLabel: "Push A", items: items)
            s.meso = meso; meso.sessions.append(s); c.insert(s); out.append(s)
        }
        return (meso, out)
    }

    func test_reAdd_takesTheSessionsLetterAndTheSameLetterTemplate_notTheOtherLetters() throws {
        let c = try ctx()
        // Week 1 (a): curl 3 x 12-15 RIR 3. Week 2 (b), where it is re-added. Week 5 (b): curl 4 x 8-10 RIR 2. Week 3 (c): curl 4 x 6-8.
        let (_, ss) = block(c, weeks: [
            (1, "a", [item("ez_bar_curl", wave: "a", sets: 3, reps: 12...15, rir: 3), item("bench_press", wave: "a")]),
            (2, "b", [item("bench_press", wave: "b")]),
            (3, "c", [item("ez_bar_curl", wave: "c", sets: 4, reps: 6...8, rir: 1)]),
            (5, "b", [item("ez_bar_curl", wave: "b", sets: 4, reps: 8...10, rir: 2)])])
        let new = fresh("ez_bar_curl")
        let restored = WaveSlotRestore.restore(new, in: ss[1], allSessions: ss)
        XCTAssertTrue(restored)
        XCTAssertEqual(new.waveRaw, "b")
        XCTAssertEqual([new.repMin, new.repMax, new.targetRIRMin, new.targetRIRMax], [8, 10, 2, 2])
        XCTAssertEqual([new.targetSets, new.effectivePrescribedSets, new.targetReps, new.targetRIR], [4, 4, 8, 2])
        XCTAssertEqual(new.plannedRepsBySet, [8, 8, 8, 8])
        XCTAssertEqual(new.plannedRIRsBySet, [2, 2, 2, 2])
        XCTAssertEqual(new.plannedLoadsBySet.count, 4)
        XCTAssertEqual(new.actualReps, [0, 0, 0, 0])
    }

    func test_reAdd_withNoTemplateInTheBlock_usesThePreviousExposureOnThatLetter() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "b", [item("bench_press", wave: "b")])])
        let old = Session(date: Date(timeIntervalSince1970: 1_700_000_000), status: .completed, weekIndex: 2, dayLabel: "Push A",
                          items: [item("ez_bar_curl", wave: "b", sets: 2, reps: 9...11, rir: 2)])
        c.insert(old)
        let new = fresh("ez_bar_curl")
        XCTAssertTrue(WaveSlotRestore.restore(new, in: ss[0], allSessions: ss + [old]))
        XCTAssertEqual(new.waveRaw, "b")
        XCTAssertEqual([new.repMin, new.repMax, new.targetSets], [9, 11, 2])
    }

    func test_reAdd_withNoSource_onlyTakesTheLetter() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "b", [item("bench_press", wave: "b")])])
        let new = fresh("ez_bar_curl")
        XCTAssertTrue(WaveSlotRestore.restore(new, in: ss[0], allSessions: ss))
        XCTAssertEqual(new.waveRaw, "b")
        XCTAssertEqual([new.targetReps, new.targetSets, new.targetRIR], [10, 3, 2], "defaults stay")
        XCTAssertNil(new.repMin)
    }

    func test_reAdd_toAWaveBlock_neverCopiesALoadOrALoggedValue() throws {
        let c = try ctx()
        let tpl = item("ez_bar_curl", wave: "b", sets: 3, reps: 10...12, rir: 2)
        tpl.suggestedLoad = 80; tpl.plannedLoadsBySet = [80, 80, 80, 80]; tpl.actualLoads = [80, 80, 80, 80]; tpl.actualReps = [10, 10, 10, 10]
        let (_, ss) = block(c, weeks: [(2, "b", [item("bench_press", wave: "b")]), (5, "b", [tpl])])
        let new = fresh("ez_bar_curl"); new.suggestedLoad = 42; new.plannedLoadsBySet = [42, 42, 42, 42]
        WaveSlotRestore.restore(new, in: ss[0], allSessions: ss)
        XCTAssertEqual(new.suggestedLoad, 42)
        XCTAssertEqual(new.plannedLoadsBySet, [42, 42, 42, 42])
        XCTAssertEqual(new.actualLoads, [0, 0, 0, 0])
    }

    func test_reAdd_toANonWaveBlock_changesNothing() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "none", [item("bench_press", wave: nil)])])
        let new = fresh("ez_bar_curl")
        XCTAssertFalse(WaveSlotRestore.restore(new, in: ss[0], allSessions: ss))
        XCTAssertNil(new.waveRaw)
        XCTAssertEqual(new.targetSets, 3)
    }

    // MARK: Today "Apply to future <weekday>" is only offered where it can act

    @MainActor
    func test_applyToFutureDialog_isNotOfferedOnAWaveBlock() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "b", [item("bench_press", wave: "b")])])
        XCTAssertFalse(SessionScreenViewModel(session: ss[0]).addedExerciseCanPropagate)
    }

    @MainActor
    func test_applyToFutureDialog_isOfferedOnABlockWithNoWaves() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "none", [item("bench_press", wave: nil)])])
        XCTAssertTrue(SessionScreenViewModel(session: ss[0]).addedExerciseCanPropagate)
    }
}


// MARK: - Scheduled deload weeks are filled by PlaceholderRefresh

@MainActor
final class ScheduledDeloadFillTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current
    private let now = Date()

    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        return ctx
    }

    /// Seeds `template` so that its LAST week starts three days from now, completes every earlier session at 100 lb x 10, and returns
    /// (the sessions of the deload week or last week, all sessions).
    private func seed(_ template: ProgramTemplate, _ ctx: ModelContext) throws -> (week: [Session], all: [Session], deloadWeek: Int?) {
        let weeks = template.totalWeeks
        let start = cal.date(byAdding: .day, value: 3 - (weeks - 1) * 7, to: cal.startOfDay(for: now))!
        let weekday = cal.component(.weekday, from: start)
        let days = (0..<template.trainingDaysPerWeek).map { ((weekday - 1 + $0) % 7) + 1 }
        try DUPProgramSeeder.seed(startDate: start, trainingWeekdays: days, context: ctx, template: template, mesoName: "M", mesoStatus: .active)
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
        let deloadWeek = template.weekRules.first(where: { $0.isDeload })?.weekNumber
        let lastWeek = deloadWeek ?? weeks
        for s in all where s.weekIndex < lastWeek {
            s.status = .completed
            for i in s.items {
                i.actualLoads = Array(repeating: 100, count: i.targetSets)
                i.actualReps = Array(repeating: 10, count: i.targetSets)
                i.actualRIRs = Array(repeating: 2, count: i.targetSets)
            }
        }
        try ctx.save()
        return (all.filter { $0.weekIndex == lastWeek }, all, deloadWeek)
    }

    func test_everyBuiltInTemplateWithAScheduledDeload_hasItsDeloadItemsFilled() throws {
        let own = ProgramTemplate.waveless(name: "Own", totalWeeks: 6, deloadFinalWeek: true, days: [
            WavelessDay(title: "A", slots: [.defaults(exerciseId: ExerciseCatalog.benchPress.id, isCompound: true),
                                           .defaults(exerciseId: ExerciseCatalog.dumbbellLateralRaise.id, isCompound: false)]),
            WavelessDay(title: "B", slots: [.defaults(exerciseId: ExerciseCatalog.romanianDeadlift.id, isCompound: true)])])
        let templates: [(String, ProgramTemplate)] = [
            ("PPL3Week", PPL3WeekTemplate.template), ("UpperLower4Day", UpperLower4DayTemplate.template),
            ("Hybrid5Day", Hybrid5DayTemplate.template), ("DUP10Week", DUP10WeekTemplate.template),
            ("PPL6Day", PPL6DayTemplate.template), ("FullBody2Day", FullBody2DayTemplate.template), ("Waveless", own)]
        var covered = 0
        var noHistory: [String] = []
        for (name, t) in templates {
            let ctx = try makeContext()
            let s = try seed(t, ctx)
            guard s.deloadWeek != nil else { continue }
            covered += 1
            let items = s.week.flatMap(\.items).filter { $0.waveRaw?.lowercased() == "deload" && $0.targetSets > 0 }
            XCTAssertFalse(items.isEmpty, "\(name): the deload week has deload items")
            let before = items.filter { $0.suggestedLoad > 0 }.count
            PlaceholderRefresh.run(in: ctx, now: now)
            let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
            for i in items where !ExerciseCatalog.isBodyweight(exerciseId: i.exerciseId, customExercises: []) {
                let z = DeloadRule.sizing(exerciseId: i.exerciseId, repMin: i.repMin ?? i.targetReps, in: s.all, profile: profile,
                                          unit: .lb, customExercises: [], referenceDate: now)
                if z.basis == .noHistory { print("SDL| \(name) \(i.exerciseId) sets \(i.targetSets) repMin \(String(describing: i.repMin)) \(i.targetReps)"); noHistory.append("\(name) \(i.exerciseId)"); XCTAssertEqual(i.suggestedLoad, 0); continue }
                XCTAssertGreaterThan(i.suggestedLoad, 0, "\(name) \(i.exerciseId): filled (\(before) were already loaded)")
                XCTAssertLessThanOrEqual(i.suggestedLoad, 95 + 1e-9, "\(name) \(i.exerciseId): never above 95% of the 100 lb working load")
                XCTAssertEqual(i.suggestedLoad, z.load, "\(name) \(i.exerciseId): the DeloadRule load")
                XCTAssertTrue(i.plannedLoadsBySet.allSatisfy { $0 == z.load }, "\(name) \(i.exerciseId): every slot \(i.plannedLoadsBySet)")
                XCTAssertEqual(i.coachNote, PlaceholderRefresh.deloadNote, name)
                XCTAssertFalse(i.planEdited, name)
            }
            for i in items where ExerciseCatalog.isBodyweight(exerciseId: i.exerciseId, customExercises: []) {
                XCTAssertEqual(i.suggestedLoad, 0, "\(name) \(i.exerciseId): bodyweight is never touched")
                XCTAssertNil(i.coachNote)
            }
            XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "\(name): idempotent")
        }
        XCTAssertGreaterThanOrEqual(covered, 5, "the built-ins with a scheduled deload were all exercised")
        print("SDL| no-history (stay 0): \(noHistory)")
    }

    func test_editedItem_loggedWeek_insertedDeload_areLeftAlone_andNoHistoryStaysZero() throws {
        let ctx = try makeContext()
        let s = try seed(DUP10WeekTemplate.template, ctx)
        let items = s.week.flatMap(\.items)
        let edited = try XCTUnwrap(items.first)
        edited.planEdited = true; edited.suggestedLoad = 42; edited.plannedLoadsBySet = Array(repeating: 42, count: edited.targetSets)
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(edited.suggestedLoad, 42, "an edited item is never touched")
        XCTAssertTrue(items.dropFirst().contains { $0.suggestedLoad == 95 })

        // Recomputed every pass: a newer working session moves the load.
        let other = try XCTUnwrap(items.dropFirst().first { $0.suggestedLoad == 95 && $0.exerciseId != edited.exerciseId })
        func latestSource() -> SessionItem {
            s.all.filter { $0.status == .completed }.sorted { $0.date > $1.date }
                .compactMap { $0.items.first { $0.exerciseId == other.exerciseId } }.first!
        }
        let newer = latestSource()
        newer.actualLoads = Array(repeating: 120, count: newer.targetSets); newer.actualReps = Array(repeating: 8, count: newer.targetSets)
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertGreaterThan(other.suggestedLoad, 95, "a heavier newest working session raises the deload with it (recomputed every pass)")
        XCTAssertLessThanOrEqual(other.suggestedLoad, 114)

        // Once a set is logged in the deload week, the pass stops.
        let held = other.suggestedLoad
        let logged = try XCTUnwrap(items.first { $0 !== edited && $0 !== other })
        logged.actualLoads = [50]; logged.actualReps = [10]
        newer.actualLoads = Array(repeating: 200, count: newer.targetSets)
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(other.suggestedLoad, held, "a logged set in the deload week freezes it")
    }

    func test_inactiveHistory_leavesALiftWithNoWorkingLoadAtZero() throws {
        let ctx = try makeContext()
        let s = try seed(DUP10WeekTemplate.template, ctx)
        for sess in s.all { for i in sess.items { i.actualLoads = []; i.actualReps = []; i.actualRIRs = [] } }
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertTrue(s.week.flatMap(\.items).allSatisfy { $0.suggestedLoad == 0 }, "nothing to size from: stays 0")
    }
}


// MARK: - Re-add stress: remove -> re-add on a real seeded wave block, both entry points' sequences

@MainActor
final class WaveRestoreReAddStressTests: XCTestCase {

    private var parked: [ModelContainer] = []

    private func seeded() throws -> (ModelContainer, ModelContext) {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))!
        let weekday = cal.component(.weekday, from: start)
        try DUPProgramSeeder.seed(startDate: start, trainingWeekdays: (0..<4).map { ((weekday - 1 + $0) % 7) + 1 }, context: ctx,
                                  template: UpperLower4DayTemplate.template, mesoName: "UL", mesoStatus: .active)
        try ctx.save()
        return (c, ctx)
    }

    /// Week 2, first day: a B week.
    private func target(_ ctx: ModelContext) throws -> Session {
        let all = try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
        return try XCTUnwrap(all.first { $0.weekIndex == 2 })
    }

    private func generic(_ id: String, order: Int) -> SessionItem {
        let i = SessionItem(order: order, exerciseId: id, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        i.plannedRepsBySet = Array(repeating: 10, count: 3); i.plannedLoadsBySet = Array(repeating: 0, count: 3)
        i.plannedRIRsBySet = Array(repeating: 2, count: 3); i.actualReps = Array(repeating: 0, count: 3)
        i.actualLoads = Array(repeating: 0, count: 3); i.actualRIRs = RIREntry.unsetArray(count: 3)
        return i
    }

    /// The Program tab's performDelete: out of session.items, the object kept (for Undo), saved.
    private func programRemove(_ item: SessionItem, from s: Session, _ ctx: ModelContext) throws {
        let idx = try XCTUnwrap(s.items.firstIndex { $0.id == item.id })
        let order = s.items[idx].order
        s.items.remove(at: idx)
        for o in s.items where o.order > order { o.order -= 1 }
        try ctx.save()
    }

    private func assertRestored(_ item: SessionItem, expected: (sets: Int, repMin: Int, repMax: Int, letter: String), _ note: String) {
        XCTAssertEqual(item.waveRaw, expected.letter, note)
        XCTAssertEqual([item.targetSets, item.repMin ?? -1, item.repMax ?? -1], [expected.sets, expected.repMin, expected.repMax], note)
    }

    func test_removeThenReAdd_tenTimes_everyVariant_alwaysComesBackAsTheSlotsPrescription() throws {
        let (container, ctx) = try seeded()
        let s = try target(ctx)
        let original = try XCTUnwrap(s.items.first { $0.exerciseId == "bench_press" })
        let want = (sets: original.targetSets, repMin: original.repMin ?? -1, repMax: original.repMax ?? -1, letter: original.waveRaw ?? "")
        XCTAssertEqual(want.letter, "b")

        // Variants: 0 Program tab, same context, immediately after the remove. 1 Program tab, fresh context (relationships not yet
        // faulted in). 2 Today, same context, the item inserted after restore. 3 Today with a fresh context. 4 hard delete (no Undo object
        // kept) then add. 5 the add happens before the remove's save is flushed (autosave off, no save between).
        for variant in 0...5 {
            for round in 1...10 {
                let note = "variant \(variant) round \(round)"
                let work = (variant == 1 || variant == 3) ? ModelContext(container) : ctx
                let session = try XCTUnwrap(try work.fetch(FetchDescriptor<Session>()).first { $0.persistentModelID == s.persistentModelID })
                guard let current = session.items.first(where: { $0.exerciseId == "bench_press" }) else { return XCTFail("bench missing \(note)") }
                if variant == 4 { session.items.removeAll { $0.id == current.id }; work.delete(current); try work.save() }
                else if variant == 5 { session.items.removeAll { $0.id == current.id } }          // not saved yet
                else { try programRemove(current, from: session, work) }
                XCTAssertNil(session.items.first { $0.exerciseId == "bench_press" }, note)

                let new = generic("bench_press", order: (session.items.map(\.order).max() ?? 0) + 1)
                let all = (try? work.fetch(FetchDescriptor<Session>())) ?? []
                XCTAssertTrue(WaveSlotRestore.restore(new, in: session, allSessions: all, entry: "stress v\(variant) r\(round)"), note)
                session.items.append(new)
                if variant == 2 || variant == 3 { work.insert(new) }
                try work.save()
                assertRestored(new, expected: want, note)
                // Re-read from the store: what was saved is what was restored.
                let reread = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<SessionItem>()).first { $0.id == new.id })
                assertRestored(reread, expected: want, note + " (re-read)")
            }
        }
    }

    func test_restoreOnASessionWithNoLoadedItems_orNoMeso_degradesToNothingWrongRatherThanTheGenericItemPassingAsRestored() throws {
        let (_, ctx) = try seeded()
        let s = try target(ctx)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        // Wave context unavailable: every item gone (nothing to read the letter from) -> not restored, and it says so.
        let emptyCopy = Session(date: s.date, status: .planned, weekIndex: s.weekIndex, dayLabel: s.dayLabel, items: [])
        let new = generic("bench_press", order: 1)
        XCTAssertFalse(WaveSlotRestore.restore(new, in: emptyCopy, allSessions: all, entry: "stress no-context"))
        XCTAssertNil(new.waveRaw)
        // A session whose only remaining item is the one being re-added still reads the letter from the block.
        let only = try XCTUnwrap(s.items.first { $0.exerciseId == "bench_press" })
        for i in s.items where i !== only { s.items.removeAll { $0.id == i.id } }
        let again = generic("bench_press", order: 2)
        XCTAssertTrue(WaveSlotRestore.restore(again, in: s, allSessions: all, entry: "stress one-item"))
        XCTAssertEqual(again.waveRaw, "b")
    }
}
