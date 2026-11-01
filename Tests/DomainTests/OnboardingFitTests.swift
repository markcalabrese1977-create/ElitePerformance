import XCTest
import SwiftData
@testable import ElitePerformance

/// Onboarding collects equipment and joints, the preview shows the fitted program, and seeding runs the same fit.
final class OnboardingFitTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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

    func test_sessionMinutesNeeded_isOnTheStepperGrid_andClearsTheOverNote() {
        for days in 2...6 {
            let tight = result(days: days, preset: .dumbbellsBench, joints: [.knees], minutes: 45)
            let fit = ProgramApplicationService.fittedProgram(for: tight)
            guard fit.reasons.contains(where: { $0.kind == .overBudget }) else { continue }
            let needed = ProgramApplicationService.sessionMinutesNeeded(for: fit.advice)
            let n = try! XCTUnwrap(needed)
            XCTAssertEqual(n % 15, 0)
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
        XCTAssertEqual(draft.sessionLengthMinutes, 60)
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
}
