import SwiftUI
import SwiftData

// MARK: - Main Session View

struct SessionView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: Session

    @State private var selectedItemForLogging: SessionItem?
    @State private var selectedItemForSwap: SessionItem?
    @State private var navigateToRecap: Bool = false

    // DEV PHASE: allow logging any session regardless of date
    private var canLogCurrentSession: Bool {
        true
    }

    private var sortedItems: [SessionItem] {
        session.items.sorted { $0.order < $1.order }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.date, style: .date)
                .font(.headline)

            Text(session.status.displayTitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    var body: some View {
        VStack {
            List {
                Section(header: header) {
                    ForEach(sortedItems) { item in
                        SessionItemRow(
                            item: item,
                            canLog: canLogCurrentSession,
                            onLogTapped: { selectedItemForLogging = item },
                            onSwapTapped: { selectedItemForSwap = item }
                        )
                        .swipeActions {
                            Button(role: .destructive) {
                                deleteItem(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            // Hidden navigation link to recap
            NavigationLink(
                destination: SessionRecapView(session: session),
                isActive: $navigateToRecap
            ) {
                EmptyView()
            }
            .hidden()
        }
        .navigationTitle("Session")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Complete") {
                    session.status = .completed
                    try? context.save()
                    navigateToRecap = true
                }
            }
        }
        .sheet(item: $selectedItemForLogging) { item in
            ExerciseLogSheet(item: item)
        }
        .sheet(item: $selectedItemForSwap) { item in
            ExerciseSwapSheet(item: item)
        }
    }

    // MARK: - Helpers

    private func deleteItem(_ item: SessionItem) {
        if let index = session.items.firstIndex(where: { $0.id == item.id }) {
            session.items.remove(at: index)
        }
        context.delete(item)
        try? context.save()
    }
}
// MARK: - Row for a single exercise in the session

struct SessionItemRow: View {
    let item: SessionItem
    let canLog: Bool
    let onLogTapped: () -> Void
    let onSwapTapped: () -> Void

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    private var loggedSummary: String {
        let count = min(item.actualReps.count, item.actualLoads.count)
        guard count > 0 else { return "Not logged" }

        let nonZero = (0..<count).filter { idx in
            item.actualReps[idx] > 0 && item.actualLoads[idx] > 0
        }.count

        return "\(nonZero) set\(nonZero == 1 ? "" : "s") logged"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(exercise?.name ?? "Unknown exercise")
                    .font(.headline)

                Spacer()

                if item.isPR {
                    Text("PR")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .foregroundColor(.purple)
                        .cornerRadius(6)
                }
            }

            HStack {
                Text("Planned: \(item.targetSets)x\(item.targetReps) · RIR \(item.targetRIR)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(loggedSummary)
                    .font(.caption)
            }

            HStack {
                Button {
                    if canLog {
                        onLogTapped()
                    }
                } label: {
                    Text(canLog ? "Log sets" : "Locked")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canLog)

                Button {
                    onSwapTapped()
                } label: {
                    Text("Swap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Log Sheet (Stepper-based, with load profiling)

struct ExerciseLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var item: SessionItem

    /// We’re still using a fixed 5-set editor.
    private let maxSets = 5

    /// Working copies for the sheet UI. These drive SessionSetRowView bindings.
    @State private var workingLoads: [Double]
    @State private var workingReps: [Int]

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    init(item: SessionItem) {
        self._item = Bindable(wrappedValue: item)

        var loads = Array(repeating: 0.0, count: maxSets)
        var reps  = Array(repeating: 0, count: maxSets)

        // Seed from actuals if they exist
        let actualCount = min(
            maxSets,
            min(item.actualLoads.count, item.actualReps.count)
        )
        for idx in 0..<actualCount {
            loads[idx] = item.actualLoads[idx]
            reps[idx]  = item.actualReps[idx]
        }

        // Where no actual reps yet, fall back to planned reps
        for idx in 0..<min(maxSets, item.plannedRepsBySet.count) {
            if reps[idx] == 0 {
                reps[idx] = item.plannedRepsBySet[idx]
            }
        }

        _workingLoads = State(initialValue: loads)
        _workingReps  = State(initialValue: reps)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                if let exercise {
                    Section {
                        Text(exercise.name)
                            .font(.headline)
                    }
                }

                Section(header: Text("Log sets")) {
                    ForEach(0..<maxSets, id: \.self) { index in
                        SessionSetRowView(
                            index: index,
                            plannedLoad: plannedLoad(for: index),
                            plannedReps: plannedReps(for: index),
                            actualLoad: $workingLoads[index],
                            actualReps: $workingReps[index]
                        )
                    }
                }
            }
            .navigationTitle("Log Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveLogs()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Planning helpers

    private func plannedReps(for index: Int) -> Int {
        if index < item.plannedRepsBySet.count {
            return item.plannedRepsBySet[index]
        }
        return item.targetReps
    }

    private func plannedLoad(for index: Int) -> Double {
        if index < item.plannedLoadsBySet.count {
            return item.plannedLoadsBySet[index]
        }
        if item.suggestedLoad > 0 {
            return item.suggestedLoad
        }
        return 0
    }

    // MARK: - Save with auto-prefill

    private func saveLogs() {
        var newReps  = workingReps
        var newLoads = workingLoads

        // Auto-prefill loads for later sets:
        // If Set 1 has a load, and a later set has load == 0,
        // copy Set 1's load into that slot.
        if newLoads.indices.contains(0), newLoads[0] > 0 {
            let baseLoad = newLoads[0]
            for idx in 1..<maxSets where newLoads[idx] == 0 {
                newLoads[idx] = baseLoad
            }
        }

        item.actualReps  = newReps
        item.actualLoads = newLoads

        // IMPORTANT: do NOT touch item.targetSets here.
        // It represents the planned number of sets from the program.
        try? context.save()
    }
}





// MARK: - Swap sheet

/// Sheet for swapping an exercise using SwapMap.
struct ExerciseSwapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var item: SessionItem

    private var currentExercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    private var alternatives: [CatalogExercise] {
        // DEV PHASE: allow swapping to ANY other exercise in the catalog.
        SwapMap.swapOptions(for: item.exerciseId)
    }

    var body: some View {
        NavigationStack {
            List {
                if let current = currentExercise {
                    Section(header: Text("Current")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(current.name)
                                .font(.headline)
                            Text(current.primaryMuscle.rawValue.capitalized)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Swap options")) {
                    ForEach(alternatives) { alt in
                        Button {
                            item.exerciseId = alt.id
                            try? context.save()
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(alt.name)
                                    Text(alt.primaryMuscle.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if alt.id == item.exerciseId {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Swap Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Per-set row with Steppers

struct SessionSetRowView: View {
    /// Index of the set (0-based here, but will display as 1-based)
    let index: Int

    /// Planned values
    let plannedLoad: Double
    let plannedReps: Int

    /// Bindings into the actual values stored on SessionItem
    @Binding var actualLoad: Double
    @Binding var actualReps: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Set label
            Text("Set \(index + 1)")
                .font(.caption)
                .fontWeight(.semibold)

            // PLAN row
            HStack(spacing: 4) {
                Text("Planned:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("\(plannedLoad, specifier: "%.1f") lb × \(plannedReps)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ACTUAL controls
            HStack(spacing: 16) {
                // LOAD: typeable field backed by the Double binding
                VStack(alignment: .leading, spacing: 4) {
                    Text("Load")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    TextField(
                        "0",
                        text: Binding(
                            get: {
                                actualLoad == 0
                                    ? ""
                                    : String(format: "%.1f", actualLoad)
                            },
                            set: { newValue in
                                let trimmed = newValue
                                    .trimmingCharacters(in: .whitespaces)
                                if let value = Double(trimmed) {
                                    actualLoad = value
                                } else if trimmed.isEmpty {
                                    actualLoad = 0
                                }
                                // If you want: we can later hook a callback here
                                // so changing set 1 can prefill other sets live.
                            }
                        )
                    )
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                }

                // REPS: keep as a Stepper (this is usually fine UX-wise)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reps")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Stepper(
                        value: $actualReps,
                        in: 0...50
                    ) {
                        Text("\(actualReps) reps")
                            .frame(minWidth: 60, alignment: .leading)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
