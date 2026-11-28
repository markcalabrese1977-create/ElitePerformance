// Features/Components/ExerciseLibraryView.swift
import SwiftUI
import SwiftData

/// Settings → Exercises: every exercise the app knows (built-in and your own). Custom exercises open an editor (name, muscles,
/// compound, bodyweight, delete); built-ins open a read-only detail with their per-exercise settings and note.
struct ExerciseLibraryView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var refreshToken = UUID()
    @State private var target: LibraryTarget?

    struct LibraryTarget: Identifiable { let id: String; var isNew: Bool { id == Self.newId }; static let newId = "__new__" }

    private var builtInIds: Set<String> { Set(ExerciseCatalog.builtIn.map(\.id)) }

    private var allExercises: [CatalogExercise] {
        var seen = Set<String>()
        return (ExerciseCatalog.all + ExerciseCatalog.customExercises(in: modelContext)).filter { seen.insert($0.id).inserted }
    }

    private var sections: [ExercisePickerModel.Section] {
        ExercisePickerModel.sections(exercises: allExercises, query: searchText, recentIds: [], swapping: nil)
    }

    var body: some View {
        List {
            Section {
                Button { target = LibraryTarget(id: LibraryTarget.newId) } label: {
                    Label("New custom exercise", systemImage: "plus.circle.fill")
                }
            }
            let shown = sections
            if shown.isEmpty {
                Section { Text("No exercises match “\(searchText)”.").foregroundStyle(.secondary) }
            }
            ForEach(shown) { section in
                Section(section.title) {
                    ForEach(section.exercises) { ex in
                        Button { target = LibraryTarget(id: ex.id) } label: { row(ex) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .id(refreshToken)
        .keyboardDismissal()
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onReceive(NotificationCenter.default.publisher(for: .exerciseCatalogDidChange)) { _ in refreshToken = UUID() }
        .sheet(item: $target, onDismiss: { refreshToken = UUID() }) { t in
            if t.isNew {
                CustomExerciseEditor(exerciseId: nil, onClose: { target = nil })
            } else if builtInIds.contains(t.id) {
                BuiltInExerciseDetail(exerciseId: t.id, onClose: { target = nil })
            } else {
                CustomExerciseEditor(exerciseId: t.id, onClose: { target = nil })
            }
        }
    }

    private func row(_ ex: CatalogExercise) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.name).foregroundStyle(.primary)
                Text(ex.primaryMuscle.rawValue.capitalized + (ex.isBodyweight ? " · bodyweight" : "") + (ex.isCompound ? " · compound" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !builtInIds.contains(ex.id) {
                Text("Custom").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Built-in detail

struct BuiltInExerciseDetail: View {
    let exerciseId: String
    let onClose: () -> Void
    @State private var showingSettings = false

    private var exercise: CatalogExercise? { ExerciseCatalog.builtIn.first { $0.id == exerciseId } }

    var body: some View {
        NavigationStack {
            Form {
                if let ex = exercise {
                    Section {
                        LabeledContent("Name", value: ex.name)
                        LabeledContent("Primary muscle", value: ex.primaryMuscle.rawValue.capitalized)
                        LabeledContent("Compound lift", value: ex.isCompound ? "Yes" : "No")
                        LabeledContent("Bodyweight", value: ex.isBodyweight ? "Yes" : "No")
                    } footer: {
                        Text("Built-in exercises can't be renamed or deleted. You can set a load step, a max load, a fixed load and a note for it.")
                    }
                    Section {
                        Button("Load settings and note") { showingSettings = true }
                    }
                }
            }
            .navigationTitle(exercise?.name ?? "Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { onClose() } } }
            .sheet(isPresented: $showingSettings) {
                ExerciseNoteSheet(exerciseId: exerciseId, exerciseName: exercise?.name ?? "Exercise", onClose: { showingSettings = false })
            }
        }
    }
}

// MARK: - Custom editor (new or existing)

struct CustomExerciseEditor: View {
    /// nil = a new exercise.
    let exerciseId: String?
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var muscle: MuscleGroup = .chest
    @State private var compound = false
    @State private var bodyweight = false
    @State private var loaded = false
    @State private var original: CustomExerciseLibrary.Edit?
    @State private var showingMapping = false
    @State private var showingSettings = false
    @State private var confirmFlags = false
    @State private var confirmDelete = false
    @State private var blockedMessage: String?
    @State private var errorText: String?

    private var check: CustomExerciseLibrary.NameCheck {
        CustomExerciseLibrary.checkName(name, forId: exerciseId, in: modelContext)
    }

    private var flagsChanged: Bool {
        guard let o = original else { return false }
        return o.isCompound != compound || o.isBodyweight != bodyweight
    }

    private var loggedSets: Int { exerciseId.map { CustomExerciseLibrary.usage(of: $0, in: modelContext).loggedSets } ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                } header: { Text("Name") } footer: {
                    if !name.isEmpty, let m = check.message { Text(m).foregroundStyle(.red) }
                    else if exerciseId != nil { Text("Renaming updates your logged history, records and program everywhere.") }
                }
                Section("Primary muscle") {
                    Picker("Muscle group", selection: $muscle) {
                        ForEach(MuscleGroup.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section {
                    Toggle(CompoundExplainer.label, isOn: $compound)
                    Toggle("Bodyweight exercise", isOn: $bodyweight)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(CompoundExplainer.footer)
                        if exerciseId != nil { Text("Changes apply to future sessions; stored sets keep their values.") }
                    }
                }
                if let id = exerciseId {
                    Section {
                        Button("Fine muscles and shares") { showingMapping = true }
                        Button("Load settings and note") { showingSettings = true }
                    }
                    Section {
                        Button("Delete exercise", role: .destructive) {
                            let u = CustomExerciseLibrary.usage(of: id, in: modelContext)
                            if u.isUnused { confirmDelete = true } else { blockedMessage = u.deleteBlockMessage }
                        }
                    }
                }
                if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
            }
            .navigationTitle(exerciseId == nil ? "New Exercise" : "Edit Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onClose() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if flagsChanged && loggedSets > 0 { confirmFlags = true } else { save() } }
                        .disabled(!check.isOK)
                }
            }
            .onAppear { load() }
            .sheet(isPresented: $showingMapping, onDismiss: { reloadFlags() }) {
                if let id = exerciseId { CustomMuscleMappingSheet(exerciseId: id) }
            }
            .sheet(isPresented: $showingSettings) {
                if let id = exerciseId { ExerciseNoteSheet(exerciseId: id, exerciseName: name, onClose: { showingSettings = false }) }
            }
            .confirmationDialog("Change how \(loggedSets) logged sets are counted?", isPresented: $confirmFlags, titleVisibility: .visible) {
                Button("Save changes") { save() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(flagsMessage)
            }
            .confirmationDialog("Delete this exercise?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("It disappears from the exercise lists, and its note and load settings are removed.")
            }
            .alert("Can't delete", isPresented: Binding(get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(blockedMessage ?? "")
            }
        }
        .keyboardDismissal()
    }

    private var flagsMessage: String {
        var parts: [String] = []
        if original?.isBodyweight != bodyweight {
            parts.append("Bodyweight decides which past sets count in analytics: sets logged at a load of 0 \(bodyweight ? "start" : "stop") counting.")
        }
        if original?.isCompound != compound {
            parts.append("Compound only changes future coaching; past sets are not touched.")
        }
        return parts.joined(separator: " ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let id = exerciseId else { return }
        _ = ExerciseCatalog.ensureCustomRecord(id: id, in: modelContext)
        guard let row = (try? modelContext.fetch(FetchDescriptor<CustomExercise>()))?.first(where: { $0.id == id }) else { return }
        name = row.name
        muscle = MuscleGroup(rawValue: row.primaryMuscleRaw) ?? .chest
        compound = row.resolvedIsCompound
        bodyweight = row.isBodyweight
        original = .init(name: name, primaryMuscle: muscle, isCompound: compound, isBodyweight: bodyweight)
    }

    /// The mapping sheet can change Compound too: pick it up so a later Save does not undo it.
    private func reloadFlags() {
        guard let id = exerciseId,
              let row = (try? modelContext.fetch(FetchDescriptor<CustomExercise>()))?.first(where: { $0.id == id }) else { return }
        compound = row.resolvedIsCompound
        original?.isCompound = row.resolvedIsCompound
    }

    private func save() {
        errorText = nil
        if let id = exerciseId {
            let r = CustomExerciseLibrary.update(id: id, edit: .init(name: name, primaryMuscle: muscle, isCompound: compound, isBodyweight: bodyweight), in: modelContext)
            switch r {
            case .saved: onClose()
            case .invalidName(let c): errorText = c.message
            case .notFound: errorText = "This exercise no longer exists."
            case .saveFailed: errorText = "Couldn't save. Nothing was changed."
            }
        } else {
            guard case .ok(let trimmed) = check else { return }
            _ = ExerciseCatalog.addCustomExercise(name: trimmed, primaryMuscle: muscle, isCompound: compound, isBodyweight: bodyweight, in: modelContext)
            onClose()
        }
    }

    private func delete() {
        guard let id = exerciseId else { return }
        switch CustomExerciseLibrary.delete(id: id, in: modelContext) {
        case .deleted, .notFound: onClose()
        case .blocked(let u): blockedMessage = u.deleteBlockMessage
        case .saveFailed: errorText = "Couldn't delete. Nothing was changed."
        }
    }
}


/// What the compound switch does, in the words every place that shows it uses (no logic: the rule itself lives in CoachingEngine).
enum CompoundExplainer {
    static let label = "Progress as a compound lift"
    static let footer = "On: judged on total reps across all sets, with one rep of slack. Off: every set must reach the top of the range."
}
