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
    @State private var showingApplyScopeDialog = false

    // MARK: - Derived ordered items

    /// Session items sorted by their `order` field.
    /// This is the canonical order we want everywhere.
    private var orderedItems: [SessionItem] {
        session.items.sorted { $0.order < $1.order }
    }

    // MARK: - Body

    var body: some View {
        List {
            headerSection

            Section("Exercises") {
                if orderedItems.isEmpty {
                    Text("No exercises yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Show rows in `order` order.
                    ForEach(orderedItems, id: \.persistentModelID) { item in
                        ProgramExercisePlanRow(item: binding(for: item))
                    }
                    .onDelete(perform: deleteExercises)
                    .onMove(perform: moveExercises)
                }
            }

            // Apply-to-meso control lives as its own section at the bottom of the page
            Section {
                Button {
                    showingApplyScopeDialog = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Apply these plan changes to other days…")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                }
            } footer: {
                Text("Use this when you want today’s loads / reps / RIR to become the plan for the same day across the rest of this block.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Left: system Edit button (delete + reorder)
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }

            // Right: add exercise
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddExerciseSheet = true
                } label: {
                    Image(systemName: "plus")
                }
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
        .confirmationDialog(
            "Apply these plan changes to…",
            isPresented: $showingApplyScopeDialog,
            titleVisibility: .visible
        ) {
            Button("This day only", role: .cancel) {
                // No-op: edits already applied live to this day.
            }

            Button("All matching days in this block") {
                applyPlanChangesToBlock()
            }
        }
    }

    // MARK: - Bindings

    /// Binding into `session.items` for a given `SessionItem`, matched by `persistentModelID`.
    private func binding(for item: SessionItem) -> Binding<SessionItem> {
        Binding(
            get: {
                // Find the live instance in session.items; if somehow missing, fall back.
                session.items.first(where: { $0.persistentModelID == item.persistentModelID }) ?? item
            },
            set: { newValue in
                guard let idx = session.items.firstIndex(where: { $0.persistentModelID == item.persistentModelID }) else {
                    return
                }
                session.items[idx] = newValue
            }
        )
    }

    // MARK: - Mutations

    private func renumberItems(using items: [SessionItem]? = nil) {
        let base = items ?? orderedItems
        for (idx, item) in base.enumerated() {
            if let realIdx = session.items.firstIndex(where: { $0.persistentModelID == item.persistentModelID }) {
                session.items[realIdx].order = idx + 1
            }
        }
    }

    private func deleteExercises(at offsets: IndexSet) {
        // Map visible indices (in orderedItems) back to underlying session.items via persistentModelID.
        let idsToDelete = offsets.map { orderedItems[$0].persistentModelID }

        session.items.removeAll { item in
            idsToDelete.contains(item.persistentModelID)
        }

        renumberItems()
        try? modelContext.save()
    }

    private func moveExercises(from source: IndexSet, to destination: Int) {
        // Work in the ordered view first.
        var newOrder = orderedItems
        newOrder.move(fromOffsets: source, toOffset: destination)

        // Then re-number the `order` field in session.items to match.
        renumberItems(using: newOrder)

        do {
            try modelContext.save()
        } catch {
            print("⚠️ Failed to save moved exercises: \(error)")
        }
    }

    private func addExercise(_ catalogExercise: CatalogExercise) {
        let nextOrder = (session.items.map(\.order).max() ?? 0) + 1

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

        session.items.append(item)
        renumberItems()
        try? modelContext.save()
    }

    /// Push current day's PLAN edits to all matching days in the meso.
    /// Matching rule:
    /// - Same weekday as this session's date.
    /// - For each exercise with the same `exerciseId`, copy plan fields.
    private func applyPlanChangesToBlock() {
        do {
            let descriptor = FetchDescriptor<Session>()
            let allSessions = try modelContext.fetch(descriptor)

            let calendar = Calendar.current
            let targetWeekday = calendar.component(.weekday, from: session.date)
            let thisID = session.persistentModelID

            let otherSessions = allSessions.filter { other in
                other.persistentModelID != thisID &&
                calendar.component(.weekday, from: other.date) == targetWeekday
            }

            guard !otherSessions.isEmpty else {
                print("ℹ️ No other matching sessions for weekday \(targetWeekday)")
                return
            }

            // Use the current session's items (ordered) as the source of truth.
            let sourceItems = orderedItems

            for other in otherSessions {
                let targetItems = other.items

                for sourceItem in sourceItems {
                    guard let target = targetItems.first(where: { $0.exerciseId == sourceItem.exerciseId }) else {
                        continue
                    }

                    // Copy PLAN-related fields
                    target.targetReps        = sourceItem.targetReps
                    target.targetSets        = sourceItem.targetSets
                    target.targetRIR         = sourceItem.targetRIR
                    target.suggestedLoad     = sourceItem.suggestedLoad
                    target.plannedRepsBySet  = sourceItem.plannedRepsBySet
                    target.plannedLoadsBySet = sourceItem.plannedLoadsBySet
                }

                // We intentionally do NOT change `order` or add/remove exercises here.
            }

            try modelContext.save()
            print("✅ Applied plan changes from \(session.date) to \(otherSessions.count) other sessions.")
        } catch {
            print("⚠️ Failed to apply plan changes to block: \(error)")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.headline)

                Text("Week \(session.weekIndex)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                let exerciseCount = session.items.count
                let plannedSets = session.items.reduce(0) { $0 + $1.targetSets }
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
struct ProgramExercisePlanRow: View {
    @Binding var item: SessionItem
    @State private var showingSwapSheet = false

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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exerciseName)
                        .font(.headline)

                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
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

                    if !SwapMap.swapOptions(for: item.exerciseId).isEmpty {
                        Button {
                            showingSwapSheet = true
                        } label: {
                            Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
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

            // Coach cue
            Text(coachCue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .italic()
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showingSwapSheet) {
            NavigationStack {
                let options = SwapMap.swapOptions(for: item.exerciseId)

                List {
                    Section("Swap \(exerciseName)") {
                        if options.isEmpty {
                            Text("No alternatives available yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(options, id: \.id) { candidate in
                                Button {
                                    item.exerciseId = candidate.id
                                    showingSwapSheet = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                            .font(.body)
                                        Text(candidate.primaryMuscle.rawValue.capitalized)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Swap Exercise")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingSwapSheet = false
                        }
                    }
                }
            }
        }
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

    private var coachCue: String {
        switch item.targetSets {
        case ..<3:
            return "Build to at least 3 quality working sets."
        case 3:
            return "3 to grow: 3 solid working sets. Push the last set if RIR holds."
        case 4:
            return "3 to grow, 1 to know: 4th set is your tester. Only push if recovery is solid."
        default:
            return "Hit clean form first, then earn your tester set."
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
