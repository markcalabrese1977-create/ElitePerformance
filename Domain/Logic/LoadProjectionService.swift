// Domain/Logic/LoadProjectionService.swift
import Foundation
import SwiftData

// MARK: - Output Types

/// How the suggested load was derived — drives coaching message specificity.
enum LoadProjectionBasis {
    /// Load derived from best RIR-weighted e1RM within the current meso.
    case currentMesoPeak(e1rm: Double)
    /// Load derived from decay-weighted e1RM baseline across prior mesos.
    case crossMesoBaseline(e1rm: Double)
    /// Same-wave progression with consecutive clean sessions confirmed — increase earned.
    case consecutiveCleanProgression(sessions: Int)
    /// Same-wave progression — last session was clean but not yet confirmed over multiple sessions.
    case sameWaveProgression
    /// No usable history — load cannot be projected.
    case noHistory
}

struct LoadProjection {
    let suggestedLoad: Double
    let basis: LoadProjectionBasis
    /// Number of consecutive clean same-wave sessions detected. Used by coaching message.
    let consecutiveCleanCount: Int

    // MARK: - Data-provider surface (CUT 1, additive)
    //
    // project() computes these internally to DECIDE suggestedLoad, then discarded
    // them. They are surfaced here so a future single-authority CoachingEngine can
    // consume project() as a pure data provider without re-deriving them. Purely
    // additive: `suggestedLoad`/`basis`/`consecutiveCleanCount` are unchanged, and
    // no consumer reads these yet. Optional because not every return path computes
    // every field (e.g. the no-lastLoad exits run before `lastLoad` is resolved).
    /// e1RM-derived load floor at the target reps/RIR (rounded). May be 0 when no
    /// usable e1RM history exists. In scope at every non-nil return.
    let e1rmFloorLoad: Double?
    /// RIR-weighted peak e1RM within the current meso (no decay). May be 0.
    let peakE1RM: Double?
    /// Decay-weighted e1RM baseline across prior mesos. May be 0.
    let crossMesoE1RM: Double?
    /// Last same-wave working load used as the same-wave progression base. Nil on
    /// the early exits that return before a valid last load is resolved.
    let lastLoad: Double?
}

// MARK: - Service

/// Canonical load projection logic.
///
/// Single source of truth for computing the next suggested load for an exercise.
/// Used by both PlanMemoryEngine (automatic carry-forward) and Auto+ (manual refresh).
///
/// Decision hierarchy:
/// 1. Current meso peak e1RM (RIR-weighted, no decay) — reflects true current capacity
/// 2. Cross-meso decay-weighted e1RM baseline — longer-term context from prior mesos
/// 3. Same-wave progression with consecutive clean session tracking:
///    - 0 clean sessions → hold load
///    - 1 clean session → hold, note that one more earns the increase
///    - 2+ consecutive clean sessions → increase
/// 4. No history — returns nil
///
/// The higher of (1 or 2) vs (3) wins. Same-wave progression is never undercut by e1RM.
enum LoadProjectionService {

    // MARK: - Clean Session Evaluation (public — used by CoachingEngine call sites)

    /// Evaluate whether a single session item represents a clean performance.
    /// Clean = reps ≥ prescribedMin, RIR on target, no fatigue/pain flags,
    /// no compromising load override reason.
    static func isCleanSession(_ item: SessionItem, prescribedMin: Int) -> Bool {
        if let reason = item.loadOverrideReason {
            switch reason {
            case .jointTenderness, .generalFatigue: return false
            case .equipmentConstraint, .deliberateDeload: break
            }
        }

        let hasFatigue = item.setFeedbackBySet.contains {
            SetFeedback.holdsLoad(raw: $0) || $0 == SetFeedback.pain.rawValue
        }
        if hasFatigue { return false }

        // Back-off rows only: a top set has its own (lower) rep range and RIR target, so it must
        // not satisfy or fail the back-off prescription. No top set = every row, as before.
        let bestReps = item.actualReps.enumerated()
            .filter { !item.isTopRow($0.offset) && $0.element > 0 }
            .map(\.element).max() ?? 0
        guard bestReps >= prescribedMin else { return false }

        let validRIRs = (0..<item.actualRIRs.count).compactMap { idx -> Int? in
            guard !item.isTopRow(idx), idx < item.actualLoads.count, item.actualLoads[idx] > 0 else { return nil }
            return RIREntry.decisionRIR(item, at: idx)   // recorded, compound lifts only
        }
        if !validRIRs.isEmpty {
            let avgRIR = Double(validRIRs.reduce(0, +)) / Double(validRIRs.count)
            if avgRIR < Double(item.targetRIR) - 0.5 { return false }
        }
        return true
    }

