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

/// What an exercise's trend is measured on.
enum ExerciseTrendBasis: Equatable {
    /// e1RM of sets of 12 reps or fewer.
    case e1RM
    /// No set of 12 reps or fewer: the best load at matched reps (at least this many).
    case loadAtReps(Int)
    /// Bodyweight lift with no body weight on the profile: reps per set.
    case reps
    case none
}

/// Per-exercise summary across the full meso.
struct ExercisePerformanceSummary {
    let exerciseId: String
    let exerciseName: String
    let primaryMuscle: String?

    /// e1RM per session, in chronological order.
    let e1rmBySession: [(weekIndex: Int, date: Date, e1rm: Double)]

    /// Best e1RM achieved this meso (sets of 12 reps or fewer only).
    let peakE1RM: Double?

    /// The block's best set, load x reps (a lift is only ever compared with itself, never ranked against another).
    let bestSet: BestSet?

    /// What the trend (and the verdict) was measured on, and its change first -> last session within this lift.
    let trendBasis: ExerciseTrendBasis
    let trendChange: Double?

    /// Load used in the first session this meso.
    let openingLoad: Double?

    /// Load used in the last session this meso.
    let closingLoad: Double?

    /// Performance verdict across the meso.
    let verdict: ExerciseVerdict

    /// A bodyweight lift with no body weight on the profile has no load to rate: it is judged on reps instead.
    let repsBased: Bool

    /// Mean reps per working set in the first / last session this meso (reps-based lifts).
    let openingReps: Double?
    let closingReps: Double?

    /// Whether this exercise set a new e1RM record (vs all prior mesos).
        let isPR: Bool

        /// The lift's first-ever working exposure is in this meso: a baseline, not a record.
        let isNew: Bool

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

    /// The load an item is represented by in an opening / closing comparison: its first logged BACK-OFF row. A top
    /// set sits at the tail and is heavier by design, so reading it as "the load" would compare a top set in one
    /// session with a back-off in another. Only an item with no logged back-off row falls back to its first logged
    /// row (a top row); nil when nothing was logged. For an item with no top set this is the first logged load, as
    /// it always was.
    static func representativeLoad(of item: SessionItem) -> Double? {
        let logged = item.actualLoads.indices.filter { item.actualLoads[$0] > 0 }
        if let back = logged.first(where: { !item.isTopRow($0) }) { return item.actualLoads[back] }
        return logged.first.map { item.actualLoads[$0] }
    }

