import Foundation
import SwiftData

enum SwapPropagationScope {
    case futurePlannedEverywhere
}

struct ExerciseSwapPropagationService {

    /// Applies a swap to future planned sessions by replacing `fromExerciseId` with `toExerciseId`.
    static func apply(
        fromExerciseId: String,
        toExerciseId: String,
        scope: SwapPropagationScope = .futurePlannedEverywhere,
        in context: ModelContext
    ) {
        let today = Calendar.current.startOfDay(for: Date())

        // SwiftData predicate: keep it SIMPLE (Date only), then filter status in memory.
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { session in
                session.date > today
            },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        do {
            let futureSessions = try context.fetch(descriptor)

            // Filter in Swift to avoid SwiftData macro enum-case limitations.
            let futurePlanned = futureSessions.filter { $0.status == .planned }

            for session in futurePlanned {
                var didChange = false

                for item in session.items {
                    if item.exerciseId == fromExerciseId {
                        item.exerciseId = toExerciseId
                        didChange = true
                    }
                }

                if didChange {
                    // SwiftData tracks mutations; keeping this for clarity/debugging.
                    // print("Updated session \(session.id) on \(session.date)")
                }
            }

            try context.save()
        } catch {
            print("ExerciseSwapPropagationService.apply failed: \(error)")
        }
    }
}


