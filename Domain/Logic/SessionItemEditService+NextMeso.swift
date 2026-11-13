import Foundation
import SwiftData

// MARK: - Start the next meso from this one

/// Builds a new meso that keeps a meso's CURRENT program (latest roster, prescriptions and cues per day
/// type and wave letter, and its week-by-week set counts) on new dates, with loads seeded from the
/// lifter's history. Same shape as the other edits: `planNextMeso` is a pure read for the preview;
/// `startNextMeso` (apply) re-plans against live state, writes, verifies and saves once, or restores.
///
/// TEMPLATE. The old meso's early weeks may hold exercises or prescriptions that were later replaced or
/// changed (those edits only touch remaining sessions), so weeks are not cloned as stored. Instead, for
/// every day type x wave letter the LATEST session of that letter (completed or planned) supplies the
/// roster, order, prescription fields, cue and wave; the old meso's week -> letter pattern lays out the
/// weeks. Inserted deload weeks are not part of the program and are skipped (weeks are renumbered
/// contiguously). Set counts are not stored as a ramp, so each new week's set count is read back from
/// the old meso's same week and slot (earned +1 sets, hand edits and the template ramp all reproduce);
/// the set band is widened to include it, never narrowed. A block with no wave letters (maintenance,
/// legacy) has one template per day type: its latest session.
extension SessionItemEditService {

    /// Peak-based seed scale (the "95" in peak95). Phase 4.4 gating can pass a different factor.
    static let nextMesoPeakFactor = 0.95

    enum NextMesoRefusal: Equatable {
        /// The meso has no sessions to copy from.
        case nothingToCopy
        /// A session in the old meso is being trained.
        case sessionInProgress
        /// The start date is before today.
        case startInPast
        /// The old meso still has sessions dated today or later and `endOldMesoNow` is false (see `remainingOldSessions`).
        case oldMesoHasRemainingSessions
        /// `endOldMesoNow` would remove a remaining session that already has something logged on it.
        case remainingSessionHasLoggedData
        /// One week of the old meso has two sessions of the same day type, so the weekday pattern is ambiguous.
        case duplicateDayLabelInWeek
        /// A new session would land on a day that already has a session (see `collisions`).
        case dateCollision
    }

    enum NextMesoError: Error, Equatable {
        case refused([NextMesoRefusal])
        /// The live state no longer matches the plan.
        case planStale
        case verificationFailed([String])
        case saveFailed(String)
    }

    struct NextMesoCollision {
        let date: Date
        let dayLabel: String?
        /// The existing session on that day; nil when two sessions of the new meso share it.
        let occupant: Session?
    }

    struct NextMesoItem {
        let order: Int
        let exerciseId: String
        let exerciseName: String?
        let targetReps: Int
        let targetSets: Int
        let targetRIR: Int
        let setMin: Int?, setMax: Int?, repMin: Int?, repMax: Int?, rirMin: Int?, rirMax: Int?
        let waveRaw: String?
        let priorityRaw: String?
        let intensifierRaw: String?
        let intensifierNotes: String?
        let prescriptionNotes: String?
        /// Back-off rows followed by the top rows (`topCount` of them).
        let plannedReps: [Int]
        let plannedRIRs: [Int]
        let seed: Double
        let seedSource: HistorySeedLoad.SeedSource
        /// Top set inherited from the latest week of this lift (0 = none). The top load is seeded
        /// separately, from top reps/RIR.
        let topCount: Int
        let topRepMin: Int?, topRepMax: Int?, topRIR: Int?
        let topSeed: Double
        let isBodyweight: Bool
        /// The latest session item this one was taken from.
        let templateItem: SessionItem

        /// "4 x 4-6 @ RIR 2-3"
        var prescription: String {
            func range(_ lo: Int?, _ hi: Int?, _ fallback: Int) -> String {
                guard let lo, let hi else { return "\(fallback)" }
                return lo == hi ? "\(lo)" : "\(lo)-\(hi)"
            }
            let backOffs = "\(targetSets) x \(range(repMin, repMax, targetReps)) @ RIR \(range(rirMin, rirMax, targetRIR))"
            guard topCount > 0 else { return backOffs }
            return "\(topCount) x \(range(topRepMin, topRepMax, targetReps)) @ RIR \(topRIR ?? targetRIR) top + \(backOffs)"
        }
    }

    struct NextMesoSession {
        let date: Date
        let dayLabel: String?
        /// 1-based, contiguous (inserted deload weeks of the old meso are skipped).
        let weekIndex: Int
        /// 1...K in date order across the whole new meso.
        let programIndex: Int
        /// Wave letter of the week ("a", "b", "c", "deload"); "" for a block with no letters.
        let letter: String
        let sessionNotes: String
        let items: [NextMesoItem]
        /// The latest session of this day type and letter, which supplied the roster.
        let templateSession: Session
    }

