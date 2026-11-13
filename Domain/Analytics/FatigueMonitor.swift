// Domain/Analytics/FatigueMonitor.swift
import Foundation

/// A kind of evidence the monitor can raise. The level logic counts kinds, not occurrences.
enum FatigueSignalType: String, CaseIterable, Hashable {
    /// One lift fell short of its own plan by more than the lifter's norm (evidence for `breadth`; never a level alone).
    case shortfall
    /// One lift lost reps at the same load against its previous same-letter exposure (evidence only).
    case repDrop
    /// Many of the lifts trained in a calendar week fell short of plan together.
    case breadth
    /// Sessions planned at creation whose day passed without them being done.
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
    /// Broad shortfall plus corroboration. A suggestion only: nothing is changed.
    case deloadSuggested
}

struct FatigueAssessment: Equatable {
    let asOf: Date
    let suggestion: FatigueSuggestion
    /// The signals inside the rolling window (after any deload reset), oldest first.
    let signals: [FatigueSignal]
    var distinctTypes: Set<FatigueSignalType> { Set(signals.map(\.type)) }
}

/// Every threshold of the monitor, as data.
struct FatiguePolicy: Equatable {
    // Window
    var windowDays = 21
    var enabledTypes: Set<FatigueSignalType> = Set(FatigueSignalType.allCases)
    /// Signal types that count toward a level. `shortfall` and `repDrop` are evidence for `breadth`, not levels.
    var levelTypes: Set<FatigueSignalType> = [.breadth, .missedSessions, .feedbackShare, .selfReport]
    /// Signals dated on or before the latest completed deload session are dropped: the deload reset the clock.
    var resetAfterDeload = true

    // Plan-relative shortfall
    /// Only sets whose logged load is within this many increments of the planned load are judged against the plan.
    var loadMatchIncrements = 1.0
    /// The lifter's norm is the median exposure deviation (all lifts) over this many days before the exposure...
    var baselineDays = 42
    /// ...and needs at least this many exposures to exist; fewer and nothing is judged yet.
    var baselineMinExposures = 8
    /// Shortfall = exposure deviation below the norm by more than this many reps per set.
    var shortfallReps = 1.0
    /// A lift whose heaviest load is under this many increments is not judged (bodyweight, assistance, tiny weights).
    var minLoadIncrements = 2.0
    /// An exposure that reached the top of the rep range on every working set at RIR >= target is never a shortfall.
    var exemptReachedTop = true

    // Breadth (per calendar week)
    var breadthMinLifts = 3
    var breadthShare = 0.30
    /// Breadth in this many consecutive calendar weeks suggests a deload on its own.
    var breadthWeeksForDeload = 2
    /// false (the shipped default): performance signals never produce `deloadSuggested`, only `watch`. The plan-relative
    /// detector over-fires on the history it was tried on (see the KNOWN LIMITS), so a deload is not suggested from it
    /// until it is tuned; self report and missed sessions alone never reach `deloadSuggested` either way.
    var performanceDrivesDeload = false

    // Same-load rep drop (evidence)
    /// Loads within this many increments of each other are "the same load".
    var loadToleranceIncrements = 1.0
    /// Mean reps per set at that load must fall by at least this much to count as a rep drop.
    var repDropMeanReps = 1.0
    /// A deliberately lowered plan starts a new rep-drop baseline: the user edited it, an override reason was recorded,
    /// a deload / maintenance session sat in between, or the previous exposure was fine (the engine only reduces after
    /// under-performance). A load the engine lowered after an under-performing exposure never resets it.
    var resetOnLowerPlannedLoad = true
    /// Rep-drop comparisons need the same rep range and RIR target; a change starts a new baseline.
    var requireComparablePrescription = true
    /// Two exposures further apart than this are not compared; a longer gap starts the chain again.
    var maxExposureGapDays = 42
    /// A change of the prescribed reps between two exposures larger than this voids a rep-drop comparison.
    var plannedRepsTolerance = 0.5

    // Missed sessions (only dates recorded at creation)
    var missedGraceDays = 2
    var missedSessionCount = 2

    // Feedback share
    var feedbackShare = 0.15
    var feedbackMinSets = 20

    // Self report
    /// A report counts toward a level for this many days...
    var selfReportDays = 7
    /// ...unless this many fall inside the window, which keeps all of them for the whole window.
    var selfReportRepeatCount = 2
    var readinessTriggers: Set<SessionReadiness> = [.fatigued, .compromised]
    var overrideTriggers: Set<LoadOverrideReason> = [.generalFatigue, .jointTenderness]

