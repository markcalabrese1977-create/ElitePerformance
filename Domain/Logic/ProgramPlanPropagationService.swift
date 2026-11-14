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

    private static func normalizedLabel(_ label: String?) -> String {
        (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func waveLetters(_ session: Session) -> Set<String> {
        Set(session.items.compactMap { $0.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    /// The sessions a propagation from `source` may change: future, planned, same weekday, SAME dayLabel, SAME wave letter(s),
    /// and the SAME meso. Never the source itself.
    static func targets(from source: Session, in context: ModelContext) -> [Session] {
        guard !WavePrescriptionGuard.isWaveBasedBlock(source) else { return [] }
        let today = Calendar.current.startOfDay(for: Date())
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { s in s.date > today },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        guard let future = try? context.fetch(descriptor) else { return [] }
        let weekday = Calendar.current.component(.weekday, from: source.date)
        let label = normalizedLabel(source.dayLabel)
        let waves = waveLetters(source)
        return future.filter {
            $0.id != source.id &&
            $0.status == .planned &&
            Calendar.current.component(.weekday, from: $0.date) == weekday &&
            normalizedLabel($0.dayLabel) == label &&
            $0.meso?.id == source.meso?.id &&
            waveLetters($0) == waves
        }
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
    /// Scope (see `targets`): planned, future, same weekday AND same dayLabel AND same wave letter AND same meso.
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
                        actualRIRs: Array(repeating: 0, count: setCount)
                    )
                    context.insert(newItem)
                    future.items.append(newItem)
                }
            }

        return result
    }
}