    /// Compute consecutive clean same-wave sessions for an exercise.
    /// Lightweight — used by CoachingEngine at call sites without needing full projection.
    static func consecutiveCleanCount(
        exerciseId: String,
        waveRaw: String?,
        repMin: Int,
        allSessions: [Session],
        referenceDate: Date = Date()
    ) -> Int {
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        let today = Calendar.current.startOfDay(for: referenceDate)

        let sessionsWithWork = allSessions
            .filter { Calendar.current.startOfDay(for: $0.date) < today }
            .filter { s in
                s.items.contains { item in
                    ExerciseCatalog.canonicalExerciseId(for: item.exerciseId) == canonicalId &&
                    item.actualLoads.contains { $0 > 0 }
                }
            }

        let sameWaveSessions: [Session] = {
            guard let wave = waveRaw?.lowercased(), !wave.isEmpty else { return sessionsWithWork }
            let filtered = sessionsWithWork.filter { s in
                s.items.first?.waveRaw?.lowercased() == wave
            }
            return filtered.isEmpty ? sessionsWithWork : filtered
        }()

        var count = 0
        for session in sameWaveSessions.suffix(3).reversed() {
            guard let item = session.items.first(where: {
                ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
            }) else { break }
            if isCleanSession(item, prescribedMin: repMin) {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    // MARK: - Full Projection

    static func project(
        exerciseId: String,
        targetReps: Int,
        targetRIR: Int,
        repMin: Int,
        repMax: Int,
        currentWaveRaw: String?,
        allSessions: [Session],
        activeMesoSessionIDs: Set<PersistentIdentifier>,
        loadIncrement: Double = 2.5,
        unit: LoadUnit = .lb,
        referenceDate: Date = Date(),
        bodyWeight: Double? = nil,
        customExercises: [CustomExercise] = []
    ) -> LoadProjection? {

        // Defense in depth: maintenance/deload items hold their load — never
        // progress them, regardless of caller. PlanMemoryEngine already guards
        // this before calling project(), but this protects every other caller too.
        if currentWaveRaw?.lowercased() == "deload" { return nil }

        // FIX B — Bodyweight exercises get NO numeric load suggestion. Their sets are
        // logged with actualLoad == 0, which makes both sub-paths below misfire:
        //  (a) the e1RM builder substitutes bodyWeight for the missing load (treating
        //      bodyweight as if it were external plate), and
        //  (b) the same-wave path reads a phantom from plannedLoadsBySet/suggestedLoad
        //      and steps it every "clean" session (isCleanSession skips RIR when
        //      actualLoads == 0, so BW sessions always count as clean).
        // Returning nil keeps suggestedLoad/plannedLoadsBySet at 0 so the plan pill
        // renders "BW". Mirrors CoachingEngine.recommend, which already returns nil for
        // BW (its working-set filter requires load > 0). Uses the customExercises-aware
        // overload — as the same-wave fallback at line ~261 does — so custom BW
        // exercises are covered too. Loaded exercises are unaffected.
        if ExerciseCatalog.isBodyweight(exerciseId: exerciseId, customExercises: customExercises) {
            return nil
        }

        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        let today = Calendar.current.startOfDay(for: referenceDate)
        let effectiveTargetReps = targetReps > 0 ? targetReps : (repMin + repMax) / 2

        // MARK: - Build RIR-weighted e1RM candidates (exclude today)

        typealias E1RMCandidate = (e1rm: Double, date: Date, sessionID: PersistentIdentifier)

        let allCandidates: [E1RMCandidate] = allSessions
            .filter { Calendar.current.startOfDay(for: $0.date) < today }
            .compactMap { s -> E1RMCandidate? in
                guard let item = s.items.first(where: {
                    ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
                }) else { return nil }

                if let reason = item.loadOverrideReason {
                    switch reason {
                    case .jointTenderness, .generalFatigue:
                        return nil
                    case .equipmentConstraint, .deliberateDeload:
                        guard item.suggestedLoad > 0 else { return nil }
                        let proxyReps = item.targetReps > 0 ? item.targetReps : 8
                        let proxyE1RM = E1RMCalculator.e1RM(load: item.suggestedLoad, reps: proxyReps)
                        guard proxyE1RM > 0 else { return nil }
                        return (e1rm: proxyE1RM, date: s.date, sessionID: s.persistentModelID)
                    }
                }

                let setCount = min(item.actualLoads.count, item.actualReps.count)
                guard setCount > 0 else { return nil }

                let sets: [(load: Double, reps: Int, actualRIR: Int)] = (0..<setCount).compactMap { idx in
                    let reps = item.actualReps[idx]
                    let load = E1RMCalculator.effectiveLoad(
                        actualLoad: item.actualLoads[idx],
                        exerciseId: item.exerciseId,
                        bodyWeight: bodyWeight
                    )
                    guard load > 0, reps > 0 else { return nil }
                    let rir = RIREntry.recorded(item, at: idx) ?? item.targetRIR
                    return (load: load, reps: reps, actualRIR: rir)
                }

                let sessionTargetRIR = item.targetRIR > 0 ? item.targetRIR : 2
                let weightedE1RM = E1RMCalculator.rirWeightedE1RM(from: sets, targetRIR: sessionTargetRIR)
                guard weightedE1RM > 0 else { return nil }
                return (e1rm: weightedE1RM, date: s.date, sessionID: s.persistentModelID)
            }

        guard !allCandidates.isEmpty else { return nil }

        // MARK: - Current meso peak (no decay)

        let currentMesoCandidates = allCandidates.filter { activeMesoSessionIDs.contains($0.sessionID) }
        let currentMesoPeakE1RM: Double = currentMesoCandidates.map { $0.e1rm }.max() ?? 0

        // MARK: - Cross-meso decay-weighted baseline

        let crossMesoCandidates = allCandidates
            .filter { !activeMesoSessionIDs.contains($0.sessionID) }
        let crossMesoE1RM = E1RMCalculator.decayWeightedE1RM(
            from: crossMesoCandidates.map { ($0.e1rm, $0.date) },
            referenceDate: referenceDate
        )

        let bestE1RM = max(currentMesoPeakE1RM, crossMesoE1RM)
        let e1rmBasis: LoadProjectionBasis = currentMesoPeakE1RM >= crossMesoE1RM
            ? .currentMesoPeak(e1rm: currentMesoPeakE1RM)
            : .crossMesoBaseline(e1rm: crossMesoE1RM)

        let e1rmFloorLoad: Double = {
            guard bestE1RM > 0 else { return 0 }
            let raw = E1RMCalculator.load(for: bestE1RM, reps: effectiveTargetReps, targetRIR: targetRIR)
            return E1RMCalculator.rounded(raw, increment: loadIncrement, unit: unit)
        }()

        // MARK: - Same-wave sessions with consecutive clean tracking

        let sessionsWithWork = allSessions
            .filter { Calendar.current.startOfDay(for: $0.date) < today }
            .filter { s in
                s.items.contains { item in
                    ExerciseCatalog.canonicalExerciseId(for: item.exerciseId) == canonicalId &&
                    (item.actualLoads.contains { $0 > 0 } || item.actualReps.contains { $0 > 0 })
                }
            }

        let sameWaveSessions: [Session] = {
            guard let wave = currentWaveRaw?.lowercased(), !wave.isEmpty else { return [] }
            return sessionsWithWork.filter { s in
                s.items.first?.waveRaw?.lowercased() == wave
            }
        }()

        let candidateSessions = sameWaveSessions.isEmpty ? sessionsWithWork : sameWaveSessions

        guard let lastSession = candidateSessions.last,
              let lastItem = lastSession.items.first(where: {
                  ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
              }) else {
            if e1rmFloorLoad > 0 {
                return LoadProjection(
                    suggestedLoad: e1rmFloorLoad,
                    basis: e1rmBasis,
                    consecutiveCleanCount: 0,
                    e1rmFloorLoad: e1rmFloorLoad,
                    peakE1RM: currentMesoPeakE1RM,
                    crossMesoE1RM: crossMesoE1RM,
                    lastLoad: nil // no candidate session → lastLoad not yet resolved
                )
            }
            return nil
        }

        let setCount = max(1, lastItem.targetSets)
        let lastLoad: Double = {
            let actuals = Array(lastItem.actualLoads.prefix(setCount)).filter { $0 > 0 }
            if let first = actuals.first { return first }
            let planned = Array(lastItem.plannedLoadsBySet.prefix(setCount)).filter { $0 > 0 }
            if let first = planned.first { return first }
            if lastItem.suggestedLoad > 0 { return lastItem.suggestedLoad }
            // No load anywhere — fall back to bodyweight as the floor for BW exercises
            // instead of bailing with nil below.
            if ExerciseCatalog.isBodyweight(exerciseId: lastItem.exerciseId, customExercises: customExercises), let bw = bodyWeight, bw > 0 {
                return bw
            }
            return 0
        }()
        guard lastLoad > 0 else {
            if e1rmFloorLoad > 0 {
                return LoadProjection(
                    suggestedLoad: e1rmFloorLoad,
                    basis: e1rmBasis,
                    consecutiveCleanCount: 0,
                    e1rmFloorLoad: e1rmFloorLoad,
                    peakE1RM: currentMesoPeakE1RM,
                    crossMesoE1RM: crossMesoE1RM,
                    lastLoad: nil // guard failed: lastLoad <= 0, no valid base load
                )
            }
            return nil
        }

        let prescribedMin = lastItem.repMin ?? repMin

        // Count consecutive clean sessions using the promoted static method
        let recentSameWave = Array(candidateSessions.suffix(3))
        var consecutiveClean = 0
        for session in recentSameWave.reversed() {
            guard let item = session.items.first(where: {
                ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
            }) else { break }
            if isCleanSession(item, prescribedMin: prescribedMin) {
                consecutiveClean += 1
            } else {
                break
            }
        }

        // Same-wave load decision based on consecutive clean count
        var repsBySet: [Int] = []
        for idx in 0..<setCount {
            let actual = idx < lastItem.actualReps.count ? lastItem.actualReps[idx] : 0
            if actual > 0 { repsBySet.append(actual); continue }
            let planned = idx < lastItem.plannedRepsBySet.count ? lastItem.plannedRepsBySet[idx] : 0
            if planned > 0 { repsBySet.append(planned); continue }
            repsBySet.append(lastItem.targetReps)
        }

        let missesCount = repsBySet.filter { $0 < (prescribedMin - 1) }.count
        let tooMuchFatigue = missesCount >= 2

        // Detect if the last session was performed with more in the tank than planned.
        // avgRIR > targetRIR means the lifter had extra reserve — a stronger signal
        // to increase than hitting target exactly. One clean session is sufficient.
        let lastValidRIRs = (0..<lastItem.actualRIRs.count).compactMap { idx -> Int? in
            guard idx < lastItem.actualLoads.count, lastItem.actualLoads[idx] > 0 else { return nil }
            return RIREntry.decisionRIR(lastItem, at: idx)
        }
        let lastAvgRIR = lastValidRIRs.isEmpty ? Double(lastItem.targetRIR) :
            Double(lastValidRIRs.reduce(0, +)) / Double(lastValidRIRs.count)
        let hadExtraReserve = lastAvgRIR > Double(lastItem.targetRIR) + 0.5

        // `loadIncrement` is in `unit`; loads are stored lb, so a step added to a load is converted first.
        let stepLb = UnitAwareRounding.stepLb(loadIncrement, unit: unit)
        func snap(_ lb: Double) -> Double { UnitAwareRounding.round(lb, increment: loadIncrement, unit: unit) }
        let sameWaveLoad: Double = {
            if tooMuchFatigue {
                return snap(lastLoad * 0.95)
            }
            // Extra reserve last session (actual RIR well above target) + clean = increase now.
            // Standard path requires 2 consecutive clean sessions.
            if consecutiveClean >= 1 && hadExtraReserve {
                return snap(lastLoad + stepLb)
            }
            if consecutiveClean >= 2 {
                return snap(lastLoad + stepLb)
            }
            return snap(lastLoad)
        }()

        let sameWaveBasis: LoadProjectionBasis = (consecutiveClean >= 2 || (consecutiveClean >= 1 && hadExtraReserve))
            ? .consecutiveCleanProgression(sessions: consecutiveClean)
            : .sameWaveProgression

        // MARK: - Final decision

        if e1rmFloorLoad > 0 && e1rmFloorLoad >= sameWaveLoad {
            return LoadProjection(
                suggestedLoad: e1rmFloorLoad,
                basis: e1rmBasis,
                consecutiveCleanCount: consecutiveClean,
                e1rmFloorLoad: e1rmFloorLoad,
                peakE1RM: currentMesoPeakE1RM,
                crossMesoE1RM: crossMesoE1RM,
                lastLoad: lastLoad
            )
        }

        if sameWaveLoad > 0 {
            return LoadProjection(
                suggestedLoad: sameWaveLoad,
                basis: sameWaveBasis,
                consecutiveCleanCount: consecutiveClean,
                e1rmFloorLoad: e1rmFloorLoad,
                peakE1RM: currentMesoPeakE1RM,
                crossMesoE1RM: crossMesoE1RM,
                lastLoad: lastLoad
            )
        }

        return nil
    }

    // MARK: - Active Meso Helper

    static func activeMesoSessionIDs(from context: ModelContext) -> Set<PersistentIdentifier> {
        let descriptor = FetchDescriptor<MesoBlock>()
        let blocks = (try? context.fetch(descriptor)) ?? []
        let active = blocks.first { $0.status == .active }
        guard let activeSessions = active?.sessions else { return [] }

        // Cap to sessions from the last 4 weeks only.
        // A single meso can span 10+ weeks — treating all of them as "current"
        // means the peak e1RM is taken from the wrong wave or an early week,
        // producing load suggestions that don't reflect current capacity.
        let cutoff = Date().addingTimeInterval(-28 * 86400)
        let recent = activeSessions.filter { $0.date >= cutoff }

        // If nothing in the last 4 weeks (e.g. fresh restore, gap in training),
        // fall back to the most recent 2 sessions so projection still works.
        if recent.isEmpty {
            let sorted = activeSessions.sorted { $0.date > $1.date }
            return Set(sorted.prefix(2).map { $0.persistentModelID })
        }

        return Set(recent.map { $0.persistentModelID })
    }

    // MARK: - Last-known-load scan

    /// Two-pass session scan returning the most recent known load for an exercise.
    /// Pass 1 prefers same-wave sessions; Pass 2 falls back to any session.
    /// Only COMPLETED sessions dated BEFORE `currentSession` are read, matched on the canonical exerciseId: a future or other
    /// planned session's `suggestedLoad` is a plan, not something the lifter lifted, and is never used.
    /// Returns 0 when no history exists — caller leaves suggestedLoad at 0.
    ///
    /// BW guard: bodyweight exercises always return 0, preventing a swap from
    /// re-manufacturing the phantom loads eliminated by Fix B. Uses the
    /// customExercises-aware isBodyweight overload so custom BW exercises are covered.
    static func lastKnownLoad(
        for exerciseId: String,
        currentSession: Session,
        context: ModelContext,
        customExercises: [CustomExercise] = []
    ) -> Double {
        if ExerciseCatalog.isBodyweight(exerciseId: exerciseId, customExercises: customExercises) {
            return 0
        }
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        let descriptor = FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .reverse)])
        guard let fetched = try? context.fetch(descriptor) else { return 0 }
        let sessions = fetched.filter {
            $0.status == .completed && $0.date < currentSession.date && $0.persistentModelID != currentSession.persistentModelID
        }
        func load(in s: Session) -> Double? {
            guard let match = s.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }) else { return nil }
            if let lastActual = match.backOffValues(match.actualLoads).filter({ $0 > 0 }).last { return lastActual }
            return match.suggestedLoad > 0 ? match.suggestedLoad : nil   // a finished session's own plan, not a future one
        }
        let currentWave = currentSession.items.compactMap { $0.waveRaw }.first?.lowercased()
        // Pass 1 — same wave type only
        if let wave = currentWave, !wave.isEmpty {
            for s in sessions where s.items.compactMap({ $0.waveRaw }).first?.lowercased() == wave {
                if let l = load(in: s) { return l }
            }
        }
        // Pass 2 — fallback: any earlier completed session
        for s in sessions { if let l = load(in: s) { return l } }
        return 0
    }
}

