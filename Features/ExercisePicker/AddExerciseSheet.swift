import SwiftUI

struct AddExerciseSheet: View {
    let onSelect: (CatalogExercise) -> Void
    let onCancel: () -> Void

    @State private var searchText: String = ""
    @State private var showingCreateCustom = false
    @State private var refreshToken = UUID()

    private var builtIn: [CatalogExercise] { ExerciseCatalog.builtIn }
    private var custom: [CatalogExercise] { ExerciseCatalog.customExercises() }

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
                        }
                        .onDelete { idx in
                            let ids = idx.map { filteredCustom[$0].id }
                            ExerciseCatalog.deleteCustomExercises(ids: ids)
                            refreshToken = UUID()
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
            .sheet(isPresented: $showingCreateCustom) {
                CreateCustomExerciseSheet(
                    onDone: { newEx in
                        showingCreateCustom = false
                        // Optional: auto-select after create
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

    @State private var name: String = ""
    @State private var primary: MuscleGroup = .shoulders
    @State private var isCompound: Bool = false

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
                }

                Section {
                    Text("Custom exercises save only on this phone and can be deleted any time.")
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
                            isCompound: isCompound
                        )
                        onDone(ex)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
