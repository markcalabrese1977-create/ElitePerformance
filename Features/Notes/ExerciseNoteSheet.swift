import SwiftUI
import SwiftData

struct ExerciseNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let exerciseId: String
    let exerciseName: String
    let onClose: () -> Void

    @Query private var allNotes: [ExerciseNote]

    @State private var text: String = ""

    private var existingNote: ExerciseNote? {
        allNotes.first(where: { $0.exerciseId == exerciseId })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .padding(12)

                Divider()
            }
            .navigationTitle(exerciseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onClose()
                    }
                }

                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Clear") {
                        clearNote()
                    }

                    Button("Save") {
                        saveNote()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                loadNote()
            }
        }
    }

    private func loadNote() {
        if let existingNote {
            text = existingNote.note
            return
        }

        // Fallback bridge from legacy UserDefaults store
        text = ExerciseNotesStore.load(exerciseId: exerciseId)
    }

    private func saveNote() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            clearNote()
            return
        }

        if let existingNote {
            existingNote.note = trimmed
            existingNote.updatedAt = Date()
        } else {
            let newNote = ExerciseNote(
                exerciseId: exerciseId,
                note: trimmed
            )
            modelContext.insert(newNote)
        }

        // Optional bridge cleanup: remove old local copy once migrated
        ExerciseNotesStore.clear(exerciseId: exerciseId)

        do {
            try modelContext.save()
        } catch {
            print("⚠️ Failed to save exercise note: \(error)")
        }

        onClose()
    }

    private func clearNote() {
        if let existingNote {
            modelContext.delete(existingNote)
        }

        ExerciseNotesStore.clear(exerciseId: exerciseId)

        do {
            try modelContext.save()
        } catch {
            print("⚠️ Failed to clear exercise note: \(error)")
        }

        onClose()
    }
}
