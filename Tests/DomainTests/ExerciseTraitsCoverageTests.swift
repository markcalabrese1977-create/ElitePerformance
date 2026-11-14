import XCTest
import SwiftData
@testable import ElitePerformance

/// Guards the exercise traits table and the equipment presets it is judged against. A new built-in without
/// traits, a stale table entry, or a template slot the fitter could not cover under a preset fails here.
final class ExerciseTraitsCoverageTests: XCTestCase {

    /// Built-ins deliberately left without traits: never auto-chosen and never auto-judged.
    static let untagged: Set<String> = ["smith_machine_dip", "bench_back_extension"]

    static let presets: [EquipmentPreset] = [.fullGym, .homeBarbell, .dumbbellsBench, .machinesOnly]

    static let templates: [ProgramTemplate] = [
        DUP10WeekTemplate.template, FullBody2DayTemplate.template, Hybrid5DayTemplate.template,
        PPL3WeekTemplate.template, PPL6DayTemplate.template, UpperLower4DayTemplate.template
    ]

    private var builtInIds: [String] { ExerciseCatalog.builtIn.map(\.id) }

    // MARK: Table vs catalog

    func test_everyBuiltInHasTraits_exceptTheExplicitUntaggedList() {
        let missing = builtInIds.filter {
            ExerciseTraits.table[$0] == nil && !Self.untagged.contains($0)
        }
        XCTAssertEqual(missing, [], "built-ins with no traits and not on the untagged list")
    }

    func test_untaggedList_hasNoStaleEntries() {
        let ids = Set(builtInIds)
        for id in Self.untagged {
            XCTAssertTrue(ids.contains(id), "untagged entry \(id) is not a built-in any more")
            XCTAssertNil(ExerciseTraits.table[id], "\(id) is on the untagged list but has traits")
        }
    }

    func test_traitsTable_hasNoStaleEntries() {
        let ids = Set(builtInIds)
        let stale = ExerciseTraits.table.keys.filter { !ids.contains($0) }.sorted()
        XCTAssertEqual(stale, [], "traits for ids that are not built-ins")
    }

    func test_customExercisesNeverHaveTraits() {
        XCTAssertNil(ExerciseTraits.traits(for: "custom_00000000-0000-0000-0000-000000000000"))
    }

    // MARK: Template coverage

