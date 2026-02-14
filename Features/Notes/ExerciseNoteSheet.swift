import SwiftUI

struct ExerciseNoteSheet: View {
    let exerciseId: String
    let exerciseName: String
    let onClose: () -> Void

    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                Spacer()
            }
            .navigationTitle(exerciseName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                text = ExerciseNotesStore.load(exerciseId: exerciseId)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        ExerciseNotesStore.save(exerciseId: exerciseId, note: text)
                        onClose()
                    }
                }

                ToolbarItem(placement: .bottomBar) {
                    Button("Clear note", role: .destructive) {
                        ExerciseNotesStore.clear(exerciseId: exerciseId)
                        text = ""
                    }
                }
            }
        }
    }
}
