import XCTest
import SwiftData
@testable import ElitePerformance

final class SessionItemEditServiceNextMesoTests: XCTestCase {

    private typealias Service = SessionItemEditService

    private var container: ModelContainer!   // keeps the in-memory store alive for the test

    // MARK: - Fixtures (same shapes as SessionItemEditServiceTests)

        private func cal() -> Calendar { Calendar(identifier: .gregorian) }

        private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal().date(from: DateComponents(year: y, month: m, day: d))!
    }

        /// The real 10-week DUP block (Fri Sep 25 2026 start, six days a week). `convert12` runs the
    /// production 10 -> 12 week conversion on it.
    private func makeBlock(convert12: Bool = false) throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self, AppState.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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

        private func plan(_ block: MesoBlock, _ ctx: ModelContext, _ p: (day: String, x: String, y: String),
                      scope: Service.ReplaceScope = .allRemaining, now: Date) -> Service.ReplacePlan {
        Service.planReplace(meso: block, dayLabel: p.day, from: p.x, to: p.y, scope: scope, context: ctx, now: now)
    }

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

    // MARK: - Start next meso: plan (M2)

    private var nextNow: Date { date(2026, 9, 20) }                     // before the fixture block starts

    private func nextPlan(_ block: MesoBlock, _ ctx: ModelContext, start: Date? = nil, end: Bool = true,
                          now: Date? = nil) -> Service.NextMesoPlan {
        Service.planNextMeso(meso: block, name: "Next", startDate: start, endOldMesoNow: end,
                             context: ctx, now: now ?? nextNow)
    }

    private func weekday(_ d: Date) -> Int { Calendar.current.component(.weekday, from: d) }

    /// A block of any template, seeded by the real seeder.
    private func makeTemplateBlock(_ template: ProgramTemplate, weekdays: [Int], start: Date) throws -> (ModelContext, MesoBlock) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self, AppState.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        try DUPProgramSeeder.seed(startDate: start, trainingWeekdays: weekdays, context: ctx, template: template,
                                  calendar: cal(), mesoName: template.name, mesoStatus: .active)
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
        try ctx.save()
        return (ctx, block)
    }

    func test_next_12weekBlock_layoutKeepsLettersWeekdaysAndContiguousNumbering() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let old = sessions(block)
        let result = nextPlan(block, ctx)
        XCTAssertTrue(result.refusals.isEmpty, "\(result.refusals)")
        XCTAssertEqual(result.weeks, 12)
        XCTAssertEqual(result.sessions.count, 72)
        XCTAssertEqual(result.sessions.map(\.programIndex), Array(1...72))
        XCTAssertEqual(result.sessions.map(\.date), result.sessions.map(\.date).sorted())
        XCTAssertEqual(Set(result.sessions.map(\.weekIndex)), Set(1...12))
        let pattern = ["a", "b", "c", "a", "b", "c", "a", "b", "c", "a", "b", "c"]
        for s in result.sessions { XCTAssertEqual(s.letter, pattern[s.weekIndex - 1]) }
        // Weekday per day type is the old one; the first session lands on the first old weekday, on/after the default start.
        for s in result.sessions {
            let o = try XCTUnwrap(old.first { $0.dayLabel == s.dayLabel })
            XCTAssertEqual(weekday(s.date), weekday(o.date), s.dayLabel ?? "")
        }
        let defaultStart = try XCTUnwrap(Service.defaultNextMesoStart(for: block))
        XCTAssertEqual(defaultStart, Calendar.current.startOfDay(for: old.last!.date.addingTimeInterval(86400)))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.sessions.first).date, defaultStart)
        XCTAssertEqual(weekday(try XCTUnwrap(result.sessions.first).date), weekday(old.first!.date))
        XCTAssertEqual(result.sessionsToDelete.count, 72, "everything is planned and in the future")
        // Items: prescription copied, arrays sized, no history -> nothing to seed.
        for s in result.sessions {
            for i in s.items {
                XCTAssertEqual(i.plannedReps.count, i.targetSets)
                XCTAssertEqual(i.waveRaw?.lowercased(), s.letter)
                XCTAssertTrue(i.seedSource == .none || i.seedSource == .bodyweight)
                XCTAssertEqual(i.seed, 0)
            }
        }
        XCTAssertFalse(result.previewLines().isEmpty)
    }

    func test_next_isPure() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let before = try fullSnapshot(ctx)
        _ = nextPlan(block, ctx)
        XCTAssertEqual(try fullSnapshot(ctx), before)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MesoBlock>()).count, 1)
    }

    func test_next_replacedSlot_usesTheNewExerciseInEveryWeek() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let first = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day })
        let order = try XCTUnwrap(item(first, p.x)).order
        complete(first, item: try XCTUnwrap(item(first, p.x)), load: 135)       // week 1 keeps X as history
        try ctx.save()
        let now = first.date.addingTimeInterval(3600)
        try Service.apply(plan(block, ctx, p, now: now), in: ctx)

        let result = nextPlan(block, ctx, now: now)
        let days = result.sessions.filter { $0.dayLabel == p.day }
        XCTAssertEqual(days.count, 12)
        for s in days {
            XCTAssertNil(s.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: p.x) },
                         "week \(s.weekIndex) still has X")
            XCTAssertEqual(s.items.first { $0.order == order }?.exerciseId, p.y, "week \(s.weekIndex)")
        }
    }

    func test_next_swappedThenReplaced_endsOnTheLastExercise() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let used = Set(block.sessions.flatMap(\.items).map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) })
        let z = try XCTUnwrap(ExerciseCatalog.all.first {
            !used.contains($0.id) && $0.id != p.y && !ExerciseCatalog.isBodyweight(exerciseId: $0.id)
        }).id
        let now = date(2026, 9, 24)
        try Service.apply(plan(block, ctx, p, now: now), in: ctx)
        try Service.apply(Service.planReplace(meso: block, dayLabel: p.day, from: p.y, to: z, scope: .allRemaining, context: ctx, now: now), in: ctx)

        let result = nextPlan(block, ctx, now: now)
        for s in result.sessions.filter({ $0.dayLabel == p.day }) {
            let ids = s.items.map { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) }
            XCTAssertTrue(ids.contains(ExerciseCatalog.canonicalExerciseId(for: z)), "week \(s.weekIndex)")
            XCTAssertFalse(ids.contains(ExerciseCatalog.canonicalExerciseId(for: p.x)))
            XCTAssertFalse(ids.contains(ExerciseCatalog.canonicalExerciseId(for: p.y)))
        }
    }

    func test_next_insertedDeloadWeek_isExcluded_andWeeksStayContiguous() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let clean = nextPlan(block, ctx)
        let insert = Service.planInsertDeloadWeek(meso: block, context: ctx, now: nextNow, week: 6)
        XCTAssertNil(insert.refusal)
        try Service.insertDeloadWeek(insert, in: ctx)
        XCTAssertEqual(block.totalWeeks, 13)

        let result = nextPlan(block, ctx)
        XCTAssertTrue(result.refusals.isEmpty, "\(result.refusals)")
        XCTAssertEqual(result.weeks, 12)
        XCTAssertEqual(result.sessions.count, 72)
        XCTAssertEqual(result.sessions.map(\.letter), clean.sessions.map(\.letter))
        XCTAssertFalse(result.sessions.contains { $0.templateSession.insertedDeload == true })
        XCTAssertFalse(result.sessions.contains { $0.letter == "deload" })
        XCTAssertEqual(result.sessions.map(\.weekIndex), clean.sessions.map(\.weekIndex))
        XCTAssertEqual(result.sessions.map(\.programIndex), Array(1...72))
        XCTAssertEqual(result.sessionsToDelete.count, 78, "the old meso's inserted week is removed with the rest")
    }

    /// CHANGED by B7 (prescribed set count): this used to pin that an earned in-session extra set was copied
    /// into the same week of the next meso. The clone now reads the PRESCRIBED count, so Add Set -- which only
    /// changes what that session ran -- is not carried; a deliberate prescription edit is (next test).
    func test_next_earnedExtraSet_isNotCopiedIntoTheNextMeso() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let w5 = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day && $0.weekIndex == 5 })
        let it = try XCTUnwrap(item(w5, p.x))
        let base = it.targetSets
        it.targetSets = base + 1
        try ctx.save()

        let result = nextPlan(block, ctx)
        func sets(_ week: Int) -> Int? {
            result.sessions.first { $0.dayLabel == p.day && $0.weekIndex == week }?
                .items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: p.x) }?.targetSets
        }
        XCTAssertEqual(sets(5), base, "an in-session Add Set is not the prescription")
        XCTAssertEqual(sets(11), try XCTUnwrap(item(try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day && $0.weekIndex == 11 }), p.x)).targetSets,
                       "the other B weeks keep their own count")
        let planned = try XCTUnwrap(result.sessions.first { $0.dayLabel == p.day && $0.weekIndex == 5 }?.items.first { $0.order == it.order })
        XCTAssertEqual(planned.plannedReps.count, base)
    }

    /// A deliberate prescription edit of one week (Change prescription / Program tab) IS copied into the same week.
    func test_next_prescriptionEditOfOneWeek_isCopiedIntoTheSameWeekOnly() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let w5 = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day && $0.weekIndex == 5 })
        let it = try XCTUnwrap(item(w5, p.x))
        let base = it.targetSets
        it.setPrescribedSets(base + 1)
        try ctx.save()
        let result = nextPlan(block, ctx)
        func sets(_ week: Int) -> Int? {
            result.sessions.first { $0.dayLabel == p.day && $0.weekIndex == week }?
                .items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: p.x) }?.targetSets
        }
        XCTAssertEqual(sets(5), base + 1)
        let planned = try XCTUnwrap(result.sessions.first { $0.dayLabel == p.day && $0.weekIndex == 5 }?.items.first { $0.order == it.order })
        XCTAssertGreaterThanOrEqual(planned.setMax ?? 0, base + 1)
        XCTAssertEqual(planned.plannedReps.count, base + 1)
    }

    func test_next_handAddedNilWaveLift_isStampedWithTheWeeksLetter() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let last = try XCTUnwrap(sessions(block).last { $0.dayLabel == p.day })     // week 12, letter c
        let added = SessionItem(order: 99, exerciseId: p.y, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        XCTAssertNil(added.waveRaw)
        last.items.append(added)
        try ctx.save()

        let result = nextPlan(block, ctx)
        for s in result.sessions.filter({ $0.dayLabel == p.day }) {
            let found = s.items.first { $0.order == 99 }
            if s.letter == "c" {
                XCTAssertEqual(found?.exerciseId, p.y, "week \(s.weekIndex)")
                XCTAssertEqual(found?.waveRaw, "c")
            } else {
                XCTAssertNil(found, "only the C template holds the lift")
            }
        }
    }

    func test_next_dayCounts_2_3_4_6_andWeekdayPatterns() throws {
        let cases: [(ProgramTemplate, [Int])] = [
            (FullBody2DayTemplate.template, [2, 5]),
            (PPL3WeekTemplate.template, [3, 5, 7]),
            (UpperLower4DayTemplate.template, [2, 3, 5, 6]),
            (Hybrid5DayTemplate.template, [2, 3, 4, 5, 6]),
            (DUP10WeekTemplate.template, [1, 2, 3, 4, 6, 7]),
        ]
        for (template, weekdays) in cases {
            let (ctx, block) = try makeTemplateBlock(template, weekdays: weekdays, start: date(2026, 9, 21))
            let old = sessions(block)
            let result = nextPlan(block, ctx)
            XCTAssertTrue(result.refusals.isEmpty, "\(template.name): \(result.refusals)")
            XCTAssertEqual(result.weeks, template.totalWeeks, template.name)
            XCTAssertEqual(result.sessions.count, weekdays.count * template.totalWeeks, template.name)
            XCTAssertEqual(result.sessions.map(\.programIndex), Array(1...result.sessions.count), template.name)
            XCTAssertEqual(Set(result.sessions.map { weekday($0.date) }), Set(weekdays), template.name)
            for s in result.sessions {
                let o = try XCTUnwrap(old.first { $0.dayLabel == s.dayLabel })
                XCTAssertEqual(weekday(s.date), weekday(o.date), "\(template.name) \(s.dayLabel ?? "")")
            }
            XCTAssertEqual(Dictionary(grouping: result.sessions, by: \.weekIndex).values.map(\.count), Array(repeating: weekdays.count, count: template.totalWeeks), template.name)
            // The week starts on the old first day's weekday.
            XCTAssertEqual(weekday(try XCTUnwrap(result.sessions.first).date), weekday(try XCTUnwrap(old.first).date), template.name)
        }
    }

    func test_next_oneOffWeekdayAnomaly_doesNotMoveTheDayType() throws {
        let (ctx, block) = try makeTemplateBlock(PPL3WeekTemplate.template, weekdays: [2, 4, 6], start: date(2026, 9, 21))
        let old = sessions(block)
        let moved = try XCTUnwrap(old.first { $0.weekIndex == 4 && $0.dayLabel == old[0].dayLabel })
        moved.date = Calendar.current.date(byAdding: .day, value: 1, to: moved.date)!       // one Tuesday instead of Monday
        try ctx.save()
        let result = nextPlan(block, ctx, start: date(2026, 12, 15))                          // a Tuesday
        let first = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(first.dayLabel, old[0].dayLabel)
        XCTAssertEqual(weekday(first.date), 2, "the usual weekday wins")
        XCTAssertGreaterThanOrEqual(first.date, date(2026, 12, 15))
        XCTAssertEqual(first.date, date(2026, 12, 21), "next Monday on/after the chosen start")
    }

    /// A 4-week, 2-day maintenance block (deload wave on every item, no letters), planned from Mon Oct 5 2026.
    private func makeMaintenanceMeso() throws -> (ModelContext, MesoBlock, [Session]) {
        let c = try ModelContainer(for: Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                                                UserProfile.self, User.self, CustomExercise.self, AppState.self]),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        let meso = MesoBlock(name: "Maintenance Block", startDate: date(2026, 10, 5), status: .active, totalWeeks: 4, isMaintenance: true)
        ctx.insert(meso)
        var made: [Session] = []
        for w in 1...4 {
            for (n, label) in ["Day A", "Day B"].enumerated() {
                let roster = [(exerciseId: "bench_press", name: "Bench Press" as String?, order: 1),
                              (exerciseId: "barbell_row", name: "Row" as String?, order: 2)]
                let s = Session(date: date(2026, 10, 5 + (w - 1) * 7 + n * 3), status: .planned, weekIndex: w, dayLabel: label,
                                items: MaintenanceProgramSeeder.applyMaintenancePrescription(to: roster))
                s.meso = meso; s.programIndex = (w - 1) * 2 + n + 1
                ctx.insert(s); made.append(s)
            }
        }
        try ctx.save()
        return (ctx, meso, made)
    }

    func test_next_maintenanceBlock_nonWave_chronologicalPerDayType() throws {
        let (ctx, meso, made) = try makeMaintenanceMeso()
        made.first { $0.weekIndex == 3 && $0.dayLabel == "Day A" }!.items.first { $0.order == 1 }!.setPrescribedSets(3)
        try ctx.save()

        let result = Service.planNextMeso(meso: meso, name: "M2", endOldMesoNow: true, context: ctx, now: date(2026, 10, 1))
        XCTAssertTrue(result.refusals.isEmpty, "\(result.refusals)")
        XCTAssertEqual(result.sessions.count, 8)
        XCTAssertTrue(result.isMaintenance)
        XCTAssertEqual(Set(result.sessions.map(\.letter)), [""])
        for s in result.sessions {
            XCTAssertEqual(s.items.map(\.waveRaw), ["deload", "deload"])
            XCTAssertEqual(s.sessionNotes, "\(s.dayLabel ?? "") · Maintenance")
        }
        XCTAssertEqual(result.sessions.first { $0.weekIndex == 3 && $0.dayLabel == "Day A" }?.items.first { $0.order == 1 }?.targetSets, 3)
        XCTAssertEqual(result.sessions.first { $0.weekIndex == 2 && $0.dayLabel == "Day A" }?.items.first { $0.order == 1 }?.targetSets, 2)
        XCTAssertEqual(weekday(try XCTUnwrap(result.sessions.first).date), weekday(made[0].date))
    }

    func test_next_seeds_comeFromThePeakOfTheOldMeso() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let first = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day })
        let it = try XCTUnwrap(item(first, p.x))
        complete(first, item: it, load: 150, reps: 6)
        try ctx.save()
        let now = first.date.addingTimeInterval(86400 * 2)

        let result = nextPlan(block, ctx, now: now)
        XCTAssertEqual(result.refusals, [], "\(result.refusals)")
        let planned = try XCTUnwrap(result.sessions.first { $0.dayLabel == p.day && $0.weekIndex == 1 }?
            .items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: p.x) })
        let expected = try XCTUnwrap(HistorySeedLoad.peakLoad(for: p.x, goalReps: planned.targetReps, targetRIR: planned.targetRIR,
                                                              in: block.sessions, loadIncrement: 2.5))
        XCTAssertEqual(planned.seed, expected)
        XCTAssertEqual(planned.seedSource, .peak)
        XCTAssertGreaterThan(planned.seed, 0)
        let todayStart = Calendar.current.startOfDay(for: now)
        XCTAssertEqual(result.sessionsToDelete.count, sessions(block).filter { $0.status == .planned && $0.date >= todayStart }.count,
                       "completed and already-passed sessions stay")
        XCTAssertFalse(result.sessionsToDelete.contains { $0 === first })
    }

    func test_next_refusals() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let all = sessions(block)

        // Remaining planned sessions and no "end now".
        let keep = nextPlan(block, ctx, end: false)
        XCTAssertTrue(keep.refusals.contains(.oldMesoHasRemainingSessions))
        XCTAssertEqual(keep.remainingOldSessions.count, 72)

        // Start before today.
        let past = nextPlan(block, ctx, start: date(2026, 9, 1))
        XCTAssertTrue(past.refusals.contains(.startInPast))

        // Anything in progress.
        all[3].status = .inProgress
        XCTAssertTrue(nextPlan(block, ctx).refusals.contains(.sessionInProgress))
        all[3].status = .planned

        // Something logged on a remaining planned session cannot be removed.
        all[4].items.first!.actualReps = [5]; all[4].items.first!.actualLoads = [100]
        XCTAssertTrue(nextPlan(block, ctx).refusals.contains(.remainingSessionHasLoggedData))
        all[4].items.first!.actualReps = []; all[4].items.first!.actualLoads = []

        // Collision with a session of ANOTHER meso on a day the new meso needs.
        let ok = nextPlan(block, ctx)
        XCTAssertTrue(ok.refusals.isEmpty)
        let day = Calendar.current.startOfDay(for: try XCTUnwrap(ok.sessions[10]).date)
        let other = MesoBlock(name: "Other", startDate: day, status: .archived, totalWeeks: 1)
        ctx.insert(other)
        let intruder = Session(date: day.addingTimeInterval(3600 * 7), status: .planned, weekIndex: 1, dayLabel: "X", items: [])
        intruder.meso = other
        ctx.insert(intruder)
        try ctx.save()
        let blocked = nextPlan(block, ctx)
        XCTAssertTrue(blocked.refusals.contains(.dateCollision))
        XCTAssertEqual(blocked.collisions.count, 1)
        XCTAssertTrue(blocked.collisions.first?.occupant === intruder)
        XCTAssertFalse(blocked.isApplicable)

        // Nothing to copy.
        let empty = MesoBlock(name: "Empty", startDate: date(2026, 12, 1), status: .active)
        ctx.insert(empty)
        XCTAssertEqual(Service.planNextMeso(meso: empty, name: "n", endOldMesoNow: true, context: ctx, now: nextNow).refusals, [.nothingToCopy])
    }

    // MARK: - Start next meso: apply (M3)

    private let lifecycleKeys = ["meso.scheduledStartDateEpoch", "meso.activeStartDateEpoch", "meso.promptSnoozeEpoch",
                                "meso.anchorDate", "meso.anchorDayNumber"]

    /// Runs `body` with the lifecycle defaults saved and restored (the apply moves them).
    private func withLifecycleDefaults(_ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        let saved = lifecycleKeys.map { ($0, d.object(forKey: $0)) }
        defer { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        try body()
    }

    /// The snapshot lines of every completed session in `snap` (its S| line and the item lines under it).
    private func completedBlocks(_ snap: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        var inCompleted = false
        for line in snap {
            if line.hasPrefix("S|") {
                if inCompleted { blocks.append(current) }
                current = [line]
                inCompleted = line.split(separator: "|", omittingEmptySubsequences: false)[2] == "completed"
            } else { current.append(line) }
        }
        if inCompleted { blocks.append(current) }
        return blocks
    }

    private func blocksOf(_ ctx: ModelContext) throws -> [MesoBlock] {
        try ctx.fetch(FetchDescriptor<MesoBlock>())
    }

    func test_nextApply_createsTheMeso_archivesTheOld_keepsHistory_andMovesTheLifecycleAfterSave() throws {
        try withLifecycleDefaults {
            let (ctx, block) = try makeBlock(convert12: true)
            let p = try pick(block)
            let first = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day })
            let it = try XCTUnwrap(item(first, p.x))
            complete(first, item: it, load: 150, reps: 6)
            try ctx.save()
            let now = first.date.addingTimeInterval(3600)
            MesoLifecycle.scheduleNextMeso(on: date(2026, 12, 14))
            let before = try fullSnapshot(ctx)

            let planned = nextPlan(block, ctx, now: now)
            XCTAssertTrue(planned.isApplicable, "\(planned.refusals)")
            let result = try Service.startNextMeso(planned, in: ctx)

            XCTAssertEqual(result.sessionsCreated, 72)
            XCTAssertEqual(result.sessionsDeleted, planned.sessionsToDelete.count)
            let blocks = try blocksOf(ctx)
            XCTAssertEqual(blocks.count, 2)
            XCTAssertEqual(block.status, .archived)
            let new = result.meso
            XCTAssertEqual(new.status, .active)
            XCTAssertEqual(blocks.filter { $0.status == .active }.count, 1)
            XCTAssertEqual(new.name, "Next")
            XCTAssertEqual(new.totalWeeks, 12)
            XCTAssertFalse(new.isMaintenance)
            XCTAssertEqual(new.sessions.count, 72)
            // Old meso: only completed and already-passed sessions remain, byte-identical.
            XCTAssertTrue(block.sessions.allSatisfy { $0.status == .completed || $0.date < Calendar.current.startOfDay(for: now) })
            let after = try fullSnapshot(ctx)
            for done in completedBlocks(before) {
                let at = try XCTUnwrap(after.firstIndex(of: done[0]))
                XCTAssertEqual(Array(after[at..<(at + done.count)]), done)
            }
            // The new items: clean, seeded from the peak, wave stamped, no state carried.
            for s in new.sessions {
                XCTAssertEqual(s.status, .planned)
                XCTAssertNotEqual(s.insertedDeload, true)
                for i in s.items {
                    XCTAssertFalse(i.planEdited)
                    XCTAssertFalse(SessionEditSafety.hasLoggedData(i))
                    XCTAssertEqual(i.plannedLoadsBySet, Array(repeating: i.suggestedLoad, count: i.targetSets))
                }
            }
            let seeded = try XCTUnwrap(new.sessions.first { $0.dayLabel == p.day && $0.weekIndex == 1 }?.items.first { $0.exerciseId == p.x })
            XCTAssertGreaterThan(seeded.suggestedLoad, 0)
            // Lifecycle moved only now.
            XCTAssertNil(MesoLifecycle.scheduledStartDate)
            XCTAssertEqual(Calendar.current.startOfDay(for: MesoLifecycle.activeStartDate), planned.startDate)
            XCTAssertEqual(AppStateBridge.shared(in: ctx).activeMesoStartDate, planned.startDate)
            XCTAssertNil(AppStateBridge.shared(in: ctx).scheduledNextMesoStartDate)
        }
    }

    func test_nextApply_replacedExerciseCuesAndSets_surviveIntoTheNewMeso() throws {
        try withLifecycleDefaults {
            let (ctx, block) = try makeBlock(convert12: true)
            let p = try pick(block)
            let now = date(2026, 9, 24)
            try Service.apply(plan(block, ctx, p, now: now), in: ctx)
            let lastOfDay = try XCTUnwrap(sessions(block).last { $0.dayLabel == p.day })
            let y = try XCTUnwrap(item(lastOfDay, p.y))
            y.prescriptionNotes = "tempo 3-1-1"; y.intensifierNotes = nil
            try ctx.save()

            let result = try Service.startNextMeso(nextPlan(block, ctx, now: now), in: ctx)
            XCTAssertEqual(result.meso.previousMesoId, block.id, "the new block remembers the block it was started from")
            for s in result.meso.sessions where s.dayLabel == p.day && s.items.contains(where: { $0.exerciseId == p.y }) {
                let i = try XCTUnwrap(s.items.first { $0.exerciseId == p.y })
                if s.weekIndex == 12 { XCTAssertEqual(i.executionNoteText, "tempo 3-1-1") }
            }
            XCTAssertTrue(result.meso.sessions.filter { $0.dayLabel == p.day }.allSatisfy { s in
                s.items.contains { $0.exerciseId == p.y } && !s.items.contains { $0.exerciseId == p.x }
            })
        }
    }

    func test_nextApply_endOldMesoFalse_whenTheOldMesoIsFinished_deletesNothing() throws {
        try withLifecycleDefaults {
            let (ctx, block) = try makeBlock(convert12: true)
            for s in block.sessions { s.status = .completed }
            try ctx.save()
            let before = try fullSnapshot(ctx)
            let now = try XCTUnwrap(Service.defaultNextMesoStart(for: block))      // the day after the last session
            let planned = nextPlan(block, ctx, end: false, now: now)
            XCTAssertTrue(planned.isApplicable, "\(planned.refusals)")
            XCTAssertTrue(planned.sessionsToDelete.isEmpty)
            let result = try Service.startNextMeso(planned, in: ctx)
            XCTAssertEqual(result.sessionsDeleted, 0)
            XCTAssertEqual(block.status, .archived)
            XCTAssertEqual(block.sessions.count, 72)
            let after = try fullSnapshot(ctx)
            XCTAssertEqual(Array(after.prefix(before.count)).count, before.count)
            XCTAssertTrue(Set(before).isSubset(of: Set(after)), "every old session line is untouched")
        }
    }

    func test_nextApply_staleRefusedAndHookedFailures_leaveEverythingAsItWas() throws {
        try withLifecycleDefaults {
            let (ctx, block) = try makeBlock(convert12: true)
            MesoLifecycle.scheduleNextMeso(on: date(2026, 12, 14))
            let scheduled = MesoLifecycle.scheduledStartDate
            let before = try fullSnapshot(ctx)
            func untouched(_ what: String) throws {
                XCTAssertEqual(try fullSnapshot(ctx), before, what)
                let blocks = try blocksOf(ctx)
                XCTAssertEqual(blocks.count, 1, what)
                XCTAssertEqual(block.status, .active, what)
                XCTAssertEqual(MesoLifecycle.scheduledStartDate, scheduled, what)
            }

            let planned = nextPlan(block, ctx)
            XCTAssertThrowsError(try Service.startNextMeso(planned, in: ctx, hooks: .init(forceVerificationFailure: true))) {
                guard case Service.NextMesoError.verificationFailed(let problems) = $0 else { return XCTFail("\($0)") }
                XCTAssertEqual(problems, ["forced verification failure (test hook)"], "a clean apply has no other problems")
            }
            try untouched("verification failure")
            XCTAssertThrowsError(try Service.startNextMeso(planned, in: ctx, hooks: .init(forceSaveFailure: true))) {
                guard case Service.NextMesoError.saveFailed = $0 else { return XCTFail("\($0)") }
            }
            try untouched("save failure")

            // A plan with refusals does not apply.
            let refused = nextPlan(block, ctx, end: false)
            XCTAssertThrowsError(try Service.startNextMeso(refused, in: ctx)) {
                guard case Service.NextMesoError.refused(let r) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(r.contains(.oldMesoHasRemainingSessions))
            }
            try untouched("refused")

            // The old meso moved under the plan: its template changed.
            let it = try XCTUnwrap(sessions(block).last!.items.first)
            let n0 = it.targetSets
            it.setPrescribedSets(n0 + 1)
            XCTAssertThrowsError(try Service.startNextMeso(planned, in: ctx)) {
                XCTAssertEqual($0 as? Service.NextMesoError, .planStale)
            }
            it.setPrescribedSets(n0)
            try untouched("stale")
            // ... and the same plan still applies once the state matches again.
            XCTAssertNoThrow(try Service.startNextMeso(planned, in: ctx))
        }
    }

    func test_nextApply_afterAnInsertedDeload_theNewMesoHasNone() throws {
        try withLifecycleDefaults {
            let (ctx, block) = try makeBlock(convert12: true)
            try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: nextNow, week: 4), in: ctx)
            let result = try Service.startNextMeso(nextPlan(block, ctx), in: ctx)
            XCTAssertEqual(result.meso.sessions.count, 72)
            XCTAssertFalse(result.meso.sessions.contains { $0.insertedDeload == true })
            XCTAssertEqual(result.meso.totalWeeks, 12)
            XCTAssertEqual(Set(result.meso.sessions.map(\.weekIndex)), Set(1...12))
        }
    }

    func test_nextApply_maintenanceBlock_staysMaintenance_andChainsChronologically() throws {
        try withLifecycleDefaults {
            let (ctx, meso, _) = try makeMaintenanceMeso()
            let planned = Service.planNextMeso(meso: meso, name: "Maint 2", endOldMesoNow: true, context: ctx, now: date(2026, 10, 1))
            let result = try Service.startNextMeso(planned, in: ctx)
            XCTAssertTrue(result.meso.isMaintenance)
            XCTAssertEqual(result.meso.sessions.count, 8)
            XCTAssertEqual(meso.status, .archived)
            // Maintenance items carry the deload wave, so the chain is: same day type, next week.
            let sorted = result.meso.sessions.sorted { $0.date < $1.date }
            let all = try ctx.fetch(FetchDescriptor<Session>())
            for (idx, s) in sorted.enumerated() {
                let a = try XCTUnwrap(s.items.first { $0.exerciseId == "bench_press" })
                let expected = sorted[(idx + 1)...].lazy.filter { $0.dayLabel == s.dayLabel }
                    .compactMap { $0.items.first { $0.exerciseId == "bench_press" } }.first
                let resolved = PlanMemoryEngine.nextTargetItem(for: a, after: s, in: all)
                XCTAssertTrue(resolved === expected, "\(s.dayLabel ?? "") wk\(s.weekIndex)")
                XCTAssertEqual(expected == nil, s.weekIndex == 4)
            }
        }
    }

    func test_nextApply_canBeRepeated_theCopyOfACopyHasTheSameShape() throws {
        try withLifecycleDefaults {
            let (ctx, block) = try makeBlock(convert12: true)
            let firstPlan = nextPlan(block, ctx)
            let first = try Service.startNextMeso(firstPlan, in: ctx)
            let again = Service.planNextMeso(meso: first.meso, name: "Third", endOldMesoNow: true, context: ctx, now: nextNow)
            XCTAssertTrue(again.refusals.isEmpty, "\(again.refusals)")
            func shape(_ sessions: [Service.NextMesoSession]) -> [String] {
                sessions.map { "\($0.weekIndex)|\($0.dayLabel ?? "")|\($0.letter)|" + $0.items.map { "\($0.order):\($0.exerciseId):\($0.targetSets):\($0.prescription)" }.joined(separator: ",") }
            }
            XCTAssertEqual(shape(again.sessions), shape(firstPlan.sessions))
            XCTAssertEqual(again.sessions.map { Calendar.current.component(.weekday, from: $0.date) },
                           firstPlan.sessions.map { Calendar.current.component(.weekday, from: $0.date) })
            XCTAssertEqual(again.sessions.count, 72)
        }
    }

    // MARK: - Top set

    /// The next meso inherits a lift's top set (roles, spec) from its latest week, with the top load seeded separately.
    func test_next_inheritsTheTopSet_andSeedsTheTopLoadAtTopReps() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let all = sessions(block)
        for s in all {
            guard let it = item(s, p.x), s.dayLabel == p.day else { continue }
            let n = it.targetSets
            it.setRolesBySet = SessionItem.roles(backOffs: n, tops: 1)
            it.topRepMin = 4; it.topRepMax = 6; it.topRIR = 2
            it.plannedLoadsBySet = Array(it.plannedLoadsBySet.prefix(n)) + [0]
            it.plannedRepsBySet = Array(it.plannedRepsBySet.prefix(n)) + [4]
            it.plannedRIRsBySet = Array(it.plannedRIRsBySet.prefix(n)) + [2]
        }
        // History: the lift was done at 200 x 8 and a heavier 4-rep top.
        let done = try XCTUnwrap(all.first { $0.dayLabel == p.day })
        let doneItem = try XCTUnwrap(item(done, p.x))
        let n = doneItem.targetSets
        doneItem.actualLoads = Array(repeating: 200, count: n) + [260]
        doneItem.actualReps = Array(repeating: 8, count: n) + [4]
        doneItem.actualRIRs = Array(repeating: 2, count: n + 1)
        done.status = .completed
        try ctx.save()

        let plan = nextPlan(block, ctx)
        XCTAssertTrue(plan.isApplicable, "\(plan.refusals)")
        let planned = plan.sessions.flatMap(\.items).filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: p.x) }
        XCTAssertFalse(planned.isEmpty)
        for ip in planned {
            XCTAssertEqual(ip.topCount, 1)
            XCTAssertEqual([ip.topRepMin, ip.topRepMax, ip.topRIR], [4, 6, 2])
            XCTAssertEqual(ip.plannedReps.count, ip.targetSets + 1)
            XCTAssertEqual(ip.plannedReps.last, 4)
            XCTAssertTrue(ip.prescription.contains(" top + "), ip.prescription)
            XCTAssertGreaterThan(ip.topSeed, ip.seed, "the top seed reads the heavy 4-rep set; the back-off seed reads the 8s")
        }
        let result = try Service.startNextMeso(plan, in: ctx)
        _ = result
        let created = try ctx.fetch(FetchDescriptor<Session>()).filter { $0.meso?.name == "Next" }
        let items = created.flatMap(\.items).filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: p.x) }
        XCTAssertFalse(items.isEmpty)
        for i in items {
            XCTAssertEqual(i.setRolesBySet, SessionItem.roles(backOffs: i.targetSets, tops: 1))
            XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets + 1)
            XCTAssertGreaterThan(i.plannedLoadsBySet.last ?? 0, i.suggestedLoad)
            XCTAssertTrue(i.plannedLoadsBySet.dropLast().allSatisfy { $0 == i.suggestedLoad })
        }
    }

    // MARK: - Prescribed set count survives in-session Add Set

    private func planned(_ plan: Service.NextMesoPlan, week: Int, day: String, x: String) -> Service.NextMesoItem? {
        plan.sessions.first { $0.weekIndex == week && $0.dayLabel == day }?.items
            .first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: x) }
    }

    /// Add Set on a completed session changes `targetSets` only; the clone keeps the prescribed count.
    func test_next_clone_usesPrescribedSets_notTheAddSetInflation() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let done = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day })
        let it = try XCTUnwrap(item(done, p.x))
        let n = it.targetSets
        XCTAssertEqual(it.prescribedSets, n, "a seeded item is born prescribed")
        it.targetSets = n + 1                   // what the logger's persist() does on Add Set
        complete(done, item: it, load: 200)
        try ctx.save()
        XCTAssertEqual(it.prescribedSets, n, "Add Set never touches prescribedSets")
        let plan = nextPlan(block, ctx)
        XCTAssertEqual(planned(plan, week: done.weekIndex, day: p.day, x: p.x)?.targetSets, n)
    }

    /// Old data (no key anywhere) keeps today's behavior: the clone reads targetSets.
    func test_next_clone_oldDataWithoutTheKey_keepsTodaysBehavior() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        for s in block.sessions { for i in s.items { i.prescribedSets = nil } }
        let done = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day })
        let it = try XCTUnwrap(item(done, p.x))
        let n = it.targetSets
        it.targetSets = n + 1
        complete(done, item: it, load: 200)
        try ctx.save()
        XCTAssertEqual(planned(nextPlan(block, ctx), week: done.weekIndex, day: p.day, x: p.x)?.targetSets, n + 1)
    }

    /// A completed item without the key takes the nearest same-letter session that has it.
    func test_next_clone_nilPrescribedOnCompleted_fallsBackToTheSameLetterNeighbour() throws {
        let (ctx, block) = try makeBlock()
        let p = try pick(block)
        let done = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day })
        let it = try XCTUnwrap(item(done, p.x))
        let n = it.targetSets
        it.targetSets = n + 1
        it.prescribedSets = nil                  // a session logged before the key existed
        complete(done, item: it, load: 200)
        try ctx.save()
        XCTAssertEqual(planned(nextPlan(block, ctx), week: done.weekIndex, day: p.day, x: p.x)?.targetSets, n,
                       "the next same-letter session of the block carries the key")
        // A planned session without the key is already the prescription: no fallback.
        let later = try XCTUnwrap(sessions(block).last { $0.dayLabel == p.day })
        let laterItem = try XCTUnwrap(item(later, p.x))
        laterItem.prescribedSets = nil
        XCTAssertEqual(Service.prescribedSetCount(of: laterItem, in: later, among: sessions(block)), laterItem.targetSets)
    }

    // MARK: - Max load

    func test_next_seeds_areClampedToTheMax() throws {
        let (ctx, block) = try makeBlock(convert12: true)
        let p = try pick(block)
        let first = try XCTUnwrap(sessions(block).first { $0.dayLabel == p.day })
        let it = try XCTUnwrap(item(first, p.x))
        complete(first, item: it, load: 200, reps: 6)
        try ctx.save()
        let now = first.date.addingTimeInterval(86400 * 2)
        func seed(_ plan: Service.NextMesoPlan) -> Double? {
            plan.sessions.first { $0.dayLabel == p.day && $0.weekIndex == 1 }?.items
                .first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: p.x) }?.seed
        }
        let free = try XCTUnwrap(seed(nextPlan(block, ctx, now: now)))
        XCTAssertGreaterThan(free, 150)
        let profile = UserProfile(); profile.setMaxLoad(150, exerciseId: p.x); ctx.insert(profile)
        try ctx.save()
        XCTAssertEqual(try XCTUnwrap(seed(nextPlan(block, ctx, now: now))), 150)
    }
}
