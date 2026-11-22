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
///    could not write for incomplete evidence (fewer than min(planned sets, 3) primary sets), or the target is still at 0
///    although the evidence was complete (the plan had no baseline to judge against): the target gets the HELD load,
///    the last performed primary set's load (`CoachingEngine.heldLoad`). A skipped or unlogged set never lowers it and
///    never raises it.
/// 2. **No usable previous session** (missed, all sets skipped, or no such session exists), in this order:
///    (i) The most recent completed session of the same day label and the same letter with performed working sets,
///    within two rotations (a rotation is the number of distinct non-deload letters in the block, in weeks: 6 weeks for
///    A/B/C). Its held load, no estimate.
///    (ii) Otherwise the cross-letter estimate, and only for a target whose repMin is 12 or less: the most recent
///    completed session of the same day label (any letter) with working sets of 12 reps or fewer. Each set gives an Epley
///    max from its reps plus its logged RIR (a missing RIR counts as the item's target RIR); the best is converted to the
///    target's top rep plus its target RIR (the midpoint of a range), taken 5% lower, rounded DOWN to the exercise's step
///    and clamped to its max load. Floor: when the target's repMax is no more than the reps performed in the source
///    set that gave the estimate, the load is max(estimate, that set's load). The note reads "Estimated from your recent B-week sets — set 1 calibrates." Sources
///    come from the same block, or from the last 12 weeks.
///    (ii-hold) When no source set has 12 reps or fewer (so there is no estimate), the most recent same-day source set of MORE than
///    12 reps that still covers the target is held: its load is written unchanged, never raised, when
///    `sourceReps - max(0, targetRIR - sourceRIR) >= target.repMin` (the source's logged RIR; a missing one counts as the source
///    item's target RIR). The note reads "Held from your recent B-week sets — set 1 calibrates." A hold only fills a target that has
///    no load: a planned load is never replaced or lowered by it.
///    (cross-day) Last of all, only when (i), (ii) and (ii-hold) found nothing on the same day: the same exercise performed on
///    any other day of the same block within two rotations, with the same math (estimate, else hold). The note reads
///    "Estimated from your Lower A sets — set 1 calibrates." ("Held from ..." for a hold). A separate lookup: the day-label matcher
///    shared with the edit-safety checks is not involved.
///    (iii) Otherwise the load is left alone. A target not written since its block was created gets the one-time note
///    "No recent data for this week type — set 1 calibrates."; a target at 0 gets "No recent history — set a load.".
/// 3. **Lowering** is blocked only when, since the target was last written, the lifter performed a working set of that
///    exercise at a load at or above the target's load with reps at or above the target's `repMin`: the target was
///    shown to be doable. Otherwise it is lowered to the estimate. Never touches an edited item or a fixed-load one. A
///    previous session or source with a pain flag is left alone: pain holds.
///
/// A target at 0 load with no qualifying source gets the note "No recent history — set a load." (once) and stays at 0. The
/// note is cleared as soon as a load is written to the item, by this rule or by carry-forward (`clearStaleNoHistoryNote`), and on every refresh
/// pass from any unedited planned item that has a load or is not one the refresh loads (bodyweight, fixed-load, deload).
///
/// A performed set counts, a failed attempt (load > 0, no reps, no "SKIP") included; a performed WORKING set for rule 3
/// has reps (a failed attempt shows nothing doable).
///
/// **Scheduled deload weeks** (the template's own deload week, not an inserted one) are a separate pass: an unedited item of a
/// planned deload session gets `DeloadRule.sizing` from the lift's latest non-deload working load (min(RIR-4 sizing at repMin,
/// 0.95 x working load), rounded down), whatever load it holds, and is recomputed on every pass until a set is logged anywhere in that
/// week or the item is `planEdited`. Bodyweight items are never touched; a fixed-load item gets its fixed load. Sets, reps and RIR stay
/// as the template wrote them. A lift with no logged history stays as it is.
///
/// Idempotent: a target that already holds the computed load is not a change.
///
/// This replaced `MissedSourceSeeding` (the older rule for targets at 0 load only), which is gone: its trigger, its
/// estimator (now Epley from reps + RIR, 0.95) and its "No recent history — set a load." note live here.
///
/// Called from session completion (after the carry-forward write-back) and from the registered startup backfill
/// (`PlaceholderRefreshBackfill`). Both check `isEnabled`, the switch for turning the rule off.
enum PlaceholderRefresh {

