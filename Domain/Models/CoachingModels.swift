import Foundation

/// Overall readiness/fatigue snapshot for the day.
/// These are 1–10 or 1–5 scales that *you* control from the UI.
public struct DayReadiness: Equatable {
    public let fatigue: Int           // e.g. 1–10
    public let sleepQuality: Int      // e.g. 1–5
    public let stress: Int            // e.g. 1–5

    public init(
        fatigue: Int = 5,
        sleepQuality: Int = 3,
        stress: Int = 3
    ) {
        self.fatigue = fatigue
        self.sleepQuality = sleepQuality
        self.stress = stress
    }
}

/// Minimal context the coach needs to make a decision about a single set.
/// This is deliberately generic so we can map your real models into it later.
public struct SetContext: Equatable {
    /// Stable identifier for the exercise (can map from your Exercise/Session models later).
    public let exerciseId: UUID

    /// Week number within the mesocycle (1–7, where 7 may be deload).
    public let weekInMeso: Int

    /// Index of this set within the exercise for today (0-based: 0,1,2,3).
    public let setIndex: Int

    /// How many sets are currently planned for this exercise today.
    public let plannedSetCount: Int

    /// Planned load (e.g. lbs or kg). Optional if not specified.
    public let plannedLoad: Double?

    /// Planned reps for this set.
    public let plannedReps: Int?

    /// Actual load used (after execution).
    public let actualLoad: Double?

    /// Actual reps performed.
    public let actualReps: Int?

    /// Target RIR for this set (e.g. 1–3).
    public let targetRIR: Double?

    /// RIR you actually felt on this set.
    public let actualRIR: Double?

    /// Pain for this movement right now (0–10). Optional.
    public let painScore: Int?

    /// Global or local fatigue as perceived on this set (1–10). Optional.
    public let setFatigueScore: Int?

    public init(
        exerciseId: UUID,
        weekInMeso: Int,
        setIndex: Int,
        plannedSetCount: Int,
        plannedLoad: Double?,
        plannedReps: Int?,
        actualLoad: Double?,
        actualReps: Int?,
        targetRIR: Double?,
        actualRIR: Double?,
        painScore: Int?,
        setFatigueScore: Int?
    ) {
        self.exerciseId = exerciseId
        self.weekInMeso = weekInMeso
        self.setIndex = setIndex
        self.plannedSetCount = plannedSetCount
        self.plannedLoad = plannedLoad
        self.plannedReps = plannedReps
        self.actualLoad = actualLoad
        self.actualReps = actualReps
        self.targetRIR = targetRIR
        self.actualRIR = actualRIR
        self.painScore = painScore
        self.setFatigueScore = setFatigueScore
    }
}

/// How the coach thinks you should adjust based on this set.
public enum SetAdjustment: Equatable {
    /// Keep everything the same next time (load/sets).
    case keepSame

    /// Increase load by a given percentage next session.
    case increaseLoad(percentage: Double)

    /// Decrease load by a given percentage next session.
    case decreaseLoad(percentage: Double)

    /// Maintain load but push reps a bit more next time.
    case pushForMoreReps

    /// Reduce reps or stop short of failure next time.
    case easeOffReps

    /// Add an optional test set (4th set) today.
    case addTestSetNow

    /// Skip the optional test set today.
    case skipTestSetNow

    /// Reduce total working sets for this movement (e.g. 4 → 3, or 3 → 2).
    case reduceSetCount

    /// Increase total working sets (e.g. 3 → 4) on good days.
    case increaseSetCount
}

/// A single human-readable recommendation for the user + app.
/// This is what the UI will display and what we can later write forward into future sessions.
public struct SetRecommendation: Equatable {
    public let adjustment: SetAdjustment
    public let rationale: String

    public init(adjustment: SetAdjustment, rationale: String) {
        self.adjustment = adjustment
        self.rationale = rationale
    }
}
