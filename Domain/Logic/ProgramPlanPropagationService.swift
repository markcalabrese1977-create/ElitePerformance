import Foundation
import SwiftData

struct ProgramPlanPropagationService {

    /// Pushes the plan (exercise list + plan fields) from a Program session
    /// into future sessions that are still planned.
    ///
    /// Scope:
    /// - Same weekday only
    /// - Planned sessions only
    /// - Excludes the source session itself
    ///
    /// Alignment strategy: match by exerciseId, not position.
    /// - Matched items: update plan fields only, never overwrite exerciseId
    /// - New items in source: append to future
    /// - Items in future not in source: delete
    ///
    /// Callers must save after calling.
    static func applyPlanEditsForward(
        from programSession: Session,
        in context: ModelContext
    ) {
        let today = Calendar.current.startOfDay(for: Date())
        let sourceSessionId = programSession.id
        let targetWeekday = Calendar.current.component(.weekday, from: programSession.date)

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { s in
                s.date > today
            },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        do {
            let futureSessions = try context.fetch(descriptor)

            print("🔍 PROPAGATION DEBUG")
            print("   source date: \(programSession.date), weekday: \(targetWeekday), meso: \(programSession.meso?.name ?? "nil")")
            print("   total future sessions fetched: \(futureSessions.count)")
            for s in futureSessions {
                let wd = Calendar.current.component(.weekday, from: s.date)
                print("     candidate date: \(s.date) weekday: \(wd) status: \(s.status) meso: \(s.meso?.name ?? "nil") id-match: \(s.id == sourceSessionId)")
            }

            let futurePlannedSameDay = futureSessions.filter {
                $0.id != sourceSessionId &&
                $0.status == .planned &&
                Calendar.current.component(.weekday, from: $0.date) == targetWeekday
            }
            print("   matched after filter: \(futurePlannedSameDay.count)")

            let sourceItems = programSession.items.sorted { $0.order < $1.order }
            let sourceIds = Set(sourceItems.map { $0.exerciseId })

            for future in futurePlannedSameDay {

                // 1) Delete future items not present in source
                let toDelete = future.items.filter { !sourceIds.contains($0.exerciseId) }
                for item in toDelete {
                    context.delete(item)
                }

                // 2) Update matched items — plan fields only, never exerciseId
                for src in sourceItems {
                    if let dst = future.items.first(where: { $0.exerciseId == src.exerciseId }) {
                        dst.order           = src.order
                        dst.targetReps      = src.targetReps
                        dst.targetSets      = src.targetSets
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
                let futureIds = Set(future.items.map { $0.exerciseId })
                for src in sourceItems {
                    guard !futureIds.contains(src.exerciseId) else { continue }

                    let setCount = max(0, src.targetSets)
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

        } catch {
            print("⚠️ ProgramPlanPropagationService.applyPlanEditsForward failed: \(error)")
        }
    }
}
