// Domain/Analytics/StallDetector.swift
import Foundation

/// Every threshold of stall detection, as data.
struct StallPolicy: Equatable {
    /// A lift is stalled when this many of its latest exposures (per lift, wave letter and role) set no new best.
    var exposures = 3
    /// A new best must beat the old one by more than this fraction of it (e1RM mode) to count; smaller gains are noise.
    var minImprovementFraction = 0.005
    /// "The same load" for the reps-based mode, in load steps.
    var loadToleranceIncrements = 1.0
    /// Only chains whose latest exposure is within this many days of `asOf` are "current" (a lift dropped long ago is not stalled, it is gone).
    var currentWithinDays = 56
    /// true (default): only the current block counts, so a lift re-seeded lower by a new block (a deliberate reset) is not
    /// "stalled" for failing to beat a record from the previous one. Needs at least `exposures + 1` exposures inside the
    /// block. false: the record is the lift's best on that letter across every block; a comparison across blocks belongs
    /// to meso-over-meso comparison (P5), not to stall flags.
    var currentBlockOnly = true
    static let `default` = StallPolicy()
}

/// One stalled lift on one wave letter.
struct Stall: Equatable {
    enum Metric: String { case e1RM, reps }
    enum Status: String {
        /// Still prescribed in the block and not progressing.
        case stalled
        /// No planned session left in the active block prescribes this lift on this letter: it is not stalled, it is gone.
        case noLongerProgrammed
    }

    var status: Status = .stalled

    let exerciseId: String
    let exerciseName: String
    /// "a" / "b" / "c", or "" for a block with no wave letters.
    let letter: String
    let isTop: Bool
    /// e1RM: the lift is judged on its best set's e1RM. reps: it is capped, fixed-load or bodyweight and is judged on
    /// mean reps per set at that load.
    let metric: Metric
    /// The record the lift has not beaten: e1RM (stored lb) or mean reps per set.
    let bestValue: Double
    let bestDate: Date
    /// The exposures since that record, oldest first (date, value).
    let sinceBest: [(date: Date, value: Double)]
    /// Load of the reps-mode comparison (stored lb); 0 in e1RM mode.
    let load: Double
    let evidence: String

    var exposuresSinceBest: Int { sinceBest.count }

    static func == (a: Stall, b: Stall) -> Bool {
        a.exerciseId == b.exerciseId && a.letter == b.letter && a.isTop == b.isTop && a.metric == b.metric
            && a.bestValue == b.bestValue && a.bestDate == b.bestDate && a.sinceBest.map(\.date) == b.sinceBest.map(\.date)
    }
}

/// Stall detection: pure, suggest-only, per lift and wave letter (and role: a top set is its own chain).
///
/// A chain is a lift's exposures on one letter, across blocks, oldest first. Deload weeks, inserted deloads, maintenance
/// blocks and exposures with a load-cutting override are not in it (`Exposures.build`), and a replaced lift is a
/// different canonical id, so its first exposure starts a new chain. Within the chain:
/// - **e1RM mode** (the default): each exposure's best working-set e1RM. A new best must beat the record by more than
///   `minImprovementFraction`. Stalled = the last `exposures` exposures set no new best.
/// - **reps mode** for a capped lift (at its max load), a fixed-load lift or a bodyweight lift, whose load cannot or
///   does not move: the metric is mean reps per set at the lift's current load (within `loadToleranceIncrements`), and
///   the record is the best of that over earlier exposures at that load. Stalled = the last `exposures` at that load
///   did not beat it.
/// Wave letters are compared only with themselves, so no cross-letter normalisation is needed.
enum StallDetector {

