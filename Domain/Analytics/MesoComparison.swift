// Domain/Analytics/MesoComparison.swift
import Foundation
import SwiftData

/// What comparison needs to know about a block. The key is the same one `SetRecordBuilder` writes into records.
struct MesoInfo: Equatable {
    let key: String
    let name: String
    let startDate: Date
    let isMaintenance: Bool
    /// `MesoBlock.previousMesoId` (as a key); nil for a first block or one created before the field existed.
    let previousKey: String?

    static func build(from blocks: [MesoBlock]) -> [MesoInfo] {
        blocks.map {
            MesoInfo(key: $0.id?.uuidString ?? "\($0.persistentModelID)", name: $0.name, startDate: $0.startDate,
                     isMaintenance: $0.isMaintenance, previousKey: $0.previousMesoId?.uuidString)
        }
    }

    /// The block to compare `key` against: the one it was started from, else the latest earlier block by start date; a
    /// maintenance block is never the answer (it is skipped and the search continues from it).
    static func previous(of key: String, in infos: [MesoInfo]) -> MesoInfo? {
        guard var current = infos.first(where: { $0.key == key }) else { return nil }
        var seen: Set<String> = [key]
        while true {
            let linked = current.previousKey.flatMap { k in infos.first { $0.key == k } }
            let byDate = infos.filter { $0.startDate < current.startDate && !seen.contains($0.key) }
                .max { $0.startDate < $1.startDate }
            guard let candidate = linked ?? byDate, !seen.contains(candidate.key) else { return nil }
            if !candidate.isMaintenance { return candidate }
            seen.insert(candidate.key)
            current = candidate
        }
    }
}

/// One lift on one wave letter in both blocks.
struct LiftComparison: Equatable {
    let exerciseId: String
    let name: String
    /// "a" / "b" / "c" or "" for a block without wave letters.
    let letter: String
    let previousPeak: Double
    let currentPeak: Double
    /// Mean of the three best sessions' best working-set e1RM (fewer if the block has fewer sessions).
    let previousTop3: Double
    let currentTop3: Double
    let previousExposures: Int
    let currentExposures: Int
    /// The current block's first exposure (a next-meso seed starts at a fraction of the previous peak, so a low early value is not a regression).
    let currentFirst: Double

    var peakChange: Double { previousPeak > 0 ? (currentPeak - previousPeak) / previousPeak : 0 }
    var top3Change: Double { previousTop3 > 0 ? (currentTop3 - previousTop3) / previousTop3 : 0 }
}

struct LiftRef: Equatable { let id: String; let name: String }
struct LiftReplacement: Equatable { let old: LiftRef; let new: LiftRef }

struct MuscleCompare: Equatable {
    let muscle: FineMuscle
    let previousAverage: Double
    let currentAverage: Double
    let range: MuscleSetRange
}

struct AdherenceStat: Equatable {
    let completed: Int
    let planned: Int
    var fraction: Double { planned == 0 ? 1 : Double(completed) / Double(planned) }
}

/// Factual notes for planning the next block. Nothing here changes a plan.
struct NextBlockNotes: Equatable {
    /// Muscles whose weekly average in the current block is below the lifter's range minimum.
    var musclesBelowRange: [(muscle: FineMuscle, average: Double, minimum: Double)] = []
    /// Lifts stalled in the current block (no new best over the last exposures).
    var stalledLifts: [String] = []
    /// Lifts whose reps at the same load and letter rose across the block: candidates for an extra (earned) set.
    var earnedSetCandidates: [EarnedSetCandidate] = []

    static func == (a: NextBlockNotes, b: NextBlockNotes) -> Bool {
        a.musclesBelowRange.map(\.muscle) == b.musclesBelowRange.map(\.muscle) && a.stalledLifts == b.stalledLifts
            && a.earnedSetCandidates == b.earnedSetCandidates
    }
}