    func test_everyTemplateSlot_underEveryPreset_hasASamePatternOrSameMuscleOption() {
        var failures: [String] = []
        for template in Self.templates {
            for day in template.dayTemplates {
                for slot in day.exerciseTemplates {
                    guard let traits = ExerciseTraits.traits(for: slot.exerciseId) else {
                        XCTAssertTrue(Self.untagged.contains(slot.exerciseId),
                                      "\(template.id)/\(day.title): \(slot.exerciseId) has no traits and is not on the untagged list")
                        continue
                    }
                    let muscle = ExerciseCatalog.all.first { $0.id == slot.exerciseId }?.primaryMuscle
                    for preset in Self.presets {
                        let gear = preset.defaultEquipment
                        let option = ExerciseCatalog.builtIn.contains { candidate in
                            guard candidate.id != slot.exerciseId,
                                  let c = ExerciseTraits.table[candidate.id],
                                  c.isAvailable(with: gear) else { return false }
                            return c.pattern == traits.pattern || candidate.primaryMuscle == muscle
                        }
                        if !option {
                            failures.append("\(template.id)/\(day.title)/\(slot.exerciseId) under \(preset.rawValue)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(failures, [], "slots with no same-pattern or same-muscle tagged option")
    }

    func test_fullGym_runsEveryTaggedTemplateSlotAsWritten() {
        for template in Self.templates {
            for day in template.dayTemplates {
                for slot in day.exerciseTemplates {
                    guard let traits = ExerciseTraits.traits(for: slot.exerciseId) else { continue }
                    XCTAssertTrue(traits.isAvailable(with: EquipmentPreset.fullGym.defaultEquipment),
                                  "\(slot.exerciseId) needs gear fullGym lacks")
                }
            }
        }
    }

    // MARK: Gear rules

    func test_barbellPressAndSquatPatterns_requireRack() {
        let rackPatterns: Set<ExercisePattern> = [.horizontalPress, .verticalPress, .squat]
        // The landmine press anchors the bar in a corner or landmine attachment: barbell only, no rack.
        let noRackNeeded: Set<String> = ["landmine_press"]
        for (id, traits) in ExerciseTraits.table
        where traits.equipment.contains(.barbell) && rackPatterns.contains(traits.pattern) && !noRackNeeded.contains(id) {
            XCTAssertTrue(traits.equipment.contains(.rack), "\(id) is a barbell \(traits.pattern) and must require a rack")
        }
    }

    func test_landminePress_isBarbellOnly_verticalPress_withTheSpecifiedStress() {
        let t = ExerciseTraits.table["landmine_press"]
        XCTAssertEqual(t?.equipment, [.barbell])
        XCTAssertEqual(t?.pattern, .verticalPress)
        XCTAssertEqual(t?.jointStress, [.shoulders: 1, .elbows: 1, .wrists: 1])
        let c = ExerciseCatalog.builtIn.first { $0.id == "landmine_press" }
        XCTAssertEqual(c?.isCompound, true)
        XCTAssertEqual(c?.isBodyweight, false)
        XCTAssertEqual(c?.primaryMuscle, .shoulders)
    }

    func test_presetsAgreeOnRack() {
        XCTAssertTrue(EquipmentPreset.fullGym.defaultEquipment.contains(.rack))
        XCTAssertTrue(EquipmentPreset.homeBarbell.defaultEquipment.contains(.rack))
        XCTAssertFalse(EquipmentPreset.dumbbellsBench.defaultEquipment.contains(.rack))
        XCTAssertFalse(EquipmentPreset.machinesOnly.defaultEquipment.contains(.rack))
    }

    // MARK: Preset storage

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    func test_storedBodyweightPreset_mapsToDumbbellsBench() throws {
        let context = try makeContext()
        let profile = UserProfile()
        context.insert(profile)
        profile.equipmentPresetRaw = "bodyweight"
        XCTAssertEqual(profile.equipmentPreset, .dumbbellsBench)
    }

    func test_unsetPreset_derivesFromLegacyProfile_andEmptyMeansFullGym() throws {
        let context = try makeContext()
        let profile = UserProfile()
        context.insert(profile)
        XCTAssertEqual(profile.equipmentPreset, .fullGym)
        profile.equipmentProfile = .homeGym
        XCTAssertEqual(profile.equipmentPreset, .homeBarbell)
        profile.equipmentProfile = .dumbbellsOnly
        XCTAssertEqual(profile.equipmentPreset, .dumbbellsBench)
        XCTAssertEqual(profile.effectiveEquipment, EquipmentPreset.dumbbellsBench.defaultEquipment)
        profile.equipmentChecklist = [.dumbbell]
        XCTAssertEqual(profile.effectiveEquipment, [.dumbbell])
    }

    func test_settingAPreset_clearsOnLegacyChange() throws {
        let context = try makeContext()
        let profile = UserProfile()
        context.insert(profile)
        profile.equipmentPreset = .machinesOnly
        XCTAssertEqual(profile.equipmentPreset, .machinesOnly)
        profile.equipmentProfile = .homeGym
        XCTAssertEqual(profile.equipmentPreset, .homeBarbell, "a direct legacy change supersedes a stored preset")
    }

    // MARK: Catalog names

    private static let newBuiltIns = [
        "barbell_back_squat", "barbell_overhead_press", "barbell_hip_thrust", "dumbbell_romanian_deadlift",
        "dumbbell_single_leg_calf_raise", "bodyweight_calf_raise", "dumbbell_pullover", "landmine_press"
    ]

    private func folded(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func test_builtInIdsAndNames_areUnique() {
        let ids = builtInIds
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate built-in ids")
        let names = ExerciseCatalog.builtIn.map { folded($0.name) }
        XCTAssertEqual(names.count, Set(names).count, "duplicate built-in names (case-insensitive)")
        for id in Self.newBuiltIns {
            XCTAssertTrue(ids.contains(id), "\(id) is not in builtIn")
        }
    }

    /// Needs TEST_RUNNER_EP_BACKUP_FIXTURE (the newest backup): none of the built-ins added with the fitter may
    /// collide (id or case-insensitive name) with a custom exercise in it, since addCustomExercise hands back the
    /// built-in when names match. Collisions with older built-ins are reported, not failed: they predate this work.
    func test_newBuiltIns_doNotCollideWithCustomExercisesInTheLatestBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BackupSnapshotV1.self, from: data)
        let customs = snapshot.customExercises
        print("TRAITS| fixture customs: \(customs.count)")

        let byName = Dictionary(grouping: ExerciseCatalog.builtIn, by: { folded($0.name) })
        let newIds = Set(Self.newBuiltIns)
        var collisionsWithNew: [String] = []
        var collisionsWithOlder: [String] = []
        for custom in customs {
            var hits = (byName[folded(custom.name)] ?? []).map(\.id)
            if builtInIds.contains(custom.id) { hits.append(custom.id) }
            for hit in hits {
                let line = "custom '\(custom.name)' ~ built-in \(hit)"
                if newIds.contains(hit) { collisionsWithNew.append(line) } else { collisionsWithOlder.append(line) }
            }
        }
        print("TRAITS| collisions with the \(newIds.count) new built-ins: \(collisionsWithNew.count); with older built-ins: \(collisionsWithOlder.count) \(collisionsWithOlder)")
        // Known and tracked in BACKLOG.md: the latest backup has a custom "Landmine Press" (shoulders, compound) that
        // shares a name with the landmine_press built-in. The one-shot dedup migration has already run on existing
        // installs, so it is not merged automatically. Any OTHER collision, or this one disappearing, fails here.
        let known = ["custom 'Landmine Press' ~ built-in landmine_press"]
        XCTAssertEqual(collisionsWithNew, known, "custom exercises in the backup that collide with a new built-in")
    }
}
