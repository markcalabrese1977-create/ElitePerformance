import SwiftUI
import SwiftData

/// High-level planner: shows the current block grouped by Week → Day,
/// and lets you inspect each day's planned exercises.
struct ProgramPlanView: View {
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    private var calendar: Calendar { Calendar.current }

    /// Start date of the current block (earliest session).
    private var blockStartDate: Date? {
        sessions.map(\.date).min()
    }

    /// Group sessions into weeks relative to the block start.
    private var weeks: [WeekGroup] {
        guard let start = blockStartDate else { return [] }

        let startDay = calendar.startOfDay(for: start)
        let sortedSessions = sessions.sorted { $0.date < $1.date }

        var groups: [Int: [Session]] = [:]

        for session in sortedSessions {
            let day = calendar.startOfDay(for: session.date)
            guard let offsetDays = calendar.dateComponents([.day], from: startDay, to: day).day else {
                continue
            }
            let weekIndex = max(1, (offsetDays / 7) + 1)
            groups[weekIndex, default: []].append(session)
        }

        return groups
            .map { (weekIndex, sessions) in
                let ordered = sessions.sorted { $0.date < $1.date }
                return WeekGroup(weekIndex: weekIndex, sessions: ordered)
            }
            .sorted { $0.weekIndex < $1.weekIndex }
    }

    var body: some View {
        List {
            if weeks.isEmpty {
                Section {
                    Text("No program found.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Create a program from onboarding to see your block here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(weeks) { week in
                    Section(header: Text("Week \(week.weekIndex)")) {
                        ForEach(week.sessions) { session in
                            NavigationLink {
                                ProgramDayDetailView(session: session)
                            } label: {
                                ProgramDayRow(session: session, calendar: calendar)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Week grouping model

struct WeekGroup: Identifiable {
    let weekIndex: Int
    let sessions: [Session]

    var id: Int { weekIndex }
}

// MARK: - Row for a single day in the plan

struct ProgramDayRow: View {
    let session: Session
    let calendar: Calendar

    private var weekdayName: String {
        let weekdayIndex = calendar.component(.weekday, from: session.date) - 1
        return calendar.weekdaySymbols[safe: weekdayIndex] ?? ""
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: session.date)
    }

    private var exerciseCountText: String {
        let count = session.items.count
        return "\(count) exercise\(count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(weekdayName)
                    .font(.headline)
                Spacer()
                Text(session.status.displayTitle)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(6)
            }

            Text(formattedDate)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(exerciseCountText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail view: plan for a single session/day (NOW EDITABLE)

struct ProgramDayDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: Session

    @State private var selectedItemForEdit: SessionItem?

    private var calendar: Calendar { Calendar.current }

    private var weekdayName: String {
        let weekdayIndex = calendar.component(.weekday, from: session.date) - 1
        return calendar.weekdaySymbols[safe: weekdayIndex] ?? ""
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: session.date)
    }

    /// Planned items in order.
    private var sortedItems: [SessionItem] {
        session.items.sorted { $0.order < $1.order }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weekdayName)
                        .font(.headline)

                    Text(formattedDate)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(session.status.displayTitle)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(6)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Planned exercises")) {
                ForEach(sortedItems) { item in
                    Button {
                        selectedItemForEdit = item
                    } label: {
                        ProgramExerciseRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Day Plan")
        .sheet(item: $selectedItemForEdit) { item in
            ProgramExerciseEditSheet(item: item)
        }
    }
}

// MARK: - Per-exercise planned row

struct ProgramExerciseRow: View {
    let item: SessionItem

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    private var titleText: String {
        exercise?.name ?? "Unknown exercise"
    }

    private var muscleText: String? {
        exercise?.primaryMuscle.rawValue.capitalized
    }

    private var prescriptionText: String {
        let sets = max(item.targetSets, 1)
        let reps = item.targetReps
        return "\(sets)x\(reps) · RIR \(item.targetRIR)"
    }

    private var startingLoadText: String? {
        // Prefer suggestedLoad, then plannedLoadsBySet[0] if present
        if item.suggestedLoad > 0 {
            return String(format: "%.1f lb starting load", item.suggestedLoad)
        }
        if let first = item.plannedLoadsBySet.first, first > 0 {
            return String(format: "%.1f lb starting load", first)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleText)
                .font(.headline)

            if let muscle = muscleText {
                Text(muscle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(prescriptionText)
                .font(.caption)
                .foregroundColor(.secondary)

            if let loadText = startingLoadText {
                Text(loadText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text("Tap to edit")
                .font(.caption2)
                .foregroundColor(.blue)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editor sheet: sets / reps / RIR / starting load

struct ProgramExerciseEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var item: SessionItem

    @State private var sets: Int
    @State private var reps: Int
    @State private var rir: Int
    @State private var startingLoadText: String

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    init(item: SessionItem) {
        self._item = Bindable(wrappedValue: item)

        let initialSets = max(item.targetSets, 1)
        let initialReps = max(item.targetReps, 1)
        let initialRir = item.targetRIR

        let baseLoad: Double
        if item.suggestedLoad > 0 {
            baseLoad = item.suggestedLoad
        } else if let first = item.plannedLoadsBySet.first, first > 0 {
            baseLoad = first
        } else {
            baseLoad = 0
        }

        _sets = State(initialValue: initialSets)
        _reps = State(initialValue: initialReps)
        _rir = State(initialValue: max(0, min(initialRir, 4)))
        _startingLoadText = State(initialValue: baseLoad > 0 ? String(format: "%.1f", baseLoad) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let exercise {
                    Section {
                        Text(exercise.name)
                            .font(.headline)
                    }
                }

                Section("Prescription") {
                    Stepper("Sets: \(sets)", value: $sets, in: 1...6)
                    Stepper("Reps: \(reps)", value: $reps, in: 4...20)
                    Stepper("Target RIR: \(rir)", value: $rir, in: 0...4)
                }

                Section("Starting load") {
                    TextField("e.g. 135", text: $startingLoadText)
                        .keyboardType(.decimalPad)

                    Text("Used as the starting working weight and to prefill planned loads for this day.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Edit Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndClose()
                    }
                }
            }
        }
    }

    private func saveAndClose() {
        let trimmed = startingLoadText.trimmingCharacters(in: .whitespaces)
        let loadValue: Double
        if let parsed = Double(trimmed), parsed > 0 {
            loadValue = parsed
        } else {
            loadValue = 0
        }

        // Update core prescription
        item.targetSets = sets
        item.targetReps = reps
        item.targetRIR = rir

        // Update planned reps to match prescription
        item.plannedRepsBySet = Array(repeating: reps, count: sets)

        // Update starting load + planned loads
        if loadValue > 0 {
            item.suggestedLoad = loadValue
            item.plannedLoadsBySet = Array(repeating: loadValue, count: sets)
        } else {
            item.suggestedLoad = 0
            item.plannedLoadsBySet = []
        }

        try? context.save()
        dismiss()
    }
}

// MARK: - Safe array index helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
