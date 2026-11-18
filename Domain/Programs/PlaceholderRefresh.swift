// Domain/Programs/PlaceholderRefresh.swift
import Foundation
import SwiftData

/// One rule, one path, for a planned load that no longer says what the lifter can do.
///
/// A planned exercise normally gets its load from carry-forward: the same exercise, same day, same wave letter, in the
/// previous session of that chain, written when that session is completed. Two things leave a target stale: the chain's
/// previous session gave the coach too little to write (some of its planned sets were not performed), or it gave nothing
/// at all (the session was missed, every set was skipped, or there is no earlier session of that letter). The target then
/// keeps whatever it was seeded with, possibly weeks old.
///
/// Runs on every unedited planned item (`planEdited == false`, not fixed-load, not bodyweight, not a deload week) of the
/// active block. For each, the previous same-day, same-letter session of the same block is found, and:
///
/// 1. **Held load.** It was completed, at least one working set was performed, no set was flagged for pain, and the coach
///    could not write for incomplete evidence (fewer than min(planned sets, 3) primary sets): the target gets the HELD load,
///    the last performed primary set's load (`CoachingEngine.heldLoad`). A skipped or unlogged set never lowers it and
///    never raises it.
/// 2. **Estimate.** It performed nothing (missed, all sets skipped, or no such session exists): take the most recent
///    completed session of the same day label (any letter) with working sets of 12 reps or fewer. Each set gives an
///    Epley max from its reps plus its logged RIR (a missing RIR counts as the item's target RIR); the best of them is
///    converted to the target's top rep plus its target RIR (the midpoint of a range), taken 5% lower, rounded DOWN to the
///    exercise's step and clamped to its max load. The note reads "Estimated from your recent B-week sets — set 1
///    calibrates." No qualifying source: the target is left alone. Sources come from the same block, or from the last
///    12 weeks.
/// 3. **Never** lowers a target the lifter has performed against since it was last written (a completed working set of
///    that exercise at or above its load), and never touches an edited item. A previous session with a pain flag is left
///    alone: pain holds. A performed set counts, a failed attempt (load > 0, no reps, no "SKIP") included.
///
/// Idempotent: a target that already holds the computed load is not a change.
///
/// This replaces `MissedSourceSeeding`, which was the second rule for targets at 0 load only (see its header).
///
/// Called from session completion (after the carry-forward write-back) and from a startup backfill. Both are gated by
/// `isEnabled`, which stays false until the backfill has been reviewed against the lifter's own data.
enum PlaceholderRefresh {

    /// The gate for the two automatic entry points. `plan` / `apply` / `run` are not gated.
    static var isEnabled = false

    static let estimateFactor = 0.95
    static let maxSourceReps = 12
    static let sourceWindowWeeks = 12

    enum Reason: Equatable {
        /// The previous session's last performed primary set; `performed` of `planned` sets were logged.
        case heldLoad(from: Date, performed: Int, planned: Int)
        /// Estimated from `from`; `why` says what the previous same-letter session did.
        case estimated(from: Date, letter: String?, e1RM: Double, why: String)

