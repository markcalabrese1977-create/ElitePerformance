import Foundation
import SwiftData

struct ProgramPlanPropagationService {

    /// What a propagation would touch, computed without writing anything.
    struct Preview: Equatable {
        /// Future planned sessions that will receive the edit.
        var sessionsToChange: Int
        /// Items the lifter edited by hand on those sessions. They are left exactly as they are.
        var editedItemsSkipped: Int
        /// Sessions on which at least one edited item is skipped.
        var sessionsWithSkippedItems: Int
    }

    private static func waveLetters(_ session: Session) -> Set<String> {
        Set(session.items.compactMap { $0.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    /// The sessions a propagation from `source` may change: future, planned, in a LATER week of the same meso, SAME day slot
    /// (`DaySlot`: dayLabel plus its place among that week's sessions of the label, by programIndex), SAME wave letter(s). Never the
    /// source itself. The weekday is not part of it, so a session slid to another day still receives the edit; a later week with
    /// no session at that place is skipped (no fallback to another occurrence).
    static func targets(from source: Session, in context: ModelContext) -> [Session] {
        guard !WavePrescriptionGuard.isWaveBasedBlock(source), let slot = source.daySlot else { return [] }
        let today = Calendar.current.startOfDay(for: Date())
        let pool: [Session]
        if let meso = source.meso { pool = meso.sessions } else { return [] }
        let waves = waveLetters(source)
        var out: [Session] = []
        for (week, sessions) in Dictionary(grouping: pool, by: { $0.weekIndex }) where week > source.weekIndex {
            let slots = DaySlot.slots(ofWeek: sessions)
            out += sessions.filter {
                $0.status == .planned && $0.date > today && slots[$0.persistentModelID] == slot && waveLetters($0) == waves
            }
        }
        return out.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) }
    }

    static func preview(from source: Session, in context: ModelContext) -> Preview {
        var skipped = 0, sessionsSkipping = 0
        let targets = targets(from: source, in: context)
        for t in targets {
            let n = t.items.filter { $0.planEdited }.count
            skipped += n
            if n > 0 { sessionsSkipping += 1 }
        }
        return Preview(sessionsToChange: targets.count, editedItemsSkipped: skipped, sessionsWithSkippedItems: sessionsSkipping)
    }

    /// Pushes the plan (exercise list + plan fields) from a Program session into future sessions that are still planned.
    ///
    /// Scope (see `targets`): planned, future, a later week of the same meso, same day slot AND same wave letter.
    /// Items the lifter edited by hand (`planEdited`) on a target are skipped, never overwritten or deleted; the returned
    /// preview says how many.
    ///
    /// Alignment strategy: match by exerciseId, not position.
    /// - Matched items: update plan fields only, never overwrite exerciseId
    /// - New items in source: append to future
    /// - Items in future not in source: delete (unless edited)
    ///
    /// Callers must save after calling, and should have asked the lifter first (`preview`).
    @discardableResult
    static func applyPlanEditsForward(
        from programSession: Session,
        in context: ModelContext
    ) -> Preview {
        // Wave-based blocks are never valid targets: the copy below rewrites
        // `waveRaw` and the whole rep/RIR/set prescription, which flattens a DUP
        // block's B and C weeks into its A week.
        guard !WavePrescriptionGuard.isWaveBasedBlock(programSession) else {
            print("⛔️ applyPlanEditsForward skipped: wave-based block, plan edits stay on this session.")
            return Preview(sessionsToChange: 0, editedItemsSkipped: 0, sessionsWithSkippedItems: 0)
        }

        let result = preview(from: programSession, in: context)
        let futurePlannedSameDay = targets(from: programSession, in: context)
        print("ℹ️ Propagation: \(futurePlannedSameDay.count) sessions, \(result.editedItemsSkipped) edited items skipped")

        let sourceItems = programSession.items.sorted { $0.order < $1.order }
            let sourceIds = Set(sourceItems.map { $0.exerciseId })

            for future in futurePlannedSameDay {

                // 1) Delete future items not present in source
                let toDelete = future.items.filter { !sourceIds.contains($0.exerciseId) && !$0.planEdited }
                for item in toDelete {
                    context.delete(item)
                }

                // 2) Update matched items — plan fields only, never exerciseId
                for src in sourceItems {
                    if let dst = future.items.first(where: { $0.exerciseId == src.exerciseId }), !dst.planEdited {
                        let fingerprint = dst.writeFingerprint()
                        defer { dst.stampIfChanged(since: fingerprint) }
                        dst.order           = src.order
                        dst.targetReps      = src.targetReps
                        dst.targetSets      = src.effectivePrescribedSets
                        dst.prescribedSets  = src.effectivePrescribedSets
                        dst.targetRIR       = src.targetRIR
                        dst.suggestedLoad   = src.suggestedLoad
                        dst.plannedRepsBySet  = src.plannedRepsBySet
                        dst.plannedLoadsBySet = src.plannedLoadsBySet
                        dst.plannedRIRsBySet  = src.plannedRIRsBySet
                        dst.waveRaw           = src.waveRaw
                        dst.priorityRaw       = src.priorityRaw
                        dst.setMin            = src.setMin
                        dst.setMax            = src.setMax
                        dst.repMin            = src.repMin
                        dst.repMax            = src.repMax
                        dst.targetRIRMin      = src.targetRIRMin
                        dst.targetRIRMax      = src.targetRIRMax
                        dst.intensifierRaw    = src.intensifierRaw
                        dst.intensifierNotes  = src.intensifierNotes
                        dst.prescriptionNotes = src.prescriptionNotes
                    }
                }

                // 3) Append source items not yet in future
                let futureIds = Set(future.items.map { $0.exerciseId })  // edited items count as present, so they are not duplicated
                for src in sourceItems {
                    guard !futureIds.contains(src.exerciseId) else { continue }

                    let setCount = max(0, src.effectivePrescribedSets)
                    let newItem = SessionItem(
                        order: src.order,
                        exerciseId: src.exerciseId,
                        exerciseNameSnapshot: src.exerciseNameSnapshot,
                        targetReps: src.targetReps,
                        targetSets: setCount,
                        targetRIR: src.targetRIR,
                        suggestedLoad: src.suggestedLoad,
                        waveRaw: src.waveRaw,
                        priorityRaw: src.priorityRaw,
                        setMin: src.setMin,
                        setMax: src.setMax,
                        repMin: src.repMin,
                        repMax: src.repMax,
                        targetRIRMin: src.targetRIRMin,
                        targetRIRMax: src.targetRIRMax,
                        intensifierRaw: src.intensifierRaw,
                        intensifierNotes: src.intensifierNotes,
                        prescriptionNotes: src.prescriptionNotes,
                        plannedRepsBySet: src.plannedRepsBySet,
                        plannedLoadsBySet: src.plannedLoadsBySet,
                        plannedRIRsBySet: src.plannedRIRsBySet,
                        actualReps: Array(repeating: 0, count: setCount),
                        actualLoads: Array(repeating: 0.0, count: setCount),
                        actualRIRs: RIREntry.unsetArray(count: setCount)
                    )
                    context.insert(newItem)
                    future.items.append(newItem)
                }
            }

        return result
    }
}

// MARK: - Apply to the block (by position)

extension ProgramPlanPropagationService {
    /// Future planned sessions of the SOURCE's meso with the same (trimmed) dayLabel. Never another meso.
    static func blockTargets(from source: Session, in context: ModelContext) -> [Session] {
        guard !WavePrescriptionGuard.isWaveBasedBlock(source), let meso = source.meso else { return [] }
        let label = source.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty else { return [] }
        let today = Calendar.current.startOfDay(for: Date())
        return meso.sessions.filter {
            $0.id != source.id && $0.status == .planned && $0.date > today &&
            ($0.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == label
        }
    }

    static func blockPreview(from source: Session, in context: ModelContext) -> Preview {
        var skipped = 0, sessionsSkipping = 0
        let targets = blockTargets(from: source, in: context)
        for t in targets {
            let n = t.items.filter { $0.planEdited }.count
            skipped += n
            if n > 0 { sessionsSkipping += 1 }
        }
        return Preview(sessionsToChange: targets.count, editedItemsSkipped: skipped, sessionsWithSkippedItems: sessionsSkipping)
    }

    /// Copies the source's plan onto each block target by position. Items the lifter edited by hand are skipped, never
    /// overwritten or deleted. Callers save.
    @discardableResult
    static func applyToBlock(from source: Session, in context: ModelContext) -> Preview {
        let result = blockPreview(from: source, in: context)
        let sourceItems = source.items.sorted { $0.order < $1.order }
        for other in blockTargets(from: source, in: context) {
            let sorted = other.items.sorted { $0.order < $1.order }
            if sorted.count > sourceItems.count {
                for extra in sorted[sourceItems.count...] where !extra.planEdited { context.delete(extra) }
            }
            if sorted.count < sourceItems.count {
                for idx in sorted.count..<sourceItems.count {
                    let src = sourceItems[idx]
                    let n = SessionItem(
                        order: idx + 1, exerciseId: src.exerciseId, exerciseNameSnapshot: src.exerciseNameSnapshot,
                        targetReps: src.targetReps, targetSets: src.targetSets, targetRIR: src.targetRIR, suggestedLoad: src.suggestedLoad,
                        waveRaw: src.waveRaw, priorityRaw: src.priorityRaw, setMin: src.setMin, setMax: src.setMax,
                        repMin: src.repMin, repMax: src.repMax, targetRIRMin: src.targetRIRMin, targetRIRMax: src.targetRIRMax,
                        intensifierRaw: src.intensifierRaw, intensifierNotes: src.intensifierNotes, prescriptionNotes: src.prescriptionNotes,
                        plannedRepsBySet: src.plannedRepsBySet, plannedLoadsBySet: src.plannedLoadsBySet)
                    context.insert(n)
                    other.items.append(n)
                }
            }
            let aligned = other.items.sorted { $0.order < $1.order }
            for (idx, src) in sourceItems.enumerated() where idx < aligned.count {
                let dst = aligned[idx]
                guard !dst.planEdited else { continue }
                let fingerprint = dst.writeFingerprint()
                defer { dst.stampIfChanged(since: fingerprint) }
                dst.order = idx + 1
                dst.exerciseId = src.exerciseId
                dst.exerciseNameSnapshot = src.exerciseNameSnapshot
                dst.targetReps = src.targetReps
                dst.targetSets = src.effectivePrescribedSets
                dst.prescribedSets = src.effectivePrescribedSets
                dst.targetRIR = src.targetRIR
                dst.suggestedLoad = src.suggestedLoad
                dst.waveRaw = src.waveRaw; dst.priorityRaw = src.priorityRaw
                dst.setMin = src.setMin; dst.setMax = src.setMax; dst.repMin = src.repMin; dst.repMax = src.repMax
                dst.targetRIRMin = src.targetRIRMin; dst.targetRIRMax = src.targetRIRMax
                dst.intensifierRaw = src.intensifierRaw; dst.intensifierNotes = src.intensifierNotes
                dst.prescriptionNotes = src.prescriptionNotes
                dst.plannedRepsBySet = src.plannedRepsBySet
                dst.plannedLoadsBySet = src.plannedLoadsBySet
            }
        }
        return result
    }
}

// MARK: - Renaming a day type

/// Renaming a day ("Push" -> "Upper A") rewrites the label on EVERY session of that day type in the same meso, planned,
/// in-progress and completed, so the data that pairs sessions by dayLabel stays one chain:
///  - `PlanMemoryEngine.nextTargetItem` (carry-forward) pairs a finished session with the next one by meso + EXACT dayLabel
///    + wave letter, so a half-renamed block stops carrying loads forward;
///  - `LoadProjectionService` (Auto+), `CoachingEngine` and `SessionItemEditService` match the same way;
///  - History cards show `SessionHistory.dayLabelSnapshot` before the session's own label, so the snapshots of the renamed
///    completed sessions are rewritten too;
///  - MesoComparison and the summaries read the sessions' labels, which are all renamed together.
/// Other mesos are never touched.
enum DayLabelRename {