    static func stalls(
        in snapshot: AnalyticsSnapshot,
        policy: StallPolicy = .default,
        loadIncrementLb: Double,
        asOf: Date,
        unit: LoadUnit = .lb,
        maxLoad: (String) -> Double? = { _ in nil },
        isFixedLoad: (String) -> Bool = { _ in false }
    ) -> [Stall] {
        let exposures = Exposures.build(from: snapshot.sets.filter { $0.sessionDate <= asOf })
        struct Key: Hashable { let id: String; let letter: String; let isTop: Bool }
        let fmt = LoadFormatter(unit: unit)
        let tol = max(0, policy.loadToleranceIncrements) * loadIncrementLb
        let currentCutoff = asOf.addingTimeInterval(-Double(policy.currentWithinDays) * 86_400)
        var out: [Stall] = []

        for (key, list) in Dictionary(grouping: exposures, by: { Key(id: $0.chain.exerciseId, letter: $0.chain.letter, isTop: $0.chain.isTop) }) {
            var chain = list.sorted { ($0.date, $0.sessionKey) < ($1.date, $1.sessionKey) }
            guard let last = chain.last, last.date >= currentCutoff else { continue }
            if policy.currentBlockOnly { chain = chain.filter { $0.chain.mesoKey == last.chain.mesoKey } }

            func meanReps(_ e: Exposure, at load: Double) -> Double? {
                let reps = e.sets.filter { abs($0.load - load) <= tol }.map(\.reps)
                return reps.isEmpty ? nil : Double(reps.reduce(0, +)) / Double(reps.count)
            }
            let cap = maxLoad(key.id)
            let atCap = cap.map { last.heaviestLoad >= $0 - 0.5 * loadIncrementLb } ?? false
            let repsMode = last.isBodyweight || isFixedLoad(key.id) || atCap

            var values: [(e: Exposure, value: Double)]
            var load = 0.0
            if repsMode {
                load = last.heaviestLoad
                values = chain.compactMap { e in meanReps(e, at: load).map { (e, $0) } }
            } else {
                values = chain.compactMap { e in e.bestE1RM > 0 ? (e, e.bestE1RM) : nil }
            }
            guard values.count > policy.exposures else { continue }   // at least one exposure to set the record

            // The record and the exposure that set it (a gain must clear the threshold in e1RM mode, any gain in reps mode).
            var best = values[0].value, bestIndex = 0
            for i in values.indices.dropFirst() {
                let beats = repsMode ? values[i].value > best + 1e-9 : values[i].value > best * (1 + policy.minImprovementFraction)
                if beats { best = values[i].value; bestIndex = i }
            }
            let since = Array(values[(bestIndex + 1)...])
            guard since.count >= policy.exposures else { continue }

            let metric: Stall.Metric = repsMode ? .reps : .e1RM
            let nums = since.map { repsMode ? String(format: "%.1f", $0.value) : fmt.whole($0.value) }.joined(separator: ", ")
            let name = last.exerciseName
            let evidence: String
            if repsMode {
                evidence = "\(name)\(key.letter.isEmpty ? "" : " " + key.letter.uppercased()) at \(fmt.compact(load)): best \(String(format: "%.1f", best)) reps/set on \(day(values[bestIndex].e.date)); "
                    + "\(since.count) exposures since: \(nums)"
            } else {
                evidence = "\(name)\(key.letter.isEmpty ? "" : " " + key.letter.uppercased()): best e1RM \(fmt.whole(best)) on \(day(values[bestIndex].e.date)); "
                    + "\(since.count) exposures since: \(nums)"
            }
            // Programmed? Only knowable when the snapshot carries sessions; none = unknown = still treated as programmed.
            var status = Stall.Status.stalled
            if !snapshot.sessions.isEmpty {
                let remaining = snapshot.sessions.contains {
                    $0.mesoKey == last.chain.mesoKey && $0.status != .completed && !$0.isInsertedDeload && !$0.isDeloadWeek
                        && $0.prescribedLifts.contains { $0.exerciseId == key.id && $0.letter == key.letter }
                }
                if !remaining { status = .noLongerProgrammed }
            }
            out.append(Stall(
                status: status,
                exerciseId: key.id, exerciseName: name, letter: key.letter, isTop: key.isTop, metric: metric,
                bestValue: best, bestDate: values[bestIndex].e.date, sinceBest: since.map { ($0.e.date, $0.value) },
                load: load, evidence: evidence))
        }
        return out.sorted { ($0.exerciseName, $0.letter, $0.isTop ? 1 : 0) < ($1.exerciseName, $1.letter, $1.isTop ? 1 : 0) }
    }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}
