// Domain/Analytics/Exposures.swift
import Foundation

/// One exercise's working sets in one session, per role: the unit stall, fatigue and comparison logic compares.
struct Exposure: Equatable {
    /// Exposures of the same lift on the same wave letter, same role, inside one meso form a chain. A new meso, or a
    /// replaced lift (a different canonical id), starts a new chain, so the first exposure of a chain never compares
    /// against an earlier block.
    struct ChainKey: Hashable {
        let exerciseId: String
        /// "a" / "b" / "c", or "" for a block with no wave letters.
        let letter: String
        let isTop: Bool
        let mesoKey: String
    }

    struct Prescription: Equatable {
        let repMin: Int?
        let repMax: Int?
        let rirMin: Int?
        let rirMax: Int?
    }

    struct WorkingSet: Equatable {
        let load: Double
        let reps: Int
        /// What the plan asked for on this row (stored lb / reps); nil when the item carried no plan for it.
        let plannedLoad: Double?
        let plannedReps: Int?
        var e1RM: Double { E1RMCalculator.e1RM(load: load, reps: reps) }
    }

    let chain: ChainKey
    let exerciseName: String
    let isBodyweight: Bool
    let sessionKey: String
    let date: Date
    let weekIndex: Int
    let sets: [WorkingSet]
    /// What the session asked for. Two exposures are comparable only when this matches.
    let prescription: Prescription
    /// The heaviest planned load of the working rows (stored lb); nil when none was planned.
    let plannedLoad: Double?
    /// The user edited the plan of this exposure's item by hand.
    let planEdited: Bool
    /// Every working set reached the top of the rep range with at least the target reserve: a strong exposure by
    /// the prescription's own terms, whatever its e1RM says.
    let reachedTopAtTarget: Bool
    /// Mean of the prescription's reps over the working rows; nil when none carries a planned entry. Lets a
    /// comparison tell "performed worse" from "was asked for something else" (a prescription edit mid-block).
    let meanPlannedReps: Double?

    /// Best working-set e1RM of the exposure (0 when no set has a load, e.g. bodyweight).
    var bestE1RM: Double { sets.map(\.e1RM).max() ?? 0 }
    var heaviestLoad: Double { sets.map(\.load).max() ?? 0 }
}

enum Exposures {

    /// Exposures of regular completed training (not deload, not maintenance), oldest first. Only working sets feed
    /// an exposure. An exercise whose load was cut on purpose that day (a load-override reason that suppresses
    /// earned progression) is left out: its numbers describe the cut, not the lifter.
    static func build(from sets: [SetRecord]) -> [Exposure] {
        struct GroupKey: Hashable { let session: String; let exercise: String; let isTop: Bool }
        var groups: [GroupKey: [SetRecord]] = [:]
        var order: [GroupKey] = []
        for s in sets where s.isPerformanceSet {
            if s.loadOverride?.suppressesEarnedProgression == true { continue }
            let k = GroupKey(session: s.sessionKey, exercise: s.exerciseId, isTop: s.isTop)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(s)
        }
        let exposures: [Exposure] = order.compactMap { k in
            guard let rows = groups[k], let first = rows.first else { return nil }
            return Exposure(
                chain: .init(exerciseId: k.exercise, letter: first.waveLetter ?? "", isTop: k.isTop, mesoKey: first.mesoKey),
                exerciseName: first.exerciseName, isBodyweight: first.isBodyweight, sessionKey: k.session, date: first.sessionDate, weekIndex: first.weekIndex,
                sets: rows.sorted { $0.rowIndex < $1.rowIndex }.map { .init(load: $0.load, reps: $0.reps, plannedLoad: $0.plannedLoad, plannedReps: $0.plannedReps) },
                prescription: .init(repMin: first.repMin, repMax: first.repMax, rirMin: first.targetRIRMin, rirMax: first.targetRIRMax),
                plannedLoad: rows.compactMap(\.plannedLoad).max(),
                planEdited: first.planEdited,
                reachedTopAtTarget: rows.allSatisfy { r in
                    guard let top = r.repMax, r.reps >= top, let rir = r.rir else { return false }
                    return rir >= (r.targetRIRMin ?? r.targetRIR)
                },
                meanPlannedReps: {
                    let p = rows.compactMap(\.plannedReps)
                    return p.isEmpty ? nil : Double(p.reduce(0, +)) / Double(p.count)
                }()
            )
        }
        return exposures.sorted { ($0.date, $0.sessionKey) < ($1.date, $1.sessionKey) }
    }

    /// Exposures grouped by chain, each chain oldest first.
    static func chains(_ exposures: [Exposure]) -> [Exposure.ChainKey: [Exposure]] {
        Dictionary(grouping: exposures, by: \.chain)
    }
}