    static let `default` = FatiguePolicy()
}

/// The fatigue monitor: pure, suggest-only. It reads an `AnalyticsSnapshot` and returns signals and a suggestion;
/// it writes nothing.
///
/// HOW IT JUDGES. Each exposure is measured against its own plan: over the working sets whose logged load is within one
/// load step of the planned load, deviation = logged reps minus planned reps, averaged per exposure. The lifter's norm is
/// the median deviation of all their exposures over the previous six weeks; a lift has a SHORTFALL when its deviation is
/// more than one rep per set under that norm. This does not depend on progression, wave letter or block. BREADTH is the
/// share of the lifts trained in one calendar week that have a shortfall (at least 3 lifts and 30%).
/// Levels: `watch` = any one level signal type in the window. When `performanceDrivesDeload` is on, `deloadSuggested` =
/// breadth in two consecutive calendar weeks, OR breadth together with a self report or missed sessions. A self report
/// or missed sessions alone never reach it.
/// Same-load rep drops against the previous same-letter exposure are kept as evidence only.
///
/// SHIPPED STATE: WATCH-ONLY FOR PERFORMANCE. `FatiguePolicy.default.performanceDrivesDeload` is false, so this monitor
/// can raise `watch` but never `deloadSuggested`. With it switched on, the backtest over the one real history reached
/// `deloadSuggested` on 98 of 239 session dates (the lifter regularly logs fewer reps than planned, so the weekly breadth
/// test fires often), and a single bad session plus a coincident self report also reached it. Two earlier designs (a
/// letter-normalized e1RM index, then same-letter rep drops) were blind to a mild two-week decline on a 6-day DUP. Closing
/// that gap needs more than one lifter's history to tune against. Even `watch` is frequent: breadth alone raised it on
/// 183 of 239 session dates of that history, so a `watch` here is a prompt to look at the numbers, not a finding.
///
/// KNOWN LIMITS (read before trusting a level):
/// - Detection lag is about two weeks on a 6-day DUP split: a lift comes round once every few days to weeks, so a broad
///   decline accumulates lift by lift and the level can only follow.
/// - Tuned on ONE lifter's history (the thresholds, the sensitivity table and the injection tests were set against a
///   single backup). Treat the defaults as a starting point; every one is a `FatiguePolicy` field.
/// - Suggest-only: nothing here changes a plan, a load or a session. It cannot tell fatigue from illness, a layoff, or a
///   deliberate change it was not told about.
/// - It needs plans: a session logged without planned reps or planned loads is not judged. A mild decline on a minority
///   of lifts is at the edge of what it can see; a single bad session never reaches `deloadSuggested`.
enum FatigueMonitor {

    // MARK: - Judgements

    /// One lift's verdict at one exposure: the unit breadth is built from.
    struct Judgement: Equatable {
        let date: Date
        let exerciseId: String
        let exerciseName: String
        /// A shortfall against plan.
        let regressing: Bool
        /// Numbers behind a shortfall; "" for a lift judged fine.
        let evidence: String
        let current: Exposure
        /// Mean deviation of the exposure, and the lifter's norm at that date.
        let deviation: Double
        let norm: Double
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Mean of (logged reps - planned reps) over the exposure's working sets that were lifted at the planned load.
    static func deviation(of e: Exposure, loadMatch: Double) -> Double? {
        let ds: [Double] = e.sets.compactMap { s in
            guard let pl = s.plannedLoad, let pr = s.plannedReps, abs(s.load - pl) <= loadMatch else { return nil }
            return Double(s.reps - pr)
        }
        return ds.isEmpty ? nil : ds.reduce(0, +) / Double(ds.count)
    }

    /// Exposures eligible for plan-relative judgement: loaded lifts, not bodyweight, with a plan to compare to.
    private static func judgeable(_ exposures: [Exposure], policy: FatiguePolicy, loadIncrementLb: Double) -> [(e: Exposure, dev: Double)] {
        let minLoad = policy.minLoadIncrements * loadIncrementLb
        let match = policy.loadMatchIncrements * loadIncrementLb
        return exposures.compactMap { e in
            guard !e.isBodyweight, e.heaviestLoad >= minLoad, let d = deviation(of: e, loadMatch: match) else { return nil }
            return (e, d)
        }.sorted { $0.e.date < $1.e.date }
    }

