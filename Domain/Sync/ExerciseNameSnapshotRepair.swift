import Foundation
import SwiftData

enum ExerciseNameSnapshotRepair {
    private static let completionKey = "exerciseNameSnapshotRepair.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Exercise name snapshot repair not needed.")
            return
        }

        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else {
            print("⚠️ Exercise name snapshot repair failed: could not fetch sessions.")
            return
        }

        var changedCount = 0

        for session in sessions {
            for item in session.items {
                let current = item.exerciseNameSnapshot?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard looksLikeOpaqueLegacySnapshot(current) else { continue }

                let resolved = ExerciseCatalog.displayName(for: item.exerciseId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !resolved.isEmpty else { continue }
                guard resolved != current else { continue }
                guard resolved != "Legacy / Custom Exercise" else { continue }

                item.exerciseNameSnapshot = resolved
                changedCount += 1
            }
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ Exercise name snapshot repair completed. Updated \(changedCount) items.")
            } else {
                print("ℹ️ Exercise name snapshot repair found nothing to update.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ Exercise name snapshot repair save failed: \(error)")
        }
    }

    private static func looksLikeOpaqueLegacySnapshot(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        let lower = value.lowercased()

        let uuidLike = lower.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil

        if uuidLike { return true }

        if lower.contains("-"), lower.count >= 24, !lower.contains("_") {
            return true
        }

        return false
    }
}
