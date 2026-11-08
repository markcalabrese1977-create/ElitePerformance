import XCTest
import SwiftData
@testable import ElitePerformance

/// K3: every display goes through LoadFormatter(unit), every input through LoadInput. lb strings are asserted to be
/// exactly what they were before kg; kg strings are the same values in kg. Stored loads are always lb.
final class UnitDisplayInputTests: XCTestCase {

    private func lb(_ kg: Double) -> Double { LoadUnit.kg.toStoredLb(kg) }
    private let L = LoadFormatter(unit: .lb)
    private let K = LoadFormatter(unit: .kg)

    // MARK: Formatter styles

    func test_lbStylesAreTheOldFormats() {
        XCTAssertEqual(L.oneDecimal(132.5), "132.5");  XCTAssertEqual(L.oneDecimal(135), "135.0")
        XCTAssertEqual(L.compact(135), "135");         XCTAssertEqual(L.compact(132.5), "132.5")
        XCTAssertEqual(L.compact(132.55), "132.6")     // the old "%.1f" rounding, kept
        XCTAssertEqual(L.zeroOrOneDecimal(0), "0");    XCTAssertEqual(L.zeroOrOneDecimal(100), "100.0")
        XCTAssertEqual(L.whole(132.6), "133");         XCTAssertEqual(L.whole(0), "0")
        XCTAssertEqual(L.truncated(132.9), "132")
        XCTAssertEqual(L.volumeInt(12345.9), "12345")
        XCTAssertEqual(L.number(135), "135");          XCTAssertEqual(L.text(132.5), "132.5 lb")
    }

    func test_kgStylesShowTheSameLoadInKg() {
        XCTAssertEqual(K.oneDecimal(lb(100)), "100");  XCTAssertEqual(K.compact(lb(46.25)), "46.25")
        XCTAssertEqual(K.zeroOrOneDecimal(0), "0");    XCTAssertEqual(K.zeroOrOneDecimal(lb(102.5)), "102.5")
        XCTAssertEqual(K.whole(lb(100)), "100");       XCTAssertEqual(K.truncated(lb(80)), "80")
        XCTAssertEqual(K.volumeInt(lb(1000)), "1000"); XCTAssertEqual(K.text(lb(60)), "60 kg")
        XCTAssertEqual(K.compact(102.5), "46.49")
    }

    func test_loadDisplayAndCaptionFollowTheUnit() {
        XCTAssertEqual(LoadDisplay.string(load: 135, exerciseId: "bench_press"), "135")
        XCTAssertEqual(LoadDisplay.string(load: 132.5, exerciseId: "bench_press"), "132.5")
        XCTAssertEqual(LoadDisplay.string(load: lb(100), exerciseId: "bench_press", unit: .kg), "100")
        let sets = [LastLetterPerformance.SetEntry(reps: 5, load: 315), .init(reps: 6, load: 315)]
        let perf = LastLetterPerformance(waveRaw: "a", date: Date(), weekIndex: 1, sets: sets, isBodyweight: false)
        XCTAssertEqual(perf.caption, "Last A: 315 x 5, 6")
        let kgSets = [LastLetterPerformance.SetEntry(reps: 5, load: lb(140)), .init(reps: 6, load: lb(140))]
        let kgPerf = LastLetterPerformance(waveRaw: "a", date: Date(), weekIndex: 1, sets: kgSets, isBodyweight: false)
        XCTAssertEqual(kgPerf.caption(unit: .kg), "Last A: 140 x 5, 6")
    }

    // MARK: Coach messages

    private func item(kg: Bool, load: Double, reps: [Int]) -> SessionItem {
        let stored = kg ? lb(load) : load
        let i = SessionItem(order: 1, exerciseId: "leg_extension", targetReps: 12, targetSets: reps.count, targetRIR: 2,
                            suggestedLoad: stored, waveRaw: "b", repMin: 10, repMax: 12)
        i.actualReps = reps
        i.actualLoads = Array(repeating: stored, count: reps.count)
        i.actualRIRs = Array(repeating: 2, count: reps.count)
        i.plannedLoadsBySet = Array(repeating: stored, count: reps.count)
        i.setFeedbackBySet = Array(repeating: "", count: reps.count)
        return i
    }

