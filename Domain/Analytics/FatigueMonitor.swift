// Domain/Analytics/FatigueMonitor.swift
import Foundation

/// A kind of evidence that the lifter may be carrying fatigue. The policy counts DISTINCT kinds, so five rep drops
/// are still one kind.
enum FatigueSignalType: String, CaseIterable, Hashable {
    /// Fewer reps than the last same-letter exposure at the same load.
    case repDrop
    /// Several lifts' e1RM below their own trailing same-letter baseline.
    case e1rmDecline
    /// Sessions whose planned day passed without them being done.
    case missedSessions
    /// A high share of sets flagged fatigue, pain or disruption.
    case feedbackShare
    /// The lifter said so: readiness fatigued / compromised, or a fatigue / joint-tenderness load override.
    case selfReport
}

struct FatigueSignal: Equatable {
    let type: FatigueSignalType
    let date: Date
    /// The canonical exercise the signal is about; nil for a whole-session or whole-window signal.
    let exerciseId: String?
    let exerciseName: String?
    /// One plain sentence with the numbers behind it.
    let evidence: String
}

enum FatigueSuggestion: String, Equatable {
    case none
    /// Some evidence; keep an eye on it.
    case watch
    /// Enough independent evidence that a deload is worth considering. A suggestion only: nothing is changed.
    case deloadSuggested
}

struct FatigueAssessment: Equatable {
    let asOf: Date
    let suggestion: FatigueSuggestion
    /// The signals inside the rolling window, oldest first.
    let signals: [FatigueSignal]
    var distinctTypes: Set<FatigueSignalType> { Set(signals.map(\.type)) }
}

/// Every threshold of the monitor. The default is the v5.4-style rule (two distinct signal types within a rolling
/// three weeks) but it is data, not code: change a number and the same engine answers differently.
struct FatiguePolicy: Equatable {
    // The rule
    var windowDays = 21
    var watchTypeCount = 1
    var deloadTypeCount = 2
    var enabledTypes: Set<FatigueSignalType> = Set(FatigueSignalType.allCases)
    /// Signals dated on or before the latest completed deload session are dropped: the deload reset the clock.
    var resetAfterDeload = true

    // 1. Same-letter rep drop at the same load
    /// Loads within this many increments of each other are "the same load".
    var loadToleranceIncrements = 1.0
    /// The mean reps per set at that load must fall by at least this much.
    var repDropMeanReps = 1.0
    /// Two exposures further apart than this are not compared (a layoff, not fatigue).
    var maxExposureGapDays = 42
    /// A change of the prescribed reps between two exposures larger than this voids the comparison.
    var plannedRepsTolerance = 0.5

    // 2. Multi-lift e1RM decline
    var e1rmDeclineFraction = 0.05
    var e1rmDeclineLiftCount = 3
    /// The baseline is the mean of this many previous same-chain exposures; fewer prior exposures = no verdict.
    var baselineExposures = 2

    // 3. Missed sessions
    var missedGraceDays = 2
    var missedSessionCount = 2

    // 4. Feedback share
    var feedbackShare = 0.15
    var feedbackMinSets = 20

    // 5. Self report
    var readinessTriggers: Set<SessionReadiness> = [.fatigued, .compromised]
    var overrideTriggers: Set<LoadOverrideReason> = [.generalFatigue, .jointTenderness]

    static let `default` = FatiguePolicy()
}

/// The fatigue monitor: pure, suggest-only. It reads an `AnalyticsSnapshot` and returns signals and a suggestion.
/// It writes nothing, anywhere.
///
/// Excluded everywhere: deload weeks, inserted deloads, maintenance blocks (a deload's low numbers are the plan, not
/// fatigue). Rep-drop and e1RM comparisons run on exposure chains (lift x wave letter x role x meso), so the first
/// exposure after a meso change or a replaced lift has nothing to be compared with.
enum FatigueMonitor {

    // MARK: - Public

