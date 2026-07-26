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

    init(
        substituteExerciseId: String? = nil,
        wavePrescriptions: [WaveType: WavePrescriptionOverride]? = nil,
        setsByWeek: [Int]? = nil
    ) {
        self.substituteExerciseId = substituteExerciseId
        self.wavePrescriptions = wavePrescriptions
        self.setsByWeek = setsByWeek
    }
}

/// Keyed by exerciseId.
typealias ExerciseOverrideMap = [String: ExerciseWaveOverride]

extension ExerciseWaveOverride {
    /// Returns a new override with `substituteExerciseId` replaced; prescription fields are preserved.
    func applyingSubstitute(_ id: String) -> ExerciseWaveOverride {
        ExerciseWaveOverride(substituteExerciseId: id, wavePrescriptions: wavePrescriptions, setsByWeek: setsByWeek)
    }

    /// Returns a new override with prescription fields replaced; `substituteExerciseId` is preserved.
    func applyingPrescription(wavePrescriptions: [WaveType: WavePrescriptionOverride]?, setsByWeek: [Int]?) -> ExerciseWaveOverride {
        ExerciseWaveOverride(substituteExerciseId: substituteExerciseId, wavePrescriptions: wavePrescriptions, setsByWeek: setsByWeek)
    }

    /// Returns an override with prescription fields cleared; `substituteExerciseId` is preserved.
    var prescriptionCleared: ExerciseWaveOverride {
        ExerciseWaveOverride(substituteExerciseId: substituteExerciseId)
    }
}
