// Domain/Analytics/PersonalRecords.swift
import Foundation

/// The one PR definition: the best working-set e1RM (`E1RMCalculator`, Epley) of a canonical exercise, over
/// regular completed training. Warm-ups, rest-pause and drop rows, skipped rows, deload weeks, inserted deloads and
/// maintenance blocks never set or hold a record.
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
        /// The first counted session of the lift: a baseline, not a beaten record.
        let isBaseline: Bool
    }

    /// Best e1RM per canonical id.
    static func bests(from sets: [SetRecord]) -> [String: Best] {
        var out: [String: Best] = [:]
        for s in sets where s.isPerformanceSet && s.e1RM > 0 {
            if let b = out[s.exerciseId], b.e1RM >= s.e1RM { continue }
            out[s.exerciseId] = Best(exerciseId: s.exerciseId, e1RM: s.e1RM, load: s.load, reps: s.reps,
                                     date: s.sessionDate, sessionKey: s.sessionKey)
        }
        return out
    }

    /// Every session that beat all earlier ones for a lift, oldest first. A strict improvement; equal does not count.
    static func events(from sets: [SetRecord]) -> [Event] {
        struct K: Hashable { let session: String; let exercise: String }
        var best: [K: (e1RM: Double, date: Date)] = [:]
        for s in sets where s.isPerformanceSet && s.e1RM > 0 {
            let k = K(session: s.sessionKey, exercise: s.exerciseId)
            if let b = best[k], b.e1RM >= s.e1RM { continue }
            best[k] = (s.e1RM, s.sessionDate)
        }
        let ordered = best.map { (key: $0.key, e1RM: $0.value.e1RM, date: $0.value.date) }
            .sorted { ($0.date, $0.key.session, $0.key.exercise) < ($1.date, $1.key.session, $1.key.exercise) }
        var running: [String: Double] = [:]
        var out: [Event] = []
        for o in ordered {
            let prior = running[o.key.exercise] ?? 0
            if o.e1RM > prior {
                out.append(Event(exerciseId: o.key.exercise, sessionKey: o.key.session, date: o.date,
                                 e1RM: o.e1RM, isBaseline: prior == 0))
                running[o.key.exercise] = o.e1RM
            }
        }
        return out
    }
}