// MARK: - Last same-letter performance (read-only display lookup)

/// What the lifter did the last time this lift appeared in the SAME wave letter, in the SAME
/// block, on the SAME day slot. Progression is judged reps-first against that exposure, so Today
/// shows it ("Last A: 315 x 5, 6, 5, 5"). Pure: takes already-fetched sessions, writes nothing.
///
/// Unlike `LoadProjectionService.sameWaveSessions` (neither block- nor day-scoped) this is scoped
/// the way `PlanMemoryEngine.nextTargetItem` anchors loads: persistent meso id + trimmed dayLabel +
/// the MATCHED item's own wave + canonical exerciseId.
struct LastLetterPerformance: Equatable {
    struct SetEntry: Equatable {
        let reps: Int
        let load: Double
    }

    /// Lowercased wave letter ("a", "b", "c").
    let waveRaw: String
    let date: Date
    let weekIndex: Int
    let sets: [SetEntry]
    /// Bodyweight lifts show reps only.
    let isBodyweight: Bool

    var letter: String { waveRaw.uppercased() }

    /// "Last A: 315 x 5, 6, 5, 5" — consecutive sets at one load are grouped, a new group starts
    /// when the load changes ("Last B: 290 x 8, 7, 6 · 315 x 5"); bodyweight: "Last A: 5, 5, 5, 5 reps".
    var caption: String { caption(unit: .lb) }

