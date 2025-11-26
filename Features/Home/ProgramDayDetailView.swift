import SwiftUI
import SwiftData

/// Plan editor for a single training day.
/// - Lives under the Program tab.
/// - Edits PLAN only (load / reps / RIR / sets).
/// - No Actual logging here.
struct ProgramDayDetailView: View {
    @Bindable var session: Session   // SwiftData-friendly

    // MARK: - Body

    var body: some View {
        List {
            headerSection

            Section("Exercises") {
                if session.items.isEmpty {
                    Text("No exercises yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                        ProgramExercisePlanRow(
                            index: index,
                            item: item,
                            session: session
                        )
                    }
                }
            }
        }
        .navigationTitle("Edit Plan")
        .navigationBarTitleDisplayMode(.inline)
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
private struct ProgramExercisePlanRow: View {
    let index: Int
    let item: SessionItem
    @Bindable var session: Session

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
                    Text("\(session.items[index].targetSets) sets")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(
                        "",
                        onIncrement: {
                            if session.items[index].targetSets < 4 {
                                session.items[index].targetSets += 1
                            }
                        },
                        onDecrement: {
                            if session.items[index].targetSets > 3 {
                                session.items[index].targetSets -= 1
                            }
                        }
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
                            value: binding(\.suggestedLoad),
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
                            value: binding(\.targetReps),
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
                            value: binding(\.targetRIR),
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

    /// Creates a binding into `session.items[index].<keyPath>`.
    /// This avoids having to know the concrete type in the parent view.
    private func binding<Value>(_ keyPath: WritableKeyPath<SessionItem, Value>) -> Binding<Value> {
        Binding(
            get: {
                session.items[index][keyPath: keyPath]
            },
            set: { newValue in
                session.items[index][keyPath: keyPath] = newValue
            }
        )
    }
}
