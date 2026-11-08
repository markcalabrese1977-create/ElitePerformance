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

    // Max-load confirmation, shown INLINE in this sheet (a second sheet cannot present from inside a sheet that
    // is being dismissed: "view is not in the window hierarchy").
    @State private var clampPlan: SessionItemEditService.MaxLoadPlan?
    @State private var clampError: String?
    /// The max the prompt was already offered for: each max is offered once, whatever the answer.
    @State private var offeredCap: Double?

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

                    MaxLoadRow(
                        profile: profile,
                        exerciseId: exerciseId,
                        onCommitted: { _ = offerClampIfNeeded() },
                        onCleared: { offeredCap = nil; clampPlan = nil; clampError = nil }
                    )

                    if let plan = clampPlan {
                        MaxLoadClampPrompt(
                            plan: plan, errorMessage: clampError,
                            onConfirm: confirmClamp,
                            onKeep: { clampPlan = nil; clampError = nil }
                        )
                    }

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
                        closeOrOffer()
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

        closeOrOffer()
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

        closeOrOffer()
    }

    /// Leaving the sheet: if planned loads above the max remain and this max has not been offered yet, show the
    /// confirmation here instead of closing (the next Close leaves). Otherwise close.
    private func closeOrOffer() {
        if offerClampIfNeeded() { return }
        onClose()
    }

    /// Plans the clamp for the saved max and, when it has work to do and this max was not offered before, shows it.
    /// Returns true when the prompt was just shown.
    private func offerClampIfNeeded() -> Bool {
        guard let profile = profiles.first,
              let cap = UserProfile.effectiveMaxLoad(for: exerciseId, profile: profile),
              offeredCap != cap else { return false }
        let found = SessionItemEditService.planClampToMax(
            meso: SessionItemEditService.activeMeso(in: modelContext), exerciseId: exerciseId, max: cap
        )
        guard found.isApplicable else { return false }
        offeredCap = cap
        clampError = nil
        clampPlan = found
        return true
    }

    private func confirmClamp() {
        guard let plan = clampPlan else { return }
        do {
            try SessionItemEditService.applyClampToMax(plan, in: modelContext)
            clampPlan = nil
            clampError = nil
        } catch {
            clampError = "Nothing was changed: \(error)"
        }
    }
}


/// "Max load" under the Fixed load toggle: an optional per-exercise cap on the loads the plan writes. The owning
/// sheet is told when the field is committed (return or focus lost) so it can offer to lower planned loads.
private struct MaxLoadRow: View {
    @Environment(\.modelContext) private var modelContext
    let profile: UserProfile
    let exerciseId: String
    let onCommitted: () -> Void
    let onCleared: () -> Void

    @State private var text: String = ""
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
                    .onChange(of: focused) { _, isFocused in if !isFocused { onCommitted() } }
                    .onSubmit { onCommitted() }
                if !text.isEmpty {
                    Button {
                        text = ""
                        profile.setMaxLoad(nil, exerciseId: exerciseId)
                        try? modelContext.save()
                        onCleared()
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
            }
        }
    }

    private func commit(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        profile.setMaxLoad(Double(cleaned), exerciseId: exerciseId)
        try? modelContext.save()
    }
}

/// The confirmation, inline in the note sheet: what will be lowered, then Set to max / Keep plan.
private struct MaxLoadClampPrompt: View {
    let plan: SessionItemEditService.MaxLoadPlan
    let errorMessage: String?
    let onConfirm: () -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lower planned loads?")
                .font(.subheadline.weight(.semibold))
            Text(SessionItemEditService.clampPreviewText(count: plan.targets.count, max: plan.max))
                .font(.footnote)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.targets.enumerated()), id: \.offset) { _, t in
                        HStack(alignment: .firstTextBaseline) {
                            Text(t.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.caption.weight(.semibold))
                            Text(t.detail(max: plan.max)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Keep plan", action: onKeep)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Set to max", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
            Text("Unchanged: completed and started sessions, loads at or below the max. Plans you edited are lowered too (marked), and stay marked as edited.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
