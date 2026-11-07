import SwiftUI
import SwiftData

struct ExerciseNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let exerciseId: String
    let exerciseName: String
    let onClose: () -> Void

    @Query private var allNotes: [ExerciseNote]
    @Query private var profiles: [UserProfile]

    @State private var text: String = ""

    private var existingNote: ExerciseNote? {
        allNotes.first(where: { $0.exerciseId == exerciseId })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let profile = profiles.first {
                    Toggle(isOn: Binding(
                        get: { profile.isProgressionExempt(exerciseId: exerciseId) },
                        set: { newValue in
                            profile.setProgressionExempt(newValue, exerciseId: exerciseId)
                            try? modelContext.save()
                        }
                    )) {
                        Text("Fixed load: never auto-increase")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                    MaxLoadRow(profile: profile, exerciseId: exerciseId)

                    Divider().padding(.top, 8)
                }

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


/// "Max load" under the Fixed load toggle: an optional per-exercise cap on the loads the plan writes.
/// When a max is set or lowered, the remaining planned sessions above it are listed and, on confirm, set to it.
private struct MaxLoadRow: View {
    @Environment(\.modelContext) private var modelContext
    let profile: UserProfile
    let exerciseId: String

    @State private var text: String = ""
    @State private var lastReviewed: Double?
    @State private var plan: SessionItemEditService.MaxLoadPlan?
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Max load")
                    .font(.subheadline)
                Spacer()
                TextField("None", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onChange(of: text) { _, newValue in commit(newValue) }
                    .onChange(of: focused) { _, isFocused in if !isFocused { review() } }
                    .onSubmit { review() }
                if !text.isEmpty {
                    Button {
                        text = ""
                        profile.setMaxLoad(nil, exerciseId: exerciseId)
                        lastReviewed = nil
                        try? modelContext.save()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear max load")
                }
            }
            Text("The plan never writes a heavier load; once you reach it, progress with reps or tempo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onAppear {
            if let cap = profile.maxLoad(for: exerciseId) {
                text = cap == cap.rounded() ? String(Int(cap)) : String(cap)
                lastReviewed = cap
            }
        }
        .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
            if let plan {
                MaxLoadClampSheet(plan: plan, errorMessage: errorMessage, onConfirm: confirm, onCancel: { self.plan = nil })
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func commit(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        profile.setMaxLoad(Double(cleaned), exerciseId: exerciseId)
        try? modelContext.save()
    }

    /// A max was set or lowered: offer to bring the remaining planned loads above it down to it.
    private func review() {
        // A fixed-load or bodyweight exercise ignores a max, so there is nothing to lower.
        guard let cap = UserProfile.effectiveMaxLoad(for: exerciseId, profile: profile) else { return }
        if let lastReviewed, cap >= lastReviewed { self.lastReviewed = cap; return }
        lastReviewed = cap
        errorMessage = nil
        let found = SessionItemEditService.planClampToMax(
            meso: SessionItemEditService.activeMeso(in: modelContext), exerciseId: exerciseId, max: cap
        )
        if found.isApplicable { plan = found }
    }

    private func confirm() {
        guard let plan else { return }
        do {
            try SessionItemEditService.applyClampToMax(plan, in: modelContext)
            self.plan = nil
        } catch {
            errorMessage = "Nothing was changed: \(error)"
        }
    }
}

private struct MaxLoadClampSheet: View {
    let plan: SessionItemEditService.MaxLoadPlan
    let errorMessage: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(SessionItemEditService.clampPreviewText(count: plan.targets.count, max: plan.max))
                        .font(.subheadline.weight(.semibold))
                }
                Section("Sessions") {
                    ForEach(Array(plan.targets.enumerated()), id: \.offset) { _, t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            Text(t.detail(max: plan.max)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }
                Section { } footer: {
                    Text("Unchanged: completed and started sessions, plans you edited by hand, loads at or below the max.")
                }
            }
            .navigationTitle("Lower planned loads?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep plan", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Set to max", action: onConfirm).fontWeight(.semibold) }
            }
        }
    }
}