    /// Analyze a completed or near-complete meso block.
    ///
    /// - Parameters:
    ///   - meso: The meso block to analyze.
    ///   - allPriorSessions: Sessions from previous mesos — used for PR detection.
    /// - Returns: A `MesoAnalysis` if there are enough completed sessions, nil otherwise.
    static func analyze(
        meso: MesoBlock,
        allPriorSessions: [Session],
        bodyWeight: Double? = nil
    ) -> MesoAnalysis? {
        // A bodyweight lift is rated at the lifter's body weight (the same rule as every other screen: the P1 definition);
        // 0 means "no load to rate": the lift is counted by reps only.
        func effective(_ load: Double, _ item: SessionItem) -> Double {
            if load > 0 { return load }
            if ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId), let bw = bodyWeight, bw > 0 { return bw }
            return 0
        }
        func isBW(_ item: SessionItem) -> Bool { ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId) }
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
                    let load = effective(item.actualLoads[idx], item)
                    let reps = item.actualReps[idx]
                    guard reps > 0, load > 0 || isBW(item) else { continue }
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
                    let load = effective(item.actualLoads[idx], item)
                    let reps = item.actualReps[idx]
                    guard reps > 0, load > 0 || isBW(item) else { continue }
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

        // Deload weeks are excluded from per-exercise load/e1RM/verdict
        // computation (not from the top-level completedSessions.isEmpty
        // "any data at all" gate above) — a deload week's necessarily-lower
        // load isn't a real performance data point, and including it as
        // "last" can flip a genuinely progressing meso to a false declining
        // verdict via the first-vs-last delta below.
        let nonDeloadCompletedSessions = completedSessions.filter { !$0.isDeloadWeek }

        // Collect all exercise IDs that appeared in this meso
        var exerciseIds: [String] = []
        var seenIds = Set<String>()
        for session in nonDeloadCompletedSessions {
            for item in session.items {
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                if !seenIds.contains(canonical) {
                    seenIds.insert(canonical)
                    exerciseIds.append(canonical)
                }
            }
        }

        // Build prior e1RM peaks for PR detection
        // Maintenance blocks are held at deliberately reduced work: they never set or raise a prior peak.
        var priorPeakE1RM: [String: Double] = [:]
        for session in allPriorSessions where session.meso?.isMaintenance != true {
            for item in session.items {
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                let setCount = min(item.actualLoads.count, item.actualReps.count)
                for idx in 0..<setCount {
                    let load = effective(item.actualLoads[idx], item)
                    let reps = item.actualReps[idx]
                    guard load > 0, reps > 0 else { continue }
                    let e1rm = BestSetRule.e1RM(load: load, reps: reps)      // sets of 12 reps or fewer only
                    guard e1rm > 0 else { continue }
                    priorPeakE1RM[canonical] = max(priorPeakE1RM[canonical] ?? 0, e1rm)
                }
            }
        }

        var exerciseSummaries: [ExercisePerformanceSummary] = []

        for exerciseId in exerciseIds {
            // Collect sessions containing this exercise, chronologically
            // (deload weeks already excluded above).
            let sessionsWithExercise: [(session: Session, item: SessionItem)] = nonDeloadCompletedSessions.compactMap { session in
                guard let item = session.items.first(where: {
                    ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == exerciseId
                }) else { return nil }
                return (session, item)
            }

            guard sessionsWithExercise.count >= 1 else { continue }

            // Working rows per session. Warm-ups are excluded: a row counts only if its load is >= 50% of that session's own
            // max load for this exercise (the threshold CoachingEngine uses), else a light high-rep warm-up could win.
            struct Row { let load: Double; let reps: Int }
            var rowsBySession: [(weekIndex: Int, date: Date, rows: [Row])] = []
            for (session, item) in sessionsWithExercise {
                let setCount = min(item.actualLoads.count, item.actualReps.count)
                let sessionMaxLoad = (0..<setCount)
                    .map { effective(item.actualLoads[$0], item) }
                    .filter { $0 > 0 }
                    .max() ?? 0
                var rows: [Row] = []
                for idx in 0..<setCount {
                    let load = effective(item.actualLoads[idx], item)
                    let reps = item.actualReps[idx]
                    guard load > 0, reps > 0, load >= 0.50 * sessionMaxLoad else { continue }
                    rows.append(Row(load: load, reps: reps))
                }
                if !rows.isEmpty { rowsBySession.append((session.weekIndex, session.date, rows)) }
            }

            // e1RM only from sets of 12 reps or fewer (BestSetRule): a 20-rep set does not predict a 1RM.
            var e1rmBySession: [(weekIndex: Int, date: Date, e1rm: Double)] = []
            for s in rowsBySession {
                let peak = s.rows.map { BestSetRule.e1RM(load: $0.load, reps: $0.reps) }.max() ?? 0
                if peak > 0 { e1rmBySession.append((s.weekIndex, s.date, peak)) }
            }
            let peakE1RM = e1rmBySession.map { $0.e1rm }.max()
            let allRows = rowsBySession.flatMap { $0.rows }
            let bestSet = BestSetRule.best(of: allRows.map { (load: $0.load, reps: $0.reps) })

            // The trend, within this one lift: e1RM first -> last; a lift with no set of 12 reps or fewer is compared at matched
            // reps (the best load lifted for at least the reps of the closing session's heaviest set).
            var trendBasis: ExerciseTrendBasis = .none
            var trendChange: Double? = nil
            if !e1rmBySession.isEmpty {
                trendBasis = .e1RM
                if e1rmBySession.count >= 2, let f = e1rmBySession.first?.e1rm, let l = e1rmBySession.last?.e1rm, f > 0 { trendChange = (l - f) / f }
            } else if let closing = rowsBySession.last?.rows.max(by: { ($0.load, $0.reps) < ($1.load, $1.reps) }) {
                trendBasis = .loadAtReps(closing.reps)
                let series = rowsBySession.map { BestSetRule.bestLoad(atLeast: closing.reps, in: $0.rows.map { (load: $0.load, reps: $0.reps) }) }.filter { $0 > 0 }
                if series.count >= 2, let f = series.first, let l = series.last, f > 0 { trendChange = (l - f) / f }
            }


            // Opening and closing loads
            let openingLoad: Double? = {
                let first = sessionsWithExercise.first?.item
                return first.flatMap { representativeLoad(of: $0) } ?? (first?.suggestedLoad ?? 0 > 0 ? first?.suggestedLoad : nil)
                    ?? (first.map { effective(0, $0) }.flatMap { $0 > 0 ? $0 : nil })
            }()

            let closingLoad: Double? = {
                let last = sessionsWithExercise.last?.item
                return last.flatMap { representativeLoad(of: $0) } ?? (last?.suggestedLoad ?? 0 > 0 ? last?.suggestedLoad : nil)
                    ?? (last.map { effective(0, $0) }.flatMap { $0 > 0 ? $0 : nil })
            }()

            // A bodyweight lift with no body weight set has no load to rate: judge it on mean reps per working set.
            let repsBased = allRows.isEmpty && sessionsWithExercise.contains { isBW($0.item) }
            func meanReps(_ item: SessionItem) -> Double? {
                let reps = (0..<min(item.actualLoads.count, item.actualReps.count)).map { item.actualReps[$0] }.filter { $0 > 0 }
                return reps.isEmpty ? nil : Double(reps.reduce(0, +)) / Double(reps.count)
            }
            let repSeries = repsBased ? sessionsWithExercise.compactMap { meanReps($0.item) } : []
            let openingReps = repSeries.first, closingReps = repSeries.last
            let repsChange: Double? = {
                guard repSeries.count >= 2, let f = repSeries.first, let l = repSeries.last, f > 0 else { return nil }
                return (l - f) / f
            }()

            // Verdict (the trend between the first and the last session of the block, +-3%)
            let verdict: ExerciseVerdict = {
                if repsBased {
                    guard repSeries.count >= 2, let f = repSeries.first, let l = repSeries.last, f > 0 else { return .insufficient }
                    let d = (l - f) / f
                    return d >= 0.03 ? .progressing : (d <= -0.03 ? .declining : .plateaued)
                }
                guard let delta = trendChange else { return .insufficient }
                if delta >= 0.03 { return .progressing }   // 3%+ gain
                if delta <= -0.03 { return .declining }     // 3%+ drop
                return .plateaued
            }()


            // PR detection
            // A record needs something to beat: a lift with no earlier exposure (prior 0) sets a baseline ("New"), not a PR.
            let isNew: Bool = peakE1RM != nil && (priorPeakE1RM[exerciseId] ?? 0) <= 0
            let isPR: Bool = {
                guard let peak = peakE1RM else { return false }
                let prior = priorPeakE1RM[exerciseId] ?? 0
                return prior > 0 && peak > prior
            }()

            // Display name and muscle
            let catalog = ExerciseCatalog.all.first { $0.id == exerciseId }
                        let snapshotName = sessionsWithExercise.first?.item.exerciseNameSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                        guard catalog != nil || snapshotName != nil else { continue }
                        let displayName = catalog?.name ?? snapshotName ?? exerciseId
            let primaryMuscle = catalog?.primaryMuscle.rawValue.capitalized

            // Per-exercise totals: working sets only (WorkingSetFilter via ItemStats): no warm-ups, skipped rows or rest-pause /
            // drop add-ons, at the effective load. The same sets the weekly-sets-by-muscle section counts.
            var exSets = 0
            var exReps = 0
            var exVolume: Double = 0
            for (_, item) in sessionsWithExercise {
                let st = AnalyticsEngine.ItemStats.of(item, bodyWeight: bodyWeight)
                exSets += st.sets
                exReps += st.reps
                exVolume += st.volume
            }

                        exerciseSummaries.append(ExercisePerformanceSummary(
                            exerciseId: exerciseId,
                            exerciseName: displayName,
                            primaryMuscle: primaryMuscle,
                            e1rmBySession: e1rmBySession,
                            peakE1RM: peakE1RM,
                            bestSet: bestSet,
                            trendBasis: repsBased ? .reps : trendBasis,
                            trendChange: repsBased ? repsChange : trendChange,
                            openingLoad: openingLoad,
                            closingLoad: closingLoad,
                            verdict: verdict,
                            repsBased: repsBased,
                            openingReps: openingReps,
                            closingReps: closingReps,
                            isPR: isPR,
                            isNew: isNew,
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

