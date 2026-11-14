import Foundation
import SwiftData

/// A planned target at zero load, because the session that would have carried a load into it (the same-letter predecessor)
/// was never completed, is seeded from history instead of staying at 0.
///
/// Source: the most recent COMPLETED session of the same meso and the same dayLabel (any letter) before the target; when
/// the block has none, the most recent completed session of that exercise anywhere within the last 12 weeks; older or none
/// leaves the load at 0 with the note "No recent history — set a load". Its best working set (reps only, no RIR credit) gives
/// an e1RM, which is converted to the target's reps and RIR, taken 2.5% lower (conservative), and rounded DOWN to the
/// lifter's load step. A target with recent history is never left at 0. Nothing the lifter edited (`planEdited`) is touched.
enum MissedSourceSeeding {

    static let conservativeFactor = 0.975

    struct Seed {
        let session: Session
        let item: SessionItem
        let loads: [Double]
        let suggestedLoad: Double
        let note: String
        let fromDate: Date
        let missedDate: Date?
        /// True when nothing recent exists to seed from: the load stays 0 and only the note is written.
        var isNoRecentHistory: Bool { loads.allSatisfy { $0 <= 0 } }
    }

    /// The any-block fallback only trusts sessions this recent.
    static let fallbackWindowWeeks = 12
    static let noRecentHistoryNote = "No recent history — set a load"
    private static let seededMarker = "Seeded from"