    func caption(unit: LoadUnit) -> String {
        if isBodyweight {
            return "Last \(letter): \(sets.map { String($0.reps) }.joined(separator: ", ")) reps"
        }
        var groups: [(load: Double, reps: [Int])] = []
        for s in sets {
            if let last = groups.last, last.load == s.load {
                groups[groups.count - 1].reps.append(s.reps)
            } else {
                groups.append((s.load, [s.reps]))
            }
        }
        let body = groups
            .map { "\(Self.formatLoad($0.load, unit: unit)) x \($0.reps.map(String.init).joined(separator: ", "))" }
            .joined(separator: " · ")
        return "Last \(letter): \(body)"
    }

    private static func formatLoad(_ v: Double, unit: LoadUnit) -> String {
        LoadFormatter(unit: unit).number(v)
    }
}

enum LastSameLetterPerformance {

    /// The most recent EARLIER completed exposure of `item` (in `session`) with the same meso,
    /// trimmed dayLabel, wave letter on the matched item, and canonical exerciseId. Nil when the
    /// item has no wave (or is a deload), the block is a maintenance block, or there is no prior
    /// exposure with logged working sets.
    static func find(
        for item: SessionItem,
        in session: Session,
        allSessions: [Session],
        customExercises: [CustomExercise] = []
    ) -> LastLetterPerformance? {
        guard let wave = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased(),
              !wave.isEmpty, wave != "deload" else { return nil }
        guard let meso = session.meso, !meso.isMaintenance else { return nil }
        let mesoID = meso.persistentModelID
        let day = (session.dayLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !day.isEmpty else { return nil }
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        let isBodyweight = ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: customExercises)

        var best: (session: Session, sets: [LastLetterPerformance.SetEntry])?
        for candidate in allSessions {
            guard candidate.status == .completed,
                  candidate.persistentModelID != session.persistentModelID,
                  candidate.date < session.date,
                  candidate.meso?.persistentModelID == mesoID,
                  (candidate.dayLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == day
            else { continue }
            if let b = best, b.session.date >= candidate.date { continue }

            // The MATCHED item's own wave decides — never the session's first item.
            for candidateItem in candidate.items {
                guard ExerciseCatalog.canonicalExerciseId(for: candidateItem.exerciseId) == canonicalId,
                      candidateItem.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() == wave
                else { continue }
                let sets = workingSets(of: candidateItem, isBodyweight: isBodyweight)
                guard !sets.isEmpty else { continue }
                best = (candidate, sets)
                break
            }
        }
        guard let best else { return nil }
        return LastLetterPerformance(
            waveRaw: wave, date: best.session.date, weekIndex: best.session.weekIndex,
            sets: best.sets, isBodyweight: isBodyweight
        )
    }

    /// Logged working sets in set order: reps > 0, and load > 0 unless bodyweight (zero-rep padding
    /// rows are ignored). A 4-row top-set pattern (290, 290, 290, 315) is kept as logged.
    static func workingSets(of item: SessionItem, isBodyweight: Bool) -> [LastLetterPerformance.SetEntry] {
        let n = min(item.actualReps.count, item.actualLoads.count)
        return (0..<n).compactMap { i in
            let reps = item.actualReps[i], load = item.actualLoads[i]
            guard reps > 0, isBodyweight || load > 0 else { return nil }
            return .init(reps: reps, load: isBodyweight ? 0 : load)
        }
    }

    /// Captions for every item of `session`, keyed by exerciseId (first item wins). Call once when
    /// the screen loads.
    static func captions(
        for session: Session,
        allSessions: [Session],
        customExercises: [CustomExercise] = [],
        unit: LoadUnit = .lb
    ) -> [String: String] {
        var out: [String: String] = [:]
        for item in session.items where out[item.exerciseId] == nil {
            if let r = find(for: item, in: session, allSessions: allSessions, customExercises: customExercises) {
                out[item.exerciseId] = r.caption(unit: unit)
            }
        }
        return out
    }
}

// MARK: - History seed load (completed-only, canonical)

/// A starting load for an exercise the lifter is about to run, derived from what they actually
/// lifted — never from what was planned.
///
/// This is the seed used when an item is swapped to a different exercise: it reads only
/// `.completed` sessions and only the `actual*` arrays, so planned/future sessions and their
/// `suggestedLoad` can never feed it (unlike `LoadProjectionService.lastKnownLoad`, which
/// falls back to planned loads). Matching is by canonical exerciseId.
///
/// Math: per set, e1RM from the logged load at reps + logged RIR (clamped 0...4, missing = 0 —
/// reps left in the tank were capacity), best set per session, decay-weighted across sessions,
/// inverse Epley at the prescription's reps and RIR, rounded DOWN to the user's increment (the same
/// `E1RMCalculator` path `ProgramGenerator.anchorLoadsForNewMeso` uses, plus the RIR credit).
///
/// Excluded as non-representative: items on a "deload" wave (which also covers maintenance
/// blocks), sets logged as rest-pause, drop or skipped, and sets under half of that session's
/// heaviest qualifying set for the exercise (warm-ups).
enum HistorySeedLoad {

