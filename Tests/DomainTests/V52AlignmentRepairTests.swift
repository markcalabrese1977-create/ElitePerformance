import XCTest
import SwiftData
@testable import ElitePerformance

/// V52AlignmentRepair: weeks 4-12 of the converted block, planned and unlogged sessions only.
///
/// Most tests run on a synthetic block that has the SAME roster as the live block (6 days, 10 weeks, the
/// real ids, orders, per-letter ranges and notes, week 10 a deload), converted in memory by the real
/// `DUPMesoLengthConversion.apply`. The fixture tests (TEST_RUNNER_EP_BACKUP_FIXTURE) run the same checks
/// against a real backup and are skipped when it is unset.
final class V52AlignmentRepairTests: XCTestCase {

    typealias R = V52AlignmentRepair

    // MARK: - Isolation

    private var mirrorBefore: Data?
    private var suiteNames: [String] = []
    private var containers: [ModelContainer] = []

    override func setUp() {
        super.setUp()
        mirrorBefore = UserDefaults.standard.data(forKey: R.customMirrorKey)
        UserDefaults.standard.removeObject(forKey: R.customMirrorKey)
    }

    override func tearDown() {
        if let mirrorBefore { UserDefaults.standard.set(mirrorBefore, forKey: R.customMirrorKey) }
        else { UserDefaults.standard.removeObject(forKey: R.customMirrorKey) }
        for n in suiteNames { UserDefaults().removePersistentDomain(forName: n) }
        suiteNames = []
        containers = []
        super.tearDown()
    }

    private func freshDefaults(converted: Bool) -> UserDefaults {
        let name = "v52tests.\(UUID().uuidString)"
        suiteNames.append(name)
        let d = UserDefaults(suiteName: name)!
        if converted { d.set(true, forKey: TwelveWeekMesoConversionMigration.completionKey) }
        return d
    }

    // MARK: - Live-shaped synthetic block

    private struct Slot {
        let order: Int
        let id: String
        let name: String
        let sets: [Int]                 // A, B, C
        let reps: [(Int, Int)]
        let rir: [(Int, Int)]
        let note: String?
        var bodyweight = false
    }

    private static let smithIncline = "custom_a45d8c4e-fc18-45a2-a224-8c89eebad7c8"
    private static let singleLegPress = "custom_07321e80-d695-42a8-97cf-7d3fc7ca9bef"
    private static let seatedSmithCalf = "custom_d02d6de1-f18a-4e99-991c-a0c21c7dc822"
    private static let lowToHigh = "custom_a3e5e40e-8435-4d3f-899a-216b580c3020"
    private static let hipThrust = "custom_7f4ffc44-7aea-449f-87d9-41e76f2f3361"
    private static let saPulldown = "custom_fdd7dfeb-24ba-4795-b00b-0d89e1a52005"
    private static let csRow = "custom_491c982e-3d5e-4753-be54-f6b244faa19b"

    private static let customRows: [(String, String, MuscleGroup, Bool)] = [
        (smithIncline, "Smith Incline Bench Press", .chest, true),
        (singleLegPress, "Single Leg Press", .quads, true),
        (seatedSmithCalf, "Seated Smith Machine Calf Raise", .calves, false),
        (lowToHigh, "Low to High Cable Fly", .chest, false),
        (hipThrust, "Smith Machine Hip Thrust", .glutes, true),
        (saPulldown, "Single Arm Pulldown (Kneeling)", .back, true),
        (csRow, "Chest Supported Barbell Row", .back, true)
    ]

    private static let lateralReps: [(Int, Int)] = [(10, 12), (12, 15), (15, 20)]
    private static let rearReps: [(Int, Int)] = [(10, 12), (12, 15), (15, 20)]
    private static func same(_ lo: Int = 1, _ hi: Int = 1) -> [(Int, Int)] { Array(repeating: (lo, hi), count: 3) }