    func test_coachMessage_lbUnchanged_kgInKg() throws {
        let lbRec = try XCTUnwrap(CoachingEngine.recommend(for: item(kg: false, load: 150, reps: [12, 12, 12]), minLoadIncrement: 5))
        XCTAssertEqual(lbRec.nextSuggestedLoad, 155)
        XCTAssertTrue(lbRec.message.contains("155.0"), lbRec.message)
        let kgRec = try XCTUnwrap(CoachingEngine.recommend(for: item(kg: true, load: 100, reps: [12, 12, 12]), minLoadIncrement: 2.5, unit: .kg))
        XCTAssertEqual(LoadUnit.kg.fromStoredLb(try XCTUnwrap(kgRec.nextSuggestedLoad)), 102.5, accuracy: 1e-6)
        XCTAssertTrue(kgRec.message.contains("102.5"), kgRec.message)
        XCTAssertFalse(kgRec.message.contains("225"), "no lb number may leak into a kg message: \(kgRec.message)")
        let reduce = try XCTUnwrap(CoachingEngine.recommend(for: item(kg: true, load: 102.5, reps: [6, 6, 6]), minLoadIncrement: 2.5, unit: .kg))
        XCTAssertTrue(reduce.message.contains("97.5"), reduce.message)
    }

    func test_capAndClampTexts() {
        let cap = CoachingEngine.LoadCap(max: 315)
        XCTAssertEqual(cap.message(streakHint: false), "At your max load (315). Progress with reps or tempo.")
        XCTAssertEqual(CoachingEngine.LoadCap(max: lb(100)).message(streakHint: false, unit: .kg),
                       "At your max load (100). Progress with reps or tempo.")
        XCTAssertEqual(SessionItemEditService.clampPreviewText(count: 2, max: 100), "2 planned sessions above 100 will be set to 100")
        XCTAssertEqual(SessionItemEditService.clampPreviewText(count: 1, max: lb(100), unit: .kg), "1 planned session above 100 will be set to 100")
        XCTAssertEqual(ReplaceExerciseModel.loadText(132.5), "Starts at 132.5 lb")
        XCTAssertEqual(ReplaceExerciseModel.loadText(lb(60), unit: .kg), "Starts at 60 kg")
    }

    // MARK: Drop sets (their stored pattern carries lb)

    func test_dropSetPattern_isStoredLb_shownInUnit() {
        let entries = [DropSetEntry(loadText: "100", repsText: "12"), DropSetEntry(loadText: "80", repsText: "10")]
        XCTAssertEqual(entries.map { $0.serialized }.joined(separator: ","), "100x12,80x10", "lb is stored as typed")
        let stored = entries.map { $0.serialized(unit: .kg) }.joined(separator: ",")
        XCTAssertEqual(stored, "220.462262x12,176.36981x10")
        let shown = DropSetEntry.parse(from: stored, unit: .kg)
        XCTAssertEqual(shown.map(\.loadText), ["100", "80"])
        XCTAssertEqual(shown.map(\.repsText), ["12", "10"])
        XCTAssertEqual(DropSetEntry.parse(from: "100x12", unit: .lb).map(\.loadText), ["100"])
        XCTAssertEqual(SessionItem.shownDropPattern("100x12,80x10", unit: .lb), "100x12,80x10")
        XCTAssertEqual(SessionItem.shownDropPattern(stored, unit: .kg), "100x12,80x10")
    }

    // MARK: Input rules: unchanged text never writes

    func test_editRules() {
        XCTAssertEqual(LoadInput.edit("", unit: .kg, current: 100), .clear)
        XCTAssertEqual(LoadInput.edit("abc", unit: .kg, current: 100), .invalid)
        XCTAssertEqual(LoadInput.edit("46.49", unit: .kg, current: 102.5), .unchanged)
        XCTAssertEqual(LoadInput.edit("102.5", unit: .lb, current: 102.5), .unchanged)
        XCTAssertEqual(LoadInput.edit("102.50", unit: .lb, current: 102.5), .unchanged)
        XCTAssertEqual(LoadInput.edit("47.5", unit: .kg, current: 102.5), .set(lb(47.5)))
    }

    func test_programTabLoad_unchangedTextWritesNothing() {
        XCTAssertNil(LoadInput.plannedLoadWrite("46.49", unit: .kg, current: 102.5), "kg: the displayed text of 102.5 lb")
        XCTAssertNil(LoadInput.plannedLoadWrite("102.5", unit: .lb, current: 102.5))
        XCTAssertEqual(LoadInput.plannedLoadWrite("", unit: .kg, current: 102.5), 0, "emptied still writes 0")
        XCTAssertEqual(LoadInput.plannedLoadWrite("x", unit: .lb, current: 102.5), 0, "unreadable still writes 0, as before")
        XCTAssertEqual(try XCTUnwrap(LoadInput.plannedLoadWrite("50", unit: .kg, current: 102.5)), lb(50), accuracy: 1e-9)
        XCTAssertEqual(LoadInput.plannedLoadWrite("140", unit: .lb, current: nil), 140)
    }

    func test_maxLoad_unchangedTextWritesNothing() {
        XCTAssertEqual(LoadInput.maxLoadWrite("100", unit: .kg, current: lb(100)), .none)
        XCTAssertEqual(LoadInput.maxLoadWrite("315", unit: .lb, current: 315), .none)
        XCTAssertEqual(LoadInput.maxLoadWrite("", unit: .kg, current: lb(100)), .clear)
        XCTAssertEqual(LoadInput.maxLoadWrite("120", unit: .kg, current: lb(100)), .set(lb(120)))
    }