    /// Floors to the increment: a starting load is never meaningfully above what history supports. The epsilon
    /// keeps a value that is a whole increment up to float noise (99.99999999 at 2.5) from dropping a step.
    ///
    /// A near miss rounds UP: when the computed load is less than `nearMissIncrementFraction` of an increment
    /// short of the next increment, the next increment is the seed (319.2 at 5 -> 320). The window is a share of
    /// the STEP, not of the load, so it is the same size for a 30 lb and a 300 lb lift: at 5 lb, 318.5 -> 315 and
    /// 104 -> 100 (exactly one lb short is not "less than").
    static func roundedDown(_ load: Double, increment: Double, unit: LoadUnit = .lb) -> Double {
        UnitAwareRounding.round(load, increment: increment, unit: unit, mode: .nearMissDown)
    }

    /// How close to the next increment, as a share of the increment itself, a computed load must be to take it.
    static let nearMissIncrementFraction = UnitAwareRounding.nearMissFraction

    static let maxCreditedRIR = 4
    /// Sets lighter than this share of the session's heaviest set are warm-ups.
    static let warmupFraction = WorkingSetFilter.warmupFraction

    /// Which rows of an item a seed reads (defined by `WorkingSetFilter`, which analytics shares).
    typealias Role = WorkingSetFilter.Role

