// Domain/Analytics/PersonalRecords.swift
import Foundation

/// The one PR definition: the best working-set e1RM (`E1RMCalculator`, Epley, on the effective load, from sets of 12 reps
/// or fewer only: `BestSetRule`) of a canonical exercise, over ALL completed sessions. Maintenance blocks and deload weeks are history and count; warm-ups,
/// rest-pause and drop rows and skipped rows do not. A bodyweight lift uses the lifter's body weight when it is set and
/// has no record (no e1RM at all) when it is not. Records that look too good to be true are surfaced by `suspects`.
///
/// Screens still compute their own numbers; this is the definition they will move to.
enum PersonalRecords {

    struct Best: Equatable {
        let exerciseId: String
        let e1RM: Double
        let load: Double
        let reps: Int
        let date: Date
        let sessionKey: String
    }

    struct Event: Equatable {
        let exerciseId: String
        let sessionKey: String
        let date: Date
        let e1RM: Double
        /// The lift's first-ever trained session: a baseline, not a beaten record.
        let isBaseline: Bool
    }

    /// Best e1RM per canonical id.
    static func bests(from sets: [SetRecord]) -> [String: Best] {
        var out: [String: Best] = [:]
        for s in sets where s.isRecordSet && s.recordE1RM > 0 {
            if let b = out[s.exerciseId], b.e1RM >= s.recordE1RM { continue }
            out[s.exerciseId] = Best(exerciseId: s.exerciseId, e1RM: s.recordE1RM, load: s.effectiveLoad, reps: s.reps,
                                     date: s.sessionDate, sessionKey: s.sessionKey)
        }
        return out
    }

    /// Every session that beat all earlier ones for a lift, oldest first. A strict improvement; equal does not count.
    static func events(from sets: [SetRecord]) -> [Event] {
        struct K: Hashable { let session: String; let exercise: String }
        var best: [K: (e1RM: Double, date: Date)] = [:]
        for s in sets where s.isRecordSet && s.recordE1RM > 0 {
            let k = K(session: s.sessionKey, exercise: s.exerciseId)
            if let b = best[k], b.e1RM >= s.recordE1RM { continue }
            best[k] = (s.recordE1RM, s.sessionDate)
        }
        // A lift's first-ever TRAINED session (a working set of any rep count) is its baseline. A lift first trained with long
        // sets only and later with a set of 12 reps or fewer has a real earlier exposure: its first record is a record, not a baseline.
        var firstTrained: [String: (date: Date, session: String)] = [:]
        for s in sets where s.isRecordSet && s.e1RM > 0 {
            if let f = firstTrained[s.exerciseId], (f.date, f.session) <= (s.sessionDate, s.sessionKey) { continue }
            firstTrained[s.exerciseId] = (s.sessionDate, s.sessionKey)
        }
        let ordered = best.map { (key: $0.key, e1RM: $0.value.e1RM, date: $0.value.date) }
            .sorted { ($0.date, $0.key.session, $0.key.exercise) < ($1.date, $1.key.session, $1.key.exercise) }
        var running: [String: Double] = [:]
        var out: [Event] = []
        for o in ordered {
            let prior = running[o.key.exercise] ?? 0
            if o.e1RM > prior {
                let first = firstTrained[o.key.exercise]
                let isFirstSession = first.map { $0.date == o.date && $0.session == o.key.session } ?? true
                out.append(Event(exerciseId: o.key.exercise, sessionKey: o.key.session, date: o.date,
                                 e1RM: o.e1RM, isBaseline: prior == 0 && isFirstSession))
                running[o.key.exercise] = o.e1RM
            }
        }
        return out
    }

    /// A record that stands well clear of the lifter's next best session for the lift: probably real, possibly a typo or a
    /// load logged in the wrong unit. For the lifter to verify; nothing is changed.
    struct Suspect: Equatable {
        let exerciseId: String
        let best: Best
        /// The best e1RM of any OTHER session of the lift.
        let nextBestE1RM: Double
        var ratio: Double { best.e1RM / nextBestE1RM }
    }

    /// Lifts whose best session e1RM is more than `threshold` (default 1.25) times the best of every other session.
    /// A lift with fewer than two counted sessions has no "next best" and is never flagged.
    static func suspects(from sets: [SetRecord], threshold: Double = 1.25) -> [Suspect] {
        let best = bests(from: sets)
        var perSession: [String: [String: Double]] = [:]   // exercise -> session -> best e1RM
        for s in sets where s.isRecordSet && s.recordE1RM > 0 {
            perSession[s.exerciseId, default: [:]][s.sessionKey] = max(perSession[s.exerciseId]?[s.sessionKey] ?? 0, s.recordE1RM)
        }
        return best.values.compactMap { b -> Suspect? in
            let others = (perSession[b.exerciseId] ?? [:]).filter { $0.key != b.sessionKey }.values
            guard let next = others.max(), next > 0, b.e1RM > threshold * next else { return nil }
            return Suspect(exerciseId: b.exerciseId, best: b, nextBestE1RM: next)
        }.sorted { $0.ratio > $1.ratio }
    }
}