struct EarnedSetCandidate: Equatable {
    let exerciseId: String
    let name: String
    let letter: String
    let load: Double
    let firstReps: Double
    let lastReps: Double
    /// The latest load is the lifter's max load for this exercise: reps are the only way left to progress.
    var atCap = false
}

struct MesoComparison {
    let current: MesoInfo
    let previous: MesoInfo
    let lifts: [LiftComparison]
    let newLifts: [LiftRef]
    let droppedLifts: [LiftRef]
    let replaced: [LiftReplacement]
    let prsPrevious: Int
    let prsCurrent: Int
    let muscles: [MuscleCompare]
    let adherencePrevious: AdherenceStat
    let adherenceCurrent: AdherenceStat
    var notes: NextBlockNotes
    /// Weeks averaged per block for the muscle comparison (the last full weeks, at most 4).
    let previousWeeksAveraged: Int
    let currentWeeksAveraged: Int
}

enum MesoComparer {

    /// Compares `currentKey`'s block with the block it follows. nil when there is no such block or either has no training.
    static func compare(
        snapshot: AnalyticsSnapshot, infos: [MesoInfo], currentKey: String,
        customs: [CustomExercise], profile: UserProfile?, asOf: Date, stalledLifts: [String]
    ) -> MesoComparison? {
        let unit = profile?.loadUnit ?? .lb
        let incrementLb = unit.toStoredLb(profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit))
        guard let current = infos.first(where: { $0.key == currentKey }),
              let previous = MesoInfo.previous(of: currentKey, in: infos) else { return nil }

        // Regular working sets only: deload and maintenance sessions are not part of what a block built.
        let work = snapshot.sets.filter { $0.isPerformanceSet && $0.sessionDate <= asOf }
        let curSets = work.filter { $0.mesoKey == current.key }
        let prevSets = work.filter { $0.mesoKey == previous.key }
        guard !curSets.isEmpty, !prevSets.isEmpty else { return nil }

        // Per lift and letter: each session's best e1RM.
        struct K: Hashable { let id: String; let letter: String }
        struct Series { var name = ""; var sessions: [(date: Date, e1rm: Double)] = [] }
        func series(_ sets: [SetRecord]) -> [K: Series] {
            var perSession: [K: [String: (date: Date, e1rm: Double)]] = [:]
            var names: [K: String] = [:]
            for s in sets where s.e1RM > 0 {
                let k = K(id: s.exerciseId, letter: s.waveLetter ?? "")
                names[k] = s.exerciseName
                let cur = perSession[k]?[s.sessionKey]
                if cur == nil || s.e1RM > cur!.e1rm { perSession[k, default: [:]][s.sessionKey] = (s.sessionDate, s.e1RM) }
            }
            var out: [K: Series] = [:]
            for (k, d) in perSession {
                out[k] = Series(name: names[k] ?? k.id, sessions: d.values.sorted { $0.date < $1.date }.map { ($0.date, $0.e1rm) })
            }
            return out
        }
        let prevSeries = series(prevSets), curSeries = series(curSets)
        func top3(_ s: Series) -> Double {
            let best = s.sessions.map(\.e1rm).sorted(by: >).prefix(3)
            return best.reduce(0, +) / Double(max(best.count, 1))
        }
        var lifts: [LiftComparison] = []
        for (k, c) in curSeries {
            guard let p = prevSeries[k], let peakC = c.sessions.map(\.e1rm).max(), let peakP = p.sessions.map(\.e1rm).max() else { continue }
            lifts.append(LiftComparison(
                exerciseId: k.id, name: c.name, letter: k.letter, previousPeak: peakP, currentPeak: peakC,
                previousTop3: top3(p), currentTop3: top3(c), previousExposures: p.sessions.count,
                currentExposures: c.sessions.count, currentFirst: c.sessions.first?.e1rm ?? 0))
        }
        lifts.sort { ($0.name, $0.letter) < ($1.name, $1.letter) }