    /// The gate for the two automatic entry points. `plan` / `apply` / `run` are not gated.
    static var isEnabled = true

    static let estimateFactor = 0.95
    static let maxSourceReps = 12
    static let sourceWindowWeeks = 12
    static let noRecentHistoryNote = "No recent history — set a load."
    static let placeholderNote = "No recent data for this week type — set 1 calibrates."
    /// The estimate converts a set to the target's rep range; a high-rep target (repMin above this) is never estimated.
    static let maxEstimatedTargetRepMin = 12

    enum Reason: Equatable {
        /// The previous session's last performed primary set; `performed` of `planned` sets were logged.
        case heldLoad(from: Date, performed: Int, planned: Int)
        /// Estimated from `from`; `why` says what the previous same-letter session did.
        case estimated(from: Date, letter: String?, e1RM: Double, why: String)
        /// The most recent same-letter session with performed sets within two rotations: its held load.
        case earlierSameLetter(from: Date, rotationWeeks: Int)
        /// No estimate was possible (every source set has more than 12 reps): the source set's load, unchanged. `math` shows the check.
        case heldHighRep(from: Date, source: String, math: String)
        /// The same exercise on another day of the block, estimated or held; `math` shows the arithmetic.
        case crossDay(from: Date, day: String, math: String)
        /// The note "No recent history — set a load." no longer holds: the item has a load, or is one the refresh never loads.
        case staleNoteCleared(why: String)
        /// A target at 0 with nothing to estimate from.
        case noRecentHistory(why: String)
        /// A target still at its block-setup value with nothing to estimate from.
        case placeholder(why: String)
        /// A scheduled deload item sized by `DeloadRule`.
        case scheduledDeload(DeloadRule.Sizing)

        var text: String {
            func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }
            switch self {
            case .heldLoad(let d, let performed, let planned):
                return "held load of the \(day(d)) session (\(performed) of \(planned) planned sets performed)"
            case .earlierSameLetter(let d, let weeks):
                return "held load of the last \(day(d)) session of this letter (within two \(weeks)-week rotations)"
            case .scheduledDeload(let z):
                func n(_ x: Double?) -> String { x.map { LoadFormatter.number($0) } ?? "-" }
                return "scheduled deload: working \(n(z.workingLoad)), RIR-4 sizing \(n(z.rirLoad)), 95% cap \(n(z.capLoad)) -> \(n(z.load)) [\(z.basis.rawValue)]"
            case .staleNoteCleared(let why):
                return "\"set a load\" note removed: \(why)"
            case .placeholder(let why):
                return "no source to estimate from; \(why); keeps its block-setup load with a note"
            case .noRecentHistory(let why):
                return "no recent history to estimate from; \(why); stays 0 with a note"
            case .heldHighRep(let d, let source, let math):
                return "held from the \(day(d)) session (\(source)); \(math)"
            case .crossDay(let d, let label, let math):
                return "from your \(label) session of \(day(d)); \(math)"
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
        /// True for a note-only change (no-history, placeholder): nothing about the load changes.
        var noteOnly = false
        var noteField: NoteField = .coach
    }

    enum NoteField { case coach, prescription, clearNoHistory }

    typealias Decision = (load: Double, reason: Reason, note: String?)

    /// What rule 2 decides for one target.
    enum Outcome {
        case write(Decision)
        case noHistoryNote(String)
        case placeholderNote(String)
        case leave
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

