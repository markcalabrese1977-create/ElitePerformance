import Foundation
import SwiftData

/// One-time migration that clears all prescriptionNotes from existing SessionItems.
///
/// Background: before Cut A (swap handler fix), swapping an exercise slot did not
/// clear the original exercise's prescriptionNotes from the SessionItem. Any of the
/// 83+ distinct template note strings could therefore appear on a completely different
/// exercise — e.g. "Rear delt and posture work." on a bicep curl, or "Primary shoulder
/// press." on a seated cable row. The note-to-exercise mismatch is undetectable without
/// the original slot id (which SessionItem does not store), so the only safe fix is a
/// wholesale clear.
///
/// prescriptionNotes is pure display text: no coaching engine, load-projection service,
/// or progression-config path reads it (verified post-B4). New program generation
/// seeds fresh, correct notes from templates. The only user-visible impact is that
/// exercises in already-generated sessions lose their note text until the next program
/// is generated.
///
/// Supersedes ShoulderPressNoteMigration (narrower predecessor that only cleared
/// "Primary shoulder press."). This migration's broader sweep makes that one redundant;
/// its completion key is intentionally different so it runs on all devices regardless
/// of whether the narrower migration already ran.
enum PrescriptionNotesClearMigration {
    private static let completionKey = "prescriptionNotesClear.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Prescription notes clear migration not needed.")
            return
        }

        guard let items = try? context.fetch(FetchDescriptor<SessionItem>()) else {
            print("⚠️ Prescription notes clear migration failed: could not fetch session items.")
            return
        }

        var changedCount = 0

        for item in items {
            guard item.prescriptionNotes != nil else { continue }
            item.prescriptionNotes = nil
            changedCount += 1
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ Prescription notes clear migration completed. Cleared \(changedCount) items.")
            } else {
                print("ℹ️ Prescription notes clear migration found nothing to clear.")
            }
            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ Prescription notes clear migration save failed: \(error)")
        }
    }
}
