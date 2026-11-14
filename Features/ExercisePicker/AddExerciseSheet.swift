import SwiftUI
import SwiftData

struct AddExerciseSheet: View {
    let onSelect: (CatalogExercise) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var searchText: String = ""
    @State private var showingCreateCustom = false
    @State private var refreshToken = UUID()
    @State private var mappingExerciseId: MappingTarget?
    @State private var pendingCustomDelete: [CatalogExercise] = []

    private var builtIn: [CatalogExercise] { ExerciseCatalog.builtIn }
    private var custom: [CatalogExercise] { ExerciseCatalog.customExercises(in: modelContext) }

    private var filteredBuiltIn: [CatalogExercise] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return builtIn }
        return builtIn.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    private var filteredCustom: [CatalogExercise] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return custom }
        return custom.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingCreateCustom = true
                    } label: {
                        Label("Create Custom Exercise", systemImage: "plus.circle.fill")
                    }
                }

                if !filteredCustom.isEmpty {
                    Section("Your Custom Exercises") {
                        ForEach(filteredCustom) { ex in
                            Button {
                                onSelect(ex)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ex.name)
                                    Text(ex.primaryMuscle.rawValue.capitalized + (ex.isCompound ? " · Compound" : " · Isolation"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    mappingExerciseId = MappingTarget(id: ex.id)
                                } label: {
                                    Label("Muscles", systemImage: "figure.strengthtraining.traditional")
                                }
                                .tint(.indigo)
                            }
                        }
                        .onDelete { idx in
                            pendingCustomDelete = idx.map { filteredCustom[$0] }
                        }
                    }
                }

                Section("Catalog") {
                    ForEach(filteredBuiltIn) { ex in
                        Button {
                            onSelect(ex)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ex.name)
                                Text(ex.primaryMuscle.rawValue.capitalized + (ex.isCompound ? " · Compound" : " · Isolation"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .id(refreshToken)
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search exercises")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                if !custom.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exerciseCatalogDidChange)) { _ in
                refreshToken = UUID()
            }
            .confirmationDialog(
                "Delete custom exercise?",
                isPresented: Binding(get: { !pendingCustomDelete.isEmpty }, set: { if !$0 { pendingCustomDelete = [] } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    ExerciseCatalog.deleteCustomExercises(ids: pendingCustomDelete.map(\.id), in: modelContext)
                    pendingCustomDelete = []
                    refreshToken = UUID()
                }
                Button("Cancel", role: .cancel) { pendingCustomDelete = [] }
            } message: {
                Text("Delete \(pendingCustomDelete.map(\.name).joined(separator: ", "))? It disappears from the exercise picker and its muscle mapping is lost. Sessions that already use it keep their logged history.")
            }
            .sheet(item: $mappingExerciseId) { target in
                CustomMuscleMappingSheet(exerciseId: target.id)
            }
            .sheet(isPresented: $showingCreateCustom) {
                CreateCustomExerciseSheet(
                    onDone: { newEx in
                        showingCreateCustom = false
                        onSelect(newEx)
                    },
                    onCancel: { showingCreateCustom = false }
                )
            }
        }
    }
}

struct CreateCustomExerciseSheet: View {
    let onDone: (CatalogExercise) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var name: String = ""
    @State private var primary: MuscleGroup = .shoulders
    @State private var isCompound: Bool = false
    @State private var isBodyweight: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g., Chest-supported incline DB row", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Primary Muscle") {
                    Picker("Primary", selection: $primary) {
                        ForEach(MuscleGroup.allCases, id: \.self) { mg in
                            Text(mg.rawValue.capitalized).tag(mg)
                        }
                    }
                }

                Section("Type") {
                    Toggle("Compound movement", isOn: $isCompound)
                    Toggle("Bodyweight exercise", isOn: $isBodyweight)
                }

                Section {
                    Text("Custom exercises are saved to this device and included in your backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let ex = ExerciseCatalog.addCustomExercise(
                            name: trimmed,
                            primaryMuscle: primary,
                            isCompound: isCompound,
                            isBodyweight: isBodyweight,
                            in: modelContext
                        )
                        onDone(ex)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}


struct MappingTarget: Identifiable { let id: String }

/// Minimal editor for the analytics muscles of a custom exercise: the fine primary muscle and what else a set trains.
/// Unmapped customs are listed as "unmapped" in volume reports and counted in no muscle's total.
struct CustomMuscleMappingSheet: View {
    let exerciseId: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var primary: FineMuscle?
    @State private var secondary: [FineMuscle: Double] = [:]
    @State private var compound = false
    @State private var loaded = false

    private var custom: CustomExercise? {
        (try? modelContext.fetch(FetchDescriptor<CustomExercise>()))?.first { $0.id == exerciseId }
    }

    private var suggestion: MuscleSuggestion? {
        guard let c = custom else { return nil }
        return MuscleSuggester.suggest(name: c.name, coarse: MuscleGroup(rawValue: c.primaryMuscleRaw) ?? .chest)
    }

    private var compoundFootnote: String {
        let suggested = custom.map { MuscleSuggester.suggestedCompound(name: $0.name, coarse: MuscleGroup(rawValue: $0.primaryMuscleRaw) ?? .chest) } ?? false
        let state = custom?.isCompound == nil ? "not decided yet" : "your choice"
        return "Suggested: \(suggested ? "compound" : "not compound") (\(state)). Compound lifts record RIR with one tap and are judged on total reps."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Primary muscle") {
                    Picker("Primary", selection: $primary) {
                        Text("Not mapped").tag(FineMuscle?.none)
                        ForEach(FineMuscle.allCases, id: \.self) { m in Text(m.displayName).tag(FineMuscle?.some(m)) }
                    }
                }
                Section {
                    Toggle("Compound lift", isOn: $compound)
                } footer: {
                    Text(compoundFootnote)
                }
                if let s = suggestion {
                    Section("Suggestion") {
                        Text("Like \(s.basedOn) (\(s.confidence.rawValue)): \(s.primary?.displayName ?? "-")")
                        Button("Use suggestion") {
                            primary = s.primary
                            secondary = s.shares.filter { $0.value < 1 && $0.key != s.primary }
                        }
                    }
                }
                if let primary {
                    Section("Also trains") {
                        ForEach(FineMuscle.allCases.filter { $0 != primary }, id: \.self) { m in
                            Picker(m.displayName, selection: Binding(get: { secondary[m] ?? 0 }, set: { secondary[m] = $0 == 0 ? nil : $0 })) {
                                Text("No").tag(0.0)
                                Text("A little").tag(0.25)
                                Text("Half a set").tag(0.5)
                            }
                        }
                    }
                }
                Section {
                    Text("Used only for weekly volume per muscle. Saved to this device and included in your backup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(custom?.name ?? "Muscles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let c = custom {
                            c.setFineMapping(primary: primary, secondary: secondary)
                            c.isCompound = compound
                            try? modelContext.save()
                            ExerciseCatalog.rebuildCustomMirror(from: modelContext)   // context-free lookups read the mirror
                        }
                        dismiss()
                    }
                }
            }
            .onChange(of: primary) { _, newPrimary in
                // the primary is 1.0: it can never also be an "also trains" share
                if let newPrimary { secondary[newPrimary] = nil }
            }
            .onAppear {
                guard !loaded, let c = custom else { return }
                loaded = true
                compound = c.resolvedIsCompound   // the lifter's choice, else what the closest built-in suggests
                if c.sanitizeFineMapping() { try? modelContext.save() }
                primary = c.fineMuscleRaw.flatMap(FineMuscle.init(rawValue:))
                secondary = Dictionary(uniqueKeysWithValues: (c.fineSecondaryShares ?? [:]).compactMap { k, v in
                    FineMuscle(rawValue: k).map { ($0, v) }
                })
            }
        }
    }
}