    /// Every judged exposure up to `asOf`, oldest first.
    static func judgements(
        in snapshot: AnalyticsSnapshot,
        policy: FatiguePolicy = .default,
        loadIncrementLb: Double,
        asOf: Date,
        unit: LoadUnit = .lb,
        maxLoad: (String) -> Double? = { _ in nil }
    ) -> [Judgement] {
        let exposures = Exposures.build(from: snapshot.sets.filter { $0.sessionDate <= asOf })
        let items = judgeable(exposures, policy: policy, loadIncrementLb: loadIncrementLb)
        let day = 86_400.0
        var out: [Judgement] = []
        for (i, item) in items.enumerated() {
            let e = item.e
            // The lifter's norm: every judged exposure of the previous `baselineDays`, any lift, before this one.
            let lo = e.date.addingTimeInterval(-Double(policy.baselineDays) * day)
            let prior = items[..<i].filter { $0.e.date >= lo && $0.e.date < e.date }.map(\.dev)
            guard prior.count >= policy.baselineMinExposures else { continue }
            let norm = median(prior)
            var short = item.dev < norm - policy.shortfallReps
            if policy.exemptReachedTop && e.reachedTopAtTarget { short = false }
            let fmt = String(format: "%+.1f", item.dev), normText = String(format: "%+.1f", norm)
            out.append(Judgement(
                date: e.date, exerciseId: e.chain.exerciseId, exerciseName: e.exerciseName, regressing: short,
                evidence: short ? "\(e.exerciseName)\(letterText(e.chain.letter)): \(fmt) reps/set against plan (your norm \(normText))" : "",
                current: e, deviation: item.dev, norm: norm))
        }
        return out
    }

    private static func letterText(_ letter: String) -> String { letter.isEmpty ? "" : " \(letter.uppercased())" }

    // MARK: - Signals

    /// Every signal occurrence the data supports up to `asOf`, oldest first.
    static func signals(
        in snapshot: AnalyticsSnapshot,
        policy: FatiguePolicy = .default,
        loadIncrementLb: Double,
        asOf: Date,
        unit: LoadUnit = .lb,
        maxLoad: (String) -> Double? = { _ in nil }
    ) -> [FatigueSignal] {
        let sets = snapshot.sets.filter { $0.sessionDate <= asOf }
        // As of `asOf`, a session completed later is simply not known yet.
        let sessions = snapshot.sessions.filter { $0.status != .completed || $0.date <= asOf }
        var out: [FatigueSignal] = []
        if policy.enabledTypes.contains(.shortfall) || policy.enabledTypes.contains(.breadth) {
            let j = judgements(in: snapshot, policy: policy, loadIncrementLb: loadIncrementLb, asOf: asOf, unit: unit, maxLoad: maxLoad)
            if policy.enabledTypes.contains(.shortfall) {
                out += j.filter(\.regressing).map {
                    FatigueSignal(type: .shortfall, date: $0.date, exerciseId: $0.exerciseId, exerciseName: $0.exerciseName, evidence: $0.evidence)
                }
            }
            if policy.enabledTypes.contains(.breadth) { out += breadth(j, policy: policy) }
        }
        if policy.enabledTypes.contains(.repDrop) {
            out += repDrops(in: snapshot, policy: policy, loadIncrementLb: loadIncrementLb, asOf: asOf, unit: unit)
        }
        if policy.enabledTypes.contains(.missedSessions) { out += missed(sessions, policy: policy, asOf: asOf) }
        if policy.enabledTypes.contains(.feedbackShare) { out += feedbackShares(sets, policy: policy) }
        if policy.enabledTypes.contains(.selfReport) { out += selfReports(sets, policy: policy) }
        return out.sorted { ($0.date, $0.type.rawValue, $0.exerciseId ?? "") < ($1.date, $1.type.rawValue, $1.exerciseId ?? "") }
    }

    /// Monday-based calendar weeks, independent of the device's locale.
    private static let isoCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone.current
        return c
    }()

