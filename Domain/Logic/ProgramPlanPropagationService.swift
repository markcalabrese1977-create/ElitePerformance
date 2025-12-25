import Foundation
import SwiftData

struct ProgramPlanPropagationService {

    /// Pushes the plan (exercise list + plan fields) from a Program session
    /// into future sessions that are still planned.
    ///
    /// Scope:
    /// - Same weekday only (Friday → future Fridays, etc.)
    /// - Planned sessions only
    /// - Excludes the source session itself
    ///
    /// IMPORTANT:
    /// - This function mutates only
    /// - Callers (ProgramDayDetailView add/move/delete) must save
    static func applyPlanEditsForward(
        from programSession: Session,
        in context: ModelContext
    ) {
        let today = Calendar.current.startOfDay(for: Date())
        let sourceSessionId = programSession.id
        let targetWeekday = Calendar.current.component(.weekday, from: programSession.date)

        // Keep predicate SIMPLE to avoid SwiftData enum limitations
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { s in
                s.date > today
            },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        do {
            let futureSessions = try context.fetch(descriptor)

            let futurePlannedSameDay = futureSessions.filter {
                $0.id != sourceSessionId &&
                $0.status == .planned &&
                Calendar.current.component(.weekday, from: $0.date) == targetWeekday
            }

            // ✅ DEBUG: print once
            print("=== PROPAGATE PLAN FORWARD ===")
            print("Source session id:", sourceSessionId)
            print("Source date:", programSession.date)
            print("Target weekday:", targetWeekday)
            print("Candidates:", futurePlannedSameDay.count)
            for s in futurePlannedSameDay {
                print("→ candidate id:", s.id,
                      "date:", s.date,
                      "weekday:", Calendar.current.component(.weekday, from: s.date),
                      "items:", s.items.count)
            }
            print("=== END CANDIDATES ===")

            let sourceItems = programSession.items.sorted { $0.order < $1.order }

            for future in futurePlannedSameDay {

                // ✅ DEBUG: print once per session being updated
                print("UPDATING:", future.id, future.date)

                let futureItems = future.items.sorted { $0.order < $1.order }

                // 1️⃣ Remove extra items
                if futureItems.count > sourceItems.count {
                    for extra in futureItems[sourceItems.count...] {
                        context.delete(extra)
                    }
                }

                // 2️⃣ Add missing items
                if futureItems.count < sourceItems.count {
                    for idx in futureItems.count..<sourceItems.count {
                        let src = sourceItems[idx]
                        let newItem = SessionItem(
                            order: idx + 1,
                            exerciseId: src.exerciseId,
                            targetReps: src.targetReps,
                            targetSets: src.targetSets,
                            targetRIR: src.targetRIR,
                            suggestedLoad: src.suggestedLoad,
                            plannedRepsBySet: src.plannedRepsBySet,
                            plannedLoadsBySet: src.plannedLoadsBySet
                        )
                        future.items.append(newItem)
                    }
                }

                // 3️⃣ Align & copy plan fields
                let aligned = future.items.sorted { $0.order < $1.order }

                for (idx, src) in sourceItems.enumerated() {
                    guard idx < aligned.count else { continue }
                    let dst = aligned[idx]

                    dst.order = idx + 1
                    dst.exerciseId = src.exerciseId
                    dst.targetReps = src.targetReps
                    dst.targetSets = src.targetSets
                    dst.targetRIR = src.targetRIR
                    dst.suggestedLoad = src.suggestedLoad
                    dst.plannedRepsBySet = src.plannedRepsBySet
                    dst.plannedLoadsBySet = src.plannedLoadsBySet
                }
            }

        } catch {
            print("⚠️ ProgramPlanPropagationService.applyPlanEditsForward failed: \(error)")
        }
    }
}