    /// `only`: restrict the pass to one item (the same rules, nothing else): an exercise just added to a planned or in-progress session.
    /// Without it every planned session from today on is covered, as at startup.
    static func plan(sessions all: [Session], ctx: Context, now: Date = Date(), only: SessionItem? = nil) -> [Change] {
        let today = Calendar.current.startOfDay(for: now)
        let completed = all.filter { $0.status == .completed }
        var changes: [Change] = []

        for target in all where (target.status == .planned || (only != nil && target.status == .inProgress)) && target.date >= today {
            if let only, !target.items.contains(where: { $0 === only }) { continue }
            guard let meso = target.meso, meso.status == .active, !meso.isMaintenance else { continue }
            let weekLogged = deloadWeekHasLoggedSet(target, meso: meso, in: all)
            for item in target.items where only == nil || item === only {
                if let change = scheduledDeloadChange(item, in: target, weekLogged: weekLogged, sessions: all, ctx: ctx, now: now) {
                    changes.append(change)
                    continue
                }
                // The note says the item has no load. When it has one, or is an item the refresh never loads (bodyweight, fixed-load, a
                // deload week), the note is stale: removed here, on every pass, whatever wrote the load. A hand-edited item is not touched.
                if !item.planEdited, item.prescriptionNotes?.contains(noRecentHistoryNote) == true {
                    let loaded = currentLoad(item) > 0
                    let loadable = eligible(item, ctx: ctx)
                    if loaded || !loadable {
                        changes.append(Change(session: target, item: item, oldLoad: currentLoad(item), newLoad: currentLoad(item),
                                              reason: .staleNoteCleared(why: loaded ? "the item has a load" : "the item is not one the refresh loads"),
                                              note: nil, noteOnly: true, noteField: .clearNoHistory))
                        if !loadable { continue }                   // a loadable item with a load still gets the rules below
                    }
                }
                guard eligible(item, ctx: ctx) else { continue }
                let letter = letterKey(item)
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

                let predecessor = all.last { s in
                    s.date < target.date && s.meso?.persistentModelID == meso.persistentModelID
                        && SessionDayLabelMatcher.matches(s.dayLabel, target.dayLabel)
                        && s.items.contains { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && letterKey($0) == letter }
                }
                let predItem = predecessor?.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && letterKey($0) == letter }

                var outcome: Outcome = .leave
                if let predecessor, let predItem {
                    if hasPain(predItem) { continue }                       // pain holds
                    if predecessor.status == .completed {
                        let performed = CoachingEngine.workingSetIndices(for: predItem)
                        if performed.isEmpty {
                            outcome = rule2(for: item, target: target, meso: meso, why: "the \(dayText(predecessor.date)) session had no performed sets",
                                            completed: completed, now: now, ctx: ctx)
                        } else if CoachingEngine.hasSufficientPrimaryEvidence(predItem) {
                            // Carry-forward owns a target that has a load. One still at 0 was never written (the plan the coach judged
                            // against had no baseline): it gets the held load, not a progression.
                            guard isZeroTarget(item), let held = CoachingEngine.heldLoad(for: predItem), held > 0 else { continue }
                            let count = CoachingEngine.plannedWorkingSetIndices(for: predItem).count
                            let planned = max(1, predItem.targetSets)
                            outcome = .write((held, .heldLoad(from: predecessor.date, performed: count, planned: planned),
                                              "Held at \(compact(held, ctx)) from \(dayText(predecessor.date)): the load you used."))
                        } else if let held = CoachingEngine.heldLoad(for: predItem), held > 0 {
                            let planned = max(1, predItem.targetSets)
                            let count = CoachingEngine.plannedWorkingSetIndices(for: predItem).count
                            outcome = .write((held, .heldLoad(from: predecessor.date, performed: count, planned: planned),
                                              "Held at \(compact(held, ctx)) from \(dayText(predecessor.date)): \(count) of \(planned) planned sets were performed."))
                        } else { continue }
                    } else if predecessor.date < today && predecessor.status != .inProgress {
                        outcome = rule2(for: item, target: target, meso: meso, why: "the \(dayText(predecessor.date)) session was missed",
                                        completed: completed, now: now, ctx: ctx)
                    } else { continue }                                     // upcoming or in progress: not yet decided
                } else {
                    outcome = rule2(for: item, target: target, meso: meso, why: "no earlier session of this letter",
                                    completed: completed, now: now, ctx: ctx)
                }
                let decision: Decision
                switch outcome {
                case .leave: continue
                case .noHistoryNote(let why):
                    changes.append(Change(session: target, item: item, oldLoad: 0, newLoad: 0, reason: .noRecentHistory(why: why),
                                          note: noRecentHistoryNote, noteOnly: true, noteField: .prescription))
                    continue
                case .placeholderNote(let why):
                    changes.append(Change(session: target, item: item, oldLoad: currentLoad(item), newLoad: currentLoad(item), reason: .placeholder(why: why),
                                          note: placeholderNote, noteOnly: true, noteField: .coach))
                    continue
                case .write(let d): decision = d
                }
                guard decision.load > 0 else { continue }

                let value = UserProfile.clampedLoad(decision.load, exerciseId: item.exerciseId, profile: ctx.profile, customExercises: ctx.customExercises)
                let current = currentLoad(item)
                if holdsLoad(item, value) { continue }                      // idempotent
                if value < current - 0.001,
                   performedAgainst(load: current, minReps: item.repMin ?? item.targetReps, canonical: canonical, since: meso.createdAt, in: completed) { continue }
                changes.append(Change(session: target, item: item, oldLoad: current, newLoad: value, reason: decision.reason, note: decision.note))
            }
        }
        return changes
    }

