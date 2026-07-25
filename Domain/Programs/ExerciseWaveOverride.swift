import Foundation

struct WavePrescriptionOverride: Equatable {
    let repMin: Int
    let repMax: Int
    let targetRIR: Int
}

struct ExerciseWaveOverride: Equatable {
    /// nil means "use template default for this exercise"
    let wavePrescriptions: [WaveType: WavePrescriptionOverride]?
    let setsByWeek: [Int]?
}

/// Keyed by exerciseId.
typealias ExerciseOverrideMap = [String: ExerciseWaveOverride]