/// Every custom exercise with its muscle mapping (mapped / unmapped); each opens the mapping editor. The way back to the
/// editor for exercises that have left the "Unmapped exercises" list.
struct CustomExerciseMusclesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CustomExercise.name) private var customs: [CustomExercise]
    @State private var editing: MappingTarget?

    private func summary(_ c: CustomExercise) -> String {
        guard let shares = c.fineShares, let primary = c.fineMuscleRaw.flatMap(FineMuscle.init(rawValue:)) else { return "Unmapped" }
        let others = shares.filter { $0.key != primary }.sorted { ($1.value, $0.key.rawValue) < ($0.value, $1.key.rawValue) }
            .map { "\($0.key.displayName) \($0.value == 0.5 ? "½" : "¼")" }
        return ([primary.displayName] + others).joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            List {
                if customs.isEmpty {
                    Text("No custom exercises.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(customs) { c in
                            Button { editing = MappingTarget(id: c.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name)
                                        Text(summary(c)).font(.caption)
                                            .foregroundStyle(c.fineShares == nil ? Color.orange : Color.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } footer: {
                        Text("Mapped: \(customs.filter { $0.fineShares != nil }.count) of \(customs.count). Unmapped exercises are counted in no muscle's weekly total.")
                    }
                }
            }
            .navigationTitle("Custom exercise muscles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { target in CustomMuscleMappingSheet(exerciseId: target.id) }
            .onAppear {
                // one-time cleanup of mappings saved with a share on their own primary
                var changed = false
                for c in customs { if c.sanitizeFineMapping() { changed = true } }
                if changed { try? modelContext.save() }
            }
        }
    }
}
