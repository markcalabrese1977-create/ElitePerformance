import SwiftData
import Foundation

struct MesoIndexBackfillEngine {
    let context: ModelContext

    func backfillIfNeeded() {
        // Fetch sessions sorted by date (best approximation for legacy data)
        let sessions = (try? context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date, order: .forward)])
        )) ?? []

        // If at least one has programIndex, assume already backfilled/seeded
        if sessions.contains(where: { $0.programIndex != nil }) { return }

        var idx = 1
        for s in sessions {
            s.programIndex = idx
            idx += 1
        }

        // Ensure ProgramState exists
        let states = (try? context.fetch(FetchDescriptor<ProgramState>())) ?? []
        if states.isEmpty {
            _ = ProgramState(currentProgramIndex: 1, activeMesoId: "meso.v1")
        }

        try? context.save()
    }
}
