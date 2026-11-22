import Foundation
import SwiftData

/// Re-adding an exercise to a session of a wave block (Today or the Program tab) used to create a waveless item with the
/// generic 3 x 10 prescription, outside the A/B/C rotation: carry-forward could not chain it and the week's undulation was
/// lost for that lift. This gives the new item the slot's wave letter and prescription instead.
///
/// Source, in order: (1) the same exercise in another session of the same block and day type on the SAME wave letter, nearest
/// week first (the same-letter template); (2) the most recent earlier exposure of the exercise on that letter in any block.
/// With neither, the item only takes the session's wave letter and keeps its defaults. Only prescription fields move: never
/// a load, a logged value, a top set or a coach note.
enum WaveSlotRestore {

    /// The wave letter (or "deload") most of the session's items carry. Nil when none has a wave.
    static func sessionWave(_ session: Session) -> String? {
        let waves = session.items.compactMap { $0.waveRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !waves.isEmpty else { return nil }
        let counts = Dictionary(waves.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    private static func letter(_ item: SessionItem) -> String {
        item.waveRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func source(for exerciseId: String, wave: String, in session: Session, allSessions: [Session]) -> SessionItem? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        func match(_ s: Session) -> SessionItem? {
            s.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && letter($0) == wave }
        }
        let others = allSessions.filter { $0.persistentModelID != session.persistentModelID }
        if let meso = session.meso {
            let day = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let template = others
                .filter { $0.meso?.persistentModelID == meso.persistentModelID
                    && (day.isEmpty || SessionDayLabelMatcher.matches($0.dayLabel, session.dayLabel)) }
                .filter { match($0) != nil }
                .min { abs($0.weekIndex - session.weekIndex) < abs($1.weekIndex - session.weekIndex) }
            if let template, let item = match(template) { return item }
        }
        let earlier = others.filter { $0.date < session.date && match($0) != nil }.max { $0.date < $1.date }
        return earlier.flatMap(match)
    }

    /// Gives `item` (just built, unlogged) the slot's wave letter and prescription. Returns false when the block is not wave
    /// based or the session has no wave, leaving the item exactly as it was.
    @discardableResult
    static func restore(_ item: SessionItem, in session: Session, allSessions: [Session]) -> Bool {
        guard WavePrescriptionGuard.isWaveBasedBlock(session), let wave = sessionWave(session) else { return false }
        item.waveRaw = wave
        guard let src = source(for: item.exerciseId, wave: wave, in: session, allSessions: allSessions) else { return true }

        item.priorityRaw = src.priorityRaw
        item.setMin = src.setMin; item.setMax = src.setMax
        item.repMin = src.repMin; item.repMax = src.repMax
        item.targetRIRMin = src.targetRIRMin; item.targetRIRMax = src.targetRIRMax
        item.targetReps = src.targetReps; item.targetRIR = src.targetRIR
        item.intensifierRaw = src.intensifierRaw; item.intensifierNotes = src.intensifierNotes
        item.prescriptionNotes = src.prescriptionNotes
        let n = max(1, src.effectivePrescribedSets)
        item.setPrescribedSets(n)

        // Per-set arrays: at least the slots the caller made, never fewer than the sets.
        let count = max(item.plannedRepsBySet.count, n)
        func fit<T>(_ values: [T], _ fill: T) -> [T] {
            values.count >= count ? Array(values.prefix(count)) : values + Array(repeating: values.last ?? fill, count: count - values.count)
        }
        item.plannedRepsBySet = Array(repeating: item.targetReps, count: count)
        item.plannedRIRsBySet = Array(repeating: item.targetRIR, count: count)
        item.plannedLoadsBySet = fit(item.plannedLoadsBySet, item.suggestedLoad)
        item.actualReps = Array(repeating: 0, count: count)
        item.actualLoads = Array(repeating: 0.0, count: count)
        item.actualRIRs = RIREntry.unsetArray(count: count)
        return true
    }
}