        // New / dropped / replaced lifts (any hard-set work, canonical id).
        func ids(_ key: String) -> [String: (name: String, days: Set<String>, muscle: MuscleGroup?)] {
            var out: [String: (name: String, days: Set<String>, muscle: MuscleGroup?)] = [:]
            for s in snapshot.sets where s.countsAsHardSet && s.mesoKey == key && s.sessionDate <= asOf {
                var e = out[s.exerciseId] ?? (s.exerciseName, [], s.muscle)
                if let d = s.dayLabel { e.days.insert(d) }
                out[s.exerciseId] = e
            }
            return out
        }
        let pIds = ids(previous.key), cIds = ids(current.key)
        var dropped = pIds.filter { cIds[$0.key] == nil }
        var added = cIds.filter { pIds[$0.key] == nil }
        // A dropped lift and a new lift in the same coarse muscle that share a training day are one replaced slot (best match first).
        var replaced: [LiftReplacement] = []
        for (oldId, old) in dropped.sorted(by: { $0.value.name < $1.value.name }) {
            let match = added.filter { $0.value.muscle == old.muscle && !$0.value.days.isDisjoint(with: old.days) }
                .sorted { (Set($1.value.days).intersection(old.days).count, $0.value.name) > (Set($0.value.days).intersection(old.days).count, $1.value.name) }
                .first
            if let (newId, new) = match {
                replaced.append(LiftReplacement(old: LiftRef(id: oldId, name: old.name), new: LiftRef(id: newId, name: new.name)))
                dropped[oldId] = nil
                added[newId] = nil
            }
        }
        // Second pass for blocks whose training days are named differently (a different program): a dropped and a new lift
        // are one replaced slot when they are the only pair with the same primary muscle.
        let customMap = MuscleVolume.customShares(from: customs)
        func primary(_ id: String, _ muscle: MuscleGroup?) -> FineMuscle? {
            let shares = ExerciseMuscleShares.shares(for: id) ?? customMap[id]
            if let shares, let p = shares.first(where: { $0.value == 1 })?.key { return p }
            return muscle.flatMap { FineMuscle.primary(forCoarse: $0) }
        }
        let droppedByMuscle = Dictionary(grouping: dropped.keys, by: { primary($0, dropped[$0]?.muscle) })
        let addedByMuscle = Dictionary(grouping: added.keys, by: { primary($0, added[$0]?.muscle) })
        for (muscle, oldIds) in droppedByMuscle {
            guard let muscle, oldIds.count == 1, let newIds = addedByMuscle[muscle], newIds.count == 1,
                  let old = dropped[oldIds[0]], let new = added[newIds[0]] else { continue }
            replaced.append(LiftReplacement(old: LiftRef(id: oldIds[0], name: old.name), new: LiftRef(id: newIds[0], name: new.name)))
            dropped[oldIds[0]] = nil
            added[newIds[0]] = nil
        }
        func refs(_ d: [String: (name: String, days: Set<String>, muscle: MuscleGroup?)]) -> [LiftRef] {
            d.map { LiftRef(id: $0.key, name: $0.value.name) }.sorted { $0.name < $1.name }
        }

        // PRs set inside each block (first-ever exposure baselines excluded).
        let events = PersonalRecords.events(from: snapshot.sets.filter { $0.sessionDate <= asOf }).filter { !$0.isBaseline }
        let curSessions = Set(snapshot.sessions.filter { $0.mesoKey == current.key }.map(\.key))
        let prevSessions = Set(snapshot.sessions.filter { $0.mesoKey == previous.key }.map(\.key))
        // "Record-setting sessions": distinct sessions with at least one record event. The same events set `SessionItem.isPR`
        // (PRRebuildService.recomputeFlags), so this count and the flags have one source.
        let prsC = Set(events.filter { curSessions.contains($0.sessionKey) }.map(\.sessionKey)).count
        let prsP = Set(events.filter { prevSessions.contains($0.sessionKey) }.map(\.sessionKey)).count

