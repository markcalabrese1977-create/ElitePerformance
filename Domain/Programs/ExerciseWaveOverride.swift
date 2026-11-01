import Foundation

struct WavePrescriptionOverride: Equatable {
    let repMin: Int
    let repMax: Int
    let targetRIR: Int
}

struct ExerciseWaveOverride: Equatable {
    /// nil means "keep the template's original exercise for this slot"
    let substituteExerciseId: String?
    /// nil means "use template default for this exercise"
    let wavePrescriptions: [WaveType: WavePrescriptionOverride]?
    let setsByWeek: [Int]?
    let isDeleted: Bool

    init(
        substituteExerciseId: String? = nil,
        wavePrescriptions: [WaveType: WavePrescriptionOverride]? = nil,
        setsByWeek: [Int]? = nil,
        isDeleted: Bool = false
    ) {
        self.substituteExerciseId = substituteExerciseId
        self.wavePrescriptions = wavePrescriptions
        self.setsByWeek = setsByWeek
        self.isDeleted = isDeleted
    }
}

/// A net-new exercise added by the user to a day, before seeding.
/// `id` is a stable per-instance UUID — the same catalog exercise can be added
/// twice to the same day and both will have distinct ids.
struct AddedExercise: Equatable, Identifiable {
    let id: String
    let exerciseId: String
    let priority: ExercisePriority
    let wavePrescriptions: [WaveType: WavePrescriptionOverride]
    let setsByWeek: [Int]

    static let defaultSetsByWeek: [Int] = [3, 3, 3, 3, 4, 4, 3, 4, 4, 2]
    static let defaultWavePrescriptions: [WaveType: WavePrescriptionOverride] = [
        .a: WavePrescriptionOverride(repMin: 8, repMax: 12, targetRIR: 3),
        .b: WavePrescriptionOverride(repMin: 8, repMax: 12, targetRIR: 2),
        .c: WavePrescriptionOverride(repMin: 6, repMax: 10, targetRIR: 1)
    ]
}

/// Addresses one slot of a (fitted) template: its day id and its position in that day's exercise list.
/// Position, not exerciseId, so a template that repeats an exercise across days (DUP10 repeats 5 ids, Hybrid5 4)
/// overrides exactly the slot the user touched.
struct SlotKey: Hashable {
    let dayId: String
    let slotIndex: Int
}

/// Replaces ExerciseOverrideMap as the single currency passed through the pipeline.
/// `slotKeyed` carries per-slot swap/customize/delete flags keyed by (day, slot index) of the template the
/// overrides are applied to (the fitted template). `slotOverrides` is the older exerciseId-keyed form, kept for
/// tests and callers that do not need slot precision: it applies to every slot with that exerciseId, and a
/// slot-keyed entry wins over it. `addedByDay` carries net-new exercises keyed by dayId.
struct PreviewOverrides: Equatable {
    var slotOverrides: [String: ExerciseWaveOverride]
    var addedByDay: [String: [AddedExercise]]
    var slotKeyed: [SlotKey: ExerciseWaveOverride] = [:]

    /// The override for the slot at `index` of `day`: slot-keyed first, then the exerciseId-keyed form.
    func override(dayId: String, slotIndex: Int, exerciseId: String) -> ExerciseWaveOverride? {
        slotKeyed[SlotKey(dayId: dayId, slotIndex: slotIndex)] ?? slotOverrides[exerciseId]
    }

    static let empty = PreviewOverrides(slotOverrides: [:], addedByDay: [:])
}

/// Keyed by exerciseId. Retained for internal test convenience.
typealias ExerciseOverrideMap = [String: ExerciseWaveOverride]

extension PreviewOverrides {
    /// Appends `ex` to the given day's added-exercise list, idempotent by `ex.id`.
    /// Calling this multiple times with the same instance id is safe — subsequent
    /// calls after the first are no-ops. This guards against the onDisappear
    /// auto-commit firing more than once during sheet-transition flicker.
    mutating func addExercise(_ ex: AddedExercise, toDay dayId: String) {
        var exercises = addedByDay[dayId] ?? []
        guard !exercises.contains(where: { $0.id == ex.id }) else { return }
        exercises.append(ex)
        addedByDay[dayId] = exercises
    }
}

extension ExerciseWaveOverride {
    /// Returns a new override with `substituteExerciseId` replaced; all other fields preserved.
    func applyingSubstitute(_ id: String) -> ExerciseWaveOverride {
        ExerciseWaveOverride(substituteExerciseId: id, wavePrescriptions: wavePrescriptions, setsByWeek: setsByWeek, isDeleted: isDeleted)
    }

    /// Returns a new override with prescription fields replaced; `substituteExerciseId` and `isDeleted` preserved.
    func applyingPrescription(wavePrescriptions: [WaveType: WavePrescriptionOverride]?, setsByWeek: [Int]?) -> ExerciseWaveOverride {
        ExerciseWaveOverride(substituteExerciseId: substituteExerciseId, wavePrescriptions: wavePrescriptions, setsByWeek: setsByWeek, isDeleted: isDeleted)
    }

    /// Returns an override with prescription fields cleared; `substituteExerciseId` and `isDeleted` preserved.
    var prescriptionCleared: ExerciseWaveOverride {
        ExerciseWaveOverride(substituteExerciseId: substituteExerciseId, isDeleted: isDeleted)
    }

    /// Returns an override flagged for soft-deletion; all other fields preserved.
    var markedDeleted: ExerciseWaveOverride {
        ExerciseWaveOverride(substituteExerciseId: substituteExerciseId, wavePrescriptions: wavePrescriptions, setsByWeek: setsByWeek, isDeleted: true)
    }

    /// Returns an override with the deletion flag cleared; all other fields preserved.
    var unmarkedDeleted: ExerciseWaveOverride {
        ExerciseWaveOverride(substituteExerciseId: substituteExerciseId, wavePrescriptions: wavePrescriptions, setsByWeek: setsByWeek, isDeleted: false)
    }
}