    // MARK: - Apply / run

    static func apply(_ changes: [Change], ctx: Context) {
        for c in changes {
            let fingerprint = c.item.writeFingerprint()
            defer { c.item.stampIfChanged(since: fingerprint) }
            if c.noteOnly {
                switch c.noteField {
                case .prescription:
                    let existing = c.item.prescriptionNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    c.item.prescriptionNotes = existing.isEmpty ? noRecentHistoryNote : existing + " " + noRecentHistoryNote
                case .coach:
                    c.item.coachNote = c.note
                case .clearNoHistory:
                    removeNoHistoryText(c.item)
                }
                continue
            }
            PlanMemoryEngine.applyPropagatedLoad(c.newLoad, to: c.item)
            PlanMemoryEngine.enforceMax(on: c.item, profile: ctx.profile, customExercises: ctx.customExercises)
            if let note = c.note { c.item.coachNote = note }
            clearStaleNoHistoryNote(c.item)
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

    /// A just-added item of a planned or in-progress session gets its load now, by the same rules as the startup pass (held load,
    /// cross-letter estimate, hold from a high-rep set, cross-day), instead of waiting for the next launch. The caller saves.
    @discardableResult
    static func refreshNewItem(_ item: SessionItem, in context: ModelContext, now: Date = Date()) -> [Change] {
        guard isEnabled else { return [] }
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let ctx = Context(profile: profile, customExercises: custom)
        guard let all = try? context.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])) else { return [] }
        let changes = plan(sessions: all, ctx: ctx, now: now, only: item)
        apply(changes, ctx: ctx)
        return changes
    }

    /// After a session is completed and carry-forward has written. The caller saves.
    static func afterCompletion(in context: ModelContext, now: Date = Date()) {
        guard isEnabled else { return }
        run(in: context, now: now)
    }

    // MARK: - Scheduled deload

    static let deloadNote = "Deload: lighter than your working weight, half the sets, stop well short of failure."
    static let fixedLoadDeloadNote = "Deload: your usual fixed load, half the sets, stop well short of failure."

    /// True when any set was logged in a session of the same week of the same block (the deload week is under way).
    private static func deloadWeekHasLoggedSet(_ target: Session, meso: MesoBlock, in all: [Session]) -> Bool {
        guard target.items.contains(where: { letterKey($0) == "deload" }) else { return false }
        return all.contains { s in
            s.meso?.persistentModelID == meso.persistentModelID && s.weekIndex == target.weekIndex
                && s.items.contains { $0.actualReps.contains { $0 > 0 } || $0.actualLoads.contains { $0 > 0 } }
        }
    }

