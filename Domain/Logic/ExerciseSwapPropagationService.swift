import Foundation
import SwiftData

enum SwapPropagationScope {
    case futurePlannedEverywhere
}

struct ExerciseSwapPropagationService {

    /// Applies a swap to future planned sessions by replacing `fromExerciseId` with `toExerciseId`.
    ///
    /// Wave-based blocks are never written: a swap resets loads on every matched item, and on a
    /// DUP block the sessions of one day type carry different wave prescriptions, so the swap
    /// belongs to the edited session only. Guarded here, not only at call sites, on both the
    /// source session's block and each target's block (the fetch below is not meso-scoped).
    static func apply(
        fromExerciseId: String,
        toExerciseId: String,
        scope: SwapPropagationScope = .futurePlannedEverywhere,
        sourceSession: Session? = nil,
        in context: ModelContext
    ) {
        if let sourceSession, WavePrescriptionGuard.isWaveBasedBlock(sourceSession) {
            print("⛔️ ExerciseSwapPropagationService.apply skipped: wave-based block, swap stays on this session.")
            return
        }
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
            let canonicalFrom = ExerciseCatalog.canonicalExerciseId(for: fromExerciseId)
            let toName = ExerciseCatalog.displayName(for: toExerciseId)

            var waveVerdictByMeso: [PersistentIdentifier: Bool] = [:]
            func isWaveTarget(_ session: Session) -> Bool {
                guard let mesoID = session.meso?.persistentModelID else {
                    return WavePrescriptionGuard.isWaveBasedBlock(session)
                }
                if let cached = waveVerdictByMeso[mesoID] { return cached }
                let verdict = WavePrescriptionGuard.isWaveBasedBlock(session)
                waveVerdictByMeso[mesoID] = verdict
                return verdict
            }

            for session in futurePlanned where !isWaveTarget(session) {
                var didChange = false

                for item in session.items {
                    if ExerciseCatalog.canonicalExerciseId(for: item.exerciseId) == canonicalFrom {
                        item.exerciseId = toExerciseId
                        item.exerciseNameSnapshot = toName
                        item.suggestedLoad = 0
                        item.plannedLoadsBySet = Array(repeating: 0.0, count: item.plannedLoadsBySet.count)
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