    // MARK: Session entry (view model)

    private func makeSession(kg: Bool) throws -> (ctx: ModelContext, session: Session) {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let ctx = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        ctx.insert(UserProfile(minLoadIncrement: kg ? 2.5 : 5, unit: kg ? .kg : .lb))
        let load = kg ? lb(102.5) : 102.5
        let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: load)
        i.plannedLoadsBySet = [load, load, load]
        i.plannedRepsBySet = [8, 8, 8]
        let s = Session(date: Date(), status: .inProgress, weekIndex: 1, items: [i])
        ctx.insert(s)
        try ctx.save()
        return (ctx, s)
    }

    @MainActor
    func test_sessionEntry_kg() throws {
        let (ctx, session) = try makeSession(kg: true)
        let vm = SessionScreenViewModel(session: session)
        XCTAssertEqual(vm.loadUnit, .kg)
        let ex = vm.exercises[0]
        XCTAssertEqual(ex.sets[0].plannedLoadText, "102.5", "planned load shown in kg")
        // Re-saving the displayed text writes nothing.
        vm.updateActualLoad(exerciseID: ex.id, setIndex: 1, text: "102.5")
        XCTAssertEqual(vm.exercises[0].sets[0].actualLoad, lb(102.5))
        vm.updateActualLoad(exerciseID: ex.id, setIndex: 1, text: "102.5")
        XCTAssertEqual(vm.exercises[0].sets[0].actualLoad, lb(102.5), "same text again: the stored lb is untouched")
        vm.updateActualLoad(exerciseID: ex.id, setIndex: 1, text: "105")
        XCTAssertEqual(try XCTUnwrap(vm.exercises[0].sets[0].actualLoad), lb(105), accuracy: 1e-9)
        // Confirming an unedited set stores the planned load exactly (no 102.4986 lb).
        vm.handleSetLogged(exerciseID: ex.id, setIndex: 2, context: ctx)
        XCTAssertEqual(vm.exercises[0].sets[1].actualLoad, lb(102.5))
        XCTAssertEqual(session.items[0].actualLoads[1], lb(102.5), "stored lb equals the planned load bit for bit")
    }

    @MainActor
    func test_sessionEntry_lbUnchanged() throws {
        let (ctx, session) = try makeSession(kg: false)
        let vm = SessionScreenViewModel(session: session)
        XCTAssertEqual(vm.loadUnit, .lb)
        let ex = vm.exercises[0]
        XCTAssertEqual(ex.sets[0].plannedLoadText, "102.5")
        vm.updateActualLoad(exerciseID: ex.id, setIndex: 1, text: "105")
        XCTAssertEqual(vm.exercises[0].sets[0].actualLoad, 105)
        vm.handleSetLogged(exerciseID: ex.id, setIndex: 2, context: ctx)
        XCTAssertEqual(session.items[0].actualLoads[1], 102.5)
    }

    // MARK: CSV

    func test_csv_unitColumnAndValuesInTheUnit() throws {
        for kg in [false, true] {
            let (ctx, session) = try makeSession(kg: kg)
            session.status = .completed
            let item = session.items[0]
            let l = kg ? lb(100) : 225
            item.actualReps = [8, 8, 8]; item.actualLoads = [l, l, l]; item.actualRIRs = [2, 2, 2]
            try ctx.save()
            let result = try SetsV1CSVExporter.exportCompletedSessionsCSV(modelContext: ctx, fileName: "k3_\(kg)_\(UUID().uuidString).csv")
            let lines = try String(contentsOf: result.url, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertTrue(lines[0].hasSuffix(",set_role,load_unit"), lines[0])
            let cols = lines[0].split(separator: ",").map(String.init)
            let row = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(row[cols.firstIndex(of: "load_unit")!], kg ? "kg" : "lb")
            XCTAssertEqual(row[cols.firstIndex(of: "actual_load")!], kg ? "100" : "225")
        }
    }

    // MARK: Recap strings

    func test_recapBestSetAndDrops() {
        let i = item(kg: false, load: 225, reps: [8, 6])
        XCTAssertEqual(i.bestSetDescription, "225.0 x 8")
        let k = item(kg: true, load: 100, reps: [8, 6])
        XCTAssertEqual(k.bestSetDescription(unit: .kg), "100 x 8")
        k.dropSetPatternsBySet = [DropSetEntry(loadText: "80", repsText: "10").serialized(unit: .kg), ""]
        XCTAssertEqual(k.dropSetDescription(forSetAt: 0, unit: .kg), "Drop 1: 80 × 10")
    }
}
