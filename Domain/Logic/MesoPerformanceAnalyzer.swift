// Domain/Logic/MesoPerformanceAnalyzer.swift
import Foundation

// MARK: - Output Types

/// Performance verdict for a single exercise across the meso.
enum ExerciseVerdict {
    /// Load or e1RM increased meaningfully across the meso.
    case progressing
    /// Load or e1RM was flat — no meaningful change.
    case plateaued
    /// Load or e1RM declined over the meso.
    case declining
    /// Not enough data to assess (fewer than 2 sessions with this exercise).
    case insufficient
}

/// Weekly volume summary for the meso.
struct WeeklyVolumeSummary {
    let weekIndex: Int
    let totalVolume: Double      // sum(load × reps) across all completed sets
    let completedSets: Int
}

/// Per-exercise summary across the full meso.
struct ExercisePerformanceSummary {
    let exerciseId: String
    let exerciseName: String
    let primaryMuscle: String?

    /// e1RM per session, in chronological order.
    let e1rmBySession: [(weekIndex: Int, date: Date, e1rm: Double)]

    /// Best e1RM achieved this meso.
    let peakE1RM: Double?

    /// Load used in the first session this meso.
    let openingLoad: Double?

    /// Load used in the last session this meso.
    let closingLoad: Double?

    /// Performance verdict across the meso.
    let verdict: ExerciseVerdict

    /// Whether this exercise set a new e1RM record (vs all prior mesos).
        let isPR: Bool

        /// Total completed sets for this exercise across the meso.
        let totalSets: Int

        /// Total completed reps for this exercise across the meso.
        let totalReps: Int

        /// Total volume (load × reps) for this exercise across the meso.
        let totalVolume: Double
}

/// Full end-of-meso analysis result.
struct MesoAnalysis {
    let mesoName: String
    let totalWeeks: Int
    let completedSessions: Int
    let totalVolume: Double
    let totalSets: Int
    let totalReps: Int

    /// Volume per week — used for the ramp chart.
    let weeklyVolume: [WeeklyVolumeSummary]

    /// Per-exercise summaries, sorted by primary muscle then exercise name.
    let exerciseSummaries: [ExercisePerformanceSummary]

    /// Overall meso verdict — derived from exercise verdicts.
    var overallVerdict: ExerciseVerdict {
        let verdicts = exerciseSummaries.map { $0.verdict }
        let progressing = verdicts.filter { $0 == .progressing }.count
        let declining = verdicts.filter { $0 == .declining }.count
        let total = verdicts.filter { $0 != .insufficient }.count
        guard total > 0 else { return .insufficient }
        if Double(progressing) / Double(total) >= 0.6 { return .progressing }
        if Double(declining) / Double(total) >= 0.5 { return .declining }
        return .plateaued
    }

    /// Coach-written narrative for the overall verdict.
    var verdictNarrative: String {
        switch overallVerdict {
        case .progressing:
            return "Strong meso. Load moved on most exercises and your e1RM trend was positive. You've built capacity — carry that into the next block."
        case .plateaued:
            return "Solid execution. Performance held steady across the meso. This is normal mid-program — the next block will give you room to climb again."
        case .declining:
            return "Fatigue accumulated this meso. Performance dropped on several exercises. A maintenance or deload phase before the next accumulation block is the right call."
        case .insufficient:
            return "Not enough completed sessions to assess this meso."
        }
    }
}

// MARK: - Analyzer

enum MesoPerformanceAnalyzer {

