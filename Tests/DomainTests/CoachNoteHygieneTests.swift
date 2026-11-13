import XCTest
import SwiftData
@testable import ElitePerformance

/// An info note that cites a load must not outlive the load it cites.
final class CoachNoteHygieneTests: XCTestCase {

    private func item(note: String?, loads: [Double], suggested: Double = 0) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: "ez_bar_skull_crusher", exerciseNameSnapshot: "Skull Crusher", targetReps: 10, targetSets: loads.count,
                            targetRIR: 2, suggestedLoad: suggested, plannedRepsBySet: Array(repeating: 10, count: loads.count),
                            plannedLoadsBySet: loads, plannedRIRsBySet: Array(repeating: 2, count: loads.count))
        i.coachNote = note
        return i
    }

    func test_citedLoad_readsOnlyGeneratedInfoNotes() {
        XCTAssertEqual(CoachNoteHygiene.citedLoad(in: "ℹ️ One more clean session at 65.0 earns the increase."), 65.0)
        XCTAssertEqual(CoachNoteHygiene.citedLoad(in: "✅ Two clean sessions confirmed. Load stepping up to 70.5."), 70.5)
        XCTAssertNil(CoachNoteHygiene.citedLoad(in: "ℹ️ Load set from your best performance this meso."))
        XCTAssertNil(CoachNoteHygiene.citedLoad(in: "⚠️ Pain was flagged in your last session for this exercise. Reassess before loading."))
        XCTAssertNil(CoachNoteHygiene.citedLoad(in: "a note the lifter typed, at 65"), "only generated notes are touched")
    }

    func test_aNoteCitingAnotherLoadThanThePlan_isStale_andHidden() {
        let stale = item(note: "ℹ️ One more clean session at 65.0 earns the increase.", loads: [70, 70, 70], suggested: 70)
        XCTAssertTrue(CoachNoteHygiene.isStale(stale, unit: .lb))
        XCTAssertNil(CoachNoteHygiene.visibleNote(of: stale, unit: .lb))
        XCTAssertTrue(CoachNoteHygiene.clearIfStale(stale, unit: .lb))
        XCTAssertNil(stale.coachNote)
    }

    func test_aNoteMatchingThePlan_staysVisible() {
        let ok = item(note: "ℹ️ One more clean session at 65.0 earns the increase.", loads: [65, 65, 65], suggested: 65)
        XCTAssertFalse(CoachNoteHygiene.isStale(ok, unit: .lb))
        XCTAssertEqual(CoachNoteHygiene.visibleNote(of: ok, unit: .lb), ok.coachNote)
        XCTAssertFalse(CoachNoteHygiene.clearIfStale(ok, unit: .lb))
        let topSet = item(note: "ℹ️ One more clean session at 65.0 earns the increase.", loads: [65, 65, 75], suggested: 65)
        XCTAssertFalse(CoachNoteHygiene.isStale(topSet, unit: .lb), "a top set above the cited back-off load is not a mismatch")
        let flag = item(note: "⚠️ Pain was flagged in your last session for this exercise. Reassess before loading.", loads: [70], suggested: 70)
        XCTAssertFalse(CoachNoteHygiene.isStale(flag, unit: .lb), "flags cite no load")
    }

    func test_inKilograms_theNoteIsComparedInTheLiftersUnit() {
        let lb = LoadUnit.kg.toStoredLb(30)
        let ok = item(note: "ℹ️ One more clean session at 30.0 earns the increase.", loads: [lb, lb], suggested: lb)
        XCTAssertFalse(CoachNoteHygiene.isStale(ok, unit: .kg))
        let stale = item(note: "ℹ️ One more clean session at 27.5 earns the increase.", loads: [lb, lb], suggested: lb)
        XCTAssertTrue(CoachNoteHygiene.isStale(stale, unit: .kg))
    }

    /// The note is WRITTEN in the lifter's display unit (`LoadFormatter(unit:).oneDecimal`, kg trimmed to at most 2 decimals) and
    /// the plan is STORED in lb, so the comparison converts the stored loads to the display unit first. A kg lifter on a
    /// 1.25 kg step must never see a fresh note judged stale (or a stale one kept) by unit-conversion rounding.
    func test_kgLifter_generatedNotesRoundTripThroughTheRealFormatter_acrossAKgLoadRange() {
        let kg = LoadFormatter(unit: .kg)
        var kgLoad = 20.0
        while kgLoad <= 140 {
            let stored = LoadUnit.kg.toStoredLb(kgLoad)
            let text = kg.oneDecimal(stored)                                            // exactly what PlanMemoryEngine writes
            let note = "ℹ️ One more clean session at \(text) earns the increase."
            let fresh = item(note: note, loads: [stored, stored], suggested: stored)
            XCTAssertFalse(CoachNoteHygiene.isStale(fresh, unit: .kg), "fresh note \(text) kg judged stale")
            XCTAssertEqual(CoachNoteHygiene.citedLoad(in: note) ?? -1, Double(text) ?? -2, accuracy: 1e-9)
            // the plan moves up one 1.25 kg step: the same note is now stale
            let moved = item(note: note, loads: [LoadUnit.kg.toStoredLb(kgLoad + 1.25)], suggested: LoadUnit.kg.toStoredLb(kgLoad + 1.25))
            XCTAssertTrue(CoachNoteHygiene.isStale(moved, unit: .kg), "\(text) kg note kept after the plan moved")
            kgLoad += 1.25
        }
    }

    func test_kgLifter_theSameStoredPlanIsJudgedInTheDisplayUnit_notAsAKgNumberAgainstLb() {
        // plan 70 lb stored = 31.75 kg; a kg lifter's note cites 31.75, not 70
        let stored = 70.0
        let kgNote = item(note: "ℹ️ One more clean session at \(LoadFormatter(unit: .kg).oneDecimal(stored)) earns the increase.", loads: [stored], suggested: stored)
        XCTAssertFalse(CoachNoteHygiene.isStale(kgNote, unit: .kg))
        // the very same text read by an lb lifter would cite 31.75 lb against a 70 lb plan: stale
        XCTAssertTrue(CoachNoteHygiene.isStale(kgNote, unit: .lb))
    }

    func test_sweep_clearsStaleNotesOnPlannedSessionsOnly() throws {
        let ctx = ModelContext(try BackupTestSupport.makeContainer())
        let planned = Session(date: Date(), status: .planned, weekIndex: 1, dayLabel: "Push",
                              items: [item(note: "ℹ️ One more clean session at 65.0 earns the increase.", loads: [70, 70], suggested: 70)])
        let done = Session(date: Date(), status: .completed, weekIndex: 1, dayLabel: "Push",
                           items: [item(note: "ℹ️ One more clean session at 65.0 earns the increase.", loads: [70, 70], suggested: 70)])
        ctx.insert(planned); ctx.insert(done)
        XCTAssertEqual(CoachNoteHygiene.sweep([planned, done], unit: .lb), 1)
        XCTAssertNil(planned.items.first?.coachNote)
        XCTAssertNotNil(done.items.first?.coachNote, "a completed session's note is history")
    }

    func test_carryForward_replacesAStaleNoteWithOneForTheNewLoad() throws {
        // The engine only writes a progression note when the slot is empty; a stale note used to block that for good.
        let stale = item(note: "ℹ️ One more clean session at 65.0 earns the increase.", loads: [70, 70], suggested: 70)
        CoachNoteHygiene.clearIfStale(stale, unit: .lb)
        XCTAssertNil(stale.coachNote, "empty again: the engine can write the note for 70")
    }
}