    /// Every signal occurrence the data supports up to `asOf`, oldest first.
    /// - Parameters:
    ///   - loadIncrementLb: the lifter's load step in stored lb (sets what "the same load" means).
    ///   - unit: only for the text of the evidence.
    static func signals(
        in snapshot: AnalyticsSnapshot,
        policy: FatiguePolicy = .default,
        loadIncrementLb: Double,
        asOf: Date,
        unit: LoadUnit = .lb
    ) -> [FatigueSignal] {
        let sets = snapshot.sets.filter { $0.sessionDate <= asOf }
        // As of `asOf`, a session completed later is simply not known yet.
        let sessions = snapshot.sessions.filter { $0.status != .completed || $0.date <= asOf }
        let exposures = Exposures.build(from: sets)
        var out: [FatigueSignal] = []
        if policy.enabledTypes.contains(.repDrop) {
            out += repDrops(exposures, policy: policy, incrementLb: loadIncrementLb, unit: unit)
        }
        if policy.enabledTypes.contains(.e1rmDecline) {
            out += e1rmDeclines(exposures, policy: policy)
        }
        if policy.enabledTypes.contains(.missedSessions) {
            out += missed(sessions, policy: policy, asOf: asOf)
        }
        if policy.enabledTypes.contains(.feedbackShare) {
            out += feedbackShares(sets, policy: policy)
        }
        if policy.enabledTypes.contains(.selfReport) {
            out += selfReports(sets, policy: policy)
        }
        return out.sorted { ($0.date, $0.type.rawValue, $0.exerciseId ?? "") < ($1.date, $1.type.rawValue, $1.exerciseId ?? "") }
    }

    /// The suggestion at `asOf` from already-computed `signals`.
    static func assess(
        signals: [FatigueSignal],
        snapshot: AnalyticsSnapshot,
        policy: FatiguePolicy = .default,
        asOf: Date
    ) -> FatigueAssessment {
        let windowStart = asOf.addingTimeInterval(-Double(policy.windowDays) * 86_400)
        var floor = windowStart
        if policy.resetAfterDeload,
           let deloaded = snapshot.sessions
            .filter({ $0.status == .completed && !$0.isMaintenance && ($0.isDeloadWeek || $0.isInsertedDeload) && $0.date <= asOf })
            .map(\.date).max() {
            floor = max(floor, deloaded)
        }
        let inWindow = signals.filter { $0.date > floor && $0.date <= asOf }
        let types = Set(inWindow.map(\.type)).intersection(policy.enabledTypes).count
        let suggestion: FatigueSuggestion =
            types >= policy.deloadTypeCount ? .deloadSuggested : (types >= policy.watchTypeCount ? .watch : .none)
        return FatigueAssessment(asOf: asOf, suggestion: suggestion, signals: inWindow)
    }

    /// Signals and suggestion in one call.
    static func evaluate(
        snapshot: AnalyticsSnapshot,
        policy: FatiguePolicy = .default,
        loadIncrementLb: Double,
        asOf: Date,
        unit: LoadUnit = .lb
    ) -> FatigueAssessment {
        let s = signals(in: snapshot, policy: policy, loadIncrementLb: loadIncrementLb, asOf: asOf, unit: unit)
        return assess(signals: s, snapshot: snapshot, policy: policy, asOf: asOf)
    }

    // MARK: - Evidence text

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    private static func letterText(_ letter: String) -> String { letter.isEmpty ? "" : " \(letter.uppercased())" }

    // MARK: - 1. Same-letter rep drop at the same load