    /// The change for one unedited item of a scheduled deload week, or nil when it is not one or nothing changes.
    private static func scheduledDeloadChange(_ item: SessionItem, in target: Session, weekLogged: Bool, sessions: [Session], ctx: Context, now: Date) -> Change? {
        guard letterKey(item) == "deload", target.insertedDeload != true, !item.planEdited, !weekLogged, item.targetSets > 0 else { return nil }
        let z = DeloadRule.sizing(exerciseId: item.exerciseId, repMin: item.repMin ?? item.targetReps, in: sessions,
                                  profile: ctx.profile, unit: ctx.unit, customExercises: ctx.customExercises, referenceDate: now)
        guard z.basis != .bodyweight, z.basis != .noHistory, z.load > 0 else { return nil }
        let current = currentLoad(item)
        let note = z.basis == .exempt ? fixedLoadDeloadNote : deloadNote
        if holdsLoad(item, z.load), item.coachNote == note { return nil }          // idempotent
        return Change(session: target, item: item, oldLoad: current, newLoad: z.load, reason: .scheduledDeload(z), note: note)
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

    private static func isZeroTarget(_ item: SessionItem) -> Bool {
        item.suggestedLoad <= 0 && !item.plannedLoadsBySet.isEmpty && item.plannedLoadsBySet.allSatisfy { $0 <= 0 }
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

    /// A completed working set of this exercise, dated after `since`, at `load` or above with at least `minReps` reps: the
    /// target's load was shown to be doable in its own rep range.
    private static func performedAgainst(load: Double, minReps: Int, canonical: String, since: Date?, in completed: [Session]) -> Bool {
        let floor = since ?? .distantPast
        for s in completed where s.date > floor {
            for i in s.items where ExerciseCatalog.canonicalExerciseId(for: i.exerciseId) == canonical && letterKey(i) != "deload" {
                if WorkingSetFilter.workingRows(of: i).contains(where: { $0.load >= load - 0.001 && $0.reps >= minReps }) { return true }
            }
        }
        return false
    }

    // MARK: Rule 2

    /// (i) the most recent same-day, same-letter session with performed sets, within two rotations: its held load, no
    /// estimate. (ii) else the cross-letter estimate, only for a target whose repMin is 12 or less. (iii) else leave the
    /// load; a target not written since the block was created gets a one-time placeholder note (a target at 0 gets the
    /// no-history note).
    private static func rule2(for item: SessionItem, target: Session, meso: MesoBlock, why: String, completed: [Session], now: Date, ctx: Context) -> Outcome {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        let letter = letterKey(item)
        let calendar = Calendar.current

        // (i)
        let letters = Set(meso.sessions.flatMap { $0.items.map(letterKey) }.filter { !$0.isEmpty && $0 != "deload" })
        let rotationWeeks = max(1, letters.count)
        let windowDays = 2 * rotationWeeks * 7
        let targetDay = calendar.startOfDay(for: target.date)
        let earlier = completed.filter { s in
            s.date < target.date && s.meso?.persistentModelID == meso.persistentModelID
                && SessionDayLabelMatcher.matches(s.dayLabel, target.dayLabel)
                && (calendar.dateComponents([.day], from: calendar.startOfDay(for: s.date), to: targetDay).day ?? Int.max) <= windowDays
        }.sorted { $0.date > $1.date }
        for s in earlier {
            guard let src = s.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && letterKey($0) == letter }),
                  !CoachingEngine.workingSetIndices(for: src).isEmpty else { continue }
            if hasPain(src) { return .leave }                               // pain holds
            guard let held = CoachingEngine.heldLoad(for: src), held > 0 else { continue }
            return .write((held, .earlierSameLetter(from: s.date, rotationWeeks: rotationWeeks),
                           "Held at \(compact(held, ctx)) from \(dayText(s.date)): your last \(letter.isEmpty ? "" : letter.uppercased() + "-week ")session."))
        }

        // (ii) estimate, else (ii-hold); then the cross-day lookup. Each stops the rule when it decides or when a pain flag holds.
        let cutoff = calendar.date(byAdding: .weekOfYear, value: -sourceWindowWeeks, to: now) ?? .distantPast
        let sameDay = completed.filter {
            $0.date < target.date && SessionDayLabelMatcher.matches($0.dayLabel, target.dayLabel)
                && ($0.meso?.persistentModelID == target.meso?.persistentModelID || $0.date >= cutoff)
        }.sorted { $0.date > $1.date }
        if let o = derive(for: item, from: sameDay, crossDay: false, why: why, ctx: ctx) { return o }

        let otherDays = completed.filter { s in
            s.date < target.date && s.meso?.persistentModelID == meso.persistentModelID
                && (calendar.dateComponents([.day], from: calendar.startOfDay(for: s.date), to: targetDay).day ?? Int.max) <= windowDays
        }.sorted { $0.date > $1.date }
        if let o = derive(for: item, from: otherDays, crossDay: true, why: why, ctx: ctx) { return o }

        // (iii)
        if isZeroTarget(item) {
            return item.prescriptionNotes?.contains(noRecentHistoryNote) == true ? .leave : .noHistoryNote(why)
        }
        if writtenSinceCreation(item, meso) == false, item.coachNote?.contains(placeholderNote) != true {
            return .placeholderNote(why)
        }
        return .leave
    }