    /// Logged working sets: reps and load present, not rest-pause, drop or skipped (`WorkingSetFilter`).
    private static func qualifyingSets(of item: SessionItem, role: Role? = nil) -> [WorkingSetFilter.Row] {
        WorkingSetFilter.qualifyingRows(of: item, role: role)
    }

    /// - Returns: `0` for bodyweight exercises (they never carry a numeric load),
    ///   `nil` when no completed session has a usable logged set for the exercise.
    static func load(
        for exerciseId: String,
        goalReps: Int,
        targetRIR: Int,
        in sessions: [Session],
        loadIncrement: Double,
        unit: LoadUnit = .lb,
        bodyWeight: Double? = nil,
        customExercises: [CustomExercise] = [],
        referenceDate: Date = Date(),
        role: Role = .backOff,
        creditRIR: Bool = false
    ) -> Double? {
        if ExerciseCatalog.isBodyweight(exerciseId: exerciseId, customExercises: customExercises) {
            return 0
        }
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)

        var candidates: [(e1rm: Double, date: Date)] = []
        for session in sessions where session.status == .completed {
            guard let match = session.items.first(where: {
                ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
            }) else { continue }
            if match.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() == "deload" { continue }

            let sets = qualifyingSets(of: match, role: role)
            guard !sets.isEmpty else { continue }
            var best = 0.0
            for set in WorkingSetFilter.droppingWarmups(sets) {
                let credited = set.reps + (creditRIR ? min(max(set.rir, 0), maxCreditedRIR) : 0)
                best = max(best, E1RMCalculator.e1RM(load: set.load, reps: credited))
            }
            if best > 0 { candidates.append((best, session.date)) }
        }
        guard !candidates.isEmpty else { return nil }

