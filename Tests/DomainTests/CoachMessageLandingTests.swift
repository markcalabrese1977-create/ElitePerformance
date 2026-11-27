import XCTest
import SwiftData
@testable import ElitePerformance

/// The coach message must name the session a load actually lands in, and must
/// never state a number that nothing will receive.
///
/// Under per-letter anchoring (PlanMemoryEngine.nextTargetItem) a bump earned in
/// week 1's A wave lands in week 4's A wave, not in the literal next session — so
/// "Next session: 105" was a promise about a session that keeps its own,
/// different load. And at the end of a letter's chain (the last A week in a block)
/// nothing in the block receives the load at all, so no number may be promised.
///
/// These live here rather than in CoachingMessageSeamTests because that class
/// crashes the test host: its SessionScreenViewModel deinit trips a Swift
/// concurrency / libmalloc fault ("pointer being freed was not allocated") on
/// teardown, which kills the process mid-suite. The crash reproduces on the
/// pre-change commit and is unrelated to load logic. These cases need no
/// ViewModel, so they run.
final class CoachMessageLandingTests: XCTestCase {

    // MARK: - Helpers

    /// An item whose logged performance clears every safety gate and hits the top
    /// of the range on all working sets — RULE 5b, the "increase earned" bump.
    private func bumpEarningItem(waveRaw: String?) -> SessionItem {
        let item = SessionItem(
            order: 1,
            exerciseId: "bench_press",
            targetReps: 10,
            targetSets: 3,
            targetRIR: 2,
            suggestedLoad: 100,
            waveRaw: waveRaw,
            repMin: 8,
            repMax: 10
        )
        item.actualReps  = [10, 10, 10]     // every set at repMax
        item.actualLoads = [100, 100, 100]
        item.actualRIRs  = [2, 2, 2]        // on target
        item.plannedRepsBySet = [10, 10, 10]
        item.setFeedbackBySet = ["", "", ""]
        return item
    }

    private func recommend(
        _ item: SessionItem,
        target: CoachingEngine.CarryForwardTarget
    ) throws -> CoachingRecommendation {
        try XCTUnwrap(
            CoachingEngine.recommend(
                for: item,
                minLoadIncrement: 5,
                carryForwardTarget: target
            ),
            "expected a recommendation for a complete, clean, top-of-range session"
        )
    }

    /// Any number that looks like a promised load. Deliberately not "contains a
    /// digit" — an end-of-chain message may still quote what was observed.
    private func assertPromisesNoLoad(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for fragment in ["105", "105", "Next session:", "Next Week"] {
            XCTAssertFalse(
                message.contains(fragment),
                "end-of-chain message must not promise a load, found '\(fragment)' in: \(message)",
                file: file, line: line
            )
        }
    }

    // MARK: - Wave-A bump WITH a target

    func test_waveABump_withTarget_namesTheWeekNotTheNextSession() throws {
        let rec = try recommend(bumpEarningItem(waveRaw: "a"), target: .exists)

        XCTAssertEqual(rec.nextSuggestedLoad, 105, "load logic must be untouched by the wording change")
        XCTAssertTrue(
            rec.message.contains("Next Week A: 105"),
            "a wave-A bump lands in the next A week, and the message must say so: \(rec.message)"
        )
        XCTAssertFalse(
            rec.message.contains("Next session"),
            "\"Next session\" is the promise this change removes for waved items: \(rec.message)"
        )
    }

    func test_waveLetterIsUppercasedForEachWave() throws {
        for (raw, expected) in [("a", "Next Week A"), ("b", "Next Week B"), ("c", "Next Week C")] {
            let rec = try recommend(bumpEarningItem(waveRaw: raw), target: .exists)
            XCTAssertTrue(
                rec.message.contains("\(expected): 105"),
                "wave '\(raw)' should read '\(expected)': \(rec.message)"
            )
        }
    }

    // MARK: - Wave-A bump with NO target (end of the letter's chain)

    func test_waveABump_endOfChain_statesNoNumber() throws {
        let rec = try recommend(bumpEarningItem(waveRaw: "a"), target: .endOfChain)

        XCTAssertEqual(
            rec.nextSuggestedLoad, 105,
            "the load is still computed — only the MESSAGE withholds it, so no load logic changes"
        )
        assertPromisesNoLoad(rec.message)
        XCTAssertTrue(
            rec.message.contains("next block"),
            "end-of-chain message should say where the result actually goes: \(rec.message)"
        )
        XCTAssertTrue(
            rec.message.contains("increase earned"),
            "the verdict itself must survive — only the number is withheld: \(rec.message)"
        )
    }

