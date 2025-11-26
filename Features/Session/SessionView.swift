//
//  SessionView.swift
//  ElitePerformance
//

import SwiftUI
import Combine

// MARK: - Root Session Screen

/// Root Session screen.
/// In normal navigation, use `SessionView(viewModel: SessionScreenViewModel(session: someSession))`.
struct SessionView: View {
    @StateObject private var viewModel: SessionScreenViewModel

    // Swap sheet state
    @State private var swapTarget: SwapTarget? = nil

    // Recap (summary) sheet state
    @State private var isSummaryPresented = false

    // MARK: - Initializers

    init(viewModel: SessionScreenViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    /// Preview-only convenience initializer.
    init() {
        _viewModel = StateObject(wrappedValue: .mock)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if viewModel.isSessionComplete {
                    completionBanner

                    Button {
                        isSummaryPresented = true
                    } label: {
                        Text("Finish Session")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.green.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                // Use enumerated so we have a stable index for swapping,
                // but still bind into the @Published exercises array.
                ForEach(Array(viewModel.exercises.enumerated()), id: \.element.id) { index, exercise in
                    SessionExerciseCardView(
                        exercise: $viewModel.exercises[index],
                        onSetLogged: { setIndex in
                            viewModel.handleSetLogged(
                                exerciseID: exercise.id,
                                setIndex: setIndex
                            )
                        },
                        onSwapTapped: {
                            swapTarget = SwapTarget(index: index)
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $swapTarget) { target in
            ExerciseSwapSheet(
                current: viewModel.exercises[target.index],
                onSelect: { catalogExercise in
                    viewModel.swapExercise(at: target.index, with: catalogExercise)
                    swapTarget = nil
                },
                onCancel: {
                    swapTarget = nil
                }
            )
        }
        .sheet(isPresented: $isSummaryPresented) {
            SessionSummaryView(summary: viewModel.buildSummary())
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(viewModel.sessionSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var completionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workout complete")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("All planned sets are logged. Nice work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.12))
        )
    }
}

// Helper used for the swap sheet
private struct SwapTarget: Identifiable {
    let id = UUID()
    let index: Int
}

// MARK: - Exercise Card

/// One card per exercise: header and set-by-set plan + actual logging.
private struct SessionExerciseCardView: View {
    @Binding var exercise: UISessionExercise
    let onSetLogged: (_ setIndex: Int) -> Void
    let onSwapTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.headline)

                    Text(exercise.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("\(exercise.targetSets) sets")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(action: onSwapTapped) {
                        Text("Swap")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }

                    if exercise.isComplete {
                        Text("Complete")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.18))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
            }

            // Set rows
            VStack(spacing: 6) {
                ForEach($exercise.sets) { $set in
                    SessionSetRowView(
                        set: $set,
                        onLog: {
                            onSetLogged(set.index)
                        }
                    )
                    .opacity(set.index <= exercise.targetSets ? 1.0 : 0.35)
                }
            }

            // Coach message
            if !exercise.coachMessage.isEmpty {
                Text(exercise.coachMessage)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(exercise.isComplete ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Set Row

private struct SessionSetRowView: View {
    @Binding var set: UISessionSet
    let onLog: () -> Void

    private var isLocked: Bool {
        return set.status == .completed || set.status == .skipped
    }

    var body: some View {
        HStack(spacing: 8) {
            // Set Index
            Text("Set \(set.index)")
                .font(.caption)
                .frame(width: 44, alignment: .leading)

            // PLAN (read-only)
            VStack(alignment: .leading, spacing: 2) {
                Text("PLAN")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(set.plannedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)

            Spacer()

            // ACTUAL (editable, unless locked)
            VStack(alignment: .leading, spacing: 2) {
                Text("ACTUAL")
                    .font(.caption2)
                    .fontWeight(.semibold)

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Load")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        TextField("0", text: $set.actualLoadText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .disabled(isLocked)
                            .opacity(isLocked ? 0.6 : 1.0)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        TextField("0", text: $set.actualRepsText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 40)
                            .disabled(isLocked)
                            .opacity(isLocked ? 0.6 : 1.0)
                    }
                }
            }

            // Log / Done / Skipped
            Button(action: {
                guard !isLocked else { return }
                onLog()
            }) {
                switch set.status {
                case .completed:
                    Text("Done")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Capsule())

                case .skipped:
                    Text("Skipped")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())

                default:
                    Text("Log")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if isLocked {
                    Button("Edit set") {
                        set.status = .notStarted
                    }
                } else {
                    Button("Skip set") {
                        set.status = .skipped
                    }
                }
            }
        }
    }
}

// MARK: - Swap Sheet

/// Simple sheet to pick a replacement exercise from the catalog.
private struct ExerciseSwapSheet: View {
    let current: UISessionExercise
    let onSelect: (CatalogExercise) -> Void
    let onCancel: () -> Void

    private var suggested: [CatalogExercise] {
        let all = ExerciseCatalog.all

        guard let currentCatalog = all.first(where: { $0.id == current.exerciseId }) else {
            return []
        }

        return all.filter { $0.primaryMuscle == currentCatalog.primaryMuscle }
    }

    private var allExercises: [CatalogExercise] {
        ExerciseCatalog.all.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if !suggested.isEmpty {
                    Section("Suggested for \(current.name)") {
                        ForEach(suggested) { exercise in
                            Button {
                                onSelect(exercise)
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
                }

                Section("All exercises") {
                    ForEach(allExercises) { exercise in
                        Button {
                            onSelect(exercise)
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
            }
            .navigationTitle("Swap Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }
}

// MARK: - Summary Models + View (renamed to avoid clashes)

struct SessionSummary {
    struct ExerciseSummary: Identifiable {
        let id = UUID()
        let name: String
        let setsCompleted: Int
        let totalReps: Int
        let totalVolume: Double
    }

    let title: String
    let subtitle: String
    let totalExercises: Int
    let totalSetsCompleted: Int
    let totalVolume: Double
    let exercises: [ExerciseSummary]
}

struct SessionSummaryView: View {
    let summary: SessionSummary

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.title)
                            .font(.headline)

                        Text(summary.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 8)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Exercises")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(summary.totalExercises)")
                                .font(.headline)
                        }

                        Spacer()

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sets completed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(summary.totalSetsCompleted)")
                                .font(.headline)
                        }

                        Spacer()

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total volume")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f", summary.totalVolume))
                                .font(.headline)
                        }
                    }
                    .padding(.top, 4)
                }

                Section("By exercise") {
                    ForEach(summary.exercises) { ex in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ex.name)
                                .font(.subheadline.weight(.semibold))

                            HStack(spacing: 12) {
                                Text("Sets: \(ex.setsCompleted)")
                                Text("Reps: \(ex.totalReps)")
                                Text("Vol: \(Int(ex.totalVolume))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Session Recap")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - View Model

final class SessionScreenViewModel: ObservableObject {
    @Published var title: String
    @Published var subtitle: String
    @Published var exercises: [UISessionExercise]

    init(
        title: String,
        subtitle: String,
        exercises: [UISessionExercise]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.exercises = exercises
    }

    /// Summary line under the header.
    var sessionSummary: String {
        let setCount = exercises.map { $0.targetSets }.reduce(0, +)
        return "\(exercises.count) exercises · \(setCount) planned working sets"
    }

    /// Whether all exercises have all planned sets completed or skipped.
    var isSessionComplete: Bool {
        exercises.allSatisfy { $0.isComplete }
    }

    // MARK: - Summary Builder

    func buildSummary() -> SessionSummary {
        let exerciseSummaries: [SessionSummary.ExerciseSummary] = exercises.map { exercise in
            let completedSets = exercise.sets
                .filter { $0.index <= exercise.targetSets }
                .filter { $0.status == .completed }

            let setsCompleted = completedSets.count

            var totalReps = 0
            var totalVolume: Double = 0

            for set in completedSets {
                let reps = set.actualReps ?? set.plannedReps
                let load = set.actualLoad ?? set.plannedLoad
                totalReps += reps
                totalVolume += Double(reps) * load
            }

            return SessionSummary.ExerciseSummary(
                name: exercise.name,
                setsCompleted: setsCompleted,
                totalReps: totalReps,
                totalVolume: totalVolume
            )
        }

        let totalExercises = exercises.count
        let totalSetsCompleted = exerciseSummaries.reduce(0) { $0 + $1.setsCompleted }
        let totalVolume = exerciseSummaries.reduce(0) { $0 + $1.totalVolume }

        return SessionSummary(
            title: title,
            subtitle: subtitle,
            totalExercises: totalExercises,
            totalSetsCompleted: totalSetsCompleted,
            totalVolume: totalVolume,
            exercises: exerciseSummaries
        )
    }

    // MARK: - Set Logging Logic

    func handleSetLogged(exerciseID: UUID, setIndex: Int) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        var exercise = exercises[exerciseIdx]
        var set = exercise.sets[setIdx]

        // Try to parse actuals (already prefilled from PLAN by default)
        let actualLoad = Double(set.actualLoadText)
        let actualReps = Int(set.actualRepsText)

        // CASE 1: User entered valid numbers → full logging + coaching
        if let load = actualLoad,
           let reps = actualReps,
           load > 0,
           reps > 0 {

            set.actualLoad = load
            set.actualReps = reps
            set.status = .completed

            exercise.sets[setIdx] = set
            exercise.coachMessage = coachMessage(for: exercise, recentSetIndex: set.index)

            exercises[exerciseIdx] = exercise
            onSetCompleted(exercise: exercise, set: set)
            return
        }

        // CASE 2: No numbers (or invalid) → just mark the set done, no coaching change
        set.status = .completed
        exercise.sets[setIdx] = set
        exercises[exerciseIdx] = exercise
        onSetCompleted(exercise: exercise, set: set)
    }

    private func onSetCompleted(exercise: UISessionExercise, set: UISessionSet) {
        // Hook for timers / haptics later if we want.
    }

    // MARK: - Swap Logic

    func swapExercise(at index: Int, with catalogExercise: CatalogExercise) {
        guard exercises.indices.contains(index) else { return }

        var exercise = exercises[index]
        exercise.exerciseId = catalogExercise.id
        exercise.name = catalogExercise.name

        let baseReps = exercise.sets.first?.plannedReps ?? 10
        let baseRIR = exercise.sets.first?.plannedRIR ?? 2

        exercise.detail = "Week \(exercise.weekInMeso) · \(catalogExercise.primaryMuscle.rawValue.capitalized) · \(baseReps) reps @ RIR \(baseRIR)"
        exercise.coachMessage = ""

        // Reset PLAN loads to 0 for all sets so you consciously re-baseline this movement.
        exercise.sets = exercise.sets.map { set in
            var updated = set
            updated.plannedLoad = 0
            updated.plannedLoadText = "0"
            updated.actualLoad = nil
            updated.actualLoadText = "0"
            updated.actualReps = nil
            updated.actualRepsText = "\(updated.plannedReps)"
            updated.status = .notStarted
            return updated
        }

        exercises[index] = exercise
    }

    // MARK: - Plan vs Actual Coaching Logic

    private func coachMessage(for exercise: UISessionExercise, recentSetIndex: Int) -> String {
        guard let recentSet = exercise.sets.first(where: { $0.index == recentSetIndex }) else {
            return ""
        }

        // Use actual load if present, otherwise fall back to planned
        let plannedReps = recentSet.plannedReps
        let actualReps = recentSet.actualReps ?? plannedReps

        let plannedLoad = recentSet.plannedLoad
        let actualLoad = recentSet.actualLoad ?? plannedLoad
        let displayLoad = actualLoad > 0 ? actualLoad : plannedLoad

        let outcome = outcome(for: recentSet)
        let loadString = formatLoad(displayLoad)
        let nextLoad = nextLoadSuggestion(for: recentSet, outcome: outcome)
        let nextLoadString = formatLoad(nextLoad)

        let repsDiff = actualReps - plannedReps
        let loadDiff = actualLoad - plannedLoad

        // Banding: when is the plan clearly off?
        let step: Double
        if plannedLoad >= 185 {
            step = 5.0
        } else if plannedLoad >= 95 {
            step = 2.5
        } else if plannedLoad > 0 {
            step = 2.0
        } else {
            step = 5.0
        }

        let similarLoad = abs(loadDiff) < (step - 0.1)
        let significantlyHeavier = loadDiff >= (step - 0.1)
        let significantlyLighter = loadDiff <= -(step - 0.1)

        let planTooEasy =
            (significantlyHeavier && actualReps >= plannedReps - 1) ||
            (similarLoad && repsDiff >= 3)

        let planTooHard =
            significantlyLighter ||
            repsDiff <= -3

        // Helper for "reset the plan" suggestions
        let easierPlanLoad = max(0, actualLoad - step)
        let easierPlanString = formatLoad(easierPlanLoad)

        switch recentSet.index {
        // 3 to grow – working sets
        case 1...3:
            if planTooEasy {
                // If there was no real load plan (0.0), don’t fake precision.
                // Treat this as a baseline set and talk in ranges.
                if plannedLoad == 0 {
                    let targetLow = max(6, plannedReps)       // e.g. 10
                    let targetHigh = targetLow + 2            // e.g. 12

                    return "Set \(recentSet.index): You had far more than needed at \(loadString) × \(actualReps). Use this as a baseline. Next time, pick a weight where your hardest working set lands around \(targetLow)–\(targetHigh) solid reps, not 20+."
                }

                // Normal “plan too easy” case when we *do* have a real plan load
                let lower = max(plannedReps + 1, actualReps - 3)
                let upper = actualReps

                let heavierLoad = nextLoadSuggestion(for: recentSet, outcome: .exceededPlan)
                let heavierLoadString = formatLoad(heavierLoad)

                if lower < upper {
                    return "Set \(recentSet.index): Plan was too easy at \(loadString) × \(actualReps). Next time, set your plan around \(loadString) × \(lower)–\(upper), or bump to \(heavierLoadString) × \(plannedReps)–\(lower) if that still feels smooth."
                } else {
                    return "Set \(recentSet.index): Plan was too easy at \(loadString) × \(actualReps). Next time, either repeat \(loadString) × \(actualReps) or try \(heavierLoadString) × \(plannedReps)–\(actualReps)."
                }
            }
            if planTooHard {
                return "Set \(recentSet.index): Plan overshot today at \(loadString) × \(actualReps). Next time, set your plan around \(easierPlanString) × \(plannedReps) or keep load and aim for fewer reps."
            }

            switch outcome {
            case .matchedPlan:
                return "Set \(recentSet.index): On target at \(loadString) × \(plannedReps). Next set: repeat \(loadString) × \(plannedReps)."

            case .exceededPlan:
                // Could be more reps, more load, or both
                return "Set \(recentSet.index): You beat your plan at \(loadString) × \(actualReps). Next set: stay at \(loadString) and aim to hold or add a rep."

            case .fellShort:
                return "Set \(recentSet.index): You fell short of plan (\(actualReps) vs \(plannedReps)). Next set: stay at \(loadString) and aim to match \(plannedReps). If this repeats next session, drop to \(nextLoadString)."
            }

        // 1 to know – diagnostic/test set
        case 4:
            if planTooEasy {
                if plannedLoad == 0 {
                    let targetLow = max(6, plannedReps)
                    let targetHigh = targetLow + 2

                    return "Test set (Set 4): This blew past a normal working set at \(loadString) × \(actualReps). Treat it as a scouting set. Next session, choose a load where your toughest set lands around \(targetLow)–\(targetHigh) clean reps and use that as your baseline."
                }

                let lower = max(plannedReps + 1, actualReps - 3)
                let upper = actualReps

                let heavierLoad = nextLoadSuggestion(for: recentSet, outcome: .exceededPlan)
                let heavierLoadString = formatLoad(heavierLoad)

                if lower < upper {
                    return "Test set (Set 4): Plan was clearly too easy at \(loadString) × \(actualReps). Next session, set your baseline around \(loadString) × \(lower)–\(upper), or try \(heavierLoadString) × \(plannedReps)–\(lower) if recovery and bar speed are strong."
                } else {
                    return "Test set (Set 4): Plan was clearly too easy at \(loadString) × \(actualReps). Next session, either repeat \(loadString) × \(actualReps) or push to \(heavierLoadString) × \(plannedReps)–\(actualReps) as your new baseline."
                }
            }
            if planTooHard {
                return "Test set (Set 4): Plan overshot at \(loadString) × \(actualReps). Next session, set your plan around \(easierPlanString) × \(plannedReps) so you’re not grinding every set."
            }

            switch outcome {
            case .matchedPlan, .exceededPlan:
                return "Test set (Set 4): Strong at \(loadString) × \(plannedReps) for \(actualReps) reps. Next session: try \(nextLoadString) × \(plannedReps) if recovery is solid."

            case .fellShort:
                return "Test set (Set 4): Right at the edge (\(actualReps) vs \(plannedReps)). Next session: hold at \(loadString) × \(plannedReps) or drop to \(nextLoadString) if fatigue stays high."
            }

        // Overflow volume – caution language
        default:
            switch outcome {
            case .matchedPlan:
                return "Set \(recentSet.index): Solid extra work at \(loadString) × \(plannedReps). Don’t chase fatigue—shut it down if performance slips."
            case .exceededPlan:
                return "Set \(recentSet.index): Over-delivering at \(loadString) × \(actualReps). Make sure this doesn’t compromise your next session."
            case .fellShort:
                return "Set \(recentSet.index): Fatigue is showing at \(loadString). This is bonus volume—better to stop than force junk reps."
            }
        }
    }

    private func outcome(for set: UISessionSet) -> SetOutcome {
        let plannedReps = set.plannedReps
        let plannedLoad = set.plannedLoad

        let actualReps = set.actualReps ?? plannedReps
        let actualLoad = set.actualLoad ?? plannedLoad

        let repsDiff = actualReps - plannedReps
        let loadDiff = actualLoad - plannedLoad

        // Heavier with roughly similar reps = progression
        let loadStep: Double
        if plannedLoad >= 185 {
            loadStep = 5.0
        } else if plannedLoad >= 95 {
            loadStep = 2.5
        } else if plannedLoad > 0 {
            loadStep = 2.0
        } else {
            loadStep = 5.0
        }

        let loadUpEnough = loadDiff >= (loadStep - 0.1)

        if loadUpEnough && actualReps >= plannedReps - 1 {
            return .exceededPlan
        }

        // Otherwise fall back to pure reps comparison
        if repsDiff >= 1 {
            return .exceededPlan
        } else if repsDiff <= -2 {
            return .fellShort
        } else {
            return .matchedPlan
        }
    }

    /// Suggest a next load based on current plan and outcome.
    /// This only affects the *text* cue, not stored data (yet).
    private func nextLoadSuggestion(for set: UISessionSet, outcome: SetOutcome) -> Double {
        // Use actual load as the base if we have it
        let baseLoad = set.actualLoad ?? set.plannedLoad
        let load = baseLoad

        // Basic heuristic for step size in lbs:
        // - Heavier lifts → bigger jumps
        // - Lighter lifts → smaller jumps
        let step: Double
        if load >= 185 {
            step = 5.0
        } else if load >= 95 {
            step = 2.5
        } else if load > 0 {
            step = 2.0
        } else {
            step = 5.0
        }

        switch outcome {
        case .exceededPlan:
            return load + step
        case .fellShort:
            return max(0, load - step)
        case .matchedPlan:
            return load
        }
    }

    private func formatLoad(_ value: Double) -> String {
        if value == 0 {
            return "0"
        } else {
            return String(format: "%.1f", value)
        }
    }
}

// MARK: - Integration with real Session model

extension SessionScreenViewModel {
    /// Build a view model from a real SwiftData `Session`.
    convenience init(session: Session) {
        let title = session.date.formatted(date: .abbreviated, time: .omitted)
        let subtitle = "Week \(session.weekIndex)"

        let exercises: [UISessionExercise] = session.items
            .sorted { $0.order < $1.order }
            .map { item in
                // Look up exercise metadata from the catalog
                let catalogExercise = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
                let name = catalogExercise?.name ?? "Exercise"

                // Planned targets
                // 3–4 working sets per exercise; UI always shows 4 rows.
                let targetSets = max(3, min(item.targetSets, 4))

                let baseReps = item.targetReps
                let baseLoad = item.suggestedLoad
                let baseRIR = item.targetRIR

                let setCount = 4   // We always show 4 set rows in the logger

                var uiSets: [UISessionSet] = []
                uiSets.reserveCapacity(setCount)

                for idx in 0..<setCount {
                    let setIndex = idx + 1
                    let isPlannedWorkingSet = setIndex <= targetSets

                    let reps = baseReps
                    let load = isPlannedWorkingSet ? baseLoad : 0.0
                    let plannedRIR = baseRIR

                    uiSets.append(
                        UISessionSet(
                            index: setIndex,
                            plannedLoad: load,
                            plannedReps: reps,
                            plannedRIR: plannedRIR
                        )
                    )
                }

                let detail: String
                if let ce = catalogExercise {
                    detail = "Week \(session.weekIndex) · \(ce.primaryMuscle.rawValue.capitalized) · \(baseReps) reps @ RIR \(baseRIR)"
                } else {
                    detail = "Week \(session.weekIndex) · \(baseReps) reps @ RIR \(baseRIR)"
                }

                return UISessionExercise(
                    exerciseId: item.exerciseId,
                    name: name,
                    detail: detail,
                    weekInMeso: session.weekIndex,
                    targetSets: targetSets,
                    sets: uiSets,
                    coachMessage: item.coachNote ?? ""
                )
            }

        self.init(
            title: title,
            subtitle: subtitle,
            exercises: exercises
        )
    }
}

// MARK: - UI Models

enum SetStatus: Equatable {
    case notStarted
    case inProgress
    case completed
    case skipped
}

enum SetOutcome {
    case matchedPlan
    case exceededPlan
    case fellShort
}

struct UISessionExercise: Identifiable {
    let id = UUID()

    var exerciseId: String          // matches CatalogExercise.id and SessionItem.exerciseId
    var name: String
    var detail: String              // e.g. "Week 3 · Day 1 · 8–12 reps @ 2–3 RIR"
    var weekInMeso: Int             // to drive meso-phase logic
    var targetSets: Int             // 3–6
    var sets: [UISessionSet]
    var coachMessage: String

    var isComplete: Bool {
        sets
            .filter { $0.index <= targetSets }
            .allSatisfy { $0.status == .completed || $0.status == .skipped }
    }

    init(
        exerciseId: String,
        name: String,
        detail: String,
        weekInMeso: Int,
        targetSets: Int,
        sets: [UISessionSet],
        coachMessage: String = ""
    ) {
        self.exerciseId = exerciseId
        self.name = name
        self.detail = detail
        self.weekInMeso = weekInMeso
        self.targetSets = max(3, min(targetSets, 6))
        self.sets = sets.sorted(by: { $0.index < $1.index })
        self.coachMessage = coachMessage
    }
}

struct UISessionSet: Identifiable {
    let id = UUID()
    let index: Int

    var plannedLoad: Double
    var plannedReps: Int
    let plannedRIR: Int?

    var actualLoad: Double?
    var actualReps: Int?
    var actualRIR: Int?

    var status: SetStatus

    // String backing for TextField input
    var plannedLoadText: String
    var plannedRepsText: String
    var actualLoadText: String
    var actualRepsText: String

    init(
        index: Int,
        plannedLoad: Double,
        plannedReps: Int,
        plannedRIR: Int?,
        actualLoad: Double? = nil,
        actualReps: Int? = nil,
        actualRIR: Int? = nil,
        status: SetStatus = .notStarted
    ) {
        self.index = index
        self.plannedLoad = plannedLoad
        self.plannedReps = plannedReps
        self.plannedRIR = plannedRIR
        self.actualLoad = actualLoad
        self.actualReps = actualReps
        self.actualRIR = actualRIR
        self.status = status

        // Text backing
        let planLoadString: String
        if plannedLoad == 0 {
            planLoadString = "0"
        } else {
            planLoadString = String(format: "%.1f", plannedLoad)
        }

        self.plannedLoadText = planLoadString
        self.plannedRepsText = "\(plannedReps)"

        if let actualLoad {
            self.actualLoadText = String(format: "%.1f", actualLoad)
        } else {
            // PREFILL: plan → actual, so one tap logs if you follow the plan
            self.actualLoadText = planLoadString
        }

        if let actualReps {
            self.actualRepsText = "\(actualReps)"
        } else {
            // PREFILL: plan → actual
            self.actualRepsText = "\(plannedReps)"
        }
    }

    var plannedDescription: String {
        if plannedLoad == 0 && plannedReps == 0 {
            return "—"
        }

        if let plannedRIR {
            return String(
                format: "%.1f × %d @ %d RIR",
                plannedLoad,
                plannedReps,
                plannedRIR
            )
        } else {
            return String(
                format: "%.1f × %d",
                plannedLoad,
                plannedReps
            )
        }
    }
}

// MARK: - Mock Data for Previews

extension SessionScreenViewModel {
    static var mock: SessionScreenViewModel {
        let benchSets = [
            UISessionSet(index: 1, plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
            UISessionSet(index: 2, plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
            UISessionSet(index: 3, plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
            UISessionSet(index: 4, plannedLoad: 185, plannedReps: 8, plannedRIR: 1),
            UISessionSet(index: 5, plannedLoad: 0, plannedReps: 0, plannedRIR: nil),
            UISessionSet(index: 6, plannedLoad: 0, plannedReps: 0, plannedRIR: nil)
        ]

        let bench = UISessionExercise(
            exerciseId: "bench",
            name: "Barbell Bench Press",
            detail: "Week 3 · Day 1 · 8–12 reps @ 2–3 RIR · 3–4 sets (4th = test)",
            weekInMeso: 3,
            targetSets: 4,
            sets: benchSets
        )

        let rowSets = [
            UISessionSet(index: 1, plannedLoad: 225, plannedReps: 10, plannedRIR: 2),
            UISessionSet(index: 2, plannedLoad: 225, plannedReps: 10, plannedRIR: 2),
            UISessionSet(index: 3, plannedLoad: 225, plannedReps: 10, plannedRIR: 2),
            UISessionSet(index: 4, plannedLoad: 225, plannedReps: 10, plannedRIR: 1)
        ]

        let row = UISessionExercise(
            exerciseId: "row",
            name: "Chest Supported Row",
            detail: "Week 3 · Day 1 · 10–15 reps @ 2–3 RIR · 3–4 sets",
            weekInMeso: 3,
            targetSets: 3,
            sets: rowSets
        )

        return SessionScreenViewModel(
            title: "Week 3 · Day 1",
            subtitle: "Upper · Heavy Press Focus",
            exercises: [bench, row]
        )
    }
}

// MARK: - Preview

struct SessionView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SessionView()
        }
    }
}