    private static let roster: [String: [Slot]] = [
        "Push A": [
            Slot(order: 1, id: "bench_press", name: "Bench Press", sets: [4, 3, 3], reps: [(4, 6), (6, 8), (8, 10)], rir: [(1, 2), (2, 2), (2, 2)], note: "Rest 3-4 min heavy."),
            Slot(order: 2, id: smithIncline, name: "Smith Incline Bench Press", sets: [3, 3, 3], reps: [(6, 8), (8, 10), (10, 12)], rir: same(2, 2), note: "Scapular-plane, shortened ROM."),
            Slot(order: 3, id: "incline_rear_delt_fly", name: "Incline Rear Delt Fly", sets: [3, 3, 3], reps: rearReps, rir: same(), note: nil),
            Slot(order: 4, id: "cable_tricep_rope_pushdown", name: "Cable Tricep Rope Pushdown", sets: [3, 3, 3], reps: [(10, 12), (10, 12), (10, 12)], rir: same(3, 3), note: "Rehab track."),
            Slot(order: 5, id: "single_arm_cable_lateral_raise", name: "Single-Arm Cable Lateral Raise", sets: [3, 3, 3], reps: lateralReps, rir: same(), note: nil)
        ],
        "Legs A": [
            Slot(order: 1, id: "hack_squat", name: "Hack Squat", sets: [3, 3, 3], reps: [(8, 10), (10, 12), (12, 15)], rir: same(2, 2), note: "Wide stance, toe-out."),
            Slot(order: 2, id: singleLegPress, name: "Single Leg Press", sets: [2, 2, 2], reps: [(8, 10), (10, 12), (12, 15)], rir: same(2, 2), note: nil),
            Slot(order: 3, id: "leg_extension", name: "Leg Extension", sets: [2, 2, 2], reps: [(10, 12), (12, 15), (15, 20)], rir: same(1, 2), note: "Capped at 2 sets."),
            Slot(order: 4, id: seatedSmithCalf, name: "Seated Smith Machine Calf Raise", sets: [3, 3, 3], reps: [(10, 12), (12, 15), (15, 20)], rir: same(), note: nil),
            Slot(order: 14, id: "lying_leg_curl", name: "Lying Leg Curl", sets: [2, 2, 2], reps: [(8, 10), (10, 12), (12, 15)], rir: same(2, 2), note: nil)
        ],
        "Pull A": [
            Slot(order: 1, id: "t_bar_row", name: "T-Bar Row", sets: [4, 3, 3], reps: [(4, 6), (6, 8), (8, 10)], rir: same(2, 2), note: "Elevated start, belt."),
            Slot(order: 2, id: "pull_up", name: "Pull-Up", sets: [4, 4, 4], reps: [(8, 10), (8, 10), (8, 10)], rir: [(3, 3), (2, 2), (2, 2)], note: "Strict. BW only.", bodyweight: true),
            Slot(order: 3, id: "incline_rear_delt_fly", name: "Incline Rear Delt Fly", sets: [3, 3, 3], reps: rearReps, rir: same(), note: nil),
            Slot(order: 4, id: "hammer_curl", name: "Hammer Curl", sets: [3, 3, 3], reps: [(6, 8), (8, 10), (10, 12)], rir: same(1, 2), note: "Neutral grip."),
            Slot(order: 5, id: "dumbbell_lateral_raise", name: "Dumbbell Lateral Raise", sets: [3, 3, 3], reps: lateralReps, rir: same(), note: nil)
        ],
        "Push B": [
            Slot(order: 1, id: "decline_bench_press", name: "Decline Bench Press", sets: [3, 3, 3], reps: [(4, 6), (6, 8), (8, 10)], rir: [(1, 2), (2, 2), (2, 2)], note: "3 sets during the cut."),
            Slot(order: 2, id: "seated_cable_fly", name: "Seated Cable Fly", sets: [3, 3, 3], reps: [(8, 10), (10, 12), (12, 15)], rir: same(), note: nil),
            Slot(order: 3, id: "dumbbell_lateral_raise", name: "Dumbbell Lateral Raise", sets: [3, 3, 3], reps: lateralReps, rir: same(), note: nil),
            Slot(order: 5, id: lowToHigh, name: "Low to High Cable Fly", sets: [3, 3, 3], reps: [(8, 10), (10, 12), (12, 15)], rir: same(), note: nil),
            Slot(order: 6, id: "cable_tricep_rope_pushdown", name: "Cable Tricep Rope Pushdown", sets: [3, 3, 3], reps: [(10, 12), (10, 12), (10, 12)], rir: same(3, 3), note: "Rehab track.")
        ],
        "Legs B": [
            Slot(order: 1, id: hipThrust, name: "Smith Machine Hip Thrust", sets: [3, 3, 3], reps: [(8, 10), (10, 12), (12, 15)], rir: same(2, 2), note: "Gated: back 0-1/10."),
            Slot(order: 2, id: "romanian_deadlift", name: "Romanian Deadlift", sets: [3, 3, 3], reps: [(8, 10), (10, 12), (10, 12)], rir: same(2, 2), note: "Hard cap 300 lb. Belt on."),
            Slot(order: 3, id: "seated_leg_curl", name: "Seated Leg Curl", sets: [3, 3, 3], reps: [(8, 10), (10, 12), (12, 15)], rir: same(2, 2), note: nil),
            Slot(order: 4, id: seatedSmithCalf, name: "Seated Smith Machine Calf Raise", sets: [3, 3, 3], reps: [(10, 12), (12, 15), (15, 20)], rir: same(), note: nil),
            Slot(order: 5, id: "leg_extension", name: "Leg Extension", sets: [2, 2, 2], reps: [(10, 12), (12, 15), (15, 20)], rir: same(2, 2), note: "Capped at 2 sets.")
        ],
        "Pull B": [
            Slot(order: 1, id: saPulldown, name: "Single Arm Pulldown (Kneeling)", sets: [4, 3, 3], reps: [(4, 6), (6, 8), (8, 10)], rir: same(2, 2), note: "Track left arm independently."),
            Slot(order: 2, id: csRow, name: "Chest Supported Barbell Row", sets: [3, 3, 3], reps: [(6, 8), (8, 10), (10, 12)], rir: same(2, 2), note: "Chest-supported."),
            Slot(order: 3, id: "hammer_curl", name: "Hammer Curl", sets: [3, 3, 3], reps: [(6, 8), (8, 10), (10, 12)], rir: same(1, 2), note: "Neutral grip."),
            Slot(order: 4, id: "dumbbell_lateral_raise", name: "Dumbbell Lateral Raise", sets: [3, 3, 3], reps: lateralReps, rir: same(), note: nil),
            Slot(order: 5, id: "cable_rear_delt_fly", name: "Cable Rear Delt Fly", sets: [3, 3, 3], reps: rearReps, rir: same(), note: nil)
        ]
    ]

    private let days = ["Push A", "Legs A", "Pull A", "Push B", "Legs B", "Pull B"]