    struct NextMesoPlan {
        let oldMeso: MesoBlock
        let name: String
        let startDate: Date
        let endOldMesoNow: Bool
        let peakFactor: Double
        let now: Date
        let sessions: [NextMesoSession]
        let weeks: Int
        let endDate: Date?
        /// Old meso sessions removed when `endOldMesoNow` (planned, dated today or later, nothing logged).
        let sessionsToDelete: [Session]
        /// Old meso sessions dated today or later that are not completed.
        let remainingOldSessions: [Session]
        let collisions: [NextMesoCollision]
        let refusals: [NextMesoRefusal]
        /// The lifter's unit, for the preview text only (the seeds themselves are stored lb).
        var unit: LoadUnit = .lb

        var isApplicable: Bool { refusals.isEmpty && !sessions.isEmpty }
        var isMaintenance: Bool { oldMeso.isMaintenance }

        /// The sessions of week 1 (the first week the lifter will train).
        var firstWeek: [NextMesoSession] { sessions.filter { $0.weekIndex == 1 } }

        /// The preview as text: header, one roster per day type x letter (prescription, seed and where it
        /// came from), and the set count by week for every slot.
        func previewLines() -> [String] {
            var out: [String] = []
            func day(_ d: Date?) -> String { d.map(SessionItemEditService.isoDay) ?? "-" }
            out.append("NEXT MESO \"\(name)\": \(weeks) weeks, \(sessions.count) sessions, \(day(startDate)) -> \(day(endDate)); "
                       + "from \"\(oldMeso.name)\"; peak factor \(peakFactor)")
            if endOldMesoNow {
                out.append("old meso ends now: \(sessionsToDelete.count) remaining planned sessions removed")
            }
            var seen = Set<String>()
            for s in sessions {
                let key = "\(s.dayLabel ?? "")|\(s.letter)"
                guard seen.insert(key).inserted else { continue }
                out.append("  \(s.dayLabel ?? "?") / \(s.letter.isEmpty ? "-" : s.letter.uppercased()) (first week \(s.weekIndex), \(day(s.date)))")
                for i in s.items {
                    out.append("    \(ExerciseCatalog.displayName(for: i.exerciseId)): \(i.prescription), seed "
                               + "\(LoadFormatter(unit: unit).number(i.seed)) [\(i.seedSource.label(factor: peakFactor))]"
                               + (SessionItemEditService.noteText(i).map { " — \($0)" } ?? ""))
                }
            }
            var labels: [String] = []
            for s in sessions where !labels.contains(s.dayLabel ?? "") { labels.append(s.dayLabel ?? "") }
            for label in labels {
                out.append("  sets by week, \(label.isEmpty ? "?" : label):")
                let mine = sessions.filter { ($0.dayLabel ?? "") == label }
                let orders = Set(mine.flatMap { $0.items.map(\.order) }).sorted()
                for o in orders {
                    let name = mine.compactMap { $0.items.first { $0.order == o }?.exerciseId }.last.map(ExerciseCatalog.displayName(for:)) ?? "?"
                    let sets = mine.sorted { $0.weekIndex < $1.weekIndex }.map { s in s.items.first { $0.order == o }.map { String($0.targetSets) } ?? "-" }
                    out.append("    \(name): \(sets.joined(separator: ","))")
                }
            }
            return out
        }
    }

    fileprivate static func noteText(_ i: NextMesoItem) -> String? {
        NoteFields(intensifier: i.intensifierNotes, prescription: i.prescriptionNotes).displayed
    }

    /// Sessions of `meso` dated today or later that are not finished: what an unfinished meso still has ahead of it.
    static func remainingSessions(of meso: MesoBlock, now: Date = Date(), calendar: Calendar = .current) -> [Session] {
        let startOfToday = calendar.startOfDay(for: now)
        return meso.sessions.filter { $0.status != .completed && $0.date >= startOfToday }
    }

    /// The day after the meso's last session, at the start of its day; nil for a meso with no sessions.
    /// The set count the program prescribed for `item` (an item of `session`), among the meso's sessions `all`.
    /// An item that carries `prescribedSets` answers with it. One that does not (data from before the key
    /// existed) on a COMPLETED session may carry an in-session Add Set, so it takes the nearest same-day-type,
    /// same-wave session of the meso that does carry the key; with none, today's `targetSets`. A planned
    /// session's `targetSets` already is the prescription.
    static func prescribedSetCount(of item: SessionItem, in session: Session, among all: [Session]) -> Int {
        if let p = item.prescribedSets { return p }
        guard session.status == .completed else { return item.targetSets }
        let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        let wave = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let nearest = all.compactMap { other -> (gap: TimeInterval, sets: Int)? in
            guard other !== session, SessionDayLabelMatcher.matches(other.dayLabel, session.dayLabel),
                  let match = other.items.first(where: {
                      ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical
                          && ($0.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? "") == wave
                  }),
                  let sets = match.prescribedSets else { return nil }
            return (abs(other.date.timeIntervalSince(session.date)), sets)
        }.min { $0.gap < $1.gap }
        return nearest?.sets ?? item.targetSets
    }

