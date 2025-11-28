import SwiftUI
import SwiftData

/// Plan editor for a single training day.
/// - Lives under the Program tab.
/// - Edits PLAN only (load / reps / RIR / sets).
/// - No Actual logging here.
struct ProgramDayDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var session: Session   // SwiftData-friendly

    @State private var showingAddExerciseSheet = false

    /// Local ordering buffer so List drag & drop is smooth and
    /// doesn’t fight SwiftData’s relationship ordering.
    @State private var orderedItems: [SessionItem] = []

    // MARK: - Body

    var body: some View {
        List {
            headerSection

            Section("Exercises") {
                if currentItems.isEmpty {
                    Text("No exercises yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Bind directly into the LOCAL ordered array.
                    ForEach($orderedItems, id: \.id) { $item in
                        ProgramExercisePlanRow(item: $item)
                    }
                    .onDelete(perform: deleteExercises)
                    .onMove(perform: moveExercises)
                }
            }
        }
        .navigationTitle("Edit Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddExerciseSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .sheet(isPresented: $showingAddExerciseSheet) {
            NavigationStack {
                ExercisePickerView { exercise in
                    addExercise(exercise)
                    showingAddExerciseSheet = false
                }
            }
        }
        .onAppear {
            // Seed local ordering once when the view appears.
            if orderedItems.isEmpty {
                orderedItems = session.items.sorted { $0.order < $1.order }
            }
        }
    }

    /// Use the local buffer when present, otherwise fall back to session.items.
    private var currentItems: [SessionItem] {
        orderedItems.isEmpty ? session.items : orderedItems
    }

    // MARK: - Mutations

    /// Sync local order → Session relationship + `order` field + save.
    private func syncToSession() {
        // Ensure every item has a clean sequential order.
        for (idx, item) in orderedItems.enumerated() {
            item.order = idx + 1
        }

        // Replace the relationship array with the ordered buffer.
        session.items = orderedItems

        do {
            try modelContext.save()
        } catch {
            print("⚠️ Failed to save session after reorder: \(error)")
        }
    }

    private func deleteExercises(at offsets: IndexSet) {
        orderedItems.remove(atOffsets: offsets)
        syncToSession()
    }

    private func moveExercises(from source: IndexSet, to destination: Int) {
        orderedItems.move(fromOffsets: source, toOffset: destination)
        syncToSession()
    }

    private func addExercise(_ catalogExercise: CatalogExercise) {
        let nextOrder = (currentItems.map(\.order).max() ?? 0) + 1

        let defaultReps = 10
        let defaultSets = 3
        let defaultRIR  = 2

        let plannedReps = Array(repeating: defaultReps, count: 4)
        let plannedLoads = Array(repeating: 0.0, count: 4)

        let item = SessionItem(
            order: nextOrder,
            exerciseId: catalogExercise.id,
            targetReps: defaultReps,
            targetSets: defaultSets,
            targetRIR: defaultRIR,
            suggestedLoad: 0.0,
            plannedRepsBySet: plannedReps,
            plannedLoadsBySet: plannedLoads
        )

        orderedItems.append(item)
        syncToSession()
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            let itemsForSummary = currentItems

            VStack(alignment: .leading, spacing: 4) {
                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.headline)

                Text("Week \(session.weekIndex)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                let exerciseCount = itemsForSummary.count
                let plannedSets = itemsForSummary.reduce(0) { $0 + $1.targetSets }
                Text("\(exerciseCount) exercises · \(plannedSets) planned working sets")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Exercise Plan Row

/// Per-exercise plan editor.
/// Edits target reps, suggested load, target RIR, and target sets.
/// Does NOT expose any Actual values.
private struct ProgramExercisePlanRow: View {
    @Binding var item: SessionItem

    // number formatter for load
    private static let loadFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 1
        nf.minimum = 0
        nf.maximum = 2000
        return nf
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exerciseName)
                        .font(.headline)

                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Sets count editor (3–4 working sets)
                HStack(spacing: 4) {
                    Text("\(item.targetSets) sets")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(
                        "",
                        value: $item.targetSets,
                        in: 3...4,
                        step: 1
                    )
                    .labelsHidden()
                }
            }

            // PLAN fields
            VStack(alignment: .leading, spacing: 4) {
                Text("PLAN")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    // Load
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Load")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        TextField(
                            "0",
                            value: $item.suggestedLoad,
                            formatter: Self.loadFormatter
                        )
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    }

                    // Reps
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        TextField(
                            "0",
                            value: $item.targetReps,
                            format: .number
                        )
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    }

                    // RIR
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RIR")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        TextField(
                            "0",
                            value: $item.targetRIR,
                            format: .number
                        )
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 40)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private var exerciseName: String {
        if let catalog = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId }) {
            return catalog.name
        } else {
            return "Exercise"
        }
    }

    private var detailLine: String {
        if let primary = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })?.primaryMuscle {
            return "\(primary.rawValue.capitalized) · \(item.targetReps) reps @ RIR \(item.targetRIR)"
        } else {
            return "\(item.targetReps) reps @ RIR \(item.targetRIR)"
        }
    }
}

// MARK: - Exercise Picker

private struct ExercisePickerView: View {
    let onSelect: (CatalogExercise) -> Void

    // Simple flat list for now; can group by muscle later
    private var allExercises: [CatalogExercise] {
        ExerciseCatalog.all.sorted { $0.name < $1.name }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(allExercises) { exercise in
                Button {
                    onSelect(exercise)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exercise.name)
                            .font(.body)

                        Text(exercise.primaryMuscle.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Add Exercise")
        .navigationBarTitleDisplayMode(.inline)
    }
}
