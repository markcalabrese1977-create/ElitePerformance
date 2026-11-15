import XCTest
import SwiftData
@testable import ElitePerformance

/// Onboarding collects equipment and joints, the preview shows the fitted program, and seeding runs the same fit.
final class OnboardingFitTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    private static func weekdays(_ days: Int) -> [Int] {
        switch days {
        case 2: return [2, 5]
        case 3: return [2, 4, 6]
        case 4: return [2, 3, 5, 6]
        case 5: return [2, 3, 4, 5, 6]
        default: return [2, 3, 4, 5, 6, 7]
        }
    }

    private func result(days: Int = 4, preset: EquipmentPreset = .fullGym, checklist: [GearTag] = [],
                        joints: [InjuryFlag] = [], minutes: Int = 120,
                        experience: TrainingExperience = .intermediate) -> OnboardingResult {
        OnboardingResult(
            goal: .hypertrophy, experience: experience, daysPerWeek: days,
            trainingDaysOfWeek: Self.weekdays(days), equipmentProfile: preset.legacyProfile,
            sessionLengthMinutes: minutes, injuryFlags: joints, minLoadIncrement: 2.5, startDate: Date(),
            equipmentPreset: preset, equipmentChecklist: checklist
        )
    }

    /// Week-1 items per day label: (exerciseId, targetSets) in order.
    private func seededWeek1(_ context: ModelContext) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for session in try context.fetch(FetchDescriptor<Session>()) where session.weekIndex == 1 {
            out[session.dayLabel ?? "?"] = session.items.sorted { $0.order < $1.order }
                .map { "\($0.exerciseId):\($0.targetSets)" }
        }
        return out
    }

    private func expectedWeek1(_ template: ProgramTemplate) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for day in template.dayTemplates {
            let plans = try ProgramTemplateResolver.resolveDay(template: template, weekNumber: 1, dayNumber: day.dayNumber)
            out[day.title] = plans.sorted { $0.order < $1.order }.map { "\($0.exerciseId):\(max(0, $0.defaultSets))" }
        }
        return out
    }

    // MARK: Result and profile storage

    func test_onboardingResult_defaultsMeanFullGymAndNoChecklist() {
        let r = OnboardingResult(goal: .hypertrophy, experience: .intermediate, daysPerWeek: 3, trainingDaysOfWeek: [2, 4, 6],
                                 equipmentProfile: .commercial, sessionLengthMinutes: 60, injuryFlags: [],
                                 minLoadIncrement: 2.5, startDate: Date())
        XCTAssertEqual(r.equipmentPreset, .fullGym)
        XCTAssertEqual(r.equipmentChecklist, [])
    }

    func test_onboardingResult_decodesOldJSONWithoutPresetOrChecklist() throws {
        let r = result(days: 3, preset: .machinesOnly, checklist: [.cable], joints: [.hips])
        let enc = JSONEncoder()
        let data = try enc.encode(r)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "equipmentPreset")
        obj.removeValue(forKey: "equipmentChecklist")
        let old = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(OnboardingResult.self, from: old)
        XCTAssertEqual(decoded.equipmentPreset, .fullGym)
        XCTAssertEqual(decoded.equipmentChecklist, [])
        XCTAssertEqual(try JSONDecoder().decode(OnboardingResult.self, from: data).equipmentPreset, .machinesOnly)
    }

    func test_writeUserProfile_storesPresetChecklistAndHips() throws {
        let context = try makeContext()
        let r = result(days: 3, preset: .dumbbellsBench, checklist: [.dumbbell], joints: [.hips, .knees])
        ProgramApplicationService.writeUserProfile(from: r, context: context)
        let profile = try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertEqual(profile.equipmentPreset, .dumbbellsBench)
        XCTAssertEqual(profile.equipmentChecklist, [.dumbbell])
        XCTAssertEqual(profile.effectiveEquipment, [.dumbbell])
        XCTAssertEqual(Set(profile.injuryFlags), [.hips, .knees])

        // an existing profile is updated, and an empty checklist reads back as the preset's defaults
        ProgramApplicationService.writeUserProfile(from: result(days: 3, preset: .machinesOnly), context: context)
        let again = try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertEqual(again.equipmentPreset, .machinesOnly)
        XCTAssertEqual(again.equipmentChecklist, [])
        XCTAssertEqual(again.effectiveEquipment, EquipmentPreset.machinesOnly.defaultEquipment)
    }

    func test_unsetProfile_isFullGymNoLimits() {
        let fresh = ProgramApplicationService.fitProfile(for: result())
        XCTAssertTrue(fresh.isUnrestricted)
    }

    // MARK: Preview == seed

    /// Preview and seeding share `fittedProgram(for:)`; this checks the seeded sessions really are that program.
    func test_previewEqualsSeededProgram_acrossAProfileMatrix() throws {
        var checked = 0
        for days in 2...6 {
            for preset in EquipmentPreset.allCases {
                for joints in [[], [InjuryFlag.knees], [.lowBack, .shoulders]] as [[InjuryFlag]] {
                    for minutes in [45, 120] {
                        for experience in [TrainingExperience.new, .intermediate] {
                            let r = result(days: days, preset: preset, joints: joints, minutes: minutes, experience: experience)
                            let context = try makeContext()
                            ProgramApplicationService.apply(r, context: context, startDate: Date())
                            let preview = ProgramApplicationService.fittedProgram(for: r).template
                            XCTAssertEqual(try seededWeek1(context), try expectedWeek1(preview),
                                           "\(days)d \(preset) \(joints) \(minutes)m \(experience)")
                            checked += 1
                        }
                    }
                }
            }
        }
        print("ONBOARDING_FIT preview==seed checked \(checked) profiles")
    }

    func test_fullGym_noFlags_120min_seedsTodaysProgramUnchanged() throws {
        for days in 2...6 {
            let r = result(days: days)
            let context = try makeContext()
            ProgramApplicationService.apply(r, context: context, startDate: Date())
            let template = ProgramApplicationService.selectTemplate(goal: r.goal, daysPerWeek: days)
            XCTAssertEqual(try seededWeek1(context), try expectedWeek1(template), "\(days) days")
            XCTAssertTrue(ProgramApplicationService.fittedProgram(for: r).reasons.isEmpty)
        }
    }

    func test_restrictedProfile_actuallyChangesTheSeededProgram() throws {
        let r = result(days: 4, preset: .dumbbellsBench, joints: [.knees], minutes: 60)
        let context = try makeContext()
        ProgramApplicationService.apply(r, context: context, startDate: Date())
        let plain = try expectedWeek1(ProgramApplicationService.selectTemplate(goal: r.goal, daysPerWeek: 4))
        XCTAssertNotEqual(try seededWeek1(context), plain)
    }

    // MARK: Slot-keyed overrides

    func test_slotKeyedOverride_appliesToExactlyOneSlot_whenTheIdRepeats() throws {
        // DUP10 repeats exercise ids across its six days.
        let r = result(days: 6)
        let fitted = ProgramApplicationService.fittedProgram(for: r).template
        var seen: [String: [(day: ProgramDayTemplate, index: Int)]] = [:]
        for day in fitted.dayTemplates { for (i, ex) in day.exerciseTemplates.enumerated() { seen[ex.exerciseId, default: []].append((day, i)) } }
        let repeated = try XCTUnwrap(seen.values.first { $0.count > 1 })
        let target = repeated[0]

        let overrides = PreviewOverrides(slotOverrides: [:], addedByDay: [:],
                                         slotKeyed: [SlotKey(dayId: target.day.id, slotIndex: target.index):
                                                        ExerciseWaveOverride(substituteExerciseId: "zz_swapped")])
        let context = try makeContext()
        ProgramApplicationService.apply(r, context: context, startDate: Date(), overrides: overrides)

        var swapped = 0
        for session in try context.fetch(FetchDescriptor<Session>()) where session.weekIndex == 1 {
            for item in session.items where item.exerciseId == "zz_swapped" {
                swapped += 1
                XCTAssertEqual(session.dayLabel, target.day.title)
                XCTAssertEqual(item.order, target.day.exerciseTemplates[target.index].order)
            }
        }
        XCTAssertEqual(swapped, 1, "exactly one slot in week 1 carries the swap")
        // the same exercise on the other days is untouched
        for other in repeated.dropFirst() {
            let items = try context.fetch(FetchDescriptor<Session>()).filter { $0.weekIndex == 1 && $0.dayLabel == other.day.title }.flatMap(\.items)
            XCTAssertTrue(items.contains { $0.exerciseId == target.day.exerciseTemplates[target.index].exerciseId })
        }
    }

    func test_slotKeyedOverride_isAppliedOnTopOfTheFittedTemplate() throws {
        let r = result(days: 4, preset: .dumbbellsBench, joints: [.knees], minutes: 60)
        let fitted = ProgramApplicationService.fittedProgram(for: r).template
        let day = fitted.dayTemplates[0]
        let key = SlotKey(dayId: day.id, slotIndex: 1)
        let overrides = PreviewOverrides(slotOverrides: [:], addedByDay: [:], slotKeyed: [key: ExerciseWaveOverride(isDeleted: true)])
        let context = try makeContext()
        ProgramApplicationService.apply(r, context: context, startDate: Date(), overrides: overrides)
        var expected = try expectedWeek1(fitted)
        expected[day.title]?.remove(at: 1)
        XCTAssertEqual(try seededWeek1(context), expected)
    }

    func test_legacyExerciseIdKeyedOverrides_stillApply() {
        let template = FullBody2DayTemplate.template
        let id = template.dayTemplates[0].exerciseTemplates[0].exerciseId
        let patched = DUPProgramSeeder.applying(
            overrides: PreviewOverrides(slotOverrides: [id: ExerciseWaveOverride(isDeleted: true)], addedByDay: [:]), to: template)
        XCTAssertNotEqual(patched.dayTemplates[0].exerciseTemplates.count, template.dayTemplates[0].exerciseTemplates.count)
    }

    // MARK: Time advice

    func test_sessionMinutesNeeded_roundsUpToFive_notFifteen() {
        func advice(_ minimum: Int) -> FitAdvice {
            FitAdvice(days: [FitAdvice.Day(dayNumber: 1, untrimmedMinutes: minimum, minimumMinutes: minimum)])
        }
        XCTAssertEqual(ProgramApplicationService.sessionMinutesNeeded(for: advice(63)), 65)   // 3 over a 60 budget asks for 65, not 75
        XCTAssertEqual(ProgramApplicationService.sessionMinutesNeeded(for: advice(65)), 65)
        XCTAssertEqual(ProgramApplicationService.sessionMinutesNeeded(for: advice(66)), 70)
        XCTAssertEqual(ProgramApplicationService.sessionMinutesNeeded(for: advice(120)), 120)
        XCTAssertNil(ProgramApplicationService.sessionMinutesNeeded(for: advice(121)))
        XCTAssertEqual(ProgramApplicationService.sessionMinutesNeeded(for: advice(10)), 30)
    }

    func test_sessionMinutesNeeded_isOnAFiveMinuteGrid_andClearsTheOverNote() {
        for days in 2...6 {
            let tight = result(days: days, preset: .dumbbellsBench, joints: [.knees], minutes: 45)
            let fit = ProgramApplicationService.fittedProgram(for: tight)
            guard fit.reasons.contains(where: { $0.kind == .overBudget }) else { continue }
            let needed = ProgramApplicationService.sessionMinutesNeeded(for: fit.advice)
            let n = try! XCTUnwrap(needed)
            XCTAssertEqual(n % 5, 0)
            XCTAssertGreaterThan(n, 45)
            var next = tight
            next.sessionLengthMinutes = n
            XCTAssertFalse(ProgramApplicationService.fittedProgram(for: next).reasons.contains { $0.kind == .overBudget }, "\(days) days at \(n) min")
        }
    }

    // MARK: - Prefill from the saved profile

    func test_noProfile_draftIsTodaysDefaults() {
        let draft = OnboardingDraft(profile: nil)
        XCTAssertEqual(draft, OnboardingDraft())
        XCTAssertEqual(draft.goal, .hypertrophy)
        XCTAssertEqual(draft.experience, .intermediate)
        XCTAssertEqual(draft.daysPerWeek, 4)
        XCTAssertEqual(draft.preset, .fullGym)
        XCTAssertTrue(draft.checklist.isEmpty)
        XCTAssertNil(draft.sessionLengthMinutes, "new profiles start with no limit")
        XCTAssertEqual(draft.loadIncrement, 2.5)
        XCTAssertTrue(draft.injuryFlags.isEmpty)
    }

    func test_savedProfile_tappingStraightThrough_leavesResultUnchanged() throws {
        let context = try makeContext()
        let saved = OnboardingResult(
            goal: .strength, experience: .new, daysPerWeek: 4,
            trainingDaysOfWeek: Self.weekdays(4), equipmentProfile: EquipmentPreset.homeBarbell.legacyProfile,
            sessionLengthMinutes: 75, injuryFlags: [.lowBack, .shoulders, .hips], minLoadIncrement: 5,
            startDate: Date(), equipmentPreset: .homeBarbell, equipmentChecklist: [.barbell, .dumbbell, .bench]
        )
        ProgramApplicationService.writeUserProfile(from: saved, context: context)
        let profile = try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first)

        let again = OnboardingDraft(profile: profile).result(startDate: saved.startDate)
        XCTAssertEqual(again.goal, saved.goal)
        XCTAssertEqual(again.experience, saved.experience)
        XCTAssertEqual(again.daysPerWeek, saved.daysPerWeek)
        XCTAssertEqual(again.trainingDaysOfWeek, saved.trainingDaysOfWeek)
        XCTAssertEqual(again.equipmentProfile, saved.equipmentProfile)
        XCTAssertEqual(again.sessionLengthMinutes, saved.sessionLengthMinutes)
        XCTAssertEqual(Set(again.injuryFlags), Set(saved.injuryFlags))
        XCTAssertEqual(again.minLoadIncrement, saved.minLoadIncrement)
        XCTAssertEqual(again.equipmentPreset, saved.equipmentPreset)
        XCTAssertEqual(Set(again.equipmentChecklist), Set(saved.equipmentChecklist))
    }

    func test_savedProfile_withDefaultChecklist_roundTripsAsEmpty() throws {
        let context = try makeContext()
        ProgramApplicationService.writeUserProfile(from: result(preset: .machinesOnly, joints: [.hips]), context: context)
        let profile = try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first)
        let again = OnboardingDraft(profile: profile).result(startDate: Date())
        XCTAssertEqual(again.equipmentPreset, .machinesOnly)
        XCTAssertTrue(again.equipmentChecklist.isEmpty)
        XCTAssertEqual(again.injuryFlags, [.hips])
    }

    // MARK: Schedule page

    func test_chipCountNotEqualToStepper_blocksNext() {
        for days in 2...6 {
            for chips in 0...7 where chips != days {
                let picked = Set(Array(1...7).prefix(chips))
                XCTAssertFalse(OnboardingDraft.scheduleIsComplete(weekdays: picked, daysPerWeek: days), "\(chips) chips vs \(days)")
                XCTAssertEqual(OnboardingDraft.scheduleMessage(weekdays: picked, daysPerWeek: days), "Select \(days) days")
            }
            let matching = OnboardingDraft.defaultTrainingDays(for: days)
            XCTAssertTrue(OnboardingDraft.scheduleIsComplete(weekdays: matching, daysPerWeek: days))
            XCTAssertNil(OnboardingDraft.scheduleMessage(weekdays: matching, daysPerWeek: days))
        }
    }

    func test_defaultPatternForEachStepperValue_hasThatManyDays() {
        for days in 2...6 { XCTAssertEqual(OnboardingDraft.defaultTrainingDays(for: days).count, days) }
        // 3 days is Mon/Wed/Fri (Calendar weekdays 2, 4, 6).
        XCTAssertEqual(OnboardingDraft.defaultTrainingDays(for: 3), [2, 4, 6])
    }

    // MARK: Seeding failure is visible

    func test_apply_withWrongWeekdayCount_failsWithReason_andWritesNothing() throws {
        let context = try makeContext()
        // A good program first, so "nothing changed" means the existing one survives.
        XCTAssertNoThrow(try ProgramApplicationService.apply(result(days: 4), context: context, startDate: Date()).get())
        let sessionsBefore = try context.fetchCount(FetchDescriptor<Session>())
        let blocksBefore = try context.fetch(FetchDescriptor<MesoBlock>()).map(\.status)
        XCTAssertGreaterThan(sessionsBefore, 0)

        var bad = result(days: 4, joints: [.wrists])
        bad.trainingDaysOfWeek = [2]   // one chip left selected
        let outcome = ProgramApplicationService.apply(bad, context: context, startDate: Date())

        guard case .failure(let error) = outcome else { return XCTFail("a 1-day schedule must not seed") }
        XCTAssertTrue(error.message.contains("4"), error.message)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), sessionsBefore, "existing sessions untouched")
        XCTAssertEqual(try context.fetch(FetchDescriptor<MesoBlock>()).map(\.status), blocksBefore, "existing meso not archived")
        let profile = try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertTrue(profile.injuryFlags.isEmpty, "profile must not take the failed answers")
    }

    func test_apply_onEmptyStore_withWrongWeekdayCount_writesNoProfile() throws {
        let context = try makeContext()
        var bad = result(days: 4)
        bad.trainingDaysOfWeek = [2]
        guard case .failure = ProgramApplicationService.apply(bad, context: context, startDate: Date()) else { return XCTFail() }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserProfile>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
    }

    // MARK: Reason text names the joints

    private func fitResult(kept: Int) -> FitResult {
        let template = ProgramApplicationService.selectTemplate(goal: .hypertrophy, daysPerWeek: 4)
        let reasons = (0..<kept).map { FitReason(kind: .keptStressed, dayNumber: 1, slotIndex: $0, message: "kept") }
        return FitResult(template: template, reasons: reasons, advice: FitAdvice(days: []))
    }

    func test_reason_namesFlaggedJoints() {
        let text = ProgramApplicationService.recommendationReason(goal: .hypertrophy, daysPerWeek: 4,
                                                                  injuries: [.knees, .lowBack], fit: fitResult(kept: 0))
        XCTAssertTrue(text.contains("lower back and knees"), text)
    }

    func test_reason_withFlags_saysWhenSomethingIsTheLowestStressOptionAvailable() {
        let kept = ProgramApplicationService.recommendationReason(goal: .hypertrophy, daysPerWeek: 4,
                                                                  injuries: [.knees], fit: fitResult(kept: 2))
        XCTAssertTrue(kept.contains("2 exercises are the lowest-stress option your equipment allows for your knees"), kept)
        XCTAssertFalse(kept.contains("without joint stress"), kept)
        let clean = ProgramApplicationService.recommendationReason(goal: .hypertrophy, daysPerWeek: 4,
                                                                   injuries: [.knees], fit: fitResult(kept: 0))
        XCTAssertTrue(clean.contains("your knees"), clean)
        XCTAssertFalse(clean.contains("lowest-stress option your equipment allows"), clean)
    }

    /// No flags: no joint wording at all, for every day count and goal, through the real fit.
    func test_reason_noFlags_containsNoJointWording() {
        for goal in Goal.allCases {
            for days in 2...6 {
                let r = result(days: days)
                let fit = ProgramApplicationService.fittedProgram(for: r)
                let text = ProgramApplicationService.recommendationReason(goal: goal, daysPerWeek: days, injuries: [], fit: fit)
                XCTAssertFalse(text.lowercased().contains("joint"), "\(goal) \(days)d: \(text)")
                XCTAssertFalse(ProgramApplicationService.recommendationReason(goal: goal, daysPerWeek: days).lowercased().contains("joint"))
            }
        }
    }

    func test_reason_withoutFlags_isTheBlurbPlusTheGoalSentence() {
        let text = ProgramApplicationService.recommendationReason(goal: .hypertrophy, daysPerWeek: 4, injuries: [], fit: fitResult(kept: 0))
        XCTAssertEqual(text, ProgramApplicationService.recommendationReason(goal: .hypertrophy, daysPerWeek: 4)
                       + "\n\n" + ProgramApplicationService.goalSentence(.hypertrophy))
    }

    // MARK: Welcome sheet and Today routing

    @MainActor
    func test_appRoute_restoreOpensSettings_andOnboardingRequestsAreCounted() {
        let route = AppRoute()
        route.openRestore()
        XCTAssertEqual(route.selectedTab, AppRoute.Tab.settings.rawValue)
        XCTAssertTrue(route.restoreRequested)
        let before = route.onboardingRequests
        route.openOnboarding()
        route.openOnboarding()
        XCTAssertEqual(route.onboardingRequests, before + 2)
    }
}