    /// Analyze a completed or near-complete meso block.
    ///
    /// - Parameters:
    ///   - meso: The meso block to analyze.
    ///   - allPriorSessions: Sessions from previous mesos — used for PR detection.
    /// - Returns: A `MesoAnalysis` if there are enough completed sessions, nil otherwise.
    static func analyze(
        meso: MesoBlock,
        allPriorSessions: [Session]
    ) -> MesoAnalysis? {
        let completedSessions = meso.sessions
            .filter { $0.status == .completed }
            .sorted { $0.date < $1.date }

        guard !completedSessions.isEmpty else { return nil }

        // MARK: - Totals

        var totalVolume: Double = 0
        var totalSets = 0
        var totalReps = 0

        for session in completedSessions {
            for item in session.items {
                let setCount = min(item.actualLoads.count, item.actualReps.count)
                for idx in 0..<setCount {
                    let load = item.actualLoads[idx]
                    let reps = item.actualReps[idx]
                    guard load > 0, reps > 0 else { continue }
                    totalVolume += load * Double(reps)
                    totalSets += 1
                    totalReps += reps
                }
            }
        }

        // MARK: - Weekly volume

        var volumeByWeek: [Int: (volume: Double, sets: Int)] = [:]
        for session in completedSessions {
            let week = session.weekIndex
            var weekVolume: Double = 0
            var weekSets = 0
            for item in session.items {
                let setCount = min(item.actualLoads.count, item.actualReps.count)
                for idx in 0..<setCount {
                    let load = item.actualLoads[idx]
                    let reps = item.actualReps[idx]
                    guard load > 0, reps > 0 else { continue }
                    weekVolume += load * Double(reps)
                    weekSets += 1
                }
            }
            let existing = volumeByWeek[week] ?? (0, 0)
            volumeByWeek[week] = (existing.volume + weekVolume, existing.sets + weekSets)
        }

        let weeklyVolume = volumeByWeek.keys.sorted().map { week in
            WeeklyVolumeSummary(
                weekIndex: week,
                totalVolume: volumeByWeek[week]!.volume,
                completedSets: volumeByWeek[week]!.sets
            )
        }

        // MARK: - Per-exercise analysis

        // Collect all exercise IDs that appeared in this meso
        var exerciseIds: [String] = []
        var seenIds = Set<String>()
        for session in completedSessions {
            for item in session.items {
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                if !seenIds.contains(canonical) {
                    seenIds.insert(canonical)
                    exerciseIds.append(canonical)
                }
            }
        }

        // Build prior e1RM peaks for PR detection
        var priorPeakE1RM: [String: Double] = [:]
        for session in allPriorSessions {
            for item in session.items {
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                let setCount = min(item.actualLoads.count, item.actualReps.count)
                for idx in 0..<setCount {
                    let load = item.actualLoads[idx]
                    let reps = item.actualReps[idx]
                    guard load > 0, reps > 0 else { continue }
                    let e1rm = E1RMCalculator.e1RM(load: load, reps: reps)
                    priorPeakE1RM[canonical] = max(priorPeakE1RM[canonical] ?? 0, e1rm)
                }
            }
        }

        var exerciseSummaries: [ExercisePerformanceSummary] = []

        for exerciseId in exerciseIds {
            // Collect sessions containing this exercise, chronologically
            let sessionsWithExercise: [(session: Session, item: SessionItem)] = completedSessions.compactMap { session in
                guard let item = session.items.first(where: {
                    ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == exerciseId
                }) else { return nil }
                return (session, item)
            }

            guard sessionsWithExercise.count >= 1 else { continue }

            // e1RM per session
            var e1rmBySession: [(weekIndex: Int, date: Date, e1rm: Double)] = []
            for (session, item) in sessionsWithExercise {
                let setCount = min(item.actualLoads.count, item.actualReps.count)
                var sessionPeak: Double = 0
                for idx in 0..<setCount {
                    let load = item.actualLoads[idx]
                    let reps = item.actualReps[idx]
                    guard load > 0, reps > 0 else { continue }
                    let e1rm = E1RMCalculator.e1RM(load: load, reps: reps)
                    sessionPeak = max(sessionPeak, e1rm)
                }
                if sessionPeak > 0 {
                    e1rmBySession.append((weekIndex: session.weekIndex, date: session.date, e1rm: sessionPeak))
                }
            }

            let peakE1RM = e1rmBySession.map { $0.e1rm }.max()

            // Opening and closing loads
            let openingLoad: Double? = {
                let first = sessionsWithExercise.first?.item
                let actuals = first?.actualLoads.filter { $0 > 0 } ?? []
                return actuals.first ?? (first?.suggestedLoad ?? 0 > 0 ? first?.suggestedLoad : nil)
            }()

            let closingLoad: Double? = {
                let last = sessionsWithExercise.last?.item
                let actuals = last?.actualLoads.filter { $0 > 0 } ?? []
                return actuals.first ?? (last?.suggestedLoad ?? 0 > 0 ? last?.suggestedLoad : nil)
            }()

            // Verdict
            let verdict: ExerciseVerdict = {
                guard e1rmBySession.count >= 2 else { return .insufficient }
                let first = e1rmBySession.first!.e1rm
                let last = e1rmBySession.last!.e1rm
                let delta = (last - first) / first
                if delta >= 0.03 { return .progressing }   // 3%+ gain
                if delta <= -0.03 { return .declining }     // 3%+ drop
                return .plateaued
            }()

            // PR detection
            let isPR: Bool = {
                guard let peak = peakE1RM else { return false }
                let prior = priorPeakE1RM[exerciseId] ?? 0
                return peak > prior
            }()

            // Display name and muscle
            let catalog = ExerciseCatalog.all.first { $0.id == exerciseId }
            let snapshotName = sessionsWithExercise.first?.item.exerciseNameSnapshot
            let displayName = catalog?.name ?? snapshotName ?? ExerciseCatalog.displayName(for: exerciseId)
            let primaryMuscle = catalog?.primaryMuscle.rawValue.capitalized

            // Per-exercise totals
                        var exSets = 0
                        var exReps = 0
                        var exVolume: Double = 0
                        for (_, item) in sessionsWithExercise {
                            let setCount = min(item.actualLoads.count, item.actualReps.count)
                            for idx in 0..<setCount {
                                let load = item.actualLoads[idx]
                                let reps = item.actualReps[idx]
                                guard load > 0, reps > 0 else { continue }
                                exSets += 1
                                exReps += reps
                                exVolume += load * Double(reps)
                            }
                        }

                        exerciseSummaries.append(ExercisePerformanceSummary(
                            exerciseId: exerciseId,
                            exerciseName: displayName,
                            primaryMuscle: primaryMuscle,
                            e1rmBySession: e1rmBySession,
                            peakE1RM: peakE1RM,
                            openingLoad: openingLoad,
                            closingLoad: closingLoad,
                            verdict: verdict,
                            isPR: isPR,
                            totalSets: exSets,
                            totalReps: exReps,
                            totalVolume: exVolume
                        ))
        }

        // Sort by primary muscle then name
        exerciseSummaries.sort {
            if $0.primaryMuscle != $1.primaryMuscle {
                return ($0.primaryMuscle ?? "") < ($1.primaryMuscle ?? "")
            }
            return $0.exerciseName < $1.exerciseName
        }

        return MesoAnalysis(
            mesoName: meso.name,
            totalWeeks: meso.totalWeeks ?? weeklyVolume.count,
            completedSessions: completedSessions.count,
            totalVolume: totalVolume,
            totalSets: totalSets,
            totalReps: totalReps,
            weeklyVolume: weeklyVolume,
            exerciseSummaries: exerciseSummaries
        )
    }
}