        // Weekly sets per muscle: the last (up to 4) full weeks of each block, adherence-aware.
        let shares = MuscleVolume.customShares(from: customs)
        func muscleAverages(_ key: String) -> (avg: [FineMuscle: Double], weeks: Int) {
            let weeks = MuscleVolume.weekly(in: snapshot, mesoKey: key, asOf: asOf, customShares: shares).filter(\.isComplete)
            let last = Array(weeks.suffix(4))
            var used = last.filter { !$0.isIncomplete && !$0.hasDeload }
            if used.isEmpty { used = last }
            var out: [FineMuscle: Double] = [:]
            for m in FineMuscle.allCases {
                out[m] = used.isEmpty ? 0 : used.map { $0.sets[m] ?? 0 }.reduce(0, +) / Double(used.count)
            }
            return (out, used.count)
        }
        let pm = muscleAverages(previous.key), cm = muscleAverages(current.key)
        let ranges = profile?.muscleSetRanges ?? MuscleVolumeRanges.defaults
        let muscles = FineMuscle.allCases.map {
            MuscleCompare(muscle: $0, previousAverage: pm.avg[$0] ?? 0, currentAverage: cm.avg[$0] ?? 0,
                          range: ranges[$0] ?? MuscleVolumeRanges.defaults[$0]!)
        }

        func adherence(_ key: String) -> AdherenceStat {
            let rs = snapshot.sessions.filter { $0.mesoKey == key && !$0.isMaintenance && (($0.plannedDate ?? $0.date) <= asOf) }
            return AdherenceStat(completed: rs.filter { $0.status == .completed }.count, planned: rs.count)
        }

        var notes = NextBlockNotes()
        notes.musclesBelowRange = muscles.filter { $0.currentAverage < $0.range.min }
            .map { ($0.muscle, $0.currentAverage, $0.range.min) }
        notes.stalledLifts = stalledLifts
        notes.earnedSetCandidates = earnedSetCandidates(
            sets: curSets, sessions: snapshot.sessions.filter { $0.mesoKey == current.key }, maxLoad: { UserProfile.effectiveMaxLoad(for: $0, profile: profile, customExercises: customs) },
            incrementLb: incrementLb)

