import SwiftUI
import SwiftData

// MARK: - Main Session View

struct SessionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
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

            // SessionStatus.displayTitle is defined elsewhere in the project.
            Text(session.status.displayTitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    var body: some View {
        NavigationStack {
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
            .onChange(of: navigateToRecap) { isActive in
                // When recap is dismissed after a completed session,
                // pop SessionView and return to Today.
                if !isActive && session.status == .completed {
                    dismiss()
                }
            }
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

    private let maxSets = 5

    @State private var loads: [Double]
    @State private var reps: [Int]

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    init(item: SessionItem) {
        self._item = Bindable(wrappedValue: item)

        var initialLoads = Array(repeating: 0.0, count: maxSets)
        var initialReps  = Array(repeating: 0, count: maxSets)

        // Seed from existing actuals if they exist
        for idx in 0..<min(maxSets, item.actualReps.count) {
            initialReps[idx] = item.actualReps[idx]
        }
        for idx in 0..<min(maxSets, item.actualLoads.count) {
            initialLoads[idx] = item.actualLoads[idx]
        }

        // Where no actual reps, fall back to planned reps
        for idx in 0..<min(maxSets, item.plannedRepsBySet.count) {
            if initialReps[idx] == 0 {
                initialReps[idx] = item.plannedRepsBySet[idx]
            }
        }

        _loads = State(initialValue: initialLoads)
        _reps  = State(initialValue: initialReps)
    }

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
                            actualLoad: $loads[index],
                            actualReps: $reps[index]
                        )
                    }

                    Text("Tip: if you only set the first set's load, the app will copy it to later sets when saving.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
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

    private func saveLogs() {
        var newReps: [Int] = []
        var newLoads: [Double] = []

        var lastNonZeroLoad: Double = 0

        for idx in 0..<maxSets {
            let r = reps[idx]
            var l = loads[idx]

            // If load is zero but we have a previous non-zero load, profile it forward
            if l <= 0, lastNonZeroLoad > 0 {
                l = lastNonZeroLoad
            }

            if l > 0 {
                lastNonZeroLoad = l
            }

            newReps.append(r)
            newLoads.append(l)
        }

        item.actualReps = newReps
        item.actualLoads = newLoads

        // Run coaching engine for this execution (optional next load)
        if let rec = CoachingEngine.recommend(for: item),
           let next = rec.nextSuggestedLoad,
           next > 0 {

            // Store the next suggested load on this item so future sessions can seed from it.
            item.suggestedLoad = next
        }

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

    /// Bindings into the actual values stored on the parent sheet
    @Binding var actualLoad: Double
    @Binding var actualReps: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set \(index + 1)")
                .font(.caption)
                .fontWeight(.semibold)

            // PLAN row
            HStack(spacing: 4) {
                Text("Planned:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if plannedLoad > 0 {
                    Text("\(plannedLoad, specifier: "%.1f") lb × \(plannedReps)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(plannedReps) reps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // ACTUAL row
            HStack(spacing: 8) {
                Text("Actual:")
                    .font(.subheadline)

                // Load with 0.5 lb increments
                Stepper(
                    value: $actualLoad,
                    in: 0...1000,
                    step: 0.5
                ) {
                    Text("\(actualLoad, specifier: "%.1f") lb")
                        .frame(minWidth: 70, alignment: .leading)
                }

                // Reps
                Stepper(
                    value: $actualReps,
                    in: 0...50
                ) {
                    Text("\(actualReps) reps")
                        .frame(minWidth: 60, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
