//
//  SessionView.swift
//  ElitePerformance
//

import SwiftUI
import SwiftData
import UIKit
import Combine

// MARK: - Root Session Screen

/// Root Session screen.
///
/// Normal usage in the app:
/// ```swift
/// NavigationLink {
///     SessionView(session: session)
/// } label: { ... }
/// ```
struct SessionView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: SessionScreenViewModel
    @State private var hasDisabledIdleTimer = false

    /// Unified sheet state: either swapping an exercise or showing the recap.
    @State private var activeSheet: ActiveSheet?

    // MARK: - Initializers

    /// Preferred initializer when you already have a view model.
    init(viewModel: SessionScreenViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    /// Convenience initializer for existing call sites:
    /// `SessionView(session: someSession)`
    init(session: Session) {
        _viewModel = StateObject(
            wrappedValue: SessionScreenViewModel(session: session)
        )
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
        // Keep screen awake while this view is visible
        .onAppear {
            if !hasDisabledIdleTimer {
                UIApplication.shared.isIdleTimerDisabled = true
                hasDisabledIdleTimer = true
            }
        }
        .onDisappear {
            if hasDisabledIdleTimer {
                UIApplication.shared.isIdleTimerDisabled = false
                hasDisabledIdleTimer = false
            }
        }
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

            Text(coachCue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coachCue: String {
        // Look across all exercises in this session
        let maxSets = viewModel.exercises.map(\.targetSets).max() ?? 3

        if maxSets >= 4 {
            return "3 to grow, 1 to know: use the 4th set as your tester if recovery is solid."
        } else {
            return "3 to grow: 3 solid working sets. Add a tester only on good days."
        }
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
                        .lineLimit(1)
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

    @State private var actualRIRText: String = ""

    private var isLocked: Bool {
        uiSet.status == .completed || uiSet.status == .skipped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top line: Set label + status chip (for locked sets)
            HStack {
                Text("Set \(uiSet.index)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if isLocked {
                    Text(uiSet.status == .skipped ? "Skipped" : "Done")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (uiSet.status == .skipped
                             ? Color.orange.opacity(0.2)
                             : Color.green.opacity(0.2))
                        )
                        .foregroundStyle(
                            uiSet.status == .skipped ? Color.orange : Color.green
                        )
                        .clipShape(Capsule())
                }
            }

            // PLAN line
            Text("PLAN \(uiSet.plannedDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            // ACTUAL inputs + Log / Skip buttons
            HStack(alignment: .bottom, spacing: 8) {
                // Load
                VStack(alignment: .leading, spacing: 2) {
                    Text("Load")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextField("0", text: $uiSet.actualLoadText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .disabled(isLocked)
                        .opacity(isLocked ? 0.6 : 1.0)
                }

                // Reps
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reps")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextField("0", text: $uiSet.actualRepsText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)
                        .disabled(isLocked)
                        .opacity(isLocked ? 0.6 : 1.0)
                }

                // RIR
                VStack(alignment: .leading, spacing: 2) {
                    Text("RIR")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextField("0", text: $actualRIRText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 40)
                        .disabled(isLocked)
                        .opacity(isLocked ? 0.6 : 1.0)
                }

                Spacer()

                // Primary actions: Log + Skip
                VStack(spacing: 4) {
                    // Log button
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
                                // Unlock and restore fields to planned values
                                uiSet.status = .notStarted
                                resetToPlan()
                            }
                        } else {
                            Button("Skip set") {
                                applySkip()
                            }
                        }
                    }

                    // Explicit Skip button
                    Button {
                        guard !isLocked else { return }
                        applySkip()
                    } label: {
                        Text("Skip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            // Pre-fill RIR from actual (if any) or from plan
            if actualRIRText.isEmpty {
                if let rir = uiSet.actualRIR {
                    actualRIRText = "\(rir)"
                } else if let planned = uiSet.plannedRIR {
                    actualRIRText = "\(planned)"
                } else {
                    actualRIRText = ""
                }
            }
        }
        .onChange(of: actualRIRText) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                uiSet.actualRIR = nil
            } else if let val = Int(trimmed) {
                uiSet.actualRIR = val
            }
        }
    }

    // MARK: - Helpers

    /// Clear any actuals and mark as skipped, ignoring prefilled plan values.
    private func applySkip() {
        uiSet.status = .skipped

        // Clear actual numeric values so they don't get persisted
        uiSet.actualLoad = nil
        uiSet.actualReps = nil
        uiSet.actualRIR = nil

        // Reset text fields away from "real" numbers
        uiSet.actualLoadText = "0"
        uiSet.actualRepsText = "\(uiSet.plannedReps)"
        actualRIRText = uiSet.plannedRIR.map { String($0) } ?? ""
    }

    /// Restore inputs to the planned baseline when you "Edit set".
    private func resetToPlan() {
        uiSet.actualLoad = nil
        uiSet.actualReps = nil
        uiSet.actualRIR = nil

        uiSet.actualLoadText = uiSet.plannedLoad == 0
            ? "0"
            : String(format: "%.1f", uiSet.plannedLoad)
        uiSet.actualRepsText = "\(uiSet.plannedReps)"
        actualRIRText = uiSet.plannedRIR.map { String($0) } ?? ""
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

    /// Whether all exercises have all planned sets completed.
    /// NOTE: skipped sets DO count as satisfied (you explicitly chose to skip).
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
                if let rir = uiSet.actualRIR, rir >= 0 {
                    item.actualRIRs[idx] = rir
                }
            }

            item.isCompleted = uiExercise.isComplete
            item.coachNote = uiExercise.coachMessage.isEmpty ? nil : uiExercise.coachMessage
        }

        // Update overall session status
        let anyLoggedSet = exercises
            .flatMap { $0.sets }
            .contains { $0.status == .completed }

        if exercises.allSatisfy({ $0.isComplete }) {
            session.status = .completed
        } else if anyLoggedSet {
            session.status = .inProgress
        } else {
            session.status = .planned
        }

        // ✅ Plan Memory v1 – always attempt to carry plans forward.
        // Safe because it only touches future items with *empty loads*.
        let planMemory = PlanMemoryEngine(context: context)
        planMemory.carryForwardPlans(from: session)

        do {
            try context.save()
        } catch {
            print("⚠️ Failed to save session: \(error)")
        }
    }

    // MARK: - Plan vs Actual Coaching Logic
    // (unchanged – logic only)

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
            var totalRepsForExercise = 0
            var totalVolume: Double = 0
            var lastRIR: Int? = nil

            for set in exercise.sets where set.index <= exercise.targetSets {
                guard set.status == .completed else { continue }

                let reps = set.actualReps ?? set.plannedReps
                let load = set.actualLoad ?? set.plannedLoad
                let rir  = set.actualRIR ?? set.plannedRIR

                setsCompleted += 1
                totalRepsForExercise += reps
                totalVolume += Double(reps) * load

                // Track the last completed set's RIR
                if let rir = rir {
                    lastRIR = rir
                }
            }

            return SessionRecapExercise(
                name: exercise.name,
                primaryMuscle: primary,
                sets: setsCompleted,
                reps: totalRepsForExercise,
                volume: totalVolume,
                lastSetRIR: lastRIR
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

        // Mark the underlying session as completed (first time only we set completedAt)
        if session.completedAt == nil {
            session.completedAt = Date()
        }
        session.status = .completed

        // Build the exercises payload for history
        let historyExercises = recap.exercises.map {
            SessionHistoryExercise(
                name: $0.name,
                primaryMuscle: $0.primaryMuscle,
                sets: $0.sets,
                reps: $0.reps,
                volume: $0.volume
            )
        }

        // Capture scalar values for the predicate (SwiftData can't compare two key paths)
        let targetDate = recap.date
        let targetWeek = recap.weekIndex

        // 🔑 Try to find an existing history entry for this same session day/week
        let descriptor = FetchDescriptor<SessionHistory>(
            predicate: #Predicate<SessionHistory> { history in
                history.date == targetDate && history.weekIndex == targetWeek
            }
        )

        let existing: [SessionHistory]
        do {
            existing = try context.fetch(descriptor)
        } catch {
            print("⚠️ Failed to fetch existing SessionHistory: \(error)")
            existing = []
        }

        if let existingHistory = existing.first {
            // Update the existing record instead of creating a duplicate
            existingHistory.title = recap.title
            existingHistory.subtitle = recap.subtitle
            existingHistory.totalExercises = recap.exerciseCount
            existingHistory.totalSets = recap.setCount
            existingHistory.totalVolume = recap.totalVolume
            existingHistory.exercises = historyExercises
        } else {
            // First time completing this session → insert a new history row
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
        }

        try context.save()
        print("✅ SessionHistory saved/updated")
    }
} // ← closes SessionScreenViewModel

