import Foundation

struct ExerciseExposure {
    let date: Date
    let waveRaw: String?

    let repMin: Int?
    let repMax: Int?

    let rirMin: Int?
    let rirMax: Int?

    let load: Double
    let reps: Int
    let rir: Int?
}

struct ComparisonReference {
    let exposure: ExerciseExposure
    let score: Int
}

enum WaveAwareComparisonEngine {
    static func bestReference(
        current: ExerciseExposure,
        prior: [ExerciseExposure]
    ) -> ComparisonReference? {
        let ranked = prior
            .map { candidate in
                ComparisonReference(
                    exposure: candidate,
                    score: score(candidate: candidate, current: current)
                )
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.exposure.date > rhs.exposure.date
            }

        return ranked.first
    }

    static func displayWave(_ raw: String?) -> String? {
        guard let raw else { return nil }

        switch raw.lowercased() {
        case "a":
            return "Strength"
        case "b":
            return "Hypertrophy"
        case "c":
            return "Intensification"
        case "deload":
            return "Deload"
        default:
            return raw.capitalized
        }
    }

    private static func score(candidate: ExerciseExposure, current: ExerciseExposure) -> Int {
        var score = 0

        if normalized(candidate.waveRaw) == normalized(current.waveRaw),
           normalized(current.waveRaw) != nil {
            score += 100
        }

        if rangesOverlap(
            minA: candidate.repMin, maxA: candidate.repMax,
            minB: current.repMin, maxB: current.repMax
        ) {
            score += 35
        }

        if rangesOverlap(
            minA: candidate.rirMin, maxA: candidate.rirMax,
            minB: current.rirMin, maxB: current.rirMax
        ) {
            score += 20
        }

        let daysApart = abs(Calendar.current.dateComponents([.day], from: candidate.date, to: current.date).day ?? 999)
        score += max(0, 20 - min(daysApart, 20))

        return score
    }

    private static func normalized(_ raw: String?) -> String? {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func rangesOverlap(
        minA: Int?, maxA: Int?,
        minB: Int?, maxB: Int?
    ) -> Bool {
        guard let minA, let maxA, let minB, let maxB else { return false }
        return max(minA, minB) <= min(maxA, maxB)
    }
}
