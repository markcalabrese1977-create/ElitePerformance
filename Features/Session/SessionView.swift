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

// MARK: - Log Sheet (static 5 rows)

struct ExerciseLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var item: SessionItem

    @State private var loadText: [String]
    @State private var repsText: [String]

    private let maxSets = 5

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    init(item: SessionItem) {
        self._item = Bindable(wrappedValue: item)

        // Always keep exactly 5 editable rows in memory
        var loads = Array(repeating: "", count: maxSets)
        var reps  = Array(repeating: "", count: maxSets)

        // Seed from actuals if they exist
        for idx in 0..<min(maxSets, item.actualReps.count) {
            reps[idx] = "\(item.actualReps[idx])"
        }
        for idx in 0..<min(maxSets, item.actualLoads.count) {
            loads[idx] = String(format: "%.0f", item.actualLoads[idx])
        }

        // Where no actuals, fall back to planned reps
        for idx in 0..<min(maxSets, item.plannedRepsBySet.count) {
            if reps[idx].isEmpty {
                reps[idx] = "\(item.plannedRepsBySet[idx])"
            }
        }

        _loadText = State(initialValue: loads)
        _repsText = State(initialValue: reps)
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
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Set \(index + 1)")
                                Spacer()
                                if index < item.plannedRepsBySet.count {
                                    Text("Plan: \(item.plannedRepsBySet[index]) reps")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            HStack {
                                TextField("Load", text: $loadText[index])
                                    .keyboardType(.decimalPad)
                                    .frame(width: 80)
                                TextField("Reps", text: $repsText[index])
                                    .keyboardType(.numberPad)
                                    .frame(width: 60)
                            }
                        }
                    }

                    // No add/remove buttons in this version.
                    // Use as many of the 5 rows as you actually do.
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

    private func saveLogs() {
        var newReps: [Int] = []
        var newLoads: [Double] = []

        // Persist all 5; recap logic only treats non-zero sets as “logged”.
        for idx in 0..<maxSets {
            let reps = Int(repsText[idx]) ?? 0
            let load = Double(loadText[idx]) ?? 0
            newReps.append(reps)
            newLoads.append(load)
        }

        item.actualReps = newReps
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

// MARK: - SessionStatus display helper

extension SessionStatus {
    var displayTitle: String {
        String(describing: self)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