// MARK: - Integration with real Session model

extension SessionScreenViewModel {
    convenience init(session: Session) {
        let title = session.date.formatted(date: .abbreviated, time: .omitted)
        let subtitle = "Week \(session.weekIndex)"

        let items = session.items.sorted { $0.order < $1.order }

        let exercises: [UISessionExercise] = items.map { item in
            let catalogExercise = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
            let name = catalogExercise?.name ?? "Exercise"

            // Clamp to 3–4 working sets for now
            let targetSets = max(3, min(item.targetSets, 4))
            let baseReps = item.targetReps
            let baseLoad = item.suggestedLoad
            let baseRIR = item.targetRIR

            // We currently support up to 4 sets in the logger UI
            let setCount = 4
            var uiSets: [UISessionSet] = []
            uiSets.reserveCapacity(setCount)

            for idx in 0..<setCount {
                let setIndex = idx + 1
                let isPlannedWorkingSet = setIndex <= targetSets

                // ---- Planned values ----
                let plannedReps: Int
                if idx < item.plannedRepsBySet.count, item.plannedRepsBySet[idx] > 0 {
                    plannedReps = item.plannedRepsBySet[idx]
                } else {
                    plannedReps = baseReps
                }

                let plannedLoad: Double
                if idx < item.plannedLoadsBySet.count, item.plannedLoadsBySet[idx] > 0 {
                    plannedLoad = item.plannedLoadsBySet[idx]
                } else {
                    plannedLoad = isPlannedWorkingSet ? baseLoad : 0.0
                }

                let plannedRIR = baseRIR

                // ---- Actual values (read back from SwiftData) ----
                var actualReps: Int? = nil
                if idx < item.actualReps.count, item.actualReps[idx] > 0 {
                    actualReps = item.actualReps[idx]
                }

                var actualLoad: Double? = nil
                if idx < item.actualLoads.count, item.actualLoads[idx] > 0 {
                    actualLoad = item.actualLoads[idx]
                }

                var actualRIR: Int? = nil
                if idx < item.actualRIRs.count {
                    let stored = item.actualRIRs[idx]
                    // Treat 0 as “real” only if there is an actual set logged
                    if stored > 0 || ((actualReps != nil || actualLoad != nil) && stored == 0) {
                        actualRIR = stored
                    }
                }

                // ---- Status ----
                let status: SetStatus
                if let reps = actualReps,
                   let load = actualLoad,
                   reps > 0,
                   load > 0 {
                    status = .completed
                } else {
                    status = .notStarted
                }

                uiSets.append(
                    UISessionSet(
                        index: setIndex,
                        plannedLoad: plannedLoad,
                        plannedReps: plannedReps,
                        plannedRIR: plannedRIR,
                        actualLoad: actualLoad,
                        actualReps: actualReps,
                        actualRIR: actualRIR,
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

    /// A session exercise is "complete" when all working sets (up to `targetSets`)
    /// are either completed or explicitly skipped.
    var isComplete: Bool {
        let workingSets = sets.filter { $0.index <= targetSets }
        guard !workingSets.isEmpty else { return false }

        return workingSets.allSatisfy { set in
            set.status == .completed || set.status == .skipped
        }
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

    /// Total reps logged across all exercises.
    var totalReps: Int {
        exercises.reduce(0) { $0 + $1.reps }
    }

    /// Last-set RIR values for exercises that have them.
    private var lastSetRIRs: [Int] {
        exercises.compactMap { $0.lastSetRIR }
    }

    /// Average last-set RIR for the session.
    var averageLastSetRIR: Double? {
        guard !lastSetRIRs.isEmpty else { return nil }
        let sum = lastSetRIRs.reduce(0, +)
        return Double(sum) / Double(lastSetRIRs.count)
    }

    /// Minimum and maximum last-set RIR.
    var minLastSetRIR: Int? { lastSetRIRs.min() }
    var maxLastSetRIR: Int? { lastSetRIRs.max() }
}

struct SessionRecapExercise: Identifiable {
    let id = UUID()
    let name: String
    let primaryMuscle: String?
    let sets: Int
    let reps: Int
    let volume: Double
    let lastSetRIR: Int?
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
            
            // Top row: same 3 metrics you already see
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
            
            // New: extra detail underneath
            if recap.totalReps > 0 {
                HStack {
                    Text("Total reps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(recap.totalReps)")
                        .font(.caption)
                }
            }
            
            if let avg = recap.averageLastSetRIR {
                HStack {
                    Text("Avg last-set RIR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f", avg))
                        .font(.caption)
                }
            }
            
            if let minR = recap.minLastSetRIR, let maxR = recap.maxLastSetRIR {
                HStack {
                    Text("Last-set RIR range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(minR)–\(maxR)")
                        .font(.caption)
                }
            }
        }
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