    static func defaultNextMesoStart(for meso: MesoBlock, calendar: Calendar = .current) -> Date? {
        guard let last = meso.sessions.map(\.date).max() else { return nil }
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    // MARK: Plan (no writes)

    static func planNextMeso(
        meso: MesoBlock,
        name: String,
        startDate: Date? = nil,
        endOldMesoNow: Bool,
        peakFactor: Double = nextMesoPeakFactor,
        context: ModelContext,
        now: Date = Date(),
        calendar cal: Calendar = .current
    ) -> NextMesoPlan {
        let startOfToday = cal.startOfDay(for: now)
        let startDay = cal.startOfDay(for: startDate ?? defaultNextMesoStart(for: meso, calendar: cal) ?? now)
        let all = meso.sessions
        var refusals: [NextMesoRefusal] = []

        let remaining = remainingSessions(of: meso, now: now, calendar: cal)
        let toDelete = endOldMesoNow ? all.filter { $0.status == .planned && $0.date >= startOfToday && SessionEditSafety.isSafeToModify($0) } : []

        func plan(sessions: [NextMesoSession] = [], weeks: Int = 0, collisions: [NextMesoCollision] = []) -> NextMesoPlan {
            var built = NextMesoPlan(oldMeso: meso, name: name, startDate: startDay, endOldMesoNow: endOldMesoNow, peakFactor: peakFactor,
                                     now: now, sessions: sessions, weeks: weeks, endDate: sessions.map(\.date).max(),
                                     sessionsToDelete: toDelete, remainingOldSessions: remaining, collisions: collisions,
                                     refusals: refusals)
            built.unit = (try? context.fetch(FetchDescriptor<UserProfile>()).first)?.loadUnit ?? .lb
            return built
        }

        let sources = all.filter { $0.insertedDeload != true }
        guard !sources.isEmpty else { refusals.append(.nothingToCopy); return plan() }

        if all.contains(where: { $0.status == .inProgress }) { refusals.append(.sessionInProgress) }
        if startDay < startOfToday { refusals.append(.startInPast) }
        if endOldMesoNow {
            if remaining.contains(where: { $0.status == .planned && !SessionEditSafety.isSafeToModify($0) }) {
                refusals.append(.remainingSessionHasLoggedData)
            }
        } else if !remaining.isEmpty {
            refusals.append(.oldMesoHasRemainingSessions)
        }

        func label(_ s: Session) -> String { s.dayLabel ?? "" }
        func ordered(_ ss: [Session]) -> [Session] {
            ss.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
        }

        // Week -> letter. A wave letter is a property of the whole week (the majority of its items' waves).
        let weekOrder = Array(Set(sources.map(\.weekIndex))).sorted()
        let waveBased = !meso.isMaintenance && sources.contains { $0.items.contains { WavePrescriptionGuard.isWaveLetter($0.waveRaw) } }
        func weekLetter(_ week: Int) -> String {
            guard waveBased else { return "" }
            var counts: [String: Int] = [:]
            for s in sources where s.weekIndex == week {
                for i in s.items {
                    let l = i.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                    if !l.isEmpty { counts[l, default: 0] += 1 }
                }
            }
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
        }
        let letters = Dictionary(uniqueKeysWithValues: weekOrder.map { ($0, weekLetter($0)) })

        /// Latest session of this day type and letter; any letter when that letter never occurred for the day.
        func template(_ dayLabel: String, _ letter: String) -> Session? {
            let ofDay = ordered(sources.filter { label($0) == dayLabel })
            return ofDay.last { letters[$0.weekIndex] == letter } ?? ofDay.last
        }

        // Weekday of each day type: the most common one across the old meso (ties: the earlier weekday).
        var weekdayCounts: [String: [Int: Int]] = [:]
        for s in sources { weekdayCounts[label(s), default: [:]][cal.component(.weekday, from: s.date), default: 0] += 1 }
        func modeWeekday(_ dayLabel: String) -> Int {
            let counts = weekdayCounts[dayLabel] ?? [:]
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 2
        }
        func firstDate(onOrAfter d: Date, weekday: Int) -> Date {
            var date = d
            for _ in 0..<7 {
                if cal.component(.weekday, from: date) == weekday { return date }
                date = cal.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return d
        }

        // Day types per old week, in the order the lifter trained them; the first of week 1 starts each new week.
        var labelsByWeek: [Int: [Session]] = [:]
        for w in weekOrder { labelsByWeek[w] = ordered(sources.filter { $0.weekIndex == w }) }
        for w in weekOrder {
            let ls = (labelsByWeek[w] ?? []).map(label)
            if Set(ls).count != ls.count { refusals.append(.duplicateDayLabelInWeek); return plan() }
        }
        guard let firstLabel = labelsByWeek[weekOrder[0]]?.first.map(label) else { refusals.append(.nothingToCopy); return plan() }
        let firstWeekStart = firstDate(onOrAfter: startDay, weekday: modeWeekday(firstLabel))

        // Loads
        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let increment = profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: profile?.loadUnit ?? .lb)
        let unit = profile?.loadUnit ?? .lb
        var seedCache: [String: (load: Double, source: HistorySeedLoad.SeedSource)] = [:]
        func seed(_ exerciseId: String, reps: Int, rir: Int) -> (load: Double, source: HistorySeedLoad.SeedSource) {
            let key = "\(ExerciseCatalog.canonicalExerciseId(for: exerciseId))|\(reps)|\(rir)"
            if let hit = seedCache[key] { return hit }
            let r = HistorySeedLoad.nextMesoSeed(
                for: exerciseId, goalReps: reps, targetRIR: rir, previousMeso: all, allSessions: allSessions,
                loadIncrement: increment, unit: unit, bodyWeight: profile?.bodyWeight,
                isFixedLoad: UserProfile.isProgressionExempt(exerciseId: exerciseId, profile: profile),
                factor: peakFactor, customExercises: custom, referenceDate: now
            )
            // A max load caps the seed (a fixed-load exercise or one without a max is unchanged).
            let capped = (UserProfile.clampedLoad(r.load, exerciseId: exerciseId, profile: profile, customExercises: custom), r.source)
            seedCache[key] = capped
            return capped
        }

        func topSeedLoad(_ exerciseId: String, reps: Int, rir: Int) -> Double {
            let key = "top|\(ExerciseCatalog.canonicalExerciseId(for: exerciseId))|\(reps)|\(rir)"
            if let hit = seedCache[key] { return hit.load }
            let r = HistorySeedLoad.nextMesoSeed(
                for: exerciseId, goalReps: reps, targetRIR: rir, previousMeso: all, allSessions: allSessions,
                loadIncrement: increment, unit: unit, bodyWeight: profile?.bodyWeight,
                isFixedLoad: UserProfile.isProgressionExempt(exerciseId: exerciseId, profile: profile),
                factor: peakFactor, customExercises: custom, referenceDate: now, role: .top
            )
            let capped = (UserProfile.clampedLoad(r.load, exerciseId: exerciseId, profile: profile, customExercises: custom), r.source)
            seedCache[key] = capped
            return capped.0
        }

        // Layout
        var built: [(date: Date, week: Int, label: String, letter: String, old: Session, tpl: Session)] = []
        for (idx, oldWeek) in weekOrder.enumerated() {
            let base = cal.date(byAdding: .day, value: 7 * idx, to: firstWeekStart) ?? firstWeekStart
            let letter = letters[oldWeek] ?? ""
            let rows: [(date: Date, week: Int, label: String, letter: String, old: Session, tpl: Session)] =
                (labelsByWeek[oldWeek] ?? []).compactMap { old in
                    let l = label(old)
                    guard let tpl = template(l, letter) else { return nil }
                    return (firstDate(onOrAfter: base, weekday: modeWeekday(l)), idx + 1, l, letter, old, tpl)
                }
            built += rows.sorted { $0.date < $1.date }
        }

        // Collisions: any existing session (any meso) except the ones this action removes, and the new sessions among themselves.
        let removing = Set(toDelete.map(\.persistentModelID))
        let occupied = Dictionary(grouping: allSessions.filter { !removing.contains($0.persistentModelID) },
                                  by: { cal.startOfDay(for: $0.date) })
        var collisions: [NextMesoCollision] = []
        var claimed = Set<Date>()
        for row in built {
            let day = cal.startOfDay(for: row.date)
            for other in occupied[day] ?? [] { collisions.append(.init(date: day, dayLabel: row.label.isEmpty ? nil : row.label, occupant: other)) }
            if !claimed.insert(day).inserted { collisions.append(.init(date: day, dayLabel: row.label.isEmpty ? nil : row.label, occupant: nil)) }
        }
        if !collisions.isEmpty { refusals.append(.dateCollision) }

        // Sessions and items
        let isMaintenance = meso.isMaintenance
        var sessions: [NextMesoSession] = []
        for (n, row) in built.enumerated() {
            let oldItems = row.old.items
            let items: [NextMesoItem] = row.tpl.items.sorted { $0.order < $1.order }.map { t in
                let canonical = ExerciseCatalog.canonicalExerciseId(for: t.exerciseId)
                // The same exercise in the old week first, else whatever sat in the same slot there.
                let slot = oldItems.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }
                    ?? oldItems.first { $0.order == t.order }
                // The PRESCRIBED set count of that week, never the count an in-session Add Set left on it.
                let sets = max(0, slot.map { prescribedSetCount(of: $0, in: row.old, among: all) } ?? t.targetSets)
                let wave: String? = {
                    if let raw = t.waveRaw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty { return t.waveRaw }
                    return waveBased && !row.letter.isEmpty ? row.letter : nil
                }()
                let shown = NoteFields(t).displayed
                let showsIntensifier = !(t.intensifierNotes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let r = seed(t.exerciseId, reps: t.targetReps, rir: t.targetRIR)
                // The latest week of this lift decides whether it carries a top set; else the template.
                let topSource: SessionItem? = (slot?.hasTopSet == true) ? slot : (t.hasTopSet ? t : nil)
                let topN = topSource?.topCount ?? 0
                let topReps = topSource?.topRepMin ?? t.targetReps
                let topRIRValue = topSource?.topRIR ?? t.targetRIR
                let isBW = ExerciseCatalog.isBodyweight(exerciseId: t.exerciseId, customExercises: custom)
                return NextMesoItem(
                    order: t.order, exerciseId: t.exerciseId,
                    exerciseName: t.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: t.exerciseId),
                    targetReps: t.targetReps, targetSets: sets, targetRIR: t.targetRIR,
                    setMin: t.setMin.map { min($0, sets) }, setMax: t.setMax.map { max($0, sets) },
                    repMin: t.repMin, repMax: t.repMax, rirMin: t.targetRIRMin, rirMax: t.targetRIRMax,
                    waveRaw: wave, priorityRaw: t.priorityRaw, intensifierRaw: t.intensifierRaw,
                    intensifierNotes: showsIntensifier ? shown : nil,
                    prescriptionNotes: showsIntensifier ? nil : shown,
                    plannedReps: resized(t.backOffValues(t.plannedRepsBySet), to: sets, fallback: t.targetReps)
                        + Array(repeating: topReps, count: topN),
                    plannedRIRs: resized(t.backOffValues(t.plannedRIRsBySet), to: sets, fallback: t.targetRIR)
                        + Array(repeating: topRIRValue, count: topN),
                    seed: r.load, seedSource: r.source,
                    topCount: topN, topRepMin: topSource?.topRepMin, topRepMax: topSource?.topRepMax, topRIR: topSource?.topRIR,
                    topSeed: topN > 0 && !isBW ? topSeedLoad(t.exerciseId, reps: topReps, rir: topRIRValue) : 0,
                    isBodyweight: isBW,
                    templateItem: t
                )
            }
            let dayName = row.label.isEmpty ? "Session" : row.label
            let notes: String = {
                if isMaintenance { return "\(dayName) · Maintenance" }
                if row.letter.isEmpty { return dayName }
                return "\(dayName) · \(row.letter == "deload" ? "Deload" : row.letter.uppercased()) wave"
            }()
            sessions.append(NextMesoSession(
                date: row.date, dayLabel: row.label.isEmpty ? nil : row.label, weekIndex: row.week, programIndex: n + 1,
                letter: row.letter, sessionNotes: notes, items: items, templateSession: row.tpl
            ))
        }
        return plan(sessions: sessions, weeks: weekOrder.count, collisions: collisions)
    }
}

