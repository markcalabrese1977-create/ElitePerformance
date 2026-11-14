// Domain/Analytics/WorkingSetFilter.swift
import Foundation

/// The one definition of which logged rows of an exercise are real work.
///
/// Extracted from `HistorySeedLoad.qualifyingSets` so seeding and analytics cannot disagree. Two views of the same
/// rows, kept apart on purpose:
///
/// - **Working sets** (`workingRows`): rows that are evidence of what the lifter can do at a load and rep count.
///   Reps and load present, not rest-pause, not drop, not skipped, and not a warm-up (under half of the item's
///   heaviest qualifying row). Used for e1RM, PRs and same-load comparisons.
/// - **Hard sets** (`hardSetRows`): rows that count as a set of stimulus. Every logged, non-skipped row that is not a
///   warm-up. A rest-pause or drop-set row counts as ONE set: its base set is the row, its extra segments live in
///   the pattern text and are never counted. Top rows count. Bodyweight rows count with no load.
///
/// Pure: reads one `SessionItem`'s arrays and nothing else. Loads are stored lb.
enum WorkingSetFilter {

    /// Sets lighter than this share of the heaviest row are warm-ups.
    static let warmupFraction = 0.5

    /// The marker `SessionView.persist` writes into `restPausePatternsBySet` for a skipped set.
    static let skipMarker = SessionEditSafety.skipMarker

    /// Which rows of an item a read covers. `backOff` = every row that is not a top row (all rows of an item with no
    /// top set). `top` = the top rows; an item with no logged top row contributes all its rows (history from before
    /// a top set existed is still the best evidence of what the lifter can do).
    enum Role { case backOff, top }

    struct Row: Equatable {
        let index: Int
        let reps: Int
        let load: Double
        /// Logged RIR, 0 when the array has no entry (the same default the seed has always used).
        let rir: Int
        let isTop: Bool
        let usedRestPause: Bool
        let hasDrop: Bool
    }

    private static func at<T>(_ a: [T], _ i: Int) -> T? { a.indices.contains(i) ? a[i] : nil }

    /// True when row `i` was skipped (the SKIP marker; its reason is in `setFeedbackBySet`).
    static func isSkipped(_ item: SessionItem, row i: Int) -> Bool {
        at(item.restPausePatternsBySet, i) == skipMarker
    }

    // MARK: - Working sets (seed / e1RM / PR)

    /// Logged working sets before the warm-up cut: reps and load present, not rest-pause, drop or skipped.
    /// Exactly `HistorySeedLoad.qualifyingSets` as it was.
    ///
    /// `isBodyweight` lets a row with no load qualify (a bodyweight set stores load 0). Seeding never passes it.
    static func qualifyingRows(of item: SessionItem, role: Role? = nil, isBodyweight: Bool = false) -> [Row] {
        let topRowsLogged = item.topRowIndices.contains { at(item.actualReps, $0).map { $0 > 0 } ?? false }
        return (0..<min(item.actualLoads.count, item.actualReps.count)).compactMap { i in
            switch role {
            case .backOff?: if item.isTopRow(i) { return nil }
            case .top?: if topRowsLogged && !item.isTopRow(i) { return nil }
            case nil: break
            }
            let reps = item.actualReps[i], load = item.actualLoads[i]
            guard reps > 0, isBodyweight || load > 0 else { return nil }
            if at(item.usedRestPauseFlags, i) == true { return nil }
            if let p = at(item.restPausePatternsBySet, i), !p.isEmpty { return nil }   // includes "SKIP"
            if let d = at(item.dropSetPatternsBySet, i), !d.isEmpty { return nil }
            return Row(index: i, reps: reps, load: load, rir: RIREntry.recorded(item, at: i) ?? 0,
                       isTop: item.isTopRow(i), usedRestPause: false, hasDrop: false)
        }
    }

    /// `rows` without warm-ups: loads under `warmupFraction` of the heaviest row are dropped.
    static func droppingWarmups(_ rows: [Row]) -> [Row] {
        guard let heaviest = rows.map(\.load).max() else { return [] }
        return rows.filter { $0.load >= heaviest * warmupFraction }
    }

    /// Working sets: qualifying rows minus warm-ups.
    static func workingRows(of item: SessionItem, role: Role? = nil, isBodyweight: Bool = false) -> [Row] {
        droppingWarmups(qualifyingRows(of: item, role: role, isBodyweight: isBodyweight))
    }

    // MARK: - Hard sets (volume)

    /// Rows that count as one hard set each, before any session-level (deload / maintenance) exclusion.
    /// Logged = reps > 0 and, unless the exercise is bodyweight, load > 0. Skipped rows never count. Rest-pause and
    /// drop rows are included once. Warm-ups (under half of the heaviest logged row) are not.
    static func hardSetRows(of item: SessionItem, isBodyweight: Bool) -> [Row] {
        let logged: [Row] = (0..<min(item.actualLoads.count, item.actualReps.count)).compactMap { i in
            let reps = item.actualReps[i], load = item.actualLoads[i]
            guard reps > 0, isBodyweight || load > 0 else { return nil }
            if isSkipped(item, row: i) { return nil }
            let rp = at(item.usedRestPauseFlags, i) == true || !(at(item.restPausePatternsBySet, i) ?? "").isEmpty
            let drop = !(at(item.dropSetPatternsBySet, i) ?? "").isEmpty
            return Row(index: i, reps: reps, load: load, rir: RIREntry.recorded(item, at: i) ?? 0,
                       isTop: item.isTopRow(i), usedRestPause: rp, hasDrop: drop)
        }
        return droppingWarmups(logged)
    }
}