    private static func repDrops(_ exposures: [Exposure], policy: FatiguePolicy, incrementLb: Double, unit: LoadUnit) -> [FatigueSignal] {
        let tol = max(0, policy.loadToleranceIncrements) * incrementLb
        let fmt = LoadFormatter(unit: unit)
        var out: [FatigueSignal] = []
        for (chain, list) in Exposures.chains(exposures) {
            let ordered = list.sorted { $0.date < $1.date }
            for k in ordered.indices.dropFirst() {
                let prev = ordered[k - 1], cur = ordered[k]
                guard cur.date.timeIntervalSince(prev.date) <= Double(policy.maxExposureGapDays) * 86_400 else { continue }
                guard abs(cur.heaviestLoad - prev.heaviestLoad) <= tol else { continue }
                if let a = prev.meanPlannedReps, let b = cur.meanPlannedReps, abs(a - b) > policy.plannedRepsTolerance { continue }
                func mean(_ e: Exposure) -> Double? {
                    let top = e.heaviestLoad
                    let reps = e.sets.filter { $0.load >= top - tol }.map(\.reps)
                    return reps.isEmpty ? nil : Double(reps.reduce(0, +)) / Double(reps.count)
                }
                guard let mp = mean(prev), let mc = mean(cur), mp - mc >= policy.repDropMeanReps else { continue }
                out.append(FatigueSignal(
                    type: .repDrop, date: cur.date, exerciseId: chain.exerciseId, exerciseName: cur.exerciseName,
                    evidence: "\(cur.exerciseName)\(letterText(chain.letter)) at \(fmt.compact(cur.heaviestLoad)): "
                        + "\(String(format: "%.1f", mc)) reps per set vs \(String(format: "%.1f", mp)) on \(shortDate(prev.date))"
                ))
            }
        }
        return out
    }

    // MARK: - 2. Multi-lift e1RM decline

    private static func e1rmDeclines(_ exposures: [Exposure], policy: FatiguePolicy) -> [FatigueSignal] {
        struct Decline { let date: Date; let exerciseId: String; let name: String; let fraction: Double }
        var declines: [Decline] = []
        for (chain, list) in Exposures.chains(exposures) {
            let ordered = list.sorted { $0.date < $1.date }
            let b = max(1, policy.baselineExposures)
            guard ordered.count > b else { continue }
            for k in b..<ordered.count {
                let cur = ordered[k]
                guard cur.date.timeIntervalSince(ordered[k - 1].date) <= Double(policy.maxExposureGapDays) * 86_400 else { continue }
                let base = ordered[(k - b)..<k].map(\.bestE1RM)
                guard !base.contains(where: { $0 <= 0 }), cur.bestE1RM > 0 else { continue }
                let baseline = base.reduce(0, +) / Double(base.count)
                let drop = (baseline - cur.bestE1RM) / baseline
                if drop >= policy.e1rmDeclineFraction {
                    declines.append(Decline(date: cur.date, exerciseId: chain.exerciseId, name: cur.exerciseName, fraction: drop))
                }
            }
        }
        declines.sort { $0.date < $1.date }
        var out: [FatigueSignal] = []
        let window = Double(policy.windowDays) * 86_400
        var emittedDates = Set<Date>()
        for d in declines where !emittedDates.contains(d.date) {
            let recent = declines.filter { $0.date <= d.date && $0.date > d.date.addingTimeInterval(-window) }
            // One entry per lift: its latest decline in the window.
            var latest: [String: Decline] = [:]
            for r in recent { latest[r.exerciseId] = r }
            guard latest.count >= policy.e1rmDeclineLiftCount else { continue }
            emittedDates.insert(d.date)
            let list = latest.values.sorted { $0.fraction > $1.fraction }
                .map { "\($0.name) −\(Int(($0.fraction * 100).rounded()))%" }.joined(separator: ", ")
            out.append(FatigueSignal(
                type: .e1rmDecline, date: d.date, exerciseId: nil, exerciseName: nil,
                evidence: "\(latest.count) lifts at least \(Int((policy.e1rmDeclineFraction * 100).rounded()))% under their trailing baseline: \(list)"
            ))
        }
        return out
    }

    // MARK: - 3. Missed sessions