    /// Whether a planned load was ever written onto the item after block setup (`SessionItem.loadEverWritten`), not read off a timestamp.
    private static func writtenSinceCreation(_ item: SessionItem, _ meso: MesoBlock) -> Bool? {
        guard meso.createdAt != nil else { return nil }       // a block with no creation date: nothing to compare setup against
        return item.loadEverWritten == true
    }

    /// The estimate, else the hold, over `candidates` (most recent first). nil when neither found a source (the caller goes on to
    /// the next lookup); `.leave` when a pain flag or a degenerate e1RM stops the rule.
    private static func derive(for item: SessionItem, from candidates: [Session], crossDay: Bool, why: String, ctx: Context) -> Outcome? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        let repMin = item.repMin ?? item.targetReps
        func source(in s: Session) -> SessionItem? {
            s.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && letterKey($0) != "deload" }
        }

        // Estimate: a source set of 12 reps or fewer, for a target whose repMin is 12 or less.
        if repMin <= maxEstimatedTargetRepMin {
            for s in candidates {
                guard let src = source(in: s) else { continue }
                let rows = WorkingSetFilter.workingRows(of: src).filter { $0.reps <= maxSourceReps }
                guard !rows.isEmpty else { continue }
                if hasPain(src) { return .leave }                           // pain holds
                // The set that gives the estimate (the highest e1RM; the first on a tie).
                var best: (e1rm: Double, load: Double, reps: Int, rir: Int)?
                for r in rows {
                    let rir = RIREntry.recorded(src, at: r.index) ?? src.targetRIR
                    let e = r.load * (1.0 + Double(r.reps + rir) / 30.0)
                    if best == nil || e > best!.e1rm { best = (e, r.load, r.reps, rir) }
                }
                guard let top = best, top.e1rm > 0 else { return .leave }
                let e1rm = top.e1rm

                let topReps = item.repMax ?? item.targetReps
                let rir: Double = {
                    if let lo = item.targetRIRMin, let hi = item.targetRIRMax { return Double(lo + hi) / 2 }
                    return Double(item.targetRIR)
                }()
                let raw = e1rm / (1.0 + (Double(topReps) + rir) / 30.0) * estimateFactor
                let step = CoachingEngine.loadIncrement(
                    for: item, base: raw,
                    minLoadIncrement: UserProfile.loadStep(for: item.exerciseId, profile: ctx.profile, unit: ctx.unit), unit: ctx.unit)
                var rounded = UnitAwareRounding.round(raw, increment: step, unit: ctx.unit, mode: .down)
                var floored = ""
                // Floor: a target whose top rep count is no more than the reps already done in the source set is not
                // an easier ask than that set, so it never writes below that set's load (the clamp to max load still applies).
                if topReps <= top.reps, top.load > rounded { rounded = top.load; floored = ", floored to the source set's load" }
                let math = "e1RM \(f(top.load)) x (1 + (\(top.reps) + \(top.rir))/30) = \(f(e1rm)); target \(topReps) reps at RIR \(f(rir)): \(f(e1rm)) / (1 + (\(topReps) + \(f(rir)))/30) x 0.95 = \(f(raw)), rounded down to \(f(step)) = \(f(rounded))\(floored)"
                let note: String
                if crossDay { note = "Estimated from your \(s.dayLabel ?? "other-day") sets — set 1 calibrates." }
                else {
                    let l = letterKey(src)
                    note = "Estimated from your recent \(l.isEmpty ? "" : l.uppercased() + "-week ")sets — set 1 calibrates."
                }
                let reason: Reason = crossDay ? .crossDay(from: s.date, day: s.dayLabel ?? "other day", math: "estimate: " + math)
                                              : .estimated(from: s.date, letter: letterKey(src).isEmpty ? nil : letterKey(src), e1RM: e1rm, why: why)
                return .write((rounded, reason, note))
            }
        }

        // Hold: no estimate is possible when every source set has more than 12 reps. The most recent such set that still covers the
        // target's repMin once its reserve is spent down to the target's RIR is held at its own load: never raised. It only fills a
        // target that has no load (or already holds that exact load); a planned load (a block-setup seed, a carried one) is never replaced or
        // lowered by a hold.
        let current = currentLoad(item)
        for s in candidates {
            guard let src = source(in: s) else { continue }
            let rows = WorkingSetFilter.workingRows(of: src).filter { $0.reps > maxSourceReps }
            guard !rows.isEmpty else { continue }
            if hasPain(src) { return .leave }                               // pain holds
            for r in rows.reversed() {                                      // the last set of the most recent session first
                let sourceRIR = RIREntry.recorded(src, at: r.index) ?? src.targetRIR
                let spend = max(0, item.targetRIR - sourceRIR)
                guard r.load > 0, CoachingEngine.adjustedReps(r.reps, targetRIR: item.targetRIR, recordedRIR: sourceRIR) >= repMin else { continue }
                if current > 0, abs(current - r.load) > 0.001 { return nil }       // a planned load is not replaced (the held value itself is: idempotent)
                let math = "\(r.reps) reps - max(0, target RIR \(item.targetRIR) - set RIR \(sourceRIR)) = \(r.reps - spend) >= repMin \(repMin): hold \(f(r.load))"
                let note: String
                let reason: Reason
                if crossDay {
                    note = "Held from your \(s.dayLabel ?? "other-day") sets — set 1 calibrates."
                    reason = .crossDay(from: s.date, day: s.dayLabel ?? "other day", math: "hold: " + math)
                } else {
                    let l = letterKey(src)
                    let which = l.isEmpty ? "" : l.uppercased() + "-week "
                    note = "Held from your recent \(which)sets — set 1 calibrates."
                    reason = .heldHighRep(from: s.date, source: l.isEmpty ? "a recent session" : "\(l.uppercased())-week", math: math)
                }
                return .write((r.load, reason, note))
            }
        }
        return nil
    }

    private static func f(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }

    /// The "No recent history — set a load." note is only true while the item has no load. Called wherever a load is written to
    /// an item (the refresh itself, and carry-forward on session completion): drops the note, leaving any other prescription note.
    static func clearStaleNoHistoryNote(_ item: SessionItem) {
        guard item.prescriptionNotes?.contains(noRecentHistoryNote) == true else { return }
        guard item.suggestedLoad > 0 || item.plannedLoadsBySet.contains(where: { $0 > 0 }) else { return }
        removeNoHistoryText(item)
    }

    /// Removes the exact note text from `prescriptionNotes`, leaving any other prescription note.
    static func removeNoHistoryText(_ item: SessionItem) {
        guard let notes = item.prescriptionNotes, notes.contains(noRecentHistoryNote) else { return }
        let rest = notes.replacingOccurrences(of: noRecentHistoryNote, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        item.prescriptionNotes = rest.isEmpty ? nil : rest
    }
}