    static func weekStart(_ d: Date) -> Date {
        isoCalendar.dateInterval(of: .weekOfYear, for: d)?.start ?? isoCalendar.startOfDay(for: d)
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
        // A self report counts for `selfReportDays`; `selfReportRepeatCount` or more in the window keep all of them.
        let reports = inWindow.filter { $0.type == .selfReport }
        let reportsCount = reports.count >= policy.selfReportRepeatCount
            || reports.contains { $0.date > asOf.addingTimeInterval(-Double(policy.selfReportDays) * 86_400) }
        var types = Set(inWindow.map(\.type))
        if !reportsCount { types.remove(.selfReport) }
        let level = types.intersection(policy.levelTypes).intersection(policy.enabledTypes)

        // Breadth in consecutive calendar weeks, or breadth with a self report / missed sessions.
        let weeks = Set(inWindow.filter { $0.type == .breadth }.map { weekStart($0.date) }).sorted()
        var run = weeks.isEmpty ? 0 : 1, best = run
        for k in weeks.indices.dropFirst() {
            let gap = weeks[k].timeIntervalSince(weeks[k - 1])
            run = abs(gap - 7 * 86_400) < 3_700 ? run + 1 : 1      // a week apart (an hour of slack for DST)
            best = max(best, run)
        }
        let corroborated = best >= policy.breadthWeeksForDeload || level.contains(.selfReport) || level.contains(.missedSessions)
        let suggestion: FatigueSuggestion =
            (policy.performanceDrivesDeload && level.contains(.breadth) && corroborated) ? .deloadSuggested : (level.isEmpty ? .none : .watch)
        return FatigueAssessment(asOf: asOf, suggestion: suggestion, signals: inWindow)
    }

    /// Signals and suggestion in one call.
    static func evaluate(
        snapshot: AnalyticsSnapshot,
        policy: FatiguePolicy = .default,
        loadIncrementLb: Double,
        asOf: Date,
        unit: LoadUnit = .lb,
        maxLoad: (String) -> Double? = { _ in nil }
    ) -> FatigueAssessment {
        let s = signals(in: snapshot, policy: policy, loadIncrementLb: loadIncrementLb, asOf: asOf, unit: unit, maxLoad: maxLoad)
        return assess(signals: s, snapshot: snapshot, policy: policy, asOf: asOf)
    }

    // MARK: - Breadth

    /// At each date with a new shortfall: the share of the lifts judged so far in that calendar week that fell short.
    private static func breadth(_ judgements: [Judgement], policy: FatiguePolicy) -> [FatigueSignal] {
        var out: [FatigueSignal] = []
        for d in Set(judgements.filter(\.regressing).map(\.date)).sorted() {
            let ws = weekStart(d)
            let inWeek = judgements.filter { weekStart($0.date) == ws && $0.date <= d }
            let judged = Set(inWeek.map(\.exerciseId))
            let short = Dictionary(grouping: inWeek.filter(\.regressing), by: \.exerciseId).compactMapValues { $0.last }
            guard short.count >= policy.breadthMinLifts, !judged.isEmpty else { continue }
            let share = Double(short.count) / Double(judged.count)
            guard share >= policy.breadthShare else { continue }
            let list = short.values.sorted { $0.exerciseName < $1.exerciseName }.map(\.evidence).joined(separator: "; ")
            out.append(FatigueSignal(
                type: .breadth, date: d, exerciseId: nil, exerciseName: nil,
                evidence: "\(short.count) of \(judged.count) lifts trained this week (\(Int((share * 100).rounded()))%) fell short of plan: \(list)"))
        }
        return out
    }

    // MARK: - Same-load rep drop (evidence)