// MARK: - Start the next meso: apply

extension SessionItemEditService {

    struct NextMesoResult {
        let meso: MesoBlock
        let sessionsCreated: Int
        let sessionsDeleted: Int
        /// One line per created session.
        let summary: [String]
    }

    private struct ForcedNextMesoSaveFailure: Error {}

    /// Everything about a session the plan or the user could have touched, as one comparable string.
    fileprivate static func sessionFingerprint(_ s: Session) -> String {
        var out = ["S", "\(s.date.timeIntervalSince1970)", s.status.rawValue, "\(s.weekIndex)", s.dayLabel ?? "-",
                   s.programIndex.map(String.init) ?? "-", s.sessionNotes ?? "-", "\(s.insertedDeload.map { "\($0)" } ?? "-")",
                   s.completedAt.map { "\($0.timeIntervalSince1970)" } ?? "-", "\(s.readinessStars)", s.readinessRaw,
                   "\(s.hkWorkoutUUID ?? "-")", "\(s.hkDuration)", "\(s.items.count)"].joined(separator: "|")
        for i in s.items.sorted(by: { ($0.order, $0.exerciseId) < ($1.order, $1.exerciseId) }) {
            func opt(_ v: Int?) -> String { v.map(String.init) ?? "-" }
            out += "\n" + [
                "I", i.id?.uuidString ?? "", "\(i.order)", i.exerciseId, i.exerciseNameSnapshot ?? "-",
                "\(i.targetReps)", "\(i.targetSets)", "\(i.targetRIR)", "\(i.suggestedLoad)",
                i.waveRaw ?? "-", i.priorityRaw ?? "-", opt(i.setMin), opt(i.setMax), opt(i.repMin), opt(i.repMax),
                opt(i.targetRIRMin), opt(i.targetRIRMax), i.intensifierRaw ?? "-", i.intensifierNotes ?? "-", i.prescriptionNotes ?? "-",
                "\(i.logs.count)", "\(i.plannedRepsBySet)", "\(i.plannedLoadsBySet)", "\(i.plannedRIRsBySet)", "\(i.planEdited)",
                "\(i.actualReps)", "\(i.actualLoads)", "\(i.actualRIRs)", "\(i.usedRestPauseFlags)", "\(i.restPausePatternsBySet)",
                "\(i.dropSetPatternsBySet)", "\(i.setFeedbackBySet)", "\(i.pumpRatingsBySet)", "\(i.isCompleted)", "\(i.isPR)",
                i.coachNote ?? "-", i.loadOverrideReasonRaw ?? "-", i.nextSuggestedLoad.map { "\($0)" } ?? "-",
            ].joined(separator: "|")
        }
        return out
    }