    struct Plan: Equatable {
        var oldLabel: String
        var newLabel: String
        var planned: Int
        var completed: Int
        var other: Int
        var sessionCount: Int { planned + completed + other }
    }

    enum Failure: Error, Equatable {
        case emptyLabel
        case unchanged
        case collidesWithAnotherDay(String)
    }

    private static func key(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Sessions of `session`'s day type in its meso (exact label, as carry-forward compares it), the session itself included.
    static func targets(of session: Session) -> [Session] {
        guard let meso = session.meso else { return [session] }
        let label = session.dayLabel
        return meso.sessions.filter { $0.id == session.id || SessionDayLabelMatcher.matches($0.dayLabel, label) }
    }

    static func plan(renaming session: Session, to newLabel: String) -> Result<Plan, Failure> {
        let trimmed = key(newLabel)
        guard !trimmed.isEmpty else { return .failure(.emptyLabel) }
        guard trimmed != key(session.dayLabel) else { return .failure(.unchanged) }
        if let meso = session.meso {
            let mine = Set(targets(of: session).map(\.id))
            if meso.sessions.contains(where: { !mine.contains($0.id) && key($0.dayLabel).lowercased() == trimmed.lowercased() }) {
                return .failure(.collidesWithAnotherDay(trimmed))
            }
        }
        let t = targets(of: session)
        return .success(Plan(
            oldLabel: key(session.dayLabel), newLabel: trimmed,
            planned: t.filter { $0.status == .planned }.count,
            completed: t.filter { $0.status == .completed }.count,
            other: t.filter { $0.status == .inProgress }.count))
    }

    /// All or nothing: every target is renamed and saved together, or none is.
    @discardableResult
    static func apply(renaming session: Session, to newLabel: String, in context: ModelContext) throws -> Plan {
        let plan: Plan
        switch Self.plan(renaming: session, to: newLabel) {
        case .success(let p): plan = p
        case .failure(let f): throw f
        }
        let t = targets(of: session)
        let ids = Set(t.map(\.id))
        do {
            for s in t { s.dayLabel = plan.newLabel }
            let histories = (try? context.fetch(FetchDescriptor<SessionHistory>())) ?? []
            for h in histories { if let sid = h.sessionId, ids.contains(sid) { h.dayLabelSnapshot = plan.newLabel } }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return plan
    }
}