        return MesoComparison(
            current: current, previous: previous, lifts: lifts, newLifts: refs(added), droppedLifts: refs(dropped),
            replaced: replaced.sorted { $0.old.name < $1.old.name }, prsPrevious: prsP, prsCurrent: prsC, muscles: muscles,
            adherencePrevious: adherence(previous.key), adherenceCurrent: adherence(current.key), notes: notes,
            previousWeeksAveraged: pm.weeks, currentWeeksAveraged: cm.weeks)
    }

    /// Lifts whose mean reps per set at the lift's latest load rose across the block: candidates for an extra (earned) set.
    /// Same letter, within the block, at least two exposures at that load, and:
    /// - a lift/letter whose working-set count INCREASED during the block is excluded (the extra set was already added,
    ///   deliberately);
    /// - a lift at its max load (`maxLoad`, within half an increment) needs reps up on at least two consecutive same-letter
    ///   exposures at the cap (so three exposures, rising twice in a row); one noisy session at the cap is not evidence;
    /// - otherwise reps up by at least one between the first and the latest exposure at that load.
    static func earnedSetCandidates(
        sets: [SetRecord], sessions: [SessionRecord] = [], loadToleranceLb: Double = 5,
        maxLoad: (String) -> Double? = { _ in nil }, incrementLb: Double = 5
    ) -> [EarnedSetCandidate] {
        let exposures = Exposures.build(from: sets)
        // The PRESCRIPTION decides whether the set count was changed on purpose: a lift whose prescribed set count, on any
        // letter, is higher in a REMAINING (not yet completed) session than in its first session of the block is out.
        // Without session data the logged working-set count is the fallback.
        var raisedBySession: Set<String> = []
        let ordered = sessions.filter { !$0.isDeloadWeek && !$0.isInsertedDeload && !$0.isMaintenance }
            .sorted { ($0.plannedDate ?? $0.date) < ($1.plannedDate ?? $1.date) }
        var startCount: [String: Int] = [:]          // "id|letter" -> prescribed sets at the first session with that lift/letter
        for r in ordered {
            for l in r.prescribedLifts where l.sets > 0 {
                let k = "\(l.exerciseId)|\(l.letter)"
                if let s = startCount[k] {
                    // only the REMAINING sessions matter: what the lifter is about to do, not a past one-off
                    if r.status != .completed, l.sets > s { raisedBySession.insert(l.exerciseId) }
                } else { startCount[k] = l.sets }
            }
        }
        struct K: Hashable { let id: String; let letter: String; let isTop: Bool }
        var out: [EarnedSetCandidate] = []
        for (k, list) in Dictionary(grouping: exposures, by: { K(id: $0.chain.exerciseId, letter: $0.chain.letter, isTop: $0.chain.isTop) }) {
            if k.isTop { continue }
            let chain = list.sorted { $0.date < $1.date }
            guard let first = chain.first, let last = chain.last, !last.isBodyweight, last.heaviestLoad > 0 else { continue }
            if raisedBySession.contains(k.id) { continue }                                  // prescribed set count went up
            if sessions.isEmpty, chain.contains(where: { $0.sets.count > first.sets.count }) { continue }
            func mean(_ e: Exposure) -> Double? {
                let r = e.sets.filter { abs($0.load - last.heaviestLoad) <= loadToleranceLb }.map(\.reps)
                return r.isEmpty ? nil : Double(r.reduce(0, +)) / Double(r.count)
            }
            let atLoad = chain.compactMap { e in mean(e).map { (e, $0) } }
            guard atLoad.count >= 2, let f = atLoad.first, let l = atLoad.last, l.1 - f.1 >= 1 else { continue }
            var atCap = false
            if let cap = maxLoad(k.id), last.heaviestLoad >= cap - 0.5 * incrementLb {
                atCap = true
                let v = atLoad.map(\.1)
                guard v.count >= 3, v[v.count - 1] > v[v.count - 2], v[v.count - 2] > v[v.count - 3] else { continue }
            }
            out.append(EarnedSetCandidate(exerciseId: k.id, name: last.exerciseName, letter: k.letter, load: last.heaviestLoad,
                                          firstReps: f.1, lastReps: l.1, atCap: atCap))
        }
        return out.sorted { ($0.name, $0.letter) < ($1.name, $1.letter) }
    }
}

extension AnalyticsEngine {

    /// Current block vs the block it follows (see `MesoComparer`). `currentKey` defaults to the lifter's current block.
    func mesoComparison(blocks: [MesoBlock], customs: [CustomExercise], profile: UserProfile?, asOf: Date = Date(),
                        currentKey: String? = nil) -> MesoComparison? {
        guard let key = currentKey ?? MuscleVolume.currentMesoKey(in: snapshot) else { return nil }
        let unit = profile?.loadUnit ?? .lb
        let incrementLb = unit.toStoredLb(profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit))
        let stalled = StallDetector.stalls(
            in: snapshot, loadIncrementLb: incrementLb, asOf: asOf, unit: unit,
            maxLoad: { UserProfile.effectiveMaxLoad(for: $0, profile: profile, customExercises: customs) },
            isFixedLoad: { UserProfile.isProgressionExempt(exerciseId: $0, profile: profile) }
        ).filter { $0.status == .stalled }.map { $0.letter.isEmpty ? $0.exerciseName : "\($0.exerciseName) \($0.letter.uppercased())" }
        return MesoComparer.compare(snapshot: snapshot, infos: MesoInfo.build(from: blocks), currentKey: key,
                                    customs: customs, profile: profile, asOf: asOf, stalledLifts: stalled)
    }
}