    struct Context {
        var profile: UserProfile?
        var customExercises: [CustomExercise] = []
        var unit: LoadUnit { profile?.loadUnit ?? .lb }
        var minLoadIncrement: Double { profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: profile?.loadUnit ?? .lb) }
    }

    private static func isZeroTarget(_ item: SessionItem) -> Bool {
        !item.planEdited && item.suggestedLoad <= 0 && !item.plannedLoadsBySet.isEmpty && item.plannedLoadsBySet.allSatisfy { $0 <= 0 }
    }

    /// Best reps-only e1RM of one session's matching item (working sets only).
    private static func e1RM(in session: Session, canonicalId: String) -> Double? {
        guard let match = session.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId }) else { return nil }
        if match.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() == "deload" { return nil }
        let rows = WorkingSetFilter.droppingWarmups(WorkingSetFilter.qualifyingRows(of: match, role: nil))
        var best = 0.0
        for r in rows {
            best = max(best, E1RMCalculator.e1RM(load: r.load, reps: r.reps))
        }
        return best > 0 ? best : nil
    }

    private static func dayText(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

    /// What would be written, without writing it. `now` bounds the targets to today onward.
    static func plan(in context: ModelContext, ctx: Context, now: Date = Date(), meso: MesoBlock? = nil) -> [Seed] {
        guard let all = try? context.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])) else { return [] }
        let today = Calendar.current.startOfDay(for: now)
        let completed = all.filter { $0.status == .completed }
        var seeds: [Seed] = []

        for target in all where target.status == .planned && target.date >= today {
            guard let tm = target.meso, !tm.isMaintenance else { continue }
            if let meso, tm.persistentModelID != meso.persistentModelID { continue }
            for item in target.items where isZeroTarget(item) {
                if item.waveRaw?.lowercased() == "deload" { continue }
                if ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: ctx.customExercises) { continue }
                if UserProfile.isProgressionExempt(exerciseId: item.exerciseId, profile: ctx.profile) { continue }
                let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

                // 1) latest completed session of this day type in this block, any letter; 2) latest anywhere.
                let sameDay = completed.filter {
                    $0.date < target.date && $0.meso?.persistentModelID == tm.persistentModelID
                        && SessionDayLabelMatcher.matches($0.dayLabel, target.dayLabel)
                }.sorted { $0.date > $1.date }
                let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -fallbackWindowWeeks, to: now) ?? .distantPast
                let anywhere = completed.filter { $0.date < target.date && $0.date >= cutoff }.sorted { $0.date > $1.date }
                var source: (session: Session, e1rm: Double)?
                for s in sameDay + anywhere {
                    if let e = e1RM(in: s, canonicalId: canonical) { source = (s, e); break }
                }
                guard let source else {
                    // Older than 12 weeks, or none: leave the load at 0 and say so (once).
                    if item.prescriptionNotes?.contains(noRecentHistoryNote) != true {
                        seeds.append(Seed(session: target, item: item, loads: item.plannedLoadsBySet.map { _ in 0 }, suggestedLoad: 0,
                                          note: noRecentHistoryNote + ".", fromDate: target.date, missedDate: nil))
                    }
                    continue
                }

                let rowCount = item.plannedLoadsBySet.count
                var loads: [Double] = []
                for i in 0..<rowCount {
                    let reps = (i < item.plannedRepsBySet.count && item.plannedRepsBySet[i] > 0) ? item.plannedRepsBySet[i] : item.targetReps
                    let rir = i < item.plannedRIRsBySet.count ? item.plannedRIRsBySet[i] : item.targetRIR
                    let raw = E1RMCalculator.load(for: source.e1rm, reps: reps, targetRIR: rir) * conservativeFactor
                    let step = CoachingEngine.loadIncrement(for: item, base: raw, minLoadIncrement: ctx.minLoadIncrement, unit: ctx.unit)
                    let rounded = HistorySeedLoad.roundedDown(raw, increment: step, unit: ctx.unit)
                    loads.append(UserProfile.clampedLoad(rounded, exerciseId: item.exerciseId, profile: ctx.profile, customExercises: ctx.customExercises))
                }
                guard loads.contains(where: { $0 > 0 }) else { continue }
                let firstBackOff = (0..<rowCount).first { !item.isTopRow($0) && loads[$0] > 0 } ?? loads.firstIndex { $0 > 0 } ?? 0

                // The same-letter predecessor whose day has passed without being completed (a later one is simply not done yet).
                let letter = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let missed = all.last {
                    $0.status != .completed && $0.date < today && $0.meso?.persistentModelID == tm.persistentModelID
                        && SessionDayLabelMatcher.matches($0.dayLabel, target.dayLabel)
                        && $0.items.contains {
                            ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical
                                && ($0.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? "") == letter
                        }
                }
                let note = missed.map { "Seeded from \(dayText(source.session.date)) — \(dayText($0.date)) was missed." }
                    ?? "Seeded from \(dayText(source.session.date))."
                seeds.append(Seed(session: target, item: item, loads: loads, suggestedLoad: loads[firstBackOff], note: note,
                                  fromDate: source.session.date, missedDate: missed?.date))
            }
        }
        return seeds
    }

    static func apply(_ seeds: [Seed]) {
        for s in seeds {
            var existing = s.item.prescriptionNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if s.isNoRecentHistory {
                s.item.prescriptionNotes = existing.isEmpty ? s.note : existing + " " + s.note
                continue
            }
            s.item.plannedLoadsBySet = s.loads
            s.item.suggestedLoad = s.suggestedLoad
            existing = existing.replacingOccurrences(of: noRecentHistoryNote + ".", with: "").trimmingCharacters(in: .whitespaces)
            if !existing.contains(seededMarker) {
                s.item.prescriptionNotes = existing.isEmpty ? s.note : existing + " " + s.note
            }
        }
    }

    /// Plans and applies (no save), reading the lifter's profile from the store. Returns what was written.
    @discardableResult
    static func run(in context: ModelContext, now: Date = Date(), meso: MesoBlock? = nil) -> [Seed] {
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let seeds = plan(in: context, ctx: Context(profile: profile, customExercises: custom), now: now, meso: meso)
        apply(seeds)
        return seeds
    }
}

/// Startup backfill: seeds the planned targets that sit at 0 load although history exists. Idempotent: once a target has a
/// load it is no longer a candidate, so there is no flag to persist.
enum MissedSourceSeedBackfill {
    static func runIfNeeded(in context: ModelContext) {
        let seeds = MissedSourceSeeding.run(in: context)
        guard !seeds.isEmpty else {
            BackfillLog.note("ℹ️ missed-source seeding not needed.")
            return
        }
        do {
            try context.save()
            BackfillLog.note("✅ missed-source seeding completed. Seeded \(seeds.count) planned exercises.")
        } catch {
            context.rollback()
            BackfillLog.note("⚠️ missed-source seeding save failed: \(error)")
        }
    }
}