    func test_overPerformedBump_endOfChain_statesNoNumber() throws {
        let item = bumpEarningItem(waveRaw: "a")
        item.actualReps = [12, 12, 12]   // repMax + 2 on every set — RULE 5a
        let rec = try recommend(item, target: .endOfChain)

        assertPromisesNoLoad(rec.message)
        XCTAssertTrue(rec.message.contains("next block"), rec.message)
    }

    /// RULE 1d — the intra-session downshift re-baseline. Its forward-looking number
    /// is gated too, but the observed from/to numbers describe what happened and stay.
    func test_intraSessionDrop_endOfChain_keepsObservedNumbersDropsThePromise() throws {
        let item = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3,
            targetRIR: 2, suggestedLoad: 300, waveRaw: "a", repMin: 6, repMax: 8
        )
        item.actualReps  = [8, 8, 8]
        item.actualLoads = [300, 280, 250]   // opened high, dropped >= 10%
        item.actualRIRs  = [2, 2, 2]
        item.plannedRepsBySet = [8, 8, 8]
        item.setFeedbackBySet = ["", "", ""]

        let withTarget = try recommend(item, target: .exists)
        XCTAssertTrue(withTarget.message.contains("Next Week A starts at 250"), withTarget.message)

        let endOfChain = try recommend(item, target: .endOfChain)
        XCTAssertEqual(endOfChain.nextSuggestedLoad, 250.0, "load logic unchanged")
        XCTAssertTrue(
            endOfChain.message.contains("Load dropped from 300 to 250"),
            "observed numbers describe what happened and must stay: \(endOfChain.message)"
        )
        XCTAssertFalse(
            endOfChain.message.contains("starts at"),
            "the forward-looking promise must go: \(endOfChain.message)"
        )
        XCTAssertTrue(endOfChain.message.contains("next block"), endOfChain.message)
    }

    // MARK: - Wave-nil items are unchanged

    func test_waveNilBump_keepsNextSessionWording() throws {
        let rec = try recommend(bumpEarningItem(waveRaw: nil), target: .exists)

        XCTAssertEqual(rec.nextSuggestedLoad, 105)
        XCTAssertTrue(
            rec.message.contains("Next session: 105"),
            "a wave-less item is not in a letter rotation and keeps the original wording: \(rec.message)"
        )
    }

    func test_waveNilBump_defaultCallerUnchanged() throws {
        // Every existing caller that passes no carryForwardTarget must be unaffected.
        let rec = try XCTUnwrap(
            CoachingEngine.recommend(for: bumpEarningItem(waveRaw: nil), minLoadIncrement: 5)
        )
        XCTAssertTrue(rec.message.contains("Next session: 105"), rec.message)
    }

    func test_emptyStringWave_keepsNextSessionWording() throws {
        let rec = try recommend(bumpEarningItem(waveRaw: ""), target: .exists)
        XCTAssertTrue(rec.message.contains("Next session: 105"), rec.message)
    }

    /// "Wave-less items keep 'Next session'" governs the PHRASING when a target
    /// exists. It does not license promising a number when there is no target: a
    /// wave-less item whose chronological next occurrence doesn't exist has nothing
    /// to receive the load either, so end-of-chain wins for it too. Pinned because
    /// the two rules look like they conflict and a future reader will have to pick.
    func test_waveNil_endOfChain_stillStatesNoNumber() throws {
        let rec = try recommend(bumpEarningItem(waveRaw: nil), target: .endOfChain)

        XCTAssertEqual(rec.nextSuggestedLoad, 105, "load logic unchanged")
        assertPromisesNoLoad(rec.message)
        XCTAssertTrue(rec.message.contains("next block"), rec.message)
    }

    // MARK: - Deload sources never promise a number

    /// A deload source returns from RULE 2 before reaching any promise site, so its
    /// retention message carries no load. Pinned so a future edit to that guard
    /// can't start promising one.
    func test_deloadSource_messageCarriesNoNumber() throws {
        let item = bumpEarningItem(waveRaw: "deload")
        let rec = try XCTUnwrap(
            CoachingEngine.recommend(for: item, minLoadIncrement: 5, carryForwardTarget: .exists)
        )
        XCTAssertFalse(rec.message.contains("Next Week"), rec.message)
        XCTAssertFalse(rec.message.contains("Next session:"), rec.message)
        XCTAssertFalse(rec.message.contains("105"), rec.message)
    }

    // MARK: - The message agrees with what the engine actually writes

    /// End to end: the wave letter the message names must be the wave of the item
    /// PlanMemoryEngine.nextTargetItem actually writes to.
    func test_messageWaveMatchesTheItemTheEngineWritesTo() throws {
        let schema = Schema([
            Session.self, SessionItem.self, MesoBlock.self,
            UserProfile.self, User.self, CustomExercise.self
        ])
        let context = ModelContext(
            try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        )
        context.insert(User(units: .lb, progressionEnabled: true))

        var c = DateComponents(); c.year = 2026; c.month = 1; c.day = 5   // Monday
        try DUPProgramSeeder.seed(
            startDate: Calendar.current.date(from: c)!,
            trainingWeekdays: [2, 3, 4, 5, 6, 7],
            context: context,
            template: DUP10WeekTemplate.template,
            mesoName: "LandingTestMeso",
            mesoStatus: .active
        )
        try context.save()

        let sessions = try context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])
        )
        let weekOneDayOne = sessions[0]
        let source = try XCTUnwrap(
            weekOneDayOne.items.first { $0.exerciseId == ExerciseCatalog.benchPress.id }
        )
        let sourceWave = try XCTUnwrap(source.waveRaw?.lowercased())

        let target = try XCTUnwrap(
            PlanMemoryEngine.nextTargetItem(for: source, after: weekOneDayOne, in: sessions),
            "week 1 A must have a later A to anchor"
        )
        XCTAssertEqual(
            target.waveRaw?.lowercased(), sourceWave,
            "sanity: the engine writes into the same wave letter"
        )

        // Now a message built for that source must name that same letter.
        let setCount = max(1, source.targetSets)
        let repMax = source.repMax ?? source.targetReps
        source.suggestedLoad     = 200
        source.plannedLoadsBySet = Array(repeating: 200, count: setCount)
        source.actualLoads       = Array(repeating: 200, count: setCount)
        source.actualReps        = Array(repeating: repMax, count: setCount)
        source.actualRIRs        = Array(repeating: source.targetRIR, count: setCount)
        source.setFeedbackBySet  = Array(repeating: "", count: setCount)
        source.plannedRepsBySet  = Array(repeating: repMax, count: setCount)

        let rec = try XCTUnwrap(
            CoachingEngine.recommend(for: source, minLoadIncrement: 5, carryForwardTarget: .exists)
        )
        XCTAssertTrue(
            rec.message.contains("Next Week \(sourceWave.uppercased())"),
            "message must name the wave the write actually lands in: \(rec.message)"
        )
    }

    // MARK: - The landing date and the different-week-type sentence

    func test_landingDate_isAddedToTheNextWeekPhrase_andTheDifferentWeekSentenceFollows() throws {
        let cal = Calendar.current
        let dec11 = cal.date(from: DateComponents(year: 2026, month: 12, day: 11))!
        let item = bumpEarningItem(waveRaw: "a")
        let withB = try XCTUnwrap(CoachingEngine.recommend(for: item, minLoadIncrement: 5, carryForwardTarget: .exists,
            landing: .init(date: dec11, nextWeekLetter: "b")))
        XCTAssertTrue(withB.message.contains("Next Week A (Dec 11): 105."), withB.message)
        XCTAssertTrue(withB.message.hasSuffix("Next week is a B week with its own target."), withB.message)
        XCTAssertEqual(withB.nextSuggestedLoad, 105, "wording only")
        // The very next session of the day is the target's own week type: date, no sentence.
        let same = try XCTUnwrap(CoachingEngine.recommend(for: item, minLoadIncrement: 5, carryForwardTarget: .exists,
            landing: .init(date: dec11, nextWeekLetter: "a")))
        XCTAssertTrue(same.message.contains("Next Week A (Dec 11): 105."), same.message)
        XCTAssertFalse(same.message.contains("its own target"), same.message)
        // No landing given (every other caller): the text is exactly as before.
        let none = try XCTUnwrap(CoachingEngine.recommend(for: item, minLoadIncrement: 5, carryForwardTarget: .exists))
        XCTAssertTrue(none.message.contains("Next Week A: 105"), none.message)
        // A wave-less item is not in a rotation: never decorated.
        let waveless = try XCTUnwrap(CoachingEngine.recommend(for: bumpEarningItem(waveRaw: nil), minLoadIncrement: 5, carryForwardTarget: .exists,
            landing: .init(date: dec11, nextWeekLetter: "b")))
        XCTAssertTrue(waveless.message.contains("Next session: 105"), waveless.message)
        XCTAssertFalse(waveless.message.contains("Dec 11"), waveless.message)
    }

    func test_landingHelper_findsTheTargetDate_andTheDifferentWeekTypeOfTheNextSameDaySession() throws {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let ctx = ModelContext(container)
        let block = MesoBlock(name: "B", startDate: Date(), status: .active, totalWeeks: 4)
        ctx.insert(block)
        let cal = Calendar.current
        let d0 = cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        var sessions: [Session] = []
        for (w, letter) in ["a", "b", "c", "a"].enumerated() {
            let item = bumpEarningItem(waveRaw: letter)
            let s = Session(date: cal.date(byAdding: .day, value: 7 * w, to: d0)!, status: w == 0 ? .completed : .planned,
                            weekIndex: w + 1, dayLabel: "Legs", items: [item], programIndex: w + 1)
            s.meso = block; ctx.insert(s); sessions.append(s)
        }
        try ctx.save()
        let target = try XCTUnwrap(PlanMemoryEngine.nextTargetItem(for: sessions[0].items[0], after: sessions[0], in: sessions))
        XCTAssertTrue(target === sessions[3].items[0], "per-letter chain: week 1's A lands in week 4's A")
        let landing = try XCTUnwrap(PlanMemoryEngine.landing(for: sessions[0].items[0], in: sessions[0], target: target, allSessions: sessions))
        XCTAssertEqual(landing.date, sessions[3].date)
        XCTAssertEqual(landing.nextWeekLetter, "b", "next week's Legs is a B week")
        // A target that IS the very next same-day session has nothing to add.
        let next = try XCTUnwrap(PlanMemoryEngine.landing(for: sessions[0].items[0], in: sessions[0], target: sessions[1].items[0], allSessions: sessions))
        XCTAssertNil(next.nextWeekLetter)
    }

    // MARK: - Pump never speaks on a coach line

    private func withPump(_ item: SessionItem, _ rating: PumpRating) -> SessionItem {
        item.pumpRatingsBySet = Array(repeating: rating.rawValue, count: item.actualReps.count)
        return item
    }

    func test_noPumpSentenceOnAnyLine_forEveryRating_onIncreaseOverPerformedAndDeload() throws {
        let bannedFragments = ["Pump was", "pump", "responding well", "stimulus"]
        for rating in [PumpRating.poor, .moderate, .good, .excellent] {
            // increase earned
            let inc = try recommend(withPump(bumpEarningItem(waveRaw: "a"), rating), target: .exists)
            // over-performed (every set two reps past the top)
            let over = bumpEarningItem(waveRaw: "a"); over.actualReps = [12, 12, 12]
            let overRec = try recommend(withPump(over, rating), target: .exists)
            // deload line
            let dl = bumpEarningItem(waveRaw: "deload"); dl.suggestedLoad = 100
            let dlRec = try XCTUnwrap(CoachingEngine.recommend(for: withPump(dl, rating), minLoadIncrement: 5))
            for (name, msg) in [("increase", inc.message), ("over-performed", overRec.message), ("deload", dlRec.message)] {
                for f in bannedFragments {
                    XCTAssertFalse(msg.contains(f), "\(name) line carries '\(f)' for \(rating): \(msg)")
                }
            }
            XCTAssertTrue(overRec.message.hasPrefix("Reps came in well above the top of your range"), overRec.message)
        }
    }

    func test_loadDecisionsAndText_areIdentical_withPumpUnratedAndExcellent() throws {
        let a = try recommend(withPump(bumpEarningItem(waveRaw: "a"), .none), target: .exists)
        let b = try recommend(withPump(bumpEarningItem(waveRaw: "a"), .excellent), target: .exists)
        XCTAssertEqual(a.nextSuggestedLoad, b.nextSuggestedLoad)
        XCTAssertEqual(a.nextTopLoad, b.nextTopLoad)
        XCTAssertEqual(a.message, b.message, "pump 0 vs 4: the whole line, not just the load, is the same")
        let over0 = bumpEarningItem(waveRaw: "a"); over0.actualReps = [12, 12, 12]
        let over4 = bumpEarningItem(waveRaw: "a"); over4.actualReps = [12, 12, 12]
        XCTAssertEqual(try recommend(withPump(over0, .none), target: .exists).message, try recommend(withPump(over4, .excellent), target: .exists).message)
    }

    func test_poorPumpVolumeNote_stillFiresOnTwoOfTheLastThree_andOnlyAsText() {
        func item(poor: Bool) -> SessionItem {
            let i = bumpEarningItem(waveRaw: "a")
            i.pumpRatingsBySet = poor ? [1, 2, 3] : [3, 3, 3]
            return i
        }
        let two = PlanMemoryEngine.volumeRegulationSignal(from: [item(poor: true), item(poor: false), item(poor: true)])
        XCTAssertEqual(two.setDelta, 0, "text only: no set change")
        XCTAssertEqual(two.reason, "ℹ️ Consistently poor pump signal across recent sessions. Holding volume before increasing.")
        let one = PlanMemoryEngine.volumeRegulationSignal(from: [item(poor: true), item(poor: false), item(poor: false)])
        XCTAssertNil(one.reason)
    }
}