    private static func repDrops(in snapshot: AnalyticsSnapshot, policy: FatiguePolicy, loadIncrementLb: Double, asOf: Date, unit: LoadUnit) -> [FatigueSignal] {
        let exposures = Exposures.build(from: snapshot.sets.filter { $0.sessionDate <= asOf })
        let fmt = LoadFormatter(unit: unit)
        let day = 86_400.0
        let tol = max(0, policy.loadToleranceIncrements) * loadIncrementLb
        let minLoad = policy.minLoadIncrements * loadIncrementLb
        var overrideDates: [String: [Date]] = [:]
        for r in snapshot.sets where r.loadOverride != nil && r.status == .completed && r.sessionDate <= asOf {
            overrideDates[r.exerciseId, default: []].append(r.sessionDate)
        }
        let deloadDates = snapshot.sessions
            .filter { $0.status == .completed && $0.date <= asOf && ($0.isDeloadWeek || $0.isInsertedDeload || $0.isMaintenance) }.map(\.date)

        func meanReps(_ e: Exposure) -> Double? {
            let reps = e.sets.filter { $0.load >= e.heaviestLoad - tol }.map(\.reps)
            return reps.isEmpty ? nil : Double(reps.reduce(0, +)) / Double(reps.count)
        }
        func drop(_ prev: Exposure, _ cur: Exposure) -> Bool {
            guard abs(cur.heaviestLoad - prev.heaviestLoad) <= tol else { return false }
            if let a = prev.meanPlannedReps, let b = cur.meanPlannedReps, abs(a - b) > policy.plannedRepsTolerance { return false }
            guard let mp = meanReps(prev), let mc = meanReps(cur) else { return false }
            return mp - mc >= policy.repDropMeanReps
        }

        struct Key: Hashable { let id: String; let isTop: Bool; let letter: String }
        var out: [FatigueSignal] = []
        for (key, list) in Dictionary(grouping: exposures, by: { Key(id: $0.chain.exerciseId, isTop: $0.chain.isTop, letter: $0.chain.letter) }) {
            var prev: (e: Exposure, underperformed: Bool)?
            var seenMeso = Set<String>()
            for e in list.sorted(by: { $0.date < $1.date }) {
                guard !e.isBodyweight, e.heaviestLoad >= minLoad else { continue }
                let first = seenMeso.insert(e.chain.mesoKey).inserted
                if let p = prev {
                    if e.date.timeIntervalSince(p.e.date) > Double(policy.maxExposureGapDays) * day { prev = nil }
                    else if policy.resetOnLowerPlannedLoad, let now = e.plannedLoad, let was = p.e.plannedLoad, now < was - 0.01,
                            e.planEdited || (overrideDates[key.id] ?? []).contains(where: { $0 > p.e.date && $0 <= e.date })
                                || deloadDates.contains(where: { $0 > p.e.date && $0 <= e.date }) || !p.underperformed || p.e.reachedTopAtTarget { prev = nil }
                    else if policy.requireComparablePrescription, e.prescription != p.e.prescription { prev = nil }
                }
                var dropped = false
                if !first, let p = prev, drop(p.e, e), !(policy.exemptReachedTop && e.reachedTopAtTarget), let now = meanReps(e), let was = meanReps(p.e) {
                    dropped = true
                    out.append(FatigueSignal(
                        type: .repDrop, date: e.date, exerciseId: key.id, exerciseName: e.exerciseName,
                        evidence: "\(e.exerciseName)\(letterText(key.letter)) at \(fmt.compact(e.heaviestLoad)): \(String(format: "%.1f", now)) reps per set, down from \(String(format: "%.1f", was)) on the previous \(key.letter.isEmpty ? "exposure" : key.letter.uppercased())"))
                }
                prev = (e, dropped)
            }
        }
        return out
    }

    // MARK: - Missed sessions

    private static func missed(_ sessions: [SessionRecord], policy: FatiguePolicy, asOf: Date) -> [FatigueSignal] {
        var lastDone: [String: Date] = [:]
        for s in sessions where s.status == .completed { lastDone[s.mesoKey] = max(lastDone[s.mesoKey] ?? .distantPast, s.date) }
        struct Miss { let at: Date; let label: String }
        var misses: [Miss] = []
        for s in sessions where s.isRegularTraining && s.status != .completed {
            // Only a date recorded at creation is a schedule; a derived (backfilled) one is never read as a miss.
            guard s.plannedDateIsExact, let planned = s.plannedDate else { continue }
            let dueAt = planned.addingTimeInterval(Double(policy.missedGraceDays) * 86_400)
            guard dueAt <= asOf else { continue }
            // Abandoned block: nothing done in this meso after the planned day means the block was dropped.
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
                evidence: "\(recent.count) sessions not done in \(policy.windowDays) days: \(recent.map(\.label).joined(separator: ", "))"))
        }
        return out
    }

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    // MARK: - Feedback share

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
                evidence: "\(flagged) of \(recent.count) sets (\(Int((share * 100).rounded()))%) flagged fatigue, pain or disruption in \(policy.windowDays) days"))
        }
        return out
    }

    // MARK: - Self report

    private static func selfReports(_ sets: [SetRecord], policy: FatiguePolicy) -> [FatigueSignal] {
        var out: [FatigueSignal] = []
        let regular = sets.filter(\.isRegularCompleted)
        var seenSessions = Set<String>()
        for s in regular where policy.readinessTriggers.contains(s.readiness) && seenSessions.insert(s.sessionKey).inserted {
            out.append(FatigueSignal(
                type: .selfReport, date: s.sessionDate, exerciseId: nil, exerciseName: nil,
                evidence: "Readiness logged as \(s.readiness.rawValue) for \(s.dayLabel ?? "the session")"))
        }
        var seenItems = Set<String>()
        for s in regular {
            guard let reason = s.loadOverride, policy.overrideTriggers.contains(reason),
                  seenItems.insert("\(s.sessionKey)|\(s.exerciseId)").inserted else { continue }
            out.append(FatigueSignal(
                type: .selfReport, date: s.sessionDate, exerciseId: s.exerciseId, exerciseName: s.exerciseName,
                evidence: "\(s.exerciseName): load cut for \(reason.displayName.lowercased())"))
        }
        return out
    }
}
