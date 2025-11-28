//
//  SessionView.swift
//  ElitePerformance
//

import SwiftUI
import Combine
import SwiftData

// MARK: - Root Session Screen

/// Root Session screen.
/// In normal navigation, use:
/// `SessionView(viewModel: SessionScreenViewModel(session: someSession))`.
struct SessionView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: SessionScreenViewModel

    /// Unified sheet state: either swapping an exercise or showing the recap.
    @State private var activeSheet: ActiveSheet?

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
                }

                // Use enumerated so we have a stable index for swapping,
                // but still bind into the @Published exercises array.
                ForEach(Array(viewModel.exercises.enumerated()), id: \.element.id) { index, exercise in
                    SessionExerciseCardView(
                        exercise: $viewModel.exercises[index],
                        onSetLogged: { setIndex in
                            viewModel.handleSetLogged(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                context: modelContext
                            )
                        },
                        onSwapTapped: {
                            activeSheet = .swap(
                                SwapTarget(exerciseIndex: index)
                            )
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .swap(let target):
                ExerciseSwapSheet(
                    current: viewModel.exercises[target.exerciseIndex],
                    onSelect: { catalogExercise in
                        viewModel.swapExercise(at: target.exerciseIndex, with: catalogExercise)
                        // Persist the swap into the Session model as well.
                        viewModel.persist(using: modelContext)
                        activeSheet = nil
                    },
                    onCancel: {
                        activeSheet = nil
                    }
                )

            case .recap(let recap):
                SessionRecapSheet(
                    recap: recap,
                    onDone: {
                        do {
                            try viewModel.persistCompletion(
                                using: modelContext,
                                recap: recap
                            )
                        } catch {
                            // For now just log – we can add user-visible error later.
                            print("Failed to persist completion: \(error)")
                        }
                        activeSheet = nil
                    }
                )
            }
        }
    }

    // MARK: - Header / Banner

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

            Button {
                let recap = viewModel.buildRecap()
                activeSheet = .recap(recap)
            } label: {
                Text("Recap")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.12))
        )
    }
}

// MARK: - Sheet Routing

/// Which sheet is currently being shown from the Session screen.
private enum ActiveSheet: Identifiable {
    case swap(SwapTarget)
    case recap(SessionRecap)

    var id: UUID {
        switch self {
        case .swap(let target):
            return target.id
        case .recap(let recap):
            return recap.id
        }
    }
}

/// Helper used for the swap sheet.
private struct SwapTarget {
    let id = UUID()
    let exerciseIndex: Int
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
                        uiSet: $set,
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
    @Binding var uiSet: UISessionSet
    let onLog: () -> Void

    private var isLocked: Bool {
        uiSet.status == .completed || uiSet.status == .skipped
    }

    var body: some View {
        HStack(spacing: 8) {
            // Set Index
            Text("Set \(uiSet.index)")
                .font(.caption)
                .frame(width: 44, alignment: .leading)

            // PLAN (read-only)
            VStack(alignment: .leading, spacing: 2) {
                Text("PLAN")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(uiSet.plannedDescription)
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

                        TextField("0", text: $uiSet.actualLoadText)
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

                        TextField("0", text: $uiSet.actualRepsText)
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
                switch uiSet.status {
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
                        uiSet.status = .notStarted
                    }
                } else {
                    Button("Skip set") {
                        uiSet.status = .skipped
                    }
                }
            }
        }
    }
}

// MARK: - Swap Sheet

/// Sheet to pick a replacement exercise from the catalog.
/// Shows "recommended" (same primary muscle group) first, then all others.
private struct ExerciseSwapSheet: View {
    let current: UISessionExercise
    let onSelect: (CatalogExercise) -> Void
    let onCancel: () -> Void