// MARK: - Session length: "No limit" is nil

final class SessionLengthNoLimitTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    func test_newProfile_defaultsToNoLimit() {
        XCTAssertNil(UserProfile().sessionLengthMinutes)
    }

    func test_existingStoredValue_isKept_notMigrated() throws {
        let context = try makeContext()
        context.insert(UserProfile(sessionLengthMinutes: 45))
        try context.save()
        let profile = try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertEqual(profile.sessionLengthMinutes, 45)
        // re-onboarding with a pre-filled draft keeps the number until the lifter changes it
        XCTAssertEqual(OnboardingDraft(profile: profile).sessionLengthMinutes, 45)
    }

    func test_onboardingResult_withNoLimit_writesNilToTheProfile() throws {
        let context = try makeContext()
        context.insert(UserProfile(sessionLengthMinutes: 45))
        var result = OnboardingResult(goal: .hypertrophy, experience: .intermediate, daysPerWeek: 4,
                                      trainingDaysOfWeek: [2, 3, 5, 6], equipmentProfile: .commercial,
                                      sessionLengthMinutes: nil, injuryFlags: [], minLoadIncrement: 2.5, startDate: Date())
        result.sessionLengthMinutes = nil
        XCTAssertNoThrow(try ProgramApplicationService.apply(result, context: context, startDate: Date()).get())
        XCTAssertNil(try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first).sessionLengthMinutes)
        // and the result survives its own Codable round trip
        let data = try JSONEncoder().encode(result)
        XCTAssertNil(try JSONDecoder().decode(OnboardingResult.self, from: data).sessionLengthMinutes)
    }

    /// No limit: no time trimming of any kind and no over-budget note, for every template, preset and goal.
    func test_noLimit_neverTrims_andNeverReportsOverBudget() {
        let timeKinds: Set<FitReason.Kind> = [.trimmedSets, .droppedForTime, .overBudget]
        for template in ExerciseTraitsCoverageTests.templates {
            for preset in ExerciseTraitsCoverageTests.presets {
                for goal in Goal.allCases {
                    let p = FitProfile(equipment: preset.defaultEquipment, injuries: [], sessionMinutes: nil, experience: .advanced, goal: goal)
                    let r = ProgramFitter.fit(template, profile: p)
                    XCTAssertFalse(r.reasons.contains { timeKinds.contains($0.kind) }, "\(template.name) \(preset) \(goal)")
                    // every slot keeps all its weeks' sets exactly as the (goal-adjusted, equipment-fitted) slot had them
                    let untimed = FitProfile(equipment: preset.defaultEquipment, injuries: [], sessionMinutes: nil, experience: .advanced, goal: goal)
                    XCTAssertEqual(r.template.dayTemplates.flatMap(\.exerciseTemplates).map(\.setsByWeek),
                                   ProgramFitter.fit(template, profile: untimed).template.dayTemplates.flatMap(\.exerciseTemplates).map(\.setsByWeek))
                }
            }
        }
    }

    func test_aLimit_stillTrims() {
        let p = FitProfile(equipment: Set(GearTag.allCases), injuries: [], sessionMinutes: 30, experience: .intermediate)
        let r = ProgramFitter.fit(UpperLower4DayTemplate.template, profile: p)
        XCTAssertTrue(r.reasons.contains { $0.kind == .droppedForTime || $0.kind == .trimmedSets || $0.kind == .overBudget })
    }

    // MARK: Backup round trip

    private func roundTrip(minutes: Int?) throws -> UserProfile {
        let source = ModelContext(try BackupTestSupport.makeContainer())
        source.insert(UserProfile(sessionLengthMinutes: minutes))
        try source.save()
        let targetContainer = try BackupTestSupport.makeContainer()
        try BackupTestSupport.restore(from: source, into: targetContainer)
        return try XCTUnwrap(try ModelContext(targetContainer).fetch(FetchDescriptor<UserProfile>()).first)
    }

    func test_backupRoundTrip_noLimit() throws {
        XCTAssertNil(try roundTrip(minutes: nil).sessionLengthMinutes)
    }

    func test_backupRoundTrip_45() throws {
        XCTAssertEqual(try roundTrip(minutes: 45).sessionLengthMinutes, 45)
    }

    func test_exportCarriesTheUnlimitedFlag_onlyWhenThereIsNoLimit() throws {
        func profileJSON(_ minutes: Int?) throws -> [String: Any] {
            let ctx = ModelContext(try BackupTestSupport.makeContainer())
            ctx.insert(UserProfile(sessionLengthMinutes: minutes))
            try ctx.save()
            return try XCTUnwrap(try BackupTestSupport.exportJSON(ctx)["userProfile"] as? [String: Any])
        }
        let none = try profileJSON(nil)
        XCTAssertEqual(none["sessionLengthUnlimited"] as? Bool, true)
        XCTAssertNil(none["sessionLengthMinutes"])
        let forty = try profileJSON(45)
        XCTAssertNil(forty["sessionLengthUnlimited"])
        XCTAssertEqual(forty["sessionLengthMinutes"] as? Int, 45)
    }

    /// A backup written before the key existed (no minutes, no flag) restores as 60, as it always did.
    func test_oldBackupWithoutTheKey_restoresAs60() throws {
        let source = ModelContext(try BackupTestSupport.makeContainer())
        source.insert(UserProfile(sessionLengthMinutes: 45))
        try source.save()
        let url = try BackupTestSupport.exportFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var profile = try XCTUnwrap(json["userProfile"] as? [String: Any])
        profile.removeValue(forKey: "sessionLengthMinutes")
        profile.removeValue(forKey: "sessionLengthUnlimited")
        json["userProfile"] = profile
        let old = FileManager.default.temporaryDirectory.appendingPathComponent("old_\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: old)
        defer { try? FileManager.default.removeItem(at: old) }
        let target = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: old, modelContainer: target)
        XCTAssertEqual(try XCTUnwrap(try ModelContext(target).fetch(FetchDescriptor<UserProfile>()).first).sessionLengthMinutes, 60)
    }
}
