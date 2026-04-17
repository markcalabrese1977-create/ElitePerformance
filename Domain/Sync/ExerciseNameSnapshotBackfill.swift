import Foundation
import SwiftData

enum ExerciseNameSnapshotBackfill {
    private static let completionKey = "exerciseNameSnapshotBackfill.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Exercise name snapshot backfill not needed.")
            return
        }

        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else {
            print("⚠️ Exercise name snapshot backfill failed: could not fetch sessions.")
            return
        }

        var changedCount = 0

        for session in sessions {
            for item in session.items {
                let existing = item.exerciseNameSnapshot?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !existing.isEmpty {
                    continue
                }

                let resolved = resolveName(for: item)

                guard !resolved.isEmpty else { continue }

                item.exerciseNameSnapshot = resolved
                changedCount += 1
            }
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ Exercise name snapshot backfill completed. Updated \(changedCount) items.")
            } else {
                print("ℹ️ Exercise name snapshot backfill found nothing to update.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ Exercise name snapshot backfill save failed: \(error)")
        }
    }

    private static func resolveName(for item: SessionItem) -> String {
        if let catalog = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId }) {
            let name = catalog.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }

        let fallback = ExerciseCatalog.displayName(for: item.exerciseId)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if fallback != "Unknown Exercise", !fallback.isEmpty {
            return fallback
        }

        return ""
    }
}