    private func cal() -> Calendar { Calendar(identifier: .gregorian) }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        return c
    }

    /// The 10-week block as it is on the device: Fri Sep 25 start, six days Fri...Wed, weeks 1-2 completed
    /// except the Oct 6 / Oct 7 sessions (planned, planEdited), weeks 3-10 planned, week 10 a deload.
    private func makeTenWeekBlock() throws -> (ModelContext, MesoBlock) {
        let ctx = ModelContext(try makeContainer())
        ctx.insert(User(units: .lb, progressionEnabled: true))
        for (id, name, muscle, compound) in Self.customRows {
            ctx.insert(CustomExercise(id: id, name: name, primaryMuscleRaw: muscle.rawValue, isCompound: compound))
        }
        let start = cal().date(from: DateComponents(year: 2026, month: 9, day: 25))!
        let block = MesoBlock(name: "10-Week DUP Meso", startDate: start, status: .active, totalWeeks: 10)
        ctx.insert(block)
        var programIndex = 0
        for week in 1...10 {
            for (d, day) in days.enumerated() {
                programIndex += 1
                let date = cal().date(byAdding: .day, value: (week - 1) * 7 + d, to: start)!
                let letterIdx = (week - 1) % 3
                let deload = week == 10
                var items: [SessionItem] = []
                for slot in Self.roster[day]! {
                    let sets = deload ? 2 : slot.sets[letterIdx]
                    let reps = deload ? (slot.reps[0].0, slot.reps[0].1) : slot.reps[letterIdx]
                    let rir = deload ? (3, 4) : slot.rir[letterIdx]
                    let load: Double = slot.bodyweight ? 0 : 100 + Double(slot.order) * 10 + Double(week)
                    let item = SessionItem(
                        order: slot.order, exerciseId: slot.id, exerciseNameSnapshot: slot.name,
                        targetReps: reps.0, targetSets: sets, targetRIR: rir.1, suggestedLoad: load,
                        waveRaw: deload ? "deload" : ["a", "b", "c"][letterIdx], priorityRaw: "standard",
                        setMin: sets, setMax: sets, repMin: reps.0, repMax: reps.1,
                        targetRIRMin: rir.0, targetRIRMax: rir.1, intensifierRaw: "none",
                        prescriptionNotes: slot.note,
                        plannedRepsBySet: Array(repeating: reps.0, count: sets),
                        plannedLoadsBySet: Array(repeating: load, count: sets),
                        plannedRIRsBySet: Array(repeating: rir.1, count: sets)
                    )
                    items.append(item)
                }
                let completed = week == 1 || (week == 2 && d < 4)
                if completed {
                    for item in items {
                        item.actualReps = Array(repeating: item.targetReps, count: item.targetSets)
                        item.actualLoads = Array(repeating: item.suggestedLoad, count: item.targetSets)
                        item.actualRIRs = Array(repeating: item.targetRIR, count: item.targetSets)
                        item.isCompleted = true
                        item.planEdited = true
                    }
                } else if week == 2 {
                    for item in items { item.planEdited = true }    // Oct 6 / Oct 7: hand-edited, untouched by V52
                }
                let s = Session(date: date, status: completed ? .completed : .planned, sessionNotes: "\(day) · wave",
                                weekIndex: week, dayLabel: day, items: items, programIndex: programIndex)
                s.meso = block
                ctx.insert(s)
            }
        }
        try ctx.save()
        return (ctx, block)
    }

    private func makeConvertedBlock() throws -> (ModelContext, MesoBlock) {
        let (ctx, block) = try makeTenWeekBlock()
        _ = try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        try ctx.save()
        XCTAssertEqual(block.totalWeeks, 12)
        return (ctx, block)
    }

    // MARK: - Helpers

    private func allSessions(_ ctx: ModelContext) throws -> [Session] {
        try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
    }

    private func session(_ ctx: ModelContext, week: Int, day: String) throws -> Session {
        try XCTUnwrap(try allSessions(ctx).first { $0.weekIndex == week && $0.dayLabel == day }, "no \(day) wk\(week)")
    }

    private func item(_ s: Session, order: Int) throws -> SessionItem {
        try XCTUnwrap(s.items.first { $0.order == order }, "no item at order \(order) in \(s.dayLabel ?? "?") wk\(s.weekIndex)")
    }

    private func customRowCount(_ ctx: ModelContext) throws -> Int { try ctx.fetch(FetchDescriptor<CustomExercise>()).count }

    private func customId(_ ctx: ModelContext, _ name: String) throws -> String {
        try XCTUnwrap(try ctx.fetch(FetchDescriptor<CustomExercise>()).first { $0.name == name }, "no custom '\(name)'").id
    }

    /// Every field of every session and item (sessions, items, block) — "the store" for unchanged checks.
    private func storeFingerprint(_ ctx: ModelContext) throws -> String {
        var out: [String] = []
        for b in try ctx.fetch(FetchDescriptor<MesoBlock>()) {
            out.append("B|\(b.name)|\(b.status.rawValue)|\(b.totalWeeks.map(String.init) ?? "nil")")
        }
        for s in try allSessions(ctx) {
            out.append("S|\(s.id?.uuidString ?? "")|\(s.weekIndex)|\(s.dayLabel ?? "")|\(s.status.rawValue)|\(s.items.count)")
            for i in s.items.sorted(by: { $0.order < $1.order }) { out.append("I|" + R.fingerprint(i)) }
        }
        return out.joined(separator: "\n")
    }

    private func itemFingerprints(_ ctx: ModelContext) throws -> [String: String] {
        var out: [String: String] = [:]
        for s in try allSessions(ctx) { for i in s.items { out[i.id!.uuidString] = R.fingerprint(i) } }
        return out
    }

    private let listedDayIds: [String: Set<String>] = [
        "Push A": ["single_arm_cable_lateral_raise"],
        "Legs A": [V52AlignmentRepairTests.singleLegPress, "hack_squat"],
        "Pull A": ["incline_rear_delt_fly", "dumbbell_lateral_raise"],
        "Push B": ["dumbbell_lateral_raise"],
        "Legs B": [V52AlignmentRepairTests.seatedSmithCalf, V52AlignmentRepairTests.hipThrust, "romanian_deadlift"],
        "Pull B": ["cable_rear_delt_fly"]
    ]

    private func applyLive(_ ctx: ModelContext, _ block: MesoBlock, defaults: UserDefaults, hooks: R.ApplyHooks = .init()) throws -> R.Report {
        try R.ensureCustomExercises(in: ctx)
        return try R.apply(block: block, context: ctx, defaults: defaults, hooks: hooks)
    }

    // MARK: - Shipping state

    func test_shipsAsADryRun() {
        XCTAssertTrue(R.dryRun)
        XCTAssertEqual(R.completionKey, "v52AlignmentRepair.v1.completed")
        XCTAssertEqual(R.dryRunLoggedKey, "v52AlignmentRepair.v1.dryRunLogged.\(R.reportVersion)")
    }

    func test_waves_areA_4_7_10_B_5_8_11_C_6_9_12() {
        for (w, expected) in [(4, WaveType.a), (7, .a), (10, .a), (5, .b), (8, .b), (11, .b), (6, .c), (9, .c), (12, .c)] {
            XCTAssertEqual(R.wave(forWeek: w), expected, "week \(w)")
        }
    }

    func test_specTable_hasTheStatedShape() {
        XCTAssertEqual(R.ops.count, 12)
        XCTAssertEqual(R.customSpecs.count, 6)
        let slots = Dictionary(grouping: R.ops, by: { $0.key.prefix(1) })
        XCTAssertEqual(slots["R"]?.count, 7)
        XCTAssertEqual(slots["H"]?.count, 3)
        XCTAssertEqual(slots["A"]?.count, 2)
    }

    // MARK: - Dry run

    func test_converted_dryRun_changesNothing_andReportsTheExpectedCounts() throws {
        let (ctx, block) = try makeConvertedBlock()
        let before = try storeFingerprint(ctx)
        let rows = try customRowCount(ctx)

        let report = R.dryRun(block: block, context: ctx, defaults: freshDefaults(converted: true))

        XCTAssertTrue(report.isSafe, report.blockers.joined(separator: "\n"))
        XCTAssertNil(report.liveBlocker)
        XCTAssertEqual(report.replaced, 63)
        XCTAssertEqual(report.reranged, 27)
        XCTAssertEqual(report.created, 18)
        XCTAssertEqual(report.customsToCreate.count, 6)
        XCTAssertTrue(report.text.contains("would create"))
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertEqual(try customRowCount(ctx), rows, "a dry run creates no custom exercise")
        XCTAssertFalse(ctx.hasChanges)
    }

    func test_runIfNeeded_dryRun_logsOnce_writesNothing_setsOnlyTheLoggedFlag() throws {
        let (ctx, _) = try makeConvertedBlock()
        let before = try storeFingerprint(ctx)
        let d = freshDefaults(converted: true)

        R.runIfNeeded(in: ctx, dryRun: true, defaults: d)

        XCTAssertTrue(d.bool(forKey: R.dryRunLoggedKey))
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        let report = try XCTUnwrap(d.string(forKey: R.reportKey))
        XCTAssertTrue(report.contains("== GATES ==") && report.contains("== PROJECTED CHAINS =="))
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertEqual(try customRowCount(ctx), Self.customRows.count)
        XCTAssertFalse(ctx.hasChanges)

        d.set("SENTINEL", forKey: R.reportKey)
        R.runIfNeeded(in: ctx, dryRun: true, defaults: d)
        XCTAssertEqual(d.string(forKey: R.reportKey), "SENTINEL", "already logged: no second report")
    }

    func test_tenWeekShape_dryRunOnly_reportsWeeks4to9_andIsBlockedLive() throws {
        let (ctx, block) = try makeTenWeekBlock()
        let before = try storeFingerprint(ctx)
        let d = freshDefaults(converted: false)

        let report = R.dryRun(block: block, context: ctx, defaults: d)
        XCTAssertTrue(report.isSafe, report.blockers.joined(separator: "\n"))
        XCTAssertFalse(report.converted)
        XCTAssertEqual(report.scopeWeeks, 4...9)
        XCTAssertNotNil(report.liveBlocker)
        XCTAssertEqual(report.replaced, 42)      // 7 slots x weeks 4-9
        XCTAssertEqual(report.reranged, 18)
        XCTAssertEqual(report.created, 12)
        XCTAssertTrue(report.shape.contains("NOT converted"))

        // Live is blocked: nothing written, no custom exercise, flag unset.
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertEqual(try customRowCount(ctx), Self.customRows.count)
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        XCTAssertFalse(ctx.hasChanges)
    }

    // MARK: - Blocked before conversion

    func test_liveApply_isBlocked_whenTheConversionFlagIsUnset_evenOnAConvertedShape() throws {
        let (ctx, block) = try makeConvertedBlock()
        let before = try storeFingerprint(ctx)
        let d = freshDefaults(converted: false)

        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        let report = R.dryRun(block: block, context: ctx, defaults: d)

        XCTAssertNotNil(report.liveBlocker)
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertEqual(try customRowCount(ctx), Self.customRows.count, "blocked: no custom exercise is created either")
        XCTAssertFalse(d.bool(forKey: R.completionKey))

        // The API refuses too: apply() returns the blocked report and writes nothing.
        let applied = try R.apply(block: block, context: ctx, defaults: d)
        XCTAssertFalse(applied.didWrite)
        XCTAssertEqual(try storeFingerprint(ctx), before)
    }

    // MARK: - Live apply

    func test_liveApply_writesTheSpec_verifiesChains_leavesEverythingElseByteIdentical_andIsIdempotent() throws {
        let (ctx, block) = try makeConvertedBlock()
        let d = freshDefaults(converted: true)
        let before = try itemFingerprints(ctx)
        var oldExerciseOf: [String: String] = [:]
        for s in try allSessions(ctx) { for i in s.items { oldExerciseOf[i.id!.uuidString] = i.exerciseId } }
        let seedsBefore: [String: (Double, [Double])] = Dictionary(uniqueKeysWithValues:
            try allSessions(ctx).flatMap { $0.items }.map { ($0.id!.uuidString, ($0.suggestedLoad, $0.plannedLoadsBySet)) })

        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)

        XCTAssertTrue(d.bool(forKey: R.completionKey), "completion is set after the verified save")
        XCTAssertEqual(try customRowCount(ctx), Self.customRows.count + 6, "6 custom rows created; A2, R4, R6 reuse built-ins")
        XCTAssertFalse(ctx.hasChanges)
        let after = try itemFingerprints(ctx)

        // Counts.
        var changedIDs = Set<String>()
        for (id, fp) in before where after[id] != fp { changedIDs.insert(id) }
        XCTAssertEqual(changedIDs.count, 63 + 27, "replaced + re-ranged items changed")
        XCTAssertEqual(after.count - before.count, 18, "18 items created")

        // Unlisted items are byte-identical; weeks 1-3 are untouched. "Listed" comes from the spec, not from the result.
        for s in try allSessions(ctx) {
            for i in s.items {
                let id = i.id!.uuidString
                guard let oldExercise = oldExerciseOf[id] else { continue }     // created by V52
                let listed = s.weekIndex >= 4 && listedDayIds[s.dayLabel ?? ""]?.contains(oldExercise) == true
                if listed { XCTAssertTrue(changedIDs.contains(id), "listed item did not change: wk\(s.weekIndex) \(s.dayLabel ?? "?") \(oldExercise)") }
                else { XCTAssertEqual(before[id], after[id], "unlisted item changed: wk\(s.weekIndex) \(s.dayLabel ?? "?") \(oldExercise)") }
            }
        }

        // Spot checks, every wave.
        for (week, letter) in [(4, "a"), (5, "b"), (6, "c"), (10, "a"), (11, "b"), (12, "c")] {
            // R1
            let pushA = try session(ctx, week: week, day: "Push A")
            let r1 = try item(pushA, order: 5)
            XCTAssertEqual(r1.exerciseId, try customId(ctx, "Single-Arm Cable Extension (Long Head)"))
            XCTAssertEqual(r1.exerciseNameSnapshot, "Single-Arm Cable Extension (Long Head)")
            XCTAssertEqual(r1.waveRaw, letter)
            XCTAssertEqual(r1.targetSets, 2)
            XCTAssertEqual(r1.suggestedLoad, 0)
            XCTAssertEqual(r1.plannedLoadsBySet, [0, 0])
            XCTAssertFalse(r1.planEdited)
            XCTAssertTrue(r1.prescriptionNotes?.hasPrefix("Last. Neutral grip") == true)
            let expectedReps = [("a", 10, 12), ("b", 12, 15), ("c", 15, 20)].first { $0.0 == letter }!
            XCTAssertEqual(r1.repMin, expectedReps.1); XCTAssertEqual(r1.repMax, expectedReps.2)
            XCTAssertEqual(r1.targetRIRMin, 1); XCTAssertEqual(r1.targetRIRMax, 2)
            XCTAssertEqual(r1.targetReps, expectedReps.1); XCTAssertEqual(r1.targetRIR, 2)

            // R4 / R6 reuse built-ins; names come from the catalog.
            XCTAssertEqual(try item(try session(ctx, week: week, day: "Pull A"), order: 5).exerciseId, "single_arm_cable_lateral_raise")
            XCTAssertEqual(try item(try session(ctx, week: week, day: "Legs B"), order: 4).exerciseId, "smith_machine_calves")

            // Adds: max order + 1, load 0, session wave.
            let legsA = try session(ctx, week: week, day: "Legs A")
            let a1 = try item(legsA, order: 15)
            XCTAssertEqual(a1.exerciseNameSnapshot, "Cable Hip Adduction")
            XCTAssertEqual(a1.waveRaw, letter)
            XCTAssertEqual(a1.suggestedLoad, 0)
            let a2 = try item(try session(ctx, week: week, day: "Legs B"), order: 6)
            XCTAssertEqual(a2.exerciseId, "pallof_press")
            XCTAssertEqual(a2.waveRaw, letter)
        }

        // Re-ranged: H1 hack squat, wave A 4x5-8 @1-2, seed (load and per-set loads) repeated.
        let hack4 = try item(try session(ctx, week: 4, day: "Legs A"), order: 1)
        XCTAssertEqual(hack4.exerciseId, "hack_squat")
        XCTAssertEqual(hack4.targetSets, 4); XCTAssertEqual(hack4.repMin, 5); XCTAssertEqual(hack4.repMax, 8)
        XCTAssertEqual(hack4.targetRIRMin, 1); XCTAssertEqual(hack4.targetRIRMax, 2)
        XCTAssertEqual(hack4.plannedLoadsBySet.count, 4)
        XCTAssertEqual(Set(hack4.plannedLoadsBySet), [seedsBefore[hack4.id!.uuidString]!.0])
        XCTAssertEqual(hack4.suggestedLoad, seedsBefore[hack4.id!.uuidString]!.0)
        XCTAssertTrue(hack4.prescriptionNotes?.hasPrefix("Wide stance, toe-out. Ranges moved") == true)
        // H3 RDL: the old "Hard cap 300 lb" text is gone.
        for w in 4...12 {
            let rdl = try item(try session(ctx, week: w, day: "Legs B"), order: 2)
            XCTAssertFalse(rdl.prescriptionNotes?.contains("Hard cap") == true)
            XCTAssertTrue(rdl.prescriptionNotes?.hasPrefix("No load cap.") == true)
            XCTAssertEqual(rdl.suggestedLoad, seedsBefore[rdl.id!.uuidString]!.0, "seed unchanged, wk\(w)")
            let hip = try item(try session(ctx, week: w, day: "Legs B"), order: 1)
            XCTAssertEqual(hip.suggestedLoad, seedsBefore[hip.id!.uuidString]!.0)
        }

        // Idempotent: a second run (flag cleared on purpose) plans nothing and changes nothing.
        let afterStore = try storeFingerprint(ctx)
        let rows = try customRowCount(ctx)
        let again = R.dryRun(block: block, context: ctx, defaults: d)
        XCTAssertTrue(again.alreadyAligned)
        XCTAssertEqual(again.replaced + again.reranged + again.created, 0)
        d.removeObject(forKey: R.completionKey)
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertEqual(try storeFingerprint(ctx), afterStore)
        XCTAssertEqual(try customRowCount(ctx), rows, "ensureCustomExercises creates nothing the second time")
        XCTAssertTrue(d.bool(forKey: R.completionKey), "nothing left to change: marked complete")
    }

    func test_liveApply_reportsEveryVerification_andAllChainsHold() throws {
        let (ctx, block) = try makeConvertedBlock()
        let report = try applyLive(ctx, block, defaults: freshDefaults(converted: true))

        XCTAssertTrue(report.didWrite)
        XCTAssertEqual(report.replaced, 63); XCTAssertEqual(report.reranged, 27); XCTAssertEqual(report.created, 18)
        XCTAssertFalse(report.verification.isEmpty)
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("[PASS]") }, report.verification.joined(separator: "\n"))
        XCTAssertEqual(report.postWriteChainTable.count, 9, "R1-R7, A1, A2 in their day (R4 Pull A, R6 Legs B ...) : \(report.postWriteChainTable)")
        // Independent re-check with the conversion's own invariants for the retained lifts.
        let sessions = try allSessions(ctx).filter { $0.meso === block }
        let bench4 = try XCTUnwrap(sessions.first { $0.weekIndex == 4 && $0.dayLabel == "Push A" }?.items.first { $0.exerciseId == "bench_press" })
        let bench4Session = try session(ctx, week: 4, day: "Push A")
        let t = try XCTUnwrap(PlanMemoryEngine.nextTargetItem(for: bench4, after: bench4Session, in: sessions))
        XCTAssertEqual(t.exerciseId, "bench_press")
        XCTAssertEqual(sessions.first { $0.items.contains { $0 === t } }?.weekIndex, 7)
        // New chains: 4 -> 7 -> 10.
        let r1 = try item(bench4Session, order: 5)
        let r1t = try XCTUnwrap(PlanMemoryEngine.nextTargetItem(for: r1, after: bench4Session, in: sessions))
        XCTAssertEqual(sessions.first { $0.items.contains { $0 === r1t } }?.weekIndex, 7)
        let w10 = try session(ctx, week: 10, day: "Push A")
        XCTAssertNil(PlanMemoryEngine.nextTargetItem(for: try item(w10, order: 5), after: w10, in: sessions))
    }

    func test_replacedItem_clearsCoachNoteActualsAndNextSuggestedLoad_andLeavesPlanEditedFalse() throws {
        let (ctx, block) = try makeConvertedBlock()
        let target = try item(try session(ctx, week: 5, day: "Legs A"), order: 2)    // R2
        target.coachNote = "stale"; target.nextSuggestedLoad = 123; target.loadOverrideReasonRaw = "something"
        try ctx.save()

        _ = try applyLive(ctx, block, defaults: freshDefaults(converted: true))

        XCTAssertNil(target.coachNote); XCTAssertNil(target.nextSuggestedLoad); XCTAssertNil(target.loadOverrideReasonRaw)
        XCTAssertEqual(target.exerciseNameSnapshot, "Smith Split Squat")
        XCTAssertEqual(target.targetSets, 2)
        XCTAssertFalse(target.planEdited)
        XCTAssertEqual(target.order, 2)
    }

    func test_ensureCustomExercises_isIdempotent_andCreatesOnlyTheMissingOnes() throws {
        let (ctx, _) = try makeConvertedBlock()
        let first = try R.ensureCustomExercises(in: ctx)
        XCTAssertEqual(first.created.count, 6)
        XCTAssertEqual(try customRowCount(ctx), Self.customRows.count + 6)
        let second = try R.ensureCustomExercises(in: ctx)
        XCTAssertEqual(second.created.count, 0)
        XCTAssertEqual(second.reused.count, 6)
        XCTAssertEqual(try customRowCount(ctx), Self.customRows.count + 6)
        // Properties the spec fixes.
        let rows = try ctx.fetch(FetchDescriptor<CustomExercise>())
        func row(_ n: String) throws -> CustomExercise { try XCTUnwrap(rows.first { $0.name == n }) }
        XCTAssertEqual(try row("Single-Arm Cable Extension (Long Head)").primaryMuscleRaw, "triceps")
        XCTAssertFalse(try row("Single-Arm Cable Extension (Long Head)").isCompound)
        XCTAssertEqual(try row("Smith Split Squat").primaryMuscleRaw, "quads")
        XCTAssertTrue(try row("Smith Split Squat").isCompound)
        XCTAssertEqual(try row("Prone Y-Raise").primaryMuscleRaw, "shoulders")
        XCTAssertEqual(try row("Incline Hammer Curl").primaryMuscleRaw, "biceps")
        XCTAssertEqual(try row("Straight-Arm Cable Pulldown").primaryMuscleRaw, "back")
        XCTAssertEqual(try row("Cable Hip Adduction").primaryMuscleRaw, "glutes")
        XCTAssertTrue(rows.allSatisfy { !$0.isBodyweight })
        // ...and they land in the UserDefaults mirror so context-free name lookups resolve.
        XCTAssertEqual(ExerciseCatalog.displayName(for: try row("Prone Y-Raise").id), "Prone Y-Raise")
    }

    // MARK: - Fresh contexts: a refused conversion, then V52

    /// The conversion and V52 each run on their own fresh ModelContext (App/ElitePerformanceApp.swift). When the
    /// conversion refuses (verification failure, rolled back), V52 on its own context reports
    /// "blocked: not converted", writes nothing, creates nothing and leaves no pending changes behind.
    func test_conversionRefuses_thenV52OnItsOwnContext_reportsBlockedNotConverted_withoutLeftovers() throws {
        let key = TwelveWeekMesoConversionMigration.completionKey
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: TwelveWeekMesoConversionMigration.dryRunLoggedKey) }
        let (setup, _) = try makeTenWeekBlock()
        let container = try XCTUnwrap(containers.last)
        _ = setup
        let before = try storeFingerprint(ModelContext(container))
        let sessionsBefore = try allSessions(ModelContext(container)).count

        // 1. The conversion, on its own context, forced to refuse: a week-10 lift disappears before verification.
        let conversionCtx = ModelContext(container)
        let refuse = DUPMesoLengthConversion.ApplyHooks(beforeVerify: { c in
            let w10 = ((try? c.fetch(FetchDescriptor<Session>())) ?? []).first { $0.weekIndex == 10 }!
            let victim = w10.items.sorted { $0.order < $1.order }[0]
            w10.items.removeAll { $0 === victim }
            c.delete(victim)
        })
        TwelveWeekMesoConversionMigration.runIfNeeded(in: conversionCtx, dryRun: false, hooks: refuse)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key), "refused: the completion flag stays unset")
        XCTAssertFalse(conversionCtx.hasChanges, "the refused context holds nothing pending")
        XCTAssertNoThrow(try conversionCtx.save(), "and saving it does not throw")
        XCTAssertEqual(try storeFingerprint(ModelContext(container)), before, "the store is exactly as before")

        // 2. V52 on a FRESH context: blocked, no error, nothing written, nothing left over.
        let v52Ctx = ModelContext(container)
        let d = freshDefaults(converted: false)          // the conversion never completed
        let customsBefore = try customRowCount(ModelContext(container))
        R.runIfNeeded(in: v52Ctx, dryRun: false, defaults: d)
        XCTAssertFalse(v52Ctx.hasChanges, "no leftover objects in V52's context")
        XCTAssertNoThrow(try v52Ctx.save())
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        XCTAssertEqual(try customRowCount(ModelContext(container)), customsBefore, "no custom exercise created")
        XCTAssertEqual(try allSessions(ModelContext(container)).count, sessionsBefore, "no session created or removed")
        XCTAssertEqual(try storeFingerprint(ModelContext(container)), before, "the store is still exactly as before")

        let block = try XCTUnwrap(try v52Ctx.fetch(FetchDescriptor<MesoBlock>()).first { $0.status == .active })
        let report = R.dryRun(block: block, context: v52Ctx, defaults: d)
        XCTAssertNotNil(report.liveBlocker)
        XCTAssertTrue(report.text.contains("blocked: not converted"), report.text)
        XCTAssertFalse(v52Ctx.hasChanges)
    }

    // MARK: - Failure injection

    private struct InjectedSaveFailure: Error {}

    func test_forcedChainBreak_rollsBack_storeUnchanged_flagUnset() throws {
        let (ctx, block) = try makeConvertedBlock()
        try R.ensureCustomExercises(in: ctx)
        try ctx.save()
        let before = try storeFingerprint(ctx)
        let d = freshDefaults(converted: true)
        let priorAutosave = ctx.autosaveEnabled

        // Delete a retained lift's week-7 occurrence: its week-4 item loses its +3 target.
        let hooks = R.ApplyHooks(beforeVerify: { c in
            let all = (try? c.fetch(FetchDescriptor<Session>())) ?? []
            let w7 = all.first { $0.weekIndex == 7 && $0.dayLabel == "Push A" }!
            let victim = w7.items.first { $0.exerciseId == "bench_press" }!
            w7.items.removeAll { $0 === victim }
            c.delete(victim)
        })
        XCTAssertThrowsError(try R.apply(block: block, context: ctx, defaults: d, hooks: hooks)) { err in
            guard case R.ApplyError.verificationFailed(let failures) = err else { return XCTFail("\(err)") }
            XCTAssertTrue(failures.contains { $0.contains("chain") }, "\(failures)")
        }
        XCTAssertEqual(try storeFingerprint(ctx), before, "store must be exactly as before")
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(ctx.autosaveEnabled, priorAutosave)

        // A normal run afterwards still succeeds (nothing was left half-applied).
        let ok = try R.apply(block: block, context: ctx, defaults: d)
        XCTAssertTrue(ok.didWrite)
    }

    func test_forcedSaveFailure_rollsBack_storeUnchanged_flagUnset() throws {
        let (ctx, block) = try makeConvertedBlock()
        try R.ensureCustomExercises(in: ctx)
        try ctx.save()
        let before = try storeFingerprint(ctx)
        let d = freshDefaults(converted: true)

        let hooks = R.ApplyHooks(save: { _ in throw InjectedSaveFailure() })
        XCTAssertThrowsError(try R.apply(block: block, context: ctx, defaults: d, hooks: hooks)) { err in
            guard case R.ApplyError.saveFailed = err else { return XCTFail("\(err)") }
        }
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        XCTAssertFalse(ctx.hasChanges)

        // Through the driver: a failed save leaves the completion flag unset so it retries.
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d, hooks: hooks)
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        XCTAssertEqual(try storeFingerprint(ctx), before)
    }

    func test_pendingChanges_areRefused() throws {
        let (ctx, block) = try makeConvertedBlock()
        try R.ensureCustomExercises(in: ctx)
        try ctx.save()
        try item(try session(ctx, week: 8, day: "Push A"), order: 1).coachNote = "unsaved edit"
        XCTAssertTrue(ctx.hasChanges)
        XCTAssertThrowsError(try R.apply(block: block, context: ctx, defaults: freshDefaults(converted: true))) { err in
            guard case R.ApplyError.pendingChanges = err else { return XCTFail("\(err)") }
        }
        XCTAssertEqual(try item(try session(ctx, week: 8, day: "Push A"), order: 1).coachNote, "unsaved edit", "someone else's edit is never discarded")
    }

    // MARK: - Scope

    func test_aLoggedWeek4Session_isSkippedAndReported_otherSlotsStillApply() throws {
        let (ctx, block) = try makeConvertedBlock()
        let w4 = try session(ctx, week: 4, day: "Push A")
        let bench = try item(w4, order: 1)
        bench.actualReps = [5, 5, 5, 5]; bench.actualLoads = [315, 315, 315, 315]; bench.isCompleted = true
        w4.status = .completed
        try ctx.save()
        func fps(_ s: Session) -> [String] { s.items.sorted { $0.order < $1.order }.map { R.fingerprint($0) } }
        let w4Before = fps(w4)
        let d = freshDefaults(converted: true)

        let plan = R.dryRun(block: block, context: ctx, defaults: d)
        XCTAssertTrue(plan.skipped.contains { $0.contains("wk4 Push A") && $0.contains("R1") }, "\(plan.skipped)")
        XCTAssertEqual(plan.replaced, 62)

        let report = try applyLive(ctx, block, defaults: d)
        XCTAssertTrue(report.didWrite)
        XCTAssertEqual(report.replaced, 62)
        XCTAssertEqual(report.reranged, 27)
        XCTAssertEqual(report.created, 18)
        XCTAssertEqual(fps(w4), w4Before, "the logged session is untouched")
        XCTAssertEqual(try item(w4, order: 5).exerciseId, "single_arm_cable_lateral_raise", "R1 not applied in week 4")
        XCTAssertNotEqual(try item(try session(ctx, week: 7, day: "Push A"), order: 5).exerciseId, "single_arm_cable_lateral_raise")
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("[PASS]") }, report.verification.joined(separator: "\n"))
    }

    func test_planEditedTargets_areSkippedAndListed_retainedPlanEditedIsOnlyReported() throws {
        let (ctx, block) = try makeConvertedBlock()
        let hack = try item(try session(ctx, week: 6, day: "Legs A"), order: 1)             // H1 target
        let proneTarget = try item(try session(ctx, week: 6, day: "Pull A"), order: 3)      // R3 target
        let retained = try item(try session(ctx, week: 6, day: "Push A"), order: 1)         // bench: retained
        hack.planEdited = true; proneTarget.planEdited = true; retained.planEdited = true
        try ctx.save()
        let hackBefore = R.fingerprint(hack), proneBefore = R.fingerprint(proneTarget), retainedBefore = R.fingerprint(retained)

        let report = try applyLive(ctx, block, defaults: freshDefaults(converted: true))

        XCTAssertTrue(report.didWrite)
        XCTAssertEqual(report.replaced, 62)
        XCTAssertEqual(report.reranged, 26)
        XCTAssertEqual(report.planEditedTouched, 2)
        XCTAssertGreaterThanOrEqual(report.planEditedRetained, 1)
        XCTAssertTrue(report.skipped.contains { $0.contains("H1") && $0.contains("planEdited") })
        XCTAssertTrue(report.skipped.contains { $0.contains("R3") && $0.contains("planEdited") })
        XCTAssertEqual(R.fingerprint(hack), hackBefore)
        XCTAssertEqual(R.fingerprint(proneTarget), proneBefore)
        XCTAssertEqual(R.fingerprint(retained), retainedBefore)
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("[PASS]") }, report.verification.joined(separator: "\n"))
    }

    func test_weeks1to3_andTheOct6And7Sessions_areNeverTouched() throws {
        let (ctx, block) = try makeConvertedBlock()
        let sessions = try allSessions(ctx).filter { $0.weekIndex <= 3 }
        let before = sessions.flatMap { s in s.items.map { R.fingerprint($0) } }
        let counts = sessions.map { $0.items.count }

        _ = try applyLive(ctx, block, defaults: freshDefaults(converted: true))

        XCTAssertEqual(sessions.flatMap { s in s.items.map { R.fingerprint($0) } }, before)
        XCTAssertEqual(sessions.map { $0.items.count }, counts)
        let oct6 = try session(ctx, week: 2, day: "Legs B")
        XCTAssertEqual(oct6.status, .planned)
        XCTAssertTrue(oct6.items.allSatisfy { $0.planEdited })
    }

    func test_aWaveMismatch_isABlocker_andNothingIsWritten() throws {
        let (ctx, block) = try makeConvertedBlock()
        let victim = try item(try session(ctx, week: 8, day: "Pull B"), order: 1)
        victim.waveRaw = "a"                                  // week 8 must be B
        try ctx.save()
        let before = try storeFingerprint(ctx)
        let d = freshDefaults(converted: true)

        let report = R.dryRun(block: block, context: ctx, defaults: d)
        XCTAssertFalse(report.isSafe)
        XCTAssertTrue(report.blockers.contains { $0.contains("Pull B wk8") })

        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertEqual(try customRowCount(ctx), Self.customRows.count, "refused before any custom exercise is created")
        XCTAssertFalse(d.bool(forKey: R.completionKey))
    }

    // MARK: - Backup fixture (local only)

    private func importFixture() throws -> (ModelContext, MesoBlock, URL) {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let url = URL(fileURLWithPath: path)
        print("V52 FIXTURE|\(url.lastPathComponent)")
        let c = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: c)
        let ctx = ModelContext(c)
        ctx.autosaveEnabled = false
        let active = try ctx.fetch(FetchDescriptor<MesoBlock>()).filter { $0.status == .active && !$0.isMaintenance }
        return (ctx, try XCTUnwrap(active.first, "no active regular block"), url)
    }

    func test_fixture_tenWeekShape_dryRunOnly_writesNothing() throws {
        let (ctx, block, url) = try importFixture()
        let fileBefore = try Data(contentsOf: url)
        let before = try storeFingerprint(ctx)
        let report = R.dryRun(block: block, context: ctx, defaults: freshDefaults(converted: false))
        print("V52 FIXTURE 10-WEEK DRY RUN|\n\(report.text)")
        XCTAssertTrue(report.isSafe, report.blockers.joined(separator: "\n"))
        XCTAssertFalse(report.converted)
        XCTAssertEqual(report.scopeWeeks, 4...9)
        XCTAssertEqual(report.replaced, 42); XCTAssertEqual(report.reranged, 18); XCTAssertEqual(report.created, 12)
        XCTAssertEqual(report.customsToCreate.count, 6)
        XCTAssertNotNil(report.liveBlocker)
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(try Data(contentsOf: url), fileBefore)
    }

    /// The raw backup's Oct 7 Pull B session is a planned, hand-swapped [Hotel] roster that has no week-5
    /// counterpart, so the conversion's strict `verifyChains` refuses it. Reported, not asserted. To keep testing V52
    /// on the real data, the roster is put back for the conversion and then swapped to the hotel lifts again.
    private func convertFixture(_ ctx: ModelContext, _ block: MesoBlock, url: URL) throws {
        // Probe on a throwaway import: a refused conversion leaves rolled-back Session objects behind in its
        // context, so the real context must never be the one that was refused.
        let probeContainer = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: probeContainer)
        let probe = ModelContext(probeContainer)
        probe.autosaveEnabled = false
        if let pb = try probe.fetch(FetchDescriptor<MesoBlock>()).first(where: { $0.status == .active && !$0.isMaintenance }) {
            do { _ = try DUPMesoLengthConversion.apply(block: pb, context: probe) }
            catch { print("V52 FIXTURE NOTE|the 12-week conversion refuses this backup as it is: \(error)") }
        }

        let all = try allSessions(ctx).filter { $0.meso === block }
        let hotel = try XCTUnwrap(all.first { $0.weekIndex == 2 && $0.dayLabel == "Pull B" })
        let w5 = try XCTUnwrap(all.first { $0.weekIndex == 5 && $0.dayLabel == "Pull B" })
        let saved = hotel.items.map { ($0, $0.exerciseId) }
        for i in hotel.items { if let match = w5.items.first(where: { $0.order == i.order }) { i.exerciseId = match.exerciseId } }
        try ctx.save()
        _ = try DUPMesoLengthConversion.apply(block: block, context: ctx)
        for (i, id) in saved { i.exerciseId = id }
        try ctx.save()
    }

    func test_fixture_converted_dryRunChangesNothing_thenLiveApplyMatchesTheCounts() throws {
        let (ctx, block, url) = try importFixture()
        let fileBefore = try Data(contentsOf: url)
        try convertFixture(ctx, block, url: url)
        XCTAssertEqual(block.totalWeeks, 12)
        let d = freshDefaults(converted: true)

        // Dry run changes nothing.
        let before = try storeFingerprint(ctx)
        let dry = R.dryRun(block: block, context: ctx, defaults: d)
        print("V52 FIXTURE CONVERTED DRY RUN|\n\(dry.text)")
        XCTAssertTrue(dry.isSafe, dry.blockers.joined(separator: "\n"))
        XCTAssertEqual(dry.replaced, 63); XCTAssertEqual(dry.reranged, 27); XCTAssertEqual(dry.created, 18)
        XCTAssertEqual(dry.customsToCreate.count, 6)
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertFalse(ctx.hasChanges)

        // Live.
        let itemsBefore = try itemFingerprints(ctx)
        let seeds: [String: (Double, [Double], String)] = Dictionary(uniqueKeysWithValues:
            try allSessions(ctx).flatMap { s in s.items.map { ($0.id!.uuidString, ($0.suggestedLoad, $0.plannedLoadsBySet, $0.exerciseId)) } })
        let rowsBefore = try customRowCount(ctx)
        let report = try applyLive(ctx, block, defaults: d)
        print("V52 FIXTURE LIVE|\n" + report.verification.joined(separator: "\n") + "\n" + report.postWriteChainTable.joined(separator: "\n"))
        XCTAssertTrue(report.didWrite)
        XCTAssertEqual(report.replaced, 63); XCTAssertEqual(report.reranged, 27); XCTAssertEqual(report.created, 18)
        XCTAssertEqual(try customRowCount(ctx) - rowsBefore, 6)
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("[PASS]") }, report.verification.joined(separator: "\n"))

        let itemsAfter = try itemFingerprints(ctx)
        let changed = Set(itemsBefore.filter { itemsAfter[$0.key] != $0.value }.keys)
        XCTAssertEqual(changed.count, 90)
        XCTAssertEqual(itemsAfter.count - itemsBefore.count, 18)
        // Hack squat / hip thrust / RDL seeds unchanged in every week.
        for s in try allSessions(ctx) where s.weekIndex >= 4 && s.meso === block {
            for i in s.items where ["hack_squat", Self.hipThrust, "romanian_deadlift"].contains(i.exerciseId) {
                let old = try XCTUnwrap(seeds[i.id!.uuidString])
                XCTAssertEqual(i.suggestedLoad, old.0, "wk\(s.weekIndex) \(i.exerciseId)")
                XCTAssertEqual(i.plannedLoadsBySet, R.resized(old.1, to: i.targetSets, fill: old.0))
            }
        }
        // Weeks 1-3 byte-identical.
        for s in try allSessions(ctx) where s.weekIndex <= 3 { for i in s.items { XCTAssertEqual(itemsBefore[i.id!.uuidString], itemsAfter[i.id!.uuidString]) } }

        // Idempotent.
        let stored = try storeFingerprint(ctx)
        XCTAssertTrue(R.dryRun(block: block, context: ctx, defaults: d).alreadyAligned)
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertEqual(try storeFingerprint(ctx), stored)
        XCTAssertEqual(try Data(contentsOf: url), fileBefore, "the backup file is never modified")
    }
}