    /// What the plan will write, as text, for the "has the live state moved" comparison.
    private static func signature(_ plan: NextMesoPlan) -> String {
        var parts = ["\(plan.oldMeso.persistentModelID)", plan.name, "\(plan.startDate.timeIntervalSince1970)", "\(plan.endOldMesoNow)",
                     "\(plan.peakFactor)", plan.sessionsToDelete.map { "\($0.persistentModelID)" }.sorted().joined(separator: ",")]
        for s in plan.sessions {
            parts.append("\(s.date.timeIntervalSince1970)|\(s.dayLabel ?? "-")|\(s.weekIndex)|\(s.programIndex)|\(s.letter)|\(s.sessionNotes)")
            for i in s.items {
                parts.append("  \(i.order)|\(i.exerciseId)|\(i.targetSets)|\(i.targetReps)|\(i.targetRIR)|\(i.waveRaw ?? "-")|\(i.seed)|\(i.seedSource.rawValue)|top\(i.topCount),\(i.topRepMin ?? -1),\(i.topRepMax ?? -1),\(i.topRIR ?? -1),\(i.topSeed)|\(i.intensifierNotes ?? "-")|\(i.prescriptionNotes ?? "-")")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Creates the planned meso, archives the old one (and removes its remaining planned sessions when the plan
    /// says so), verifies, and saves once. Any failure puts every changed field back and throws, leaving the
    /// store as it was. The meso lifecycle (labeling anchor, scheduled next-meso date) moves only after the save.
    @discardableResult
    static func startNextMeso(_ plan: NextMesoPlan, in context: ModelContext, hooks: ApplyHooks = ApplyHooks()) throws -> NextMesoResult {
        guard plan.isApplicable else {
            throw NextMesoError.refused(plan.refusals.isEmpty ? [.nothingToCopy] : plan.refusals)
        }
        let old = plan.oldMeso

        let priorAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = priorAutosave }

        // The plan is a preview; trust only live state.
        let live = planNextMeso(meso: old, name: plan.name, startDate: plan.startDate, endOldMesoNow: plan.endOldMesoNow,
                                peakFactor: plan.peakFactor, context: context, now: plan.now)
        guard live.refusals.isEmpty, live.isApplicable else { throw NextMesoError.refused(live.refusals.isEmpty ? [.nothingToCopy] : live.refusals) }
        guard signature(live) == signature(plan) else { throw NextMesoError.planStale }

        if context.hasChanges {
            print("SessionItemEdit: context had pending changes; saved them before applying so a rollback stays exact")
            try context.save()
        }

        let calendar = Calendar.current
        let completedBefore = Dictionary(uniqueKeysWithValues: old.sessions.filter { $0.status == .completed }
            .map { ($0.persistentModelID, sessionFingerprint($0)) })
        let blocksBefore = (try? context.fetch(FetchDescriptor<MesoBlock>())) ?? []
        let statusBefore = blocksBefore.map { (block: $0, status: $0.status) }
        let removedIDs = Set(live.sessionsToDelete.map(\.persistentModelID))
        let otherSessionsBefore = ((try? context.fetch(FetchDescriptor<Session>())) ?? []).filter { !removedIDs.contains($0.persistentModelID) }

        // rollback() drops inserts and deletes but does not revert property edits (see DUPMesoLengthConversion.Snapshot),
        // so the one edit made to live objects, the status of the blocks it archives, is put back by hand.
        var created: [Session] = []
        var newMeso: MesoBlock?
        func abandon() {
            for entry in statusBefore { entry.block.status = entry.status }
            for s in created { context.delete(s) }
            if let newMeso { context.delete(newMeso) }
            context.rollback()
        }

        // 1. Archive every active block (the old meso among them).
        for block in blocksBefore where block.status == .active { block.status = .archived }
        old.status = .archived

        // 2. Remove the old meso's remaining planned sessions.
        for s in live.sessionsToDelete { context.delete(s) }

        // 3. The new meso, its sessions and items.
        let block = MesoBlock(
            name: plan.name, startDate: live.startDate, status: .active,
            notes: "Next meso from \(old.name) on \(isoDay(live.startDate))",
            totalWeeks: live.weeks, isMaintenance: old.isMaintenance
        )
        block.previousMesoId = old.id
        context.insert(block)
        newMeso = block
        for sp in live.sessions {
            let items: [SessionItem] = sp.items.map { ip in
                let item = SessionItem(
                    order: ip.order, exerciseId: ip.exerciseId, exerciseNameSnapshot: ip.exerciseName,
                    targetReps: ip.targetReps, targetSets: ip.targetSets, targetRIR: ip.targetRIR, suggestedLoad: ip.seed,
                    waveRaw: ip.waveRaw, priorityRaw: ip.priorityRaw,
                    setMin: ip.setMin, setMax: ip.setMax, repMin: ip.repMin, repMax: ip.repMax,
                    targetRIRMin: ip.rirMin, targetRIRMax: ip.rirMax,
                    intensifierRaw: ip.intensifierRaw, intensifierNotes: ip.intensifierNotes, prescriptionNotes: ip.prescriptionNotes,
                    plannedRepsBySet: ip.plannedReps,
                    plannedLoadsBySet: Array(repeating: ip.seed, count: ip.targetSets)
                        + Array(repeating: ip.topSeed, count: ip.topCount),
                    plannedRIRsBySet: ip.plannedRIRs
                )
                if ip.topCount > 0 {
                    item.setRolesBySet = SessionItem.roles(backOffs: ip.targetSets, tops: ip.topCount)
                    item.topRepMin = ip.topRepMin; item.topRepMax = ip.topRepMax; item.topRIR = ip.topRIR
                }
                item.planEdited = false
                return item
            }
            let session = Session(date: sp.date, status: .planned, sessionNotes: sp.sessionNotes,
                                  weekIndex: sp.weekIndex, dayLabel: sp.dayLabel, items: items, programIndex: sp.programIndex)
            session.meso = block
            context.insert(session)
            created.append(session)
        }

        // 4. Verify before anything is saved.
        var problems: [String] = []
        func check<T: Equatable>(_ what: String, _ expected: T, _ actual: T) {
            if expected != actual { problems.append("\(what): expected \(expected), found \(actual)") }
        }
        check("created sessions in the block", live.sessions.count, block.sessions.count)
        check("block status", MesoStatus.active, block.status)
        check("totalWeeks", live.weeks, block.totalWeeks ?? -1)
        check("old meso status", MesoStatus.archived, old.status)
        check("active blocks", 1, blocksBefore.filter { $0.status == .active }.count + 1)

        let byIndex = created.sorted { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) }
        check("programIndex contiguous", Array(1...created.count), byIndex.compactMap(\.programIndex))
        check("programIndex follows date order", byIndex.map(\.date), byIndex.map(\.date).sorted())
        let weeks = Set(created.map(\.weekIndex))
        check("weeks contiguous", Array(1...live.weeks), weeks.sorted())
        var weekdayByLabel: [String: Set<Int>] = [:]
        for s in created { weekdayByLabel[s.dayLabel ?? "", default: []].insert(calendar.component(.weekday, from: s.date)) }
        for (label, days) in weekdayByLabel where days.count != 1 { problems.append("day type \(label.isEmpty ? "?" : label) is on \(days.sorted()) weekdays") }

        for (sp, s) in zip(live.sessions, created) {
            let tag = "\(isoDay(sp.date)) \(sp.dayLabel ?? "?") wk\(sp.weekIndex)"
            check("\(tag) date", sp.date, s.date)
            check("\(tag) week", sp.weekIndex, s.weekIndex)
            check("\(tag) status", SessionStatus.planned, s.status)
            check("\(tag) insertedDeload", false, s.insertedDeload == true)
            check("\(tag) item count", sp.items.count, s.items.count)
            for (ip, i) in zip(sp.items, s.items.sorted { $0.order < $1.order }) {
                let t = "\(tag) \(ip.exerciseId)"
                check("\(t) exercise", ip.exerciseId, i.exerciseId)
                check("\(t) sets", ip.targetSets, i.targetSets)
                let rows = ip.targetSets + ip.topCount
                check("\(t) array sizes", [rows, rows, rows],
                      [i.plannedRepsBySet.count, i.plannedLoadsBySet.count, i.plannedRIRsBySet.count])
                check("\(t) top rows", ip.topCount, i.topCount)
                check("\(t) load", ip.seed, i.suggestedLoad)
                check("\(t) planned loads", Array(repeating: ip.seed, count: ip.targetSets) + Array(repeating: ip.topSeed, count: ip.topCount),
                      i.plannedLoadsBySet)
                check("\(t) planEdited", false, i.planEdited)
                check("\(t) logged", false, SessionEditSafety.hasLoggedData(i))
                check("\(t) actuals", 0, i.actualReps.count + i.actualLoads.count + i.actualRIRs.count + i.logs.count)
                if ip.isBodyweight { check("\(t) bodyweight load", 0.0, i.suggestedLoad) }
                if let lo = i.setMin, lo > ip.targetSets { problems.append("\(t): setMin \(lo) above sets \(ip.targetSets)") }
                if let hi = i.setMax, hi < ip.targetSets { problems.append("\(t): setMax \(hi) below sets \(ip.targetSets)") }
                if sp.letter.isEmpty == false, WavePrescriptionGuard.isWaveLetter(sp.letter) == false, i.waveRaw?.lowercased() != sp.letter {
                    problems.append("\(t): wave \(i.waveRaw ?? "nil") in a \(sp.letter) week")
                }
            }
        }

        // Dates: none shares a day with a session that stays, or with another new one.
        let stayingDays = Dictionary(grouping: otherSessionsBefore, by: { calendar.startOfDay(for: $0.date) })
        var claimed = Set<Date>()
        for s in created {
            let day = calendar.startOfDay(for: s.date)
            if !claimed.insert(day).inserted { problems.append("date collision on \(isoDay(day)) within the new meso") }
            if let other = stayingDays[day]?.first { problems.append("date collision on \(isoDay(day)) with \(other.dayLabel ?? "?")") }
        }

        // Chains: every new item's carry-forward target is the next occurrence inside the new meso, or nothing.
        let all = otherSessionsBefore + created
        for s in created {
            for i in s.items {
                let canonical = ExerciseCatalog.canonicalExerciseId(for: i.exerciseId)
                let wave = i.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let later = created.filter { $0.date > s.date }.sorted { $0.date < $1.date }
                var expected: SessionItem?
                for c in later {
                    guard let match = c.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }) else { continue }
                    if wave.isEmpty {
                        if match.waveRaw?.lowercased() != deloadWaveRaw { expected = match; break }
                    } else if SessionDayLabelMatcher.matches(c.dayLabel, s.dayLabel), match.waveRaw?.lowercased() == wave {
                        expected = match; break
                    }
                }
                let resolved = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: all)
                if resolved !== expected {
                    let at = resolved.flatMap { r in all.first { $0.items.contains { $0 === r } } }
                    problems.append("chain \(isoDay(s.date)) \(s.dayLabel ?? "?") \(i.exerciseId) \(wave.isEmpty ? "(no wave)" : wave): expected "
                                    + "\(expected == nil ? "none" : "next in the new meso"), resolved \(at.map { "\(isoDay($0.date)) wk\($0.weekIndex)" } ?? "none")")
                }
            }
        }