/// Startup backfill for `PlaceholderRefresh`: refreshes the stale planned loads of the active block once at launch, and
/// logs one line. Idempotent (a refreshed target is no longer a change). Registered in `StartupBackfills` (where
/// `MissedSourceSeedBackfill` was); gated by `PlaceholderRefresh.isEnabled`.
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

/// One-time carry-over for items that predate `SessionItem.loadEverWritten`: the old reading of "was a load written after setup?" was
/// `item.updatedAt` later than the block's `createdAt` plus a minute (or either date unknown, which counted as written). Every item still
/// at nil (existing stores, old backups) gets that reading once, as true or false; items created from now on start at false and are
/// never nil, so a later launch finds nothing to do. After this the refresh never reads `updatedAt`.
enum LoadEverWrittenBackfill {
    static func carriedValue(_ item: SessionItem, meso: MesoBlock?) -> Bool {
        guard let created = meso?.createdAt, let updated = item.updatedAt else { return true }
        return updated > created.addingTimeInterval(60)
    }

    static func run(in context: ModelContext) -> Int {
        guard let sessions = try? context.fetch(FetchDescriptor<Session>()) else { return 0 }
        var n = 0
        for s in sessions {
            for i in s.items where i.loadEverWritten == nil { i.loadEverWritten = carriedValue(i, meso: s.meso); n += 1 }
        }
        return n
    }

    static func runIfNeeded(in context: ModelContext) {
        let n = run(in: context)
        guard n > 0 else { BackfillLog.note("ℹ️ load-ever-written carry-over not needed."); return }
        do { try context.save(); BackfillLog.note("✅ load-ever-written carry-over completed. Carried the reading over for \(n) items.") }
        catch { context.rollback(); BackfillLog.note("⚠️ load-ever-written carry-over save failed: \(error)") }
    }
}
