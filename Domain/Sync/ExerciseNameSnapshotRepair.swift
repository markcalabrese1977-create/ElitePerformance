import Foundation
import SwiftData

enum ExerciseNameSnapshotRepair {
    private static let completionKey = "exerciseNameSnapshotRepair.v6.completed"

    private static let snapshotRepairMap: [String: String] = [
        "591028b2-9f09-4347-a245-6cf71e5f403d": "Supination / Pronation Curl",
        "31c44a80-6c56-4f8e-acb1-2a6761b71a7c": "Arnold Press",
        "7ddaa8ff-55c5-4af5-891e-62676cdc9daf": "Single-Arm Cable Lateral Raise",
        "e8f675c1-2bc2-4eeb-a0b2-d701a6412f58": "Seated Cable Press",
        "1cb4f3a7-65f2-4e9d-aca1-ee754cd157b6": "Single-Arm Cable Curl"
    ]

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

                guard !current.isEmpty else { continue }

                let normalizedSnapshot = normalizeLegacyId(current)

                if let repaired = snapshotRepairMap[normalizedSnapshot],
                   repaired != current {
                    item.exerciseNameSnapshot = repaired
                    changedCount += 1
                    continue
                }

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

    private static func normalizeLegacyId(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let collapsedWhitespace = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()

        return collapsedWhitespace
    }

    private static func looksLikeOpaqueLegacySnapshot(_ value: String) -> Bool {
        let normalized = normalizeLegacyId(value)
        guard !normalized.isEmpty else { return false }

        let dashedUUID = normalized.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil

        if dashedUUID { return true }

        if normalized.contains("-"), normalized.count >= 24, !normalized.contains("_") {
            return true
        }

        return false
    }
}