        var text: String {
            func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }
            switch self {
            case .heldLoad(let d, let performed, let planned):
                return "held load of the \(day(d)) session (\(performed) of \(planned) planned sets performed)"
            case .estimated(let d, let letter, let e1rm, let why):
                return "estimated from the \(day(d))\(letter.map { " \($0.uppercased())-week" } ?? "") session (e1RM \(Int(e1rm.rounded()))); \(why)"
            }
        }
    }

    struct Change {
        let session: Session
        let item: SessionItem
        let oldLoad: Double
        let newLoad: Double
        let reason: Reason
        let note: String?
    }

    struct Context {
        var profile: UserProfile?
        var customExercises: [CustomExercise] = []
        var unit: LoadUnit { profile?.loadUnit ?? .lb }
    }

    // MARK: - Plan (no writes)

    static func plan(in context: ModelContext, now: Date = Date()) -> [Change] {
        guard let all = try? context.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])) else { return [] }
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        return plan(sessions: all, ctx: Context(profile: profile, customExercises: custom), now: now)
    }

    static func plan(sessions all: [Session], ctx: Context, now: Date = Date()) -> [Change] {
        let today = Calendar.current.startOfDay(for: now)
        let completed = all.filter { $0.status == .completed }
        var changes: [Change] = []

        for target in all where target.status == .planned && target.date >= today {
            guard let meso = target.meso, meso.status == .active, !meso.isMaintenance else { continue }
            for item in target.items {
                guard eligible(item, ctx: ctx) else { continue }
                let letter = letterKey(item)
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

                let predecessor = all.last { s in
                    s.date < target.date && s.meso?.persistentModelID == meso.persistentModelID
                        && SessionDayLabelMatcher.matches(s.dayLabel, target.dayLabel)
                        && s.items.contains { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && letterKey($0) == letter }
                }
                let predItem = predecessor?.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && letterKey($0) == letter }

                let decision: (load: Double, reason: Reason, note: String?)?
                if let predecessor, let predItem {
                    if hasPain(predItem) { continue }                       // pain holds
                    if predecessor.status == .completed {
                        let performed = CoachingEngine.workingSetIndices(for: predItem)
                        if performed.isEmpty {
                            decision = estimate(for: item, target: target, why: "the \(dayText(predecessor.date)) session had no performed sets",
                                                completed: completed, now: now, ctx: ctx)
                        } else if CoachingEngine.hasSufficientPrimaryEvidence(predItem) {
                            continue                                       // carry-forward owns it
                        } else if let held = CoachingEngine.heldLoad(for: predItem), held > 0 {
                            let planned = max(1, predItem.targetSets)
                            decision = (held, .heldLoad(from: predecessor.date, performed: CoachingEngine.plannedWorkingSetIndices(for: predItem).count, planned: planned),
                                        "Held at \(compact(held, ctx)) from \(dayText(predecessor.date)): \(CoachingEngine.plannedWorkingSetIndices(for: predItem).count) of \(planned) planned sets were performed.")
                        } else { continue }
                    } else if predecessor.date < today && predecessor.status != .inProgress {
                        decision = estimate(for: item, target: target, why: "the \(dayText(predecessor.date)) session was missed",
                                            completed: completed, now: now, ctx: ctx)
                    } else { continue }                                     // upcoming or in progress: not yet decided
                } else {
                    decision = estimate(for: item, target: target, why: "no earlier session of this letter", completed: completed, now: now, ctx: ctx)
                }
                guard let decision, decision.load > 0 else { continue }

                let value = UserProfile.clampedLoad(decision.load, exerciseId: item.exerciseId, profile: ctx.profile, customExercises: ctx.customExercises)
                let current = currentLoad(item)
                if holdsLoad(item, value) { continue }                      // idempotent
                if value < current - 0.001, performedAgainst(load: current, canonical: canonical, since: item.updatedAt, in: completed) { continue }
                changes.append(Change(session: target, item: item, oldLoad: current, newLoad: value, reason: decision.reason, note: decision.note))
            }
        }
        return changes
    }

    // MARK: - Apply / run

    static func apply(_ changes: [Change], ctx: Context) {
        for c in changes {
            PlanMemoryEngine.applyPropagatedLoad(c.newLoad, to: c.item)
            PlanMemoryEngine.enforceMax(on: c.item, profile: ctx.profile, customExercises: ctx.customExercises)
            if let note = c.note { c.item.coachNote = note }
            // planEdited stays false: this is an automatic write.
        }
    }

    @discardableResult
    static func run(in context: ModelContext, now: Date = Date()) -> [Change] {
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let ctx = Context(profile: profile, customExercises: custom)
        guard let all = try? context.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])) else { return [] }
        let changes = plan(sessions: all, ctx: ctx, now: now)
        apply(changes, ctx: ctx)
        return changes
    }

    /// After a session is completed and carry-forward has written. The caller saves.
    static func afterCompletion(in context: ModelContext, now: Date = Date()) {
        guard isEnabled else { return }
        run(in: context, now: now)
    }

    // MARK: - Pieces

    private static func eligible(_ item: SessionItem, ctx: Context) -> Bool {
        !item.planEdited && item.targetSets > 0
            && letterKey(item) != "deload"
            && !ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: ctx.customExercises)
            && !UserProfile.isProgressionExempt(exerciseId: item.exerciseId, profile: ctx.profile)
    }

    private static func letterKey(_ item: SessionItem) -> String {
        item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }

    private static func hasPain(_ item: SessionItem) -> Bool {
        item.setFeedbackBySet.contains(SetFeedback.pain.rawValue)
    }

    private static func dayText(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

    private static func compact(_ load: Double, _ ctx: Context) -> String { LoadFormatter(unit: ctx.unit).compact(load) }

    /// What the target plans now: its suggested load, or its heaviest back-off slot when that is 0.
    private static func currentLoad(_ item: SessionItem) -> Double {
        if item.suggestedLoad > 0 { return item.suggestedLoad }
        return item.backOffValues(item.plannedLoadsBySet).max() ?? 0
    }

    /// True when the target already plans exactly `value` on its suggested load and every back-off slot.
    private static func holdsLoad(_ item: SessionItem, _ value: Double) -> Bool {
        guard abs(item.suggestedLoad - value) < 0.001 else { return false }
        let slots = item.backOffValues(item.plannedLoadsBySet).prefix(max(0, item.targetSets))
        return !slots.isEmpty && slots.allSatisfy { abs($0 - value) < 0.001 }
    }

    /// A completed working set of this exercise, dated after `since`, at or above `load`.
    private static func performedAgainst(load: Double, canonical: String, since: Date?, in completed: [Session]) -> Bool {
        let floor = since ?? .distantPast
        for s in completed where s.date > floor {
            for i in s.items where ExerciseCatalog.canonicalExerciseId(for: i.exerciseId) == canonical && letterKey(i) != "deload" {
                if WorkingSetFilter.workingRows(of: i).contains(where: { $0.load >= load - 0.001 }) { return true }
            }
        }
        return false
    }

    // MARK: Rule 2

    private static func estimate(for item: SessionItem, target: Session, why: String, completed: [Session], now: Date, ctx: Context)
        -> (load: Double, reason: Reason, note: String?)? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -sourceWindowWeeks, to: now) ?? .distantPast
        let candidates = completed.filter {
            $0.date < target.date && SessionDayLabelMatcher.matches($0.dayLabel, target.dayLabel)
                && ($0.meso?.persistentModelID == target.meso?.persistentModelID || $0.date >= cutoff)
        }.sorted { $0.date > $1.date }

        for s in candidates {
            guard let src = s.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && letterKey($0) != "deload" }) else { continue }
            let rows = WorkingSetFilter.workingRows(of: src).filter { $0.reps <= maxSourceReps }
            guard !rows.isEmpty else { continue }
            if hasPain(src) { return nil }                                  // pain holds
            let e1rm = rows.map { r -> Double in
                let rir = RIREntry.recorded(src, at: r.index) ?? src.targetRIR
                return r.load * (1.0 + Double(r.reps + rir) / 30.0)
            }.max() ?? 0
            guard e1rm > 0 else { return nil }

            let topReps = item.repMax ?? item.targetReps
            let rir: Double = {
                if let lo = item.targetRIRMin, let hi = item.targetRIRMax { return Double(lo + hi) / 2 }
                return Double(item.targetRIR)
            }()
            let raw = e1rm / (1.0 + (Double(topReps) + rir) / 30.0) * estimateFactor
            let step = CoachingEngine.loadIncrement(
                for: item, base: raw,
                minLoadIncrement: UserProfile.loadStep(for: item.exerciseId, profile: ctx.profile, unit: ctx.unit), unit: ctx.unit)
            let rounded = UnitAwareRounding.round(raw, increment: step, unit: ctx.unit, mode: .down)
            let letter = letterKey(src).isEmpty ? nil : letterKey(src)
            let note = "Estimated from your recent \(letter.map { "\($0.uppercased())-week " } ?? "")sets — set 1 calibrates."
            return (rounded, .estimated(from: s.date, letter: letter, e1RM: e1rm, why: why), note)
        }
        return nil
    }
}

/// Startup backfill for `PlaceholderRefresh`: refreshes the stale planned loads of the active block once at launch, and
/// logs one line. Idempotent (a refreshed target is no longer a change). NOT REGISTERED in `StartupBackfills` until the
/// list of what it would change on the lifter's real data has been reviewed; gated by `PlaceholderRefresh.isEnabled`.
enum PlaceholderRefreshBackfill {
    static func runIfNeeded(in context: ModelContext) {
        guard PlaceholderRefresh.isEnabled else {
            BackfillLog.note("ℹ️ placeholder refresh is off.")
            return
        }
        let changes = PlaceholderRefresh.run(in: context)
        guard !changes.isEmpty else {
            BackfillLog.note("ℹ️ placeholder refresh not needed.")
            return
        }
        do {
            try context.save()
            BackfillLog.note("✅ placeholder refresh completed. Updated \(changes.count) planned exercises.")
        } catch {
            context.rollback()
            BackfillLog.note("⚠️ placeholder refresh save failed: \(error)")
        }
    }
}