    private var options: [CatalogExercise] {
        let all = ExerciseCatalog.all

        guard let currentCatalog = all.first(where: { $0.id == current.exerciseId }) else {
            return all
        }

        let same = all.filter { $0.primaryMuscle == currentCatalog.primaryMuscle }
        let others = all.filter {
            $0.id != currentCatalog.id && $0.primaryMuscle != currentCatalog.primaryMuscle
        }

        return same + others
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options) { exercise in
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
                } header: {
                    Text("Choose a replacement for \(current.name)")
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

// MARK: - View Model

final class SessionScreenViewModel: ObservableObject {
    // Backing SwiftData model (what we persist to)
    private let session: Session

    // UI state
    @Published var title: String
    @Published var subtitle: String
    @Published var exercises: [UISessionExercise]

    init(
        session: Session,
        title: String,
        subtitle: String,
        exercises: [UISessionExercise]
    ) {
        self.session = session
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

    // MARK: - Set Logging Logic

    func handleSetLogged(exerciseID: UUID, setIndex: Int, context: ModelContext) {
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

            persist(using: context)
            return
        }

        // CASE 2: No numbers (or invalid) → just mark the set done, no coaching change
        set.status = .completed
        exercise.sets[setIdx] = set
        exercises[exerciseIdx] = exercise
        onSetCompleted(exercise: exercise, set: set)

        persist(using: context)
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

        // Reset loads, text fields, and logged data when we swap to a new exercise.
        for i in exercise.sets.indices {
            // numeric values
            exercise.sets[i].plannedLoad = 0.0
            exercise.sets[i].actualLoad = nil
            exercise.sets[i].actualReps = nil
            exercise.sets[i].actualRIR = nil
            exercise.sets[i].status = .notStarted

            // text fields shown in the UI
            exercise.sets[i].plannedLoadText = "0"
            exercise.sets[i].actualLoadText = "0"
            exercise.sets[i].plannedRepsText = "\(exercise.sets[i].plannedReps)"
            exercise.sets[i].actualRepsText = "\(exercise.sets[i].plannedReps)"
        }

        let baseReps = exercise.sets.first?.plannedReps ?? 10
        let baseRIR = exercise.sets.first?.plannedRIR ?? 2

        exercise.detail = "Week \(exercise.weekInMeso) · \(catalogExercise.primaryMuscle.rawValue.capitalized) · \(baseReps) reps @ RIR \(baseRIR)"
        exercise.coachMessage = ""

        exercises[index] = exercise
    }

    // MARK: - Persist UI → SwiftData

    /// Push current UI state into the underlying `Session` / `SessionItem`s.
    func persist(using context: ModelContext) {
        let items = session.items.sorted { $0.order < $1.order }

        for (exerciseIndex, uiExercise) in exercises.enumerated() {
            guard exerciseIndex < items.count else { continue }
            let item = items[exerciseIndex]

            // Sync basic exercise info (including swaps)
            item.exerciseId = uiExercise.exerciseId
            item.targetSets = uiExercise.targetSets

            if let firstSet = uiExercise.sets.first {
                item.targetReps = firstSet.plannedReps
                item.suggestedLoad = firstSet.plannedLoad
                if let plannedRIR = firstSet.plannedRIR {
                    item.targetRIR = plannedRIR
                }
            }

            let setCount = uiExercise.sets.count

            // Resize arrays to match UI
            item.plannedRepsBySet = Array(repeating: 0, count: setCount)
            item.plannedLoadsBySet = Array(repeating: 0, count: setCount)
            item.actualReps        = Array(repeating: 0, count: setCount)
            item.actualLoads       = Array(repeating: 0, count: setCount)
            item.actualRIRs        = Array(repeating: 0, count: setCount)
            item.usedRestPauseFlags = Array(repeating: false, count: setCount)
            item.restPausePatternsBySet = Array(repeating: "", count: setCount)

            for uiSet in uiExercise.sets {
                let idx = uiSet.index - 1
                guard idx >= 0 && idx < setCount else { continue }

                item.plannedRepsBySet[idx] = uiSet.plannedReps
                item.plannedLoadsBySet[idx] = uiSet.plannedLoad

                if let reps = uiSet.actualReps, reps > 0 {
                    item.actualReps[idx] = reps
                }
                if let load = uiSet.actualLoad, load > 0 {
                    item.actualLoads[idx] = load
                }
            }

            item.isCompleted = uiExercise.isComplete
            item.coachNote = uiExercise.coachMessage.isEmpty ? nil : uiExercise.coachMessage
        }

        // Update overall session status
        let anyLoggedSet = exercises
            .flatMap { $0.sets }
            .contains { $0.status == .completed || $0.status == .skipped }

        if exercises.allSatisfy({ $0.isComplete }) {
            session.status = .completed
        } else if anyLoggedSet {
            session.status = .inProgress
        } else {
            session.status = .planned
        }

        do {
            try context.save()
        } catch {
            print("⚠️ Failed to save session: \(error)")
        }
    }

    // MARK: - Plan vs Actual Coaching Logic
    // (unchanged)
    private func coachMessage(for exercise: UISessionExercise, recentSetIndex: Int) -> String {
        guard let recentSet = exercise.sets.first(where: { $0.index == recentSetIndex }) else {
            return ""
        }

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

        let easierPlanLoad = max(0, actualLoad - step)
        let easierPlanString = formatLoad(easierPlanLoad)

        switch recentSet.index {
        case 1...3:
            if planTooEasy {
                if plannedLoad == 0 {
                    let targetLow = max(6, plannedReps)
                    let targetHigh = targetLow + 2

                    return "Set \(recentSet.index): You had far more than needed at \(loadString) × \(actualReps). Use this as a baseline. Next time, pick a weight where your hardest working set lands around \(targetLow)–\(targetHigh) solid reps, not 20+."
                }

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
                return "Set \(recentSet.index): You beat your plan at \(loadString) × \(actualReps). Next set: stay at \(loadString) and aim to hold or add a rep."
            case .fellShort:
                return "Set \(recentSet.index): You fell short of plan (\(actualReps) vs \(plannedReps)). Next set: stay at \(loadString) and aim to match \(plannedReps). If this repeats next session, drop to \(nextLoadString)."
            }

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

        if repsDiff >= 1 {
            return .exceededPlan
        } else if repsDiff <= -2 {
            return .fellShort
        } else {
            return .matchedPlan
        }
    }

    private func nextLoadSuggestion(for set: UISessionSet, outcome: SetOutcome) -> Double {
        let baseLoad = set.actualLoad ?? set.plannedLoad
        let load = baseLoad

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
        value == 0 ? "0" : String(format: "%.1f", value)
    }

    // MARK: - Recap + Persistence (History)

    func buildRecap() -> SessionRecap {
        let exerciseSummaries: [SessionRecapExercise] = exercises.map { exercise in
            let catalog = ExerciseCatalog.all.first(where: { $0.id == exercise.exerciseId })
            let primary = catalog?.primaryMuscle.rawValue.capitalized

            var setsCompleted = 0
            var totalReps = 0
            var totalVolume: Double = 0

            for set in exercise.sets where set.index <= exercise.targetSets {
                guard set.status == .completed else { continue }

                let reps = set.actualReps ?? set.plannedReps
                let load = set.actualLoad ?? set.plannedLoad

                setsCompleted += 1
                totalReps += reps
                totalVolume += Double(reps) * load
            }

            return SessionRecapExercise(
                name: exercise.name,
                primaryMuscle: primary,
                sets: setsCompleted,
                reps: totalReps,
                volume: totalVolume
            )
        }

        return SessionRecap(
            date: session.date,
            weekIndex: session.weekIndex,
            title: title,
            subtitle: subtitle,
            exercises: exerciseSummaries
        )
    }

    func persistCompletion(using context: ModelContext, recap: SessionRecap) throws {
        print("🔁 persistCompletion called – exercises: \(recap.exerciseCount), sets: \(recap.setCount), volume: \(recap.totalVolume)")

        if session.completedAt == nil {
            session.completedAt = Date()
        }
        session.status = .completed

        let historyExercises = recap.exercises.map {
            SessionHistoryExercise(
                name: $0.name,
                primaryMuscle: $0.primaryMuscle,
                sets: $0.sets,
                reps: $0.reps,
                volume: $0.volume
            )
        }

        let history = SessionHistory(
            date: recap.date,
            weekIndex: recap.weekIndex,
            title: recap.title,
            subtitle: recap.subtitle,
            totalExercises: recap.exerciseCount,
            totalSets: recap.setCount,
            totalVolume: recap.totalVolume,
            exercises: historyExercises
        )

        context.insert(history)
        try context.save()

        print("✅ SessionHistory saved")
    }
}

// MARK: - Integration with real Session model

extension SessionScreenViewModel {
    convenience init(session: Session) {
        let title = session.date.formatted(date: .abbreviated, time: .omitted)
        let subtitle = "Week \(session.weekIndex)"

        let exercises: [UISessionExercise] = session.items
            .sorted { $0.order < $1.order }
            .map { item in
                let catalogExercise = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
                let name = catalogExercise?.name ?? "Exercise"

                let targetSets = max(3, min(item.targetSets, 4))
                let baseReps = item.targetReps
                let baseLoad = item.suggestedLoad
                let baseRIR = item.targetRIR

                let setCount = 4
                var uiSets: [UISessionSet] = []
                uiSets.reserveCapacity(setCount)

                for idx in 0..<setCount {
                    let setIndex = idx + 1
                    let isPlannedWorkingSet = setIndex <= targetSets

                    let plannedReps = baseReps
                    let plannedLoad = isPlannedWorkingSet ? baseLoad : 0.0
                    let plannedRIR = baseRIR

                    // Do NOT read item.actualReps / item.actualLoads here.
                    let actualReps: Int? = nil
                    let actualLoad: Double? = nil
                    let status: SetStatus = .notStarted

                    uiSets.append(
                        UISessionSet(
                            index: setIndex,
                            plannedLoad: plannedLoad,
                            plannedReps: plannedReps,
                            plannedRIR: plannedRIR,
                            actualLoad: actualLoad,
                            actualReps: actualReps,
                            actualRIR: nil,
                            status: status
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
            session: session,
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

    var exerciseId: String
    var name: String
    var detail: String
    var weekInMeso: Int
    var targetSets: Int
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
            self.actualLoadText = planLoadString
        }

        if let actualReps {
            self.actualRepsText = "\(actualReps)"
        } else {
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

// MARK: - Recap Types + Sheet

struct SessionRecap: Identifiable {
    let id = UUID()
    let date: Date
    let weekIndex: Int
    let title: String
    let subtitle: String
    let exercises: [SessionRecapExercise]

    var exerciseCount: Int {
        exercises.count
    }

    var setCount: Int {
        exercises.reduce(0) { $0 + $1.sets }
    }

    var totalVolume: Double {
        exercises.reduce(0) { $0 + $1.volume }
    }
}

struct SessionRecapExercise: Identifiable {
    let id = UUID()
    let name: String
    let primaryMuscle: String?
    let sets: Int
    let reps: Int
    let volume: Double
}

private struct SessionRecapSheet: View {
    let recap: SessionRecap
    let onDone: () -> Void

    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard

                    VStack(alignment: .leading, spacing: 8) {
                        Text("By exercise")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 0) {
                            ForEach(recap.exercises) { ex in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ex.name)
                                        .font(.body)
                                    HStack(spacing: 12) {
                                        Text("Sets: \(ex.sets)")
                                        Text("Reps: \(ex.reps)")
                                        Text("Vol: \(Int(ex.volume))")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)

                                if ex.id != recap.exercises.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color(.systemBackground))
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Session Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone()
                    }
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dateFormatter.string(from: recap.date))
                .font(.headline)

            Text("Week \(recap.weekIndex)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Exercises")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(recap.exerciseCount)")
                        .font(.headline)
                }

                Spacer()

                VStack(alignment: .leading) {
                    Text("Sets completed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(recap.setCount)")
                        .font(.headline)
                }

                Spacer()

                VStack(alignment: .leading) {
                    Text("Total volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(recap.totalVolume))")
                        .font(.headline)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
        )
    }
}

// MARK: - Mock Data for Previews

extension SessionScreenViewModel {
    static var mock: SessionScreenViewModel {
        let dummySession = Session(
            date: Date(),
            weekIndex: 1,
            items: []
        )

        let benchSets = [
            UISessionSet(index: 1, plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
            UISessionSet(index: 2, plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
            UISessionSet(index: 3, plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
            UISessionSet(index: 4, plannedLoad: 185, plannedReps: 8, plannedRIR: 1)
        ]

        let bench = UISessionExercise(
            exerciseId: "bench",
            name: "Barbell Bench Press",
            detail: "Week 1 · Chest · 8–12 reps @ 2–3 RIR",
            weekInMeso: 1,
            targetSets: 3,
            sets: benchSets
        )

        return SessionScreenViewModel(
            session: dummySession,
            title: "Nov 26, 2025",
            subtitle: "Week 1",
            exercises: [bench]
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