        let e1rm = E1RMCalculator.decayWeightedE1RM(from: candidates, referenceDate: referenceDate)
        let raw = E1RMCalculator.load(for: e1rm, reps: goalReps, targetRIR: targetRIR)
        let seeded = roundedDown(raw, increment: loadIncrement, unit: unit)
        return seeded > 0 ? seeded : nil
    }

    /// Where a next-meso seed came from (for the preview).
    enum SeedSource: String, Equatable {
        case peak, history, fixed, bodyweight, none

        /// "peak95" for a 0.95 factor, "history", "fixed", "bodyweight", "none".
        func label(factor: Double) -> String {
            self == .peak ? "peak\(Int((factor * 100).rounded()))" : rawValue
        }
    }

    /// Best RIR-credited e1RM of `exerciseId` over `sessions` (the meso being continued), converted to a
    /// load at the prescription and scaled by `factor`, rounded DOWN to the increment.
    ///
    /// Counted: completed sessions only, not on an inserted deload week, not in a maintenance block, and
    /// not a deload-wave item. Sets are the same working sets `load` uses (rest-pause, drop and skipped
    /// sets excluded, sets under half of the session's heaviest set dropped as warm-ups), credited with
    /// their logged RIR (clamped 0...4). Unlike `load`, nothing is averaged: the best set of the best
    /// session wins, so a deload, a maintenance block or an old light session cannot dilute it.
    ///
    /// - Returns: `nil` when no counted set exists. Bodyweight exercises are `0`.
    static func peakLoad(
        for exerciseId: String,
        goalReps: Int,
        targetRIR: Int,
        in sessions: [Session],
        loadIncrement: Double,
        unit: LoadUnit = .lb,
        factor: Double = 0.95,
        customExercises: [CustomExercise] = [],
        role: Role = .backOff,
        creditRIR: Bool = false
    ) -> Double? {
        if ExerciseCatalog.isBodyweight(exerciseId: exerciseId, customExercises: customExercises) { return 0 }
        guard let peak = peakE1RM(for: exerciseId, in: sessions, role: role, creditRIR: creditRIR) else { return nil }
        let seeded = roundedDown(E1RMCalculator.load(for: peak, reps: goalReps, targetRIR: targetRIR) * factor,
                                 increment: loadIncrement, unit: unit)
        return seeded > 0 ? seeded : nil
    }