        // The old meso's finished sessions are exactly as they were.
        for s in old.sessions where completedBefore[s.persistentModelID] != nil {
            if sessionFingerprint(s) != completedBefore[s.persistentModelID] { problems.append("completed session \(isoDay(s.date)) \(s.dayLabel ?? "?") changed") }
        }
        check("completed sessions kept", completedBefore.count, old.sessions.filter { $0.status == .completed && !removedIDs.contains($0.persistentModelID) }.count)
        if hooks.forceVerificationFailure { problems.append("forced verification failure (test hook)") }

        guard problems.isEmpty else {
            abandon()
            throw NextMesoError.verificationFailed(problems)
        }
        do {
            if hooks.forceSaveFailure { throw ForcedNextMesoSaveFailure() }
            try context.save()
        } catch {
            abandon()
            throw NextMesoError.saveFailed("\(error)")
        }

        // Saved: the lifecycle follows.
        MesoLifecycle.clearScheduledNextMeso()
        MesoLifecycle.confirmStartNewMeso(on: live.startDate)
        AppStateBridge.setActiveMesoStartDate(live.startDate, in: context)
        AppStateBridge.setScheduledNextMesoStartDate(nil, in: context)
        AppStateBridge.setMesoPromptSnoozeUntil(nil, in: context)

        let summary = live.sessions.map { s in
            "SessionItemEdit: next meso wk\(s.weekIndex) \(isoDay(s.date)) \(s.dayLabel ?? "?") \(s.letter.isEmpty ? "-" : s.letter) "
                + s.items.map { "\($0.exerciseId) \($0.prescription) @ \($0.seed) [\($0.seedSource.label(factor: live.peakFactor))]" }.joined(separator: "; ")
        }
        summary.forEach { print($0) }
        return NextMesoResult(meso: block, sessionsCreated: created.count, sessionsDeleted: live.sessionsToDelete.count, summary: summary)
    }
}