    private static func missed(_ sessions: [SessionRecord], policy: FatiguePolicy, asOf: Date) -> [FatigueSignal] {
        var lastDone: [String: Date] = [:]
        for s in sessions where s.status == .completed { lastDone[s.mesoKey] = max(lastDone[s.mesoKey] ?? .distantPast, s.date) }
        struct Miss { let at: Date; let label: String }
        var misses: [Miss] = []
        for s in sessions where s.isRegularTraining && s.status != .completed {
            guard let planned = s.plannedDate else { continue }                 // unknown planned day: never guessed
            let dueAt = planned.addingTimeInterval(Double(policy.missedGraceDays) * 86_400)
            guard dueAt <= asOf else { continue }
            // Abandoned block: if the lifter never trained in this meso after the planned day, the block was dropped,
            // not skipped session by session.
            guard let done = lastDone[s.mesoKey], done >= planned else { continue }
            misses.append(Miss(at: dueAt, label: "\(s.dayLabel ?? "Session") (\(shortDate(planned)))"))
        }
        misses.sort { $0.at < $1.at }
        let window = Double(policy.windowDays) * 86_400
        var out: [FatigueSignal] = []
        for m in misses {
            let recent = misses.filter { $0.at <= m.at && $0.at > m.at.addingTimeInterval(-window) }
            guard recent.count >= policy.missedSessionCount else { continue }
            out.append(FatigueSignal(
                type: .missedSessions, date: m.at, exerciseId: nil, exerciseName: nil,
                evidence: "\(recent.count) sessions not done in \(policy.windowDays) days: \(recent.map(\.label).joined(separator: ", "))"
            ))
        }
        return out
    }

    // MARK: - 4. Feedback share

    private static func feedbackShares(_ sets: [SetRecord], policy: FatiguePolicy) -> [FatigueSignal] {
        // Denominator: every hard set plus every skipped row (a skip carries its reason as feedback).
        let rows = sets.filter { $0.isRegularCompleted && ($0.isHardSetRow || $0.isSkipped) }
        let sessionDates = Dictionary(grouping: rows, by: \.sessionKey).compactMapValues { $0.first?.sessionDate }
        let window = Double(policy.windowDays) * 86_400
        var out: [FatigueSignal] = []
        for (key, date) in sessionDates.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            // Only a session that itself carries a flag adds evidence.
            guard rows.contains(where: { $0.sessionKey == key && $0.hasFatigueFlag }) else { continue }
            let recent = rows.filter { $0.sessionDate <= date && $0.sessionDate > date.addingTimeInterval(-window) }
            guard recent.count >= policy.feedbackMinSets else { continue }
            let flagged = recent.filter(\.hasFatigueFlag).count
            let share = Double(flagged) / Double(recent.count)
            guard share >= policy.feedbackShare else { continue }
            out.append(FatigueSignal(
                type: .feedbackShare, date: date, exerciseId: nil, exerciseName: nil,
                evidence: "\(flagged) of \(recent.count) sets (\(Int((share * 100).rounded()))%) flagged fatigue, pain or disruption in \(policy.windowDays) days"
            ))
        }
        return out
    }

    // MARK: - 5. Self report

    private static func selfReports(_ sets: [SetRecord], policy: FatiguePolicy) -> [FatigueSignal] {
        var out: [FatigueSignal] = []
        let regular = sets.filter(\.isRegularCompleted)
        var seenSessions = Set<String>()
        for s in regular where policy.readinessTriggers.contains(s.readiness) && seenSessions.insert(s.sessionKey).inserted {
            out.append(FatigueSignal(
                type: .selfReport, date: s.sessionDate, exerciseId: nil, exerciseName: nil,
                evidence: "Readiness logged as \(s.readiness.rawValue) for \(s.dayLabel ?? "the session")"
            ))
        }
        var seenItems = Set<String>()
        for s in regular {
            guard let reason = s.loadOverride, policy.overrideTriggers.contains(reason),
                  seenItems.insert("\(s.sessionKey)|\(s.exerciseId)").inserted else { continue }
            out.append(FatigueSignal(
                type: .selfReport, date: s.sessionDate, exerciseId: s.exerciseId, exerciseName: s.exerciseName,
                evidence: "\(s.exerciseName): load cut for \(reason.displayName.lowercased())"
            ))
        }
        return out
    }
}