    /// The best RIR-credited e1RM `peakLoad` converts: completed, not an inserted deload, not maintenance, not a
    /// deload-wave item, working sets only. `nil` when no such set exists.
    ///
    /// `role: nil` (the default) counts EVERY logged row, top sets included: the lifter's peak is a fact
    /// about the lifter, whichever role the set had. `peakLoad` passes the role of the load it seeds.
    static func peakE1RM(for exerciseId: String, in sessions: [Session], role: Role? = nil, creditRIR: Bool = false) -> Double? {
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        var peak = 0.0
        for session in sessions where session.status == .completed {
            if session.insertedDeload == true || session.meso?.isMaintenance == true { continue }
            guard let match = session.items.first(where: {
                ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
            }) else { continue }
            if match.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() == "deload" { continue }

            let sets = qualifyingSets(of: match, role: role)
            guard !sets.isEmpty else { continue }
            for set in WorkingSetFilter.droppingWarmups(sets) {
                let credited = set.reps + (creditRIR ? min(max(set.rir, 0), maxCreditedRIR) : 0)
                peak = max(peak, E1RMCalculator.e1RM(load: set.load, reps: credited))
            }
        }
        return peak > 0 ? peak : nil
    }

    /// The starting load for one item of a next meso, and where it came from.
    ///
    /// Order: bodyweight 0; fixed-load (exempt) lifts take the last lifted load; otherwise the peak of
    /// `previousMeso` (x `factor`); otherwise the decay-weighted `load` over all history; otherwise 0.
    static func nextMesoSeed(
        for exerciseId: String,
        goalReps: Int,
        targetRIR: Int,
        previousMeso: [Session],
        allSessions: [Session],
        loadIncrement: Double,
        unit: LoadUnit = .lb,
        bodyWeight: Double? = nil,
        isFixedLoad: Bool,
        factor: Double = 0.95,
        customExercises: [CustomExercise] = [],
        referenceDate: Date = Date(),
        role: Role = .backOff,
        creditRIR: Bool = false
    ) -> (load: Double, source: SeedSource) {
        if ExerciseCatalog.isBodyweight(exerciseId: exerciseId, customExercises: customExercises) {
            return (0, .bodyweight)
        }
        if isFixedLoad {
            if let last = SessionItemEditService.lastCompletedLoad(for: exerciseId, in: allSessions) { return (last, .fixed) }
            return (0, .none)
        }
        if let peak = peakLoad(for: exerciseId, goalReps: goalReps, targetRIR: targetRIR, in: previousMeso,
                               loadIncrement: loadIncrement, unit: unit, factor: factor, customExercises: customExercises, role: role, creditRIR: creditRIR) {
            return (peak, .peak)
        }
        if let h = load(for: exerciseId, goalReps: goalReps, targetRIR: targetRIR, in: allSessions,
                        loadIncrement: loadIncrement, unit: unit, bodyWeight: bodyWeight, customExercises: customExercises,
                        referenceDate: referenceDate, role: role, creditRIR: creditRIR) {
            return (h, .history)
        }
        return (0, .none)
    }

    /// Context convenience: fetches sessions, custom exercises and the profile's increment/bodyweight.
    static func load(
        for exerciseId: String,
        goalReps: Int,
        targetRIR: Int,
        context: ModelContext
    ) -> Double? {
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        return load(
            for: exerciseId, goalReps: goalReps, targetRIR: targetRIR, in: sessions,
            loadIncrement: profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: profile?.loadUnit ?? .lb),
            unit: profile?.loadUnit ?? .lb,
            bodyWeight: profile?.bodyWeight,
            customExercises: custom
        )
    }
}
