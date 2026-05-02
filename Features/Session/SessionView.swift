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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: SessionScreenViewModel
    @State private var hasDisabledIdleTimer = false
    @AppStorage("warmup.isHidden.v1") private var isWarmupHidden = false
    // Unified sheet state (swap / recap / history / note / add)
    @State private var activeSheet: ActiveSheet?
    @State private var pendingSwapForPropagation: (from: String, to: String, name: String)?
    @State private var showSwapPropagationDialog = false
    @State private var pendingAddedExerciseForPropagation: (exerciseId: String, exerciseName: String)?
    @State private var showAddExercisePropagationDialog = false

    // MARK: - Initializers

    init(viewModel: SessionScreenViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    init(session: Session) {
        _viewModel = StateObject(wrappedValue: SessionScreenViewModel(session: session))
    }

    init() {
        _viewModel = StateObject(wrappedValue: .mock)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                // ✅ Warm-up card (toggle hide/show)
                if let first = viewModel.exercises.first {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Warm-up")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                isWarmupHidden.toggle()
                            } label: {
                                Label(
                                    isWarmupHidden ? "Show warm-up" : "Hide warm-up",
                                    systemImage: isWarmupHidden ? "chevron.down" : "chevron.up"
                                )
                                .labelStyle(.iconOnly)
                                .font(.caption)
                                .padding(6)
                            }
                            .background(Color.black.opacity(0.05))
                            .clipShape(Circle())
                            .accessibilityLabel(isWarmupHidden ? "Show warm-up" : "Hide warm-up")
                        }

                        if !isWarmupHidden {
                            WarmupCardView(
                                sessionKey: warmupSessionKey,
                                firstExerciseName: first.name,
                                firstExercisePlannedLoad: (first.sets.first?.plannedLoad ?? 0) > 0
                                    ? first.sets.first?.plannedLoad
                                    : nil,
                                rounding: warmupRounding(for: first.name)
                            )
                        }
                    }
                }

                if viewModel.isSessionComplete {
                    completionBanner
                }

                ForEach(Array(viewModel.exercises.enumerated()), id: \.element.id) { index, exercise in
                    SessionExerciseCardView(
                        exercise: exercise,
                        onLoadChanged: { setIndex, text in
                            viewModel.updateActualLoad(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                text: text
                            )
                        },
                        onRepsChanged: { setIndex, text in
                            viewModel.updateActualReps(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                text: text
                            )
                        },
                        onRIRChanged: { setIndex, text in
                            viewModel.updateActualRIR(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                text: text
                            )
                        },
                        onRPToggled: { setIndex, isOn in
                            viewModel.updateRestPauseToggle(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                isOn: isOn
                            )
                        },
                        onRPPatternChanged: { setIndex, text in
                            viewModel.updateRestPausePattern(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                text: text
                            )
                        },
                        onDropSetToggled: { [exerciseId = exercise.id] setIndex, isOn in
                            viewModel.updateDropSetToggle(
                                exerciseID: exerciseId,
                                setIndex: setIndex,
                                isOn: isOn
                            )
                        },
                        onDropSetPatternChanged: { [exerciseId = exercise.id] setIndex, text in
                            viewModel.updateDropSetPattern(
                                exerciseID: exerciseId,
                                setIndex: setIndex,
                                text: text
                            )
                        },
                        onLogTapped: { setIndex in
                            viewModel.handleSetLogged(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                context: modelContext
                            )
                        },
                        onSkipTapped: { setIndex in
                            viewModel.skipSet(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                context: modelContext
                            )
                        },
                        onEditTapped: { setIndex in
                            viewModel.editSet(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                context: modelContext
                            )
                        },
                        onSwapTapped: { [exerciseIndex = index] in
                            activeSheet = .swap(SwapTarget(exerciseIndex: exerciseIndex))
                        },
                        onHistoryTapped: { [exerciseId = exercise.exerciseId, exerciseName = exercise.name] in
                            activeSheet = .history(exerciseId: exerciseId, exerciseName: exerciseName)
                        },
                        onNoteTapped: { [exerciseId = exercise.exerciseId, exerciseName = exercise.name] in
                            activeSheet = .note(exerciseId: exerciseId, exerciseName: exerciseName)
                        },
                        onAddSetTapped: { [exerciseId = exercise.id] in
                            viewModel.addSet(toExerciseID: exerciseId, context: modelContext)
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {

                // ✅ Session Complete → Recap → persistCompletion (History + Apple Health)
                Button {
                    let recap = viewModel.buildRecap()
                    activeSheet = .recap(recap)
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .disabled(!viewModel.isSessionComplete)
                .accessibilityLabel("Complete session")

                // Add exercise
                Button {
                    activeSheet = .addExercise
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add exercise")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.isSessionComplete {
                SessionCompleteBar(
                    isEnabled: true,
                    onComplete: {
                        let recap = viewModel.buildRecap()
                        activeSheet = .recap(recap)
                    }
                )
            }
        }
        .onAppear {
            disableIdleTimerIfNeeded()
            viewModel.refreshFromSession()
        }
        .onDisappear(perform: restoreIdleTimerIfNeeded)
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                viewModel.refreshFromSession()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetView(for: sheet)
        }
        .confirmationDialog(
            "Swapped to \(pendingSwapForPropagation?.name ?? "new exercise")",
            isPresented: $showSwapPropagationDialog,
            titleVisibility: .visible
        ) {
            Button("Apply to future \(propagationWeekdayName) sessions") {
                guard let swap = pendingSwapForPropagation else { return }
                ExerciseSwapPropagationService.apply(
                    fromExerciseId: swap.from,
                    toExerciseId: swap.to,
                    in: modelContext
                )
                pendingSwapForPropagation = nil
            }

            Button("Keep this session only") {
                pendingSwapForPropagation = nil
            }

            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog(
            "Added \(pendingAddedExerciseForPropagation?.exerciseName ?? "exercise")",
            isPresented: $showAddExercisePropagationDialog,
            titleVisibility: .visible
        ) {
            Button("Apply to future \(propagationWeekdayName) sessions") {
                guard let pending = pendingAddedExerciseForPropagation else { return }
                viewModel.propagateAddedExerciseForward(
                    exerciseId: pending.exerciseId,
                    context: modelContext
                )
                pendingAddedExerciseForPropagation = nil
            }

            Button("Keep this session only") {
                pendingAddedExerciseForPropagation = nil
            }

            Button("Cancel", role: .cancel) { }
        }
    }

    
    
    // MARK: - Sheets

    @ViewBuilder
    private func sheetView(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .addExercise:
            AddExerciseSheet(
                onSelect: { catalogExercise in
                    viewModel.addExercise(catalogExercise, context: modelContext)
                    activeSheet = nil

                    pendingAddedExerciseForPropagation = (
                        exerciseId: catalogExercise.id,
                        exerciseName: catalogExercise.name
                    )
                    showAddExercisePropagationDialog = true
                },
                onCancel: {
                    activeSheet = nil
                }
            )

        case .swap(let target):
            ExerciseSwapSheet(
                current: viewModel.exercises[target.exerciseIndex],
                onSelect: { catalogExercise in
                    let fromId = viewModel.exercises[target.exerciseIndex].exerciseId
                    let toId = catalogExercise.id
                    let toName = catalogExercise.name

                    viewModel.swapExercise(at: target.exerciseIndex, with: catalogExercise)
                    viewModel.persist(using: modelContext)
                    activeSheet = nil

                    pendingSwapForPropagation = (from: fromId, to: toId, name: toName)
                    showSwapPropagationDialog = true
                },
                onCancel: { activeSheet = nil }
            )

        case .recap(let recap):
            SessionRecapSheet(
                recap: recap,
                onDone: {
                    do {
                        try viewModel.persistCompletion(using: modelContext, recap: recap)
                    } catch {
                        print("Failed to persist completion: \(error)")
                    }
                    activeSheet = nil
                }
            )

        case .history(let exerciseId, let exerciseName):
            ExerciseHistorySheet(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                onClose: { activeSheet = nil }
            )

        case .note(let exerciseId, let exerciseName):
            ExerciseNoteSheet(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                onClose: { activeSheet = nil }
            )
        }
    }

    // MARK: - Idle Timer

    private func disableIdleTimerIfNeeded() {
        guard !hasDisabledIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        hasDisabledIdleTimer = true
    }

    private func restoreIdleTimerIfNeeded() {
        guard hasDisabledIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        hasDisabledIdleTimer = false
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
        let maxSets = viewModel.exercises.map(\.targetSets).max() ?? 3
        return maxSets >= 4
            ? "Complete the planned working sets with clean execution. Extra sets are supportive, not mandatory."
            : "Complete the planned working sets with clean execution and stable effort."
    }

    private var warmupSessionKey: String {
        let raw = "\(viewModel.title)_\(viewModel.subtitle)"
        return raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
    }

    private func warmupRounding(for exerciseName: String) -> WarmupCardView.LoadRounding {
        let n = exerciseName.lowercased()
        if n.contains("dumbbell") || n.contains("db") { return .dumbbell }
        if n.contains("cable") || n.contains("machine") { return .machine }
        return .barbell
    }

    private var propagationWeekdayName: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEEE"
        return formatter.string(from: viewModel.sessionDate)
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
                activeSheet = .recap(viewModel.buildRecap())
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
    typealias ID = String

    case swap(SwapTarget)
    case recap(SessionRecap)
    case history(exerciseId: String, exerciseName: String)
    case note(exerciseId: String, exerciseName: String)
    case addExercise

    var id: String {
        switch self {
        case .swap(let target):
            return "swap-\(target.id)"
        case .recap(let recap):
            return "recap-\(recap.id)"
        case .history(let exerciseId, _):
            return "history-\(exerciseId)"
        case .note(let exerciseId, _):
            return "note-\(exerciseId)"
        case .addExercise:
            return "add-exercise"
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
    @Environment(\.modelContext) private var modelContext
    let exercise: UISessionExercise

    let onLoadChanged: (_ setIndex: Int, _ text: String) -> Void
    let onRepsChanged: (_ setIndex: Int, _ text: String) -> Void
    let onRIRChanged: (_ setIndex: Int, _ text: String) -> Void
    let onRPToggled: (_ setIndex: Int, _ isOn: Bool) -> Void
    let onRPPatternChanged: (_ setIndex: Int, _ text: String) -> Void
    let onDropSetToggled: (_ setIndex: Int, _ isOn: Bool) -> Void
    let onDropSetPatternChanged: (_ setIndex: Int, _ text: String) -> Void

    let onLogTapped: (_ setIndex: Int) -> Void
    let onSkipTapped: (_ setIndex: Int) -> Void
    let onEditTapped: (_ setIndex: Int) -> Void

    let onSwapTapped: () -> Void
    let onHistoryTapped: () -> Void
    let onNoteTapped: () -> Void
    let onAddSetTapped: () -> Void

    // MARK: - Coach v5 (ProgressionEngine) helpers

    /// Map the current exercise ID into a progression cluster.
    /// This is meso-specific: tuned for the Chest/Bis/Tris + Low-Back 8-week block.
    private var exerciseCluster: ExerciseCluster? {
        switch exercise.exerciseId {

        case "bench_press",
             "incline_dumbbell_press",
             "machine_chest_press":
            return .primaryChestPress

        case "cable_tricep_rope_pushdown",
             "overhead_rope_tricep_extension",
             "smith_machine_dip",
             "wide_grip_pulldown",
             "pulldown_normal_grip",
             "seated_cable_row",
             "chest_supported_incline_dumbbell_row",
             "dumbbell_row_single_arm":
            return .secondaryPressOrArms

        case "hack_squat",
             "leg_press":
            return .primaryLeg

        case "seated_cable_fly",
             "leg_extension",
             "lying_leg_curl",
             "seated_leg_curl",
             "smith_machine_calves",
             "seated_calf_raise",
             "leg_press_calf_raise",
             "ez_bar_curl",
             "hammer_curl",
             "cable_rope_hammer_curl",
             "single_arm_cable_curl",
             "dumbbell_lateral_raise",
             "incline_rear_delt_fly",
             "cable_rope_crunch":
            return .pumpIsolation

        case "cable_pull_through",
             "back_extension_45",
             "bench_back_extension",
             "pallof_press",
             "dead_bug",
             "suitcase_carry",
             "farmer_carry":
            return .lowBackStability

        default:
            return nil
        }
    }

    private var repRange: RepRange {
        RepRangeRulebook.range(
            forExerciseId: exercise.exerciseId,
            exerciseName: exercise.name
        )
    }

    private var todayDetailLine: String {
        let parts = exercise.detail.components(separatedBy: " · ")

        let weekText = parts.indices.contains(0) ? parts[0] : "Week \(exercise.weekIndex)"
        let muscleText = parts.indices.contains(1) ? parts[1] : nil
        let setsText = "\(exercise.targetSets) sets"

        let plannedReps = exercise.sets.first(where: { $0.index == 1 })?.plannedReps
            ?? exercise.sets.first?.plannedReps
            ?? 10
        let repsText = "\(plannedReps) reps"

        let rirText: String = {
            if let rir = exercise.sets.first(where: { $0.index == 1 })?.plannedRIR
                ?? exercise.sets.first?.plannedRIR {
                return "\(rir) RIR"
            }
            return "— RIR"
        }()

        if let muscleText {
            return "\(weekText) · \(muscleText) · \(setsText) · \(repsText) · \(rirText)"
        } else {
            return "\(weekText) · \(setsText) · \(repsText) · \(rirText)"
        }
    }

    private var hasExerciseNote: Bool {
        ExerciseNoteLookup.hasNote(exerciseId: exercise.exerciseId, in: modelContext)
    }

    private var noteIconName: String {
        hasExerciseNote ? "note.text" : "note"
    }

    private var executionNoteLine: String? {
        let intensifier = exercise.intensifierNotes?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let intensifier, !intensifier.isEmpty {
            return intensifier
        }

        let prescription = exercise.prescriptionNotes?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let prescription, !prescription.isEmpty {
            return prescription
        }

        return nil
    }

    private func shouldShowSet(_ set: UISessionSet) -> Bool {
        if set.index <= exercise.targetSets {
            return true
        }

        let hasActualWork = (set.actualReps ?? 0) > 0 || (set.actualLoad ?? 0) > 0
        let wasSkipped = set.status == .skipped

        return hasActualWork || wasSkipped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(todayDetailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let executionNoteLine {
                        Text(executionNoteLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .italic()
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                HStack(spacing: 8) {
                    Text("\(exercise.targetSets) sets")
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(action: onNoteTapped) {
                        Image(systemName: noteIconName)
                            .font(.caption)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.05))
                    .clipShape(Circle())
                    .accessibilityLabel(hasExerciseNote ? "View note" : "Add note")

                    Button(action: onHistoryTapped) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.05))
                    .clipShape(Circle())

                    Button(action: onSwapTapped) {
                        Text("Swap")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            HStack {
                Spacer()

                Button(action: onAddSetTapped) {
                    Label("Add Set", systemImage: "plus")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.12))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(exercise.targetSets >= 6)
                .opacity(exercise.targetSets >= 6 ? 0.5 : 1.0)
            }

            VStack(spacing: 6) {
                ForEach(exercise.sets) { set in
                    if shouldShowSet(set) {
                        SessionSetRowView(
                            uiSet: set,
                            repRange: repRange,
                            onLoadChanged: { text in
                                onLoadChanged(set.index, text)
                            },
                            onRepsChanged: { text in
                                onRepsChanged(set.index, text)
                            },
                            onRIRChanged: { text in
                                onRIRChanged(set.index, text)
                            },
                            onRPToggled: { isOn in
                                onRPToggled(set.index, isOn)
                            },
                            onRPPatternChanged: { text in
                                onRPPatternChanged(set.index, text)
                            },
                            onDropSetToggled: { isOn in
                                onDropSetToggled(set.index, isOn)
                            },
                            onDropSetPatternChanged: { text in
                                onDropSetPatternChanged(set.index, text)
                            },
                            onLog: {
                                onLogTapped(set.index)
                            },
                            onSkip: {
                                onSkipTapped(set.index)
                            },
                            onEdit: {
                                onEditTapped(set.index)
                            }
                        )
                    }
                }
            }

            if !exercise.coachMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
    let uiSet: UISessionSet
    let repRange: RepRange

    let onLoadChanged: (String) -> Void
    let onRepsChanged: (String) -> Void
    let onRIRChanged: (String) -> Void
    let onRPToggled: (Bool) -> Void
    let onRPPatternChanged: (String) -> Void
    let onDropSetToggled: (Bool) -> Void
    let onDropSetPatternChanged: (String) -> Void

    let onLog: () -> Void
    let onSkip: () -> Void
    let onEdit: () -> Void
    
    private var isLocked: Bool {
        uiSet.status == .completed || uiSet.status == .skipped
    }
    


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Top line: Set label + status chip (locked sets only)
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
                        .background(uiSet.status == .skipped ? Color.orange.opacity(0.2) : Color.green.opacity(0.2))
                        .foregroundStyle(uiSet.status == .skipped ? Color.orange : Color.green)
                        .clipShape(Capsule())
                }
            }

            // PLAN line
            Text("PLAN \(uiSet.plannedDescription(with: repRange))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            // ACTUAL inputs row
            HStack(alignment: .bottom, spacing: 8) {
                // Load
                VStack(alignment: .leading, spacing: 2) {
                    Text("Load")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("0", text: Binding(
                        get: { uiSet.actualLoadText },
                        set: { onLoadChanged($0) }
                    ))
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
                    TextField("0", text: Binding(
                        get: { uiSet.actualRepsText },
                        set: { onRepsChanged($0) }
                    ))
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
                    TextField("0", text: Binding(
                        get: {
                            if let actual = uiSet.actualRIR { return "\(actual)" }
                            if let planned = uiSet.plannedRIR { return "\(planned)" }
                            return ""
                        },
                        set: { onRIRChanged($0) }
                    ))
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .disabled(isLocked)
                    .opacity(isLocked ? 0.6 : 1.0)
                }

                Spacer()

                // Log / Skip / Edit
                VStack(spacing: 4) {
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
                            Button("Edit set") { onEdit() }
                        } else {
                            Button("Skip set") { onSkip() }
                        }
                    }

                    Button {
                        guard !isLocked else { return }
                        onSkip()
                    } label: {
                        Text("Skip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Intensifier toggles row (hidden when locked)
            if !isLocked {
                HStack(spacing: 20) {
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { uiSet.usedRestPause },
                            set: { onRPToggled($0) }
                        ))
                        .labelsHidden()
                        .scaleEffect(0.85)
                        Text("Rest-pause")
                            .font(.caption2)
                            .foregroundStyle(uiSet.usedRestPause ? Color.primary : Color.secondary)
                    }
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { uiSet.usedDropSet },
                            set: { onDropSetToggled($0) }
                        ))
                        .labelsHidden()
                        .scaleEffect(0.85)
                        Text("Drop set")
                            .font(.caption2)
                            .foregroundStyle(uiSet.usedDropSet ? Color.primary : Color.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }

            // RP pattern field (shown when toggle is on)
            if uiSet.usedRestPause {
                TextField("RP pattern (e.g. 10+4+3)", text: Binding(
                    get: { uiSet.restPausePattern },
                    set: { onRPPatternChanged($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .disabled(isLocked)
                .opacity(isLocked ? 0.6 : 1.0)
            }

            // Drop set pattern field (shown when toggle is on)
            if uiSet.usedDropSet {
                TextField("Drop pattern (e.g. 120x12, 100x8)", text: Binding(
                    get: { uiSet.dropSetPattern },
                    set: { onDropSetPatternChanged($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .disabled(isLocked)
                .opacity(isLocked ? 0.6 : 1.0)
            }
        }
        .padding(.vertical, 4)
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

    var sessionDate: Date {
        session.date
    }

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

    func refreshFromSession() {
        let refreshed = SessionScreenViewModel(session: session)
        self.title = refreshed.title
        self.subtitle = refreshed.subtitle
        self.exercises = refreshed.exercises
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

    func handleSetLogged(
        exerciseID: UUID,
        setIndex: Int,
        context: ModelContext
    ) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else {
            return
        }

        var exercise = exercises[exerciseIdx]

        guard let setIdx = exercise.sets.firstIndex(where: { $0.index == setIndex }) else {
            return
        }

        var set = exercise.sets[setIdx]

        let parsedLoad = Double(set.actualLoadText.trimmingCharacters(in: .whitespacesAndNewlines))
        let parsedReps = Int(set.actualRepsText.trimmingCharacters(in: .whitespacesAndNewlines))

        if let reps = parsedReps, reps > 0 {
            let loadToStore: Double = {
                if let load = parsedLoad {
                    return load
                }
                if let actual = set.actualLoad {
                    return actual
                }
                return set.plannedLoad
            }()

            // 1) Update UI state
            set.actualReps = reps
            set.actualLoad = loadToStore
            set.status = .completed
            exercise.sets[setIdx] = set

            // 2) Sync fresh data into matching SessionItem before coaching
            if let matchingItem = session.items.first(where: { $0.exerciseId == exercise.exerciseId }) {
                let idx = setIndex - 1

                if idx >= 0 {
                    while matchingItem.actualReps.count <= idx {
                        matchingItem.actualReps.append(0)
                    }
                    while matchingItem.actualLoads.count <= idx {
                        matchingItem.actualLoads.append(0)
                    }
                    while matchingItem.actualRIRs.count <= idx {
                        matchingItem.actualRIRs.append(0)
                    }
                    while matchingItem.usedRestPauseFlags.count <= idx {
                        matchingItem.usedRestPauseFlags.append(false)
                    }
                    while matchingItem.restPausePatternsBySet.count <= idx {
                        matchingItem.restPausePatternsBySet.append("")
                    }

                    matchingItem.actualReps[idx] = reps
                    matchingItem.actualLoads[idx] = loadToStore
                    if set.actualRIR == nil {
                        set.actualRIR = set.plannedRIR
                        exercise.sets[setIdx] = set
                    }
                    let rirToStore = set.actualRIR ?? set.plannedRIR ?? matchingItem.targetRIR
                    matchingItem.actualRIRs[idx] = rirToStore
                    matchingItem.usedRestPauseFlags[idx] = set.usedRestPause
                    matchingItem.restPausePatternsBySet[idx] = set.restPausePattern

                    if let recommendation = CoachingEngine.recommend(for: matchingItem) {
                        exercise.coachMessage = recommendation.message
                    } else {
                        exercise.coachMessage = ""
                    }
                }
            }

            exercises[exerciseIdx] = exercise
            // onSetCompleted(exercise: exercise, set: set)
            persist(using: context)
            return
        }

        exercises[exerciseIdx] = exercise
        persist(using: context)
    }

    func updateActualLoad(exerciseID: UUID, setIndex: Int, text: String) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        exercises[exerciseIdx].sets[setIdx].actualLoadText = text

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            exercises[exerciseIdx].sets[setIdx].actualLoad = nil
        } else if let value = Double(trimmed) {
            exercises[exerciseIdx].sets[setIdx].actualLoad = max(0, value)
        }
    }

    func updateActualReps(exerciseID: UUID, setIndex: Int, text: String) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        exercises[exerciseIdx].sets[setIdx].actualRepsText = text

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            exercises[exerciseIdx].sets[setIdx].actualReps = nil
        } else if let value = Int(trimmed) {
            exercises[exerciseIdx].sets[setIdx].actualReps = value
        }
    }

    func updateActualRIR(exerciseID: UUID, setIndex: Int, text: String) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            exercises[exerciseIdx].sets[setIdx].actualRIR = nil
        } else if let value = Int(trimmed) {
            exercises[exerciseIdx].sets[setIdx].actualRIR = value
        }
    }

    func updateRestPauseToggle(exerciseID: UUID, setIndex: Int, isOn: Bool) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        exercises[exerciseIdx].sets[setIdx].usedRestPause = isOn
        if !isOn {
            exercises[exerciseIdx].sets[setIdx].restPausePattern = ""
        }
    }

    func updateRestPausePattern(exerciseID: UUID, setIndex: Int, text: String) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        exercises[exerciseIdx].sets[setIdx].restPausePattern = text
    }
    
    func updateDropSetToggle(exerciseID: UUID, setIndex: Int, isOn: Bool) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        exercises[exerciseIdx].sets[setIdx].usedDropSet = isOn
        if !isOn {
            exercises[exerciseIdx].sets[setIdx].dropSetPattern = ""
        }
    }

    func updateDropSetPattern(exerciseID: UUID, setIndex: Int, text: String) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        exercises[exerciseIdx].sets[setIdx].dropSetPattern = text
    }
    
    func skipSet(exerciseID: UUID, setIndex: Int, context: ModelContext) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        exercises[exerciseIdx].sets[setIdx].status = .skipped
        exercises[exerciseIdx].sets[setIdx].actualLoad = nil
        exercises[exerciseIdx].sets[setIdx].actualReps = nil
        exercises[exerciseIdx].sets[setIdx].actualRIR = nil
        exercises[exerciseIdx].sets[setIdx].usedRestPause = false
        exercises[exerciseIdx].sets[setIdx].restPausePattern = ""
        exercises[exerciseIdx].sets[setIdx].usedDropSet = false
        exercises[exerciseIdx].sets[setIdx].dropSetPattern = ""
        exercises[exerciseIdx].sets[setIdx].actualLoadText = "0"
        exercises[exerciseIdx].sets[setIdx].actualRepsText = "\(exercises[exerciseIdx].sets[setIdx].plannedReps)"

        persist(using: context)
    }

    func editSet(exerciseID: UUID, setIndex: Int, context: ModelContext) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

        exercises[exerciseIdx].sets[setIdx].status = .notStarted
        exercises[exerciseIdx].sets[setIdx].actualLoad = nil
        exercises[exerciseIdx].sets[setIdx].actualReps = nil
        exercises[exerciseIdx].sets[setIdx].actualRIR = nil
        exercises[exerciseIdx].sets[setIdx].usedRestPause = false
        exercises[exerciseIdx].sets[setIdx].restPausePattern = ""
        exercises[exerciseIdx].sets[setIdx].usedDropSet = false
        exercises[exerciseIdx].sets[setIdx].dropSetPattern = ""
        exercises[exerciseIdx].sets[setIdx].actualLoadText = exercises[exerciseIdx].sets[setIdx].plannedLoad == 0
            ? "0"
            : String(format: "%.1f", exercises[exerciseIdx].sets[setIdx].plannedLoad)
        exercises[exerciseIdx].sets[setIdx].actualRepsText = "\(exercises[exerciseIdx].sets[setIdx].plannedReps)"

        persist(using: context)
    }

    private func onSetCompleted(exercise: UISessionExercise, set: UISessionSet) {
        // Hook for timers / haptics later if we want.
    }

    func addSet(toExerciseID exerciseID: UUID, context: ModelContext) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }

        var exercise = exercises[exerciseIdx]
        guard exercise.targetSets < 6 else { return }

        let seedSet = exercise.sets
            .filter { $0.index <= exercise.targetSets }
            .last ?? exercise.sets.last

        let nextIndex = (exercise.sets.map(\.index).max() ?? 0) + 1

        let plannedLoad = seedSet?.plannedLoad ?? 0
        let plannedReps = seedSet?.plannedReps ?? 10
        let plannedRIR = seedSet?.plannedRIR ?? 2

        let newSet = UISessionSet(
            index: nextIndex,
            plannedLoad: plannedLoad,
            plannedReps: plannedReps,
            plannedRIR: plannedRIR,
            actualLoad: nil,
            actualReps: nil,
            actualRIR: nil,
            status: .notStarted,
            usedRestPause: false,
            restPausePattern: ""
        )

        exercise.targetSets += 1
        exercise.sets.append(newSet)
        exercise.sets.sort { $0.index < $1.index }

        let parts = exercise.detail.components(separatedBy: " · ")
        let weekText = parts.indices.contains(0) ? parts[0] : "Week \(exercise.weekIndex)"
        let muscleText = parts.indices.contains(1) ? parts[1] : nil
        let repsText = "\(plannedReps) reps"
        let rirText = "\(plannedRIR) RIR"
        let setsText = "\(exercise.targetSets) sets"

        if let muscleText {
            exercise.detail = "\(weekText) · \(muscleText) · \(setsText) · \(repsText) · \(rirText)"
        } else {
            exercise.detail = "\(weekText) · \(setsText) · \(repsText) · \(rirText)"
        }

        exercises[exerciseIdx] = exercise
        persist(using: context)
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

        exercise.detail = "Week \(exercise.weekIndex) · \(catalogExercise.primaryMuscle.rawValue.capitalized) · \(exercise.prescriptionDetailLine.replacingOccurrences(of: "Week \(exercise.weekIndex) · ", with: ""))"
        exercise.coachMessage = ""

        exercises[index] = exercise
    }

    func addExercise(_ catalogExercise: CatalogExercise, context: ModelContext) {
        // If the user already "completed" the session, adding an exercise means we're back in progress.
        if session.status == .completed {
            session.status = .inProgress
            session.completedAt = nil
        }

        let nextOrder = (session.items.map(\.order).max() ?? 0) + 1

        // Defaults: simple + sane.
        let defaultSets = 3
        let defaultRIR = 2
        let defaultReps = catalogExercise.isCompound ? 10 : 12
        let defaultLoad: Double = 0

        let newItem = SessionItem(
            order: nextOrder,
            exerciseId: catalogExercise.id,
            targetReps: defaultReps,
            targetSets: defaultSets,
            targetRIR: defaultRIR,
            suggestedLoad: defaultLoad,
            plannedRepsBySet: Array(repeating: defaultReps, count: 4),
            plannedLoadsBySet: Array(repeating: 0, count: 4)
        )

        // Attach to session + persist
        session.items.append(newItem)
        context.insert(newItem)

        do {
            try context.save()
        } catch {
            print("⚠️ Failed to add exercise: \(error)")
        }

        // Build UI model immediately so it appears instantly (no backing out).
        let uiSets: [UISessionSet] = (1...4).map { idx in
            UISessionSet(
                index: idx,
                plannedLoad: (idx <= defaultSets) ? defaultLoad : 0,
                plannedReps: defaultReps,
                plannedRIR: defaultRIR,
                actualLoad: nil,
                actualReps: nil,
                actualRIR: nil,
                status: .notStarted
            )
        }

        let range = RepRangeRulebook.range(forExerciseId: catalogExercise.id, exerciseName: catalogExercise.name)
        let repsLabel = RepRangeRulebook.display(targetReps: defaultReps, range: range)
        let detail = "Week \(session.weekIndex) · \(catalogExercise.primaryMuscle.rawValue.capitalized) · \(defaultSets) sets · \(defaultReps) reps · \(defaultRIR) RIR"

        let uiExercise = UISessionExercise(
            exerciseId: catalogExercise.id,
            name: catalogExercise.name,
            detail: detail,
            weekInMeso: session.weekIndex,

            waveRaw: nil,
            priorityRaw: nil,
            setMin: nil,
            setMax: nil,
            repMin: nil,
            repMax: nil,
            targetRIRMin: nil,
            targetRIRMax: nil,
            intensifierRaw: nil,
            intensifierNotes: nil,
            prescriptionNotes: nil,

            targetSets: defaultSets,
            sets: uiSets,
            coachMessage: ""
        )

        exercises.append(uiExercise)
    }
    
    func propagateAddedExerciseForward(exerciseId: String, context: ModelContext) {
        guard let sourceItem = session.items.sorted(by: { $0.order < $1.order }).last(where: { $0.exerciseId == exerciseId }) else {
            return
        }

        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: session.date)
        let sourceDate = calendar.startOfDay(for: session.date)
        let sourceOrder = sourceItem.order

        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        do {
            let allSessions = try context.fetch(descriptor)

            let targets = allSessions.filter { other in
                guard other.id != session.id else { return false }
                guard other.status == .planned else { return false }
                guard calendar.startOfDay(for: other.date) > sourceDate else { return false }
                guard calendar.component(.weekday, from: other.date) == weekday else { return false }

                if let lhs = session.meso?.persistentModelID, let rhs = other.meso?.persistentModelID {
                    return lhs == rhs
                }

                return session.meso == nil && other.meso == nil
            }

            for target in targets {
                let alreadyExists = target.items.contains { $0.exerciseId == exerciseId }
                if alreadyExists { continue }

                let newItem = SessionItem(
                    order: sourceOrder,
                    exerciseId: sourceItem.exerciseId,
                    exerciseNameSnapshot: sourceItem.exerciseNameSnapshot,
                    targetReps: sourceItem.targetReps,
                    targetSets: sourceItem.targetSets,
                    targetRIR: sourceItem.targetRIR,
                    suggestedLoad: sourceItem.suggestedLoad,

                    waveRaw: sourceItem.waveRaw,
                    priorityRaw: sourceItem.priorityRaw,
                    setMin: sourceItem.setMin,
                    setMax: sourceItem.setMax,
                    repMin: sourceItem.repMin,
                    repMax: sourceItem.repMax,
                    targetRIRMin: sourceItem.targetRIRMin,
                    targetRIRMax: sourceItem.targetRIRMax,
                    intensifierRaw: sourceItem.intensifierRaw,
                    intensifierNotes: sourceItem.intensifierNotes,
                    prescriptionNotes: sourceItem.prescriptionNotes,

                    plannedRepsBySet: sourceItem.plannedRepsBySet,
                    plannedLoadsBySet: sourceItem.plannedLoadsBySet,
                    plannedRIRsBySet: sourceItem.plannedRIRsBySet,
                    actualReps: Array(repeating: 0, count: sourceItem.plannedRepsBySet.count),
                    actualLoads: Array(repeating: 0, count: sourceItem.plannedLoadsBySet.count),
                    actualRIRs: Array(repeating: 0, count: sourceItem.plannedRIRsBySet.count),
                    usedRestPauseFlags: Array(repeating: false, count: sourceItem.plannedRepsBySet.count),
                    restPausePatternsBySet: Array(repeating: "", count: sourceItem.plannedRepsBySet.count),
                    isCompleted: false,
                    isPR: false,
                    coachNote: nil,
                    nextSuggestedLoad: nil
                )

                for item in target.items where item.order >= sourceOrder {
                    item.order += 1
                }

                target.items.append(newItem)
            }

            try context.save()
        } catch {
            print("⚠️ Failed to propagate added exercise forward: \(error)")
        }
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
            item.plannedRepsBySet        = Array(repeating: 0, count: setCount)
            item.plannedLoadsBySet       = Array(repeating: 0, count: setCount)
            item.plannedRIRsBySet        = Array(repeating: 0, count: setCount)
            item.actualReps              = Array(repeating: 0, count: setCount)
            item.actualLoads             = Array(repeating: 0, count: setCount)
            item.actualRIRs              = Array(repeating: 0, count: setCount)
            item.usedRestPauseFlags      = Array(repeating: false, count: setCount)
            item.restPausePatternsBySet  = Array(repeating: "", count: setCount)
            item.dropSetPatternsBySet   = Array(repeating: "", count: setCount)

            for uiSet in uiExercise.sets {
                let idx = uiSet.index - 1
                guard idx >= 0 && idx < setCount else { continue }

                // Planned
                item.plannedRepsBySet[idx]  = uiSet.plannedReps
                item.plannedLoadsBySet[idx] = uiSet.plannedLoad
                item.plannedRIRsBySet[idx]  = uiSet.plannedRIR ?? item.targetRIR

                // Actuals (only persist meaningful values)
                if let reps = uiSet.actualReps, reps > 0 {
                    item.actualReps[idx] = reps
                    // Persist load even if 0 when reps exist (BW/no-load work)
                    item.actualLoads[idx] = uiSet.actualLoad ?? 0
                }
                if let rir = uiSet.actualRIR, rir >= 0 {
                    item.actualRIRs[idx] = rir
                }

                // RP tracking (persist regardless of whether actuals exist)
                item.usedRestPauseFlags[idx] = uiSet.usedRestPause

                // Skip encoding takes priority; otherwise store the RP pattern text
                if uiSet.status == .skipped {
                    item.restPausePatternsBySet[idx] = "SKIP"
                } else {
                    item.restPausePatternsBySet[idx] = uiSet.restPausePattern
                    // Drop set tracking
                    item.dropSetPatternsBySet[idx] = uiSet.usedDropSet ? uiSet.dropSetPattern : ""
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

        // ✅ Plan Memory v1 – only carry plans forward once the session is completed.
        if session.status == .completed {
            let planMemory = PlanMemoryEngine(context: context)
            planMemory.carryForwardPlans(from: session)
        }

        do {
            try context.save()
        } catch {
            print("⚠️ Failed to save session: \(error)")
        }
    }

    private func currentExposure(
        for exercise: UISessionExercise,
        recentSet: UISessionSet
    ) -> ExerciseExposure? {
        let reps = recentSet.actualReps ?? recentSet.plannedReps
        let load = recentSet.actualLoad ?? recentSet.plannedLoad
        let rir = recentSet.actualRIR ?? recentSet.plannedRIR

        guard reps > 0 else { return nil }

        return ExerciseExposure(
            date: session.date,
            waveRaw: exercise.waveRaw,
            repMin: exercise.repMin,
            repMax: exercise.repMax,
            rirMin: exercise.targetRIRMin,
            rirMax: exercise.targetRIRMax,
            load: load,
            reps: reps,
            rir: rir
        )
    }

    private func priorExposures(
        for exercise: UISessionExercise,
        context: ModelContext
    ) -> [ExerciseExposure] {
        let allSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []

        let sourceMesoID = session.meso?.persistentModelID

        func sameBlock(_ other: Session) -> Bool {
            switch (sourceMesoID, other.meso?.persistentModelID) {
            case let (lhs?, rhs?):
                return lhs == rhs
            case (nil, nil):
                return true
            default:
                return false
            }
        }

        var exposures: [ExerciseExposure] = []

        for other in allSessions {
            guard other.date < session.date else { continue }
            guard sameBlock(other) else { continue }

            guard let item = other.items.first(where: { $0.exerciseId == exercise.exerciseId }) else {
                continue
            }

            let workingSetCount = max(1, min(item.targetSets, max(
                item.actualReps.count,
                item.actualLoads.count,
                item.actualRIRs.count
            )))

            var best: ExerciseExposure?

            for idx in 0..<workingSetCount {
                let reps = (idx < item.actualReps.count) ? item.actualReps[idx] : 0
                guard reps > 0 else { continue }

                let load = (idx < item.actualLoads.count) ? item.actualLoads[idx] : 0
                let rir: Int? = {
                    guard idx < item.actualRIRs.count else { return nil }
                    let raw = item.actualRIRs[idx]
                    return raw >= 0 ? raw : nil
                }()

                let exposure = ExerciseExposure(
                    date: other.date,
                    waveRaw: item.waveRaw,
                    repMin: item.repMin,
                    repMax: item.repMax,
                    rirMin: item.targetRIRMin,
                    rirMax: item.targetRIRMax,
                    load: load,
                    reps: reps,
                    rir: rir
                )

                if let existing = best {
                    if load > existing.load || (load == existing.load && reps > existing.reps) {
                        best = exposure
                    }
                } else {
                    best = exposure
                }
            }

            if let best {
                exposures.append(best)
            }
        }

        return exposures
    }

    private func comparisonNote(
        for exercise: UISessionExercise,
        recentSet: UISessionSet,
        context: ModelContext
    ) -> String? {
        guard let current = currentExposure(for: exercise, recentSet: recentSet) else { return nil }

        let prior = priorExposures(for: exercise, context: context)
        guard let reference = WaveAwareComparisonEngine.bestReference(current: current, prior: prior) else {
            return nil
        }

        let ref = reference.exposure
        let waveText = WaveAwareComparisonEngine.displayWave(ref.waveRaw) ?? "Closest match"
        let dateText = ref.date.formatted(date: .numeric, time: .omitted)

        let loadDelta = current.load - ref.load
        let repsDelta = current.reps - ref.reps

        let loadDeltaText: String = {
            if abs(loadDelta) < 0.1 { return "same load" }
            if loadDelta > 0 { return "+\(Int(loadDelta.rounded())) lb" }
            return "\(Int(loadDelta.rounded())) lb"
        }()

        let repsDeltaText: String = {
            if repsDelta == 0 { return "same reps" }
            if repsDelta > 0 { return "+\(repsDelta) reps" }
            return "\(repsDelta) reps"
        }()

        var refLine = "\(waveText) reference (\(dateText)): \(formatLoad(ref.load)) × \(ref.reps)"
        if let rir = ref.rir {
            refLine += " @ \(rir) RIR"
        }

        return "\(refLine). Delta: \(loadDeltaText), \(repsDeltaText)."
    }
    private func withComparison(_ base: String, comparison: String?) -> String {
        guard let comparison, !comparison.isEmpty else { return base }
        return "\(base) \(comparison)"
    }
    // MARK: - Plan vs Actual Coaching Logic (legacy)

    // LEGACY DISPLAY PATH — FROZEN
    // This is the current user-visible coaching authority but is scheduled
    // for removal after CoachingEngine message seam is live and tested.
    // Do not modify. Do not add cases. Do not extend.
    // Replacement: CoachingEngine.recommend(for:).message via handleSetLogged
    
    private func coachMessage(
        for exercise: UISessionExercise,
        recentSetIndex: Int,
        context: ModelContext
    ) -> String {
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

        let comparison = comparisonNote(
            for: exercise,
            recentSet: recentSet,
            context: context
        )

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

                    return withComparison(
                        "Set \(recentSet.index): You had far more than needed at \(loadString) × \(actualReps). Use this as a baseline. Next time, pick a weight where your hardest working set lands around \(targetLow)–\(targetHigh) solid reps, not 20+.",
                        comparison: comparison
                    )
                }

                let lower = max(plannedReps + 1, actualReps - 3)
                let upper = actualReps

                let heavierLoad = nextLoadSuggestion(for: recentSet, outcome: .exceededPlan)
                let heavierLoadString = formatLoad(heavierLoad)

                if lower < upper {
                    return withComparison(
                        "Set \(recentSet.index): Plan was too easy at \(loadString) × \(actualReps). Next time, set your plan around \(loadString) × \(lower)–\(upper), or bump to \(heavierLoadString) × \(plannedReps)–\(lower) if that still feels smooth.",
                        comparison: comparison
                    )
                } else {
                    return withComparison(
                        "Set \(recentSet.index): Plan was too easy at \(loadString) × \(actualReps). Next time, either repeat \(loadString) × \(actualReps) or try \(heavierLoadString) × \(plannedReps)–\(actualReps).",
                        comparison: comparison
                    )
                }
            }

            if planTooHard {
                return withComparison(
                    "Set \(recentSet.index): Plan overshot today at \(loadString) × \(actualReps). Next time, set your plan around \(easierPlanString) × \(plannedReps) or keep load and aim for fewer reps.",
                    comparison: comparison
                )
            }

            switch outcome {
            case .matchedPlan:
                return withComparison(
                    "Set \(recentSet.index): On target at \(loadString) × \(plannedReps). Next set: repeat \(loadString) × \(plannedReps).",
                    comparison: comparison
                )
            case .exceededPlan:
                return withComparison(
                    "Set \(recentSet.index): You beat your plan at \(loadString) × \(actualReps). Next set: stay at \(loadString) and aim to hold or add a rep.",
                    comparison: comparison
                )
            case .fellShort:
                return withComparison(
                    "Set \(recentSet.index): You fell short of plan (\(actualReps) vs \(plannedReps)). Next set: stay at \(loadString) and aim to match \(plannedReps). If this repeats next session, drop to \(nextLoadString).",
                    comparison: comparison
                )
            }

        case 4:
            if planTooEasy {
                if plannedLoad == 0 {
                    let targetLow = max(6, plannedReps)
                    let targetHigh = targetLow + 2

                    return withComparison(
                        "Test set (Set 4): This blew past a normal working set at \(loadString) × \(actualReps). Treat it as a scouting set. Next session, choose a load where your toughest set lands around \(targetLow)–\(targetHigh) clean reps and use that as your baseline.",
                        comparison: comparison
                    )
                }

                let lower = max(plannedReps + 1, actualReps - 3)
                let upper = actualReps

                let heavierLoad = nextLoadSuggestion(for: recentSet, outcome: .exceededPlan)
                let heavierLoadString = formatLoad(heavierLoad)

                if lower < upper {
                    return withComparison(
                        "Test set (Set 4): Plan was clearly too easy at \(loadString) × \(actualReps). Next session, set your baseline around \(loadString) × \(lower)–\(upper), or try \(heavierLoadString) × \(plannedReps)–\(lower) if recovery and bar speed are strong.",
                        comparison: comparison
                    )
                } else {
                    return withComparison(
                        "Test set (Set 4): Plan was clearly too easy at \(loadString) × \(actualReps). Next session, either repeat \(loadString) × \(actualReps) or push to \(heavierLoadString) × \(plannedReps)–\(actualReps) as your new baseline.",
                        comparison: comparison
                    )
                }
            }

            if planTooHard {
                return withComparison(
                    "Test set (Set 4): Plan overshot at \(loadString) × \(actualReps). Next session, set your plan around \(easierPlanString) × \(plannedReps) so you’re not grinding every set.",
                    comparison: comparison
                )
            }

            switch outcome {
            case .matchedPlan, .exceededPlan:
                return withComparison(
                    "Test set (Set 4): Strong at \(loadString) × \(plannedReps) for \(actualReps) reps. Next session: try \(nextLoadString) × \(plannedReps) if recovery is solid.",
                    comparison: comparison
                )
            case .fellShort:
                return withComparison(
                    "Test set (Set 4): Right at the edge (\(actualReps) vs \(plannedReps)). Next session: hold at \(loadString) × \(plannedReps) or drop to \(nextLoadString) if fatigue stays high.",
                    comparison: comparison
                )
            }

        default:
            switch outcome {
            case .matchedPlan:
                return withComparison(
                    "Set \(recentSet.index): Solid extra work at \(loadString) × \(plannedReps). Don’t chase fatigue—shut it down if performance slips.",
                    comparison: comparison
                )
            case .exceededPlan:
                return withComparison(
                    "Set \(recentSet.index): Over-delivering at \(loadString) × \(actualReps). Make sure this doesn’t compromise your next session.",
                    comparison: comparison
                )
            case .fellShort:
                return withComparison(
                    "Set \(recentSet.index): Fatigue is showing at \(loadString). This is bonus volume—better to stop than force junk reps.",
                    comparison: comparison
                )
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
        var exerciseSummaries: [SessionRecapExercise] = []
        exerciseSummaries.reserveCapacity(exercises.count)

        for exercise in exercises {
            let catalog = ExerciseCatalog.all.first(where: { $0.id == exercise.exerciseId })
            let primary = catalog?.primaryMuscle.rawValue.capitalized

            var setsCompleted = 0
            var totalRepsForExercise = 0
            var totalVolume: Double = 0
            var lastRIR: Int? = nil
            var topE1RM: Double? = nil

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

                // Epley e1RM estimate for this set
                if load > 0 && reps > 0 {
                    let e1 = load * (1.0 + Double(reps) / 30.0)
                    if let currentTop = topE1RM {
                        if e1 > currentTop {
                            topE1RM = e1
                        }
                    } else {
                        topE1RM = e1
                    }
                }
            }

            let summary = SessionRecapExercise(
                name: exercise.name,
                primaryMuscle: primary,
                sets: setsCompleted,
                reps: totalRepsForExercise,
                volume: totalVolume,
                lastSetRIR: lastRIR,
                topE1RM: topE1RM
            )

            exerciseSummaries.append(summary)
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
        
        let dayLabelSnapshot = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDayLabelSnapshot = (dayLabelSnapshot?.isEmpty == false) ? dayLabelSnapshot : nil

        let mesoBlockId = session.meso?.id
        let mesoBlockNameSnapshot = session.meso?.name

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
            existingHistory.dayLabelSnapshot = normalizedDayLabelSnapshot
            existingHistory.exercises = historyExercises
            existingHistory.mesoBlockId = mesoBlockId
            existingHistory.mesoBlockNameSnapshot = mesoBlockNameSnapshot
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
                dayLabelSnapshot: normalizedDayLabelSnapshot,
                mesoBlockId: mesoBlockId,
                mesoBlockNameSnapshot: mesoBlockNameSnapshot,
                exercises: historyExercises
            )

            context.insert(history)
        }

        try context.save()
        print("✅ SessionHistory saved/updated")
        // ✅ Link Apple Health workout + pull metrics after completion is saved.
        Task { @MainActor in
            await HealthKitWorkoutSummarySyncService
                .syncForCompletedSession(session, in: context)
        }
    }
} // ← closes SessionScreenViewModel

// MARK: - Integration with real Session model

extension SessionScreenViewModel {
    convenience init(session: Session) {
        let title = session.date.formatted(date: .abbreviated, time: .omitted)
        let subtitle = session.weekDayLabel
        let items = session.items.sorted { $0.order < $1.order }

        let exercises: [UISessionExercise] = items.map { item in
            let catalogExercise = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
            let name = {
                if let snapshot = item.exerciseNameSnapshot?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !snapshot.isEmpty {
                    return snapshot
                }
                return catalogExercise?.name ?? ExerciseCatalog.displayName(for: item.exerciseId)
            }()

            // Clamp to 3–4 working sets for now
            let targetSets = max(1, min(item.targetSets, 6))
            let baseReps = item.targetReps
            let baseLoad = item.suggestedLoad
            let baseRIR = item.targetRIR

            // We currently support up to 4 sets in the logger UI
            let setCount = max(4, targetSets)   // keeps “3-to-grow, 1-to-know” UI baseline
            var uiSets: [UISessionSet] = []
            uiSets.reserveCapacity(setCount)

            for idx in 0..<setCount {
                let setIndex = idx + 1
                let isPlannedWorkingSet = setIndex <= targetSets

                // ---- Planned values ----
                let plannedReps: Int = {
                    if idx < item.plannedRepsBySet.count, item.plannedRepsBySet[idx] > 0 {
                        return item.plannedRepsBySet[idx]
                    } else {
                        return baseReps
                    }
                }()

                let plannedLoad: Double = {
                    if idx < item.plannedLoadsBySet.count, item.plannedLoadsBySet[idx] > 0 {
                        return item.plannedLoadsBySet[idx]
                    } else {
                        return isPlannedWorkingSet ? baseLoad : 0.0
                    }
                }()

                let plannedRIR: Int? = {
                    if idx < item.plannedRIRsBySet.count {
                        return item.plannedRIRsBySet[idx]
                    }
                    return baseRIR
                }()

                // ---- Actual values (read back from SwiftData) ----
                let actualReps: Int? = {
                    if idx < item.actualReps.count, item.actualReps[idx] > 0 {
                        return item.actualReps[idx]
                    }
                    return nil
                }()

                let actualLoad: Double? = {
                    guard idx < item.actualLoads.count else { return nil }
                    let stored = item.actualLoads[idx]
                    if stored > 0 { return stored }
                    // If reps exist, allow BW/no-load work to be represented as 0
                    if stored == 0, actualReps != nil { return 0 }
                    return nil
                }()

                let actualRIR: Int? = {
                    guard idx < item.actualRIRs.count else { return nil }

                    // Only treat actual RIR as real if the set itself was actually logged.
                    guard actualReps != nil || actualLoad != nil else { return nil }

                    let stored = item.actualRIRs[idx]
                    return stored > 0 ? stored : nil
                }()

                // ---- RP flags/patterns ----
                let rpUsed: Bool = {
                    if idx < item.usedRestPauseFlags.count { return item.usedRestPauseFlags[idx] }
                    return false
                }()

                let rpPatternRaw: String = {
                    if idx < item.restPausePatternsBySet.count { return item.restPausePatternsBySet[idx] }
                    return ""
                }()

                let isSkipped = (rpPatternRaw == "SKIP")
                let rpPattern = isSkipped ? "" : rpPatternRaw
                // ---- Drop set flags/patterns ----
                let dropUsed: Bool = {
                    if idx < item.dropSetPatternsBySet.count {
                        return !item.dropSetPatternsBySet[idx].isEmpty
                    }
                    return false
                }()

                let dropPattern: String = {
                    if idx < item.dropSetPatternsBySet.count { return item.dropSetPatternsBySet[idx] }
                    return ""
                }()

                // ---- Status ----
                let status: SetStatus
                if isSkipped {
                    status = .skipped
                } else if let reps = actualReps, reps > 0 {
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
                        status: status,
                        usedRestPause: rpUsed,
                        restPausePattern: rpPattern,
                        usedDropSet: dropUsed,
                        dropSetPattern: dropPattern
                    )
                )
            }

            let detail: String

            let setsText = "\(item.targetSets) sets"
            let repsText = "\(baseReps) reps"
            let rirText = "\(baseRIR) RIR"

            if let ce = catalogExercise {
                detail = "Week \(session.weekIndex) · \(ce.primaryMuscle.rawValue.capitalized) · \(setsText) · \(repsText) · \(rirText)"
            } else {
                detail = "Week \(session.weekIndex) · \(setsText) · \(repsText) · \(rirText)"
            }

            return UISessionExercise(
                exerciseId: item.exerciseId,
                name: name,
                detail: detail,
                weekInMeso: session.weekIndex,

                waveRaw: item.waveRaw,
                priorityRaw: item.priorityRaw,
                setMin: item.setMin,
                setMax: item.setMax,
                repMin: item.repMin,
                repMax: item.repMax,
                targetRIRMin: item.targetRIRMin,
                targetRIRMax: item.targetRIRMax,
                intensifierRaw: item.intensifierRaw,
                intensifierNotes: item.intensifierNotes,
                prescriptionNotes: item.prescriptionNotes,

                targetSets: item.targetSets,
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
    let id: UUID

    var exerciseId: String
    var name: String
    var detail: String

    var weekInMeso: Int

    var weekIndex: Int {
        get { weekInMeso }
        set { weekInMeso = newValue }
    }

    var waveRaw: String?
    var priorityRaw: String?

    var setMin: Int?
    var setMax: Int?
    var repMin: Int?
    var repMax: Int?
    var targetRIRMin: Int?
    var targetRIRMax: Int?
    var intensifierRaw: String?
    var intensifierNotes: String?
    var prescriptionNotes: String?

    var targetSets: Int
    var sets: [UISessionSet]
    var coachMessage: String

    var setsText: String {
        if let min = setMin, let max = setMax {
            return min == max ? "\(min) sets" : "\(min)–\(max) sets"
        }
        return "\(targetSets) sets"
    }

    var repsText: String {
        if let min = repMin, let max = repMax {
            return min == max ? "\(min) reps" : "\(min)–\(max) reps"
        }
        if let first = sets.first { return "\(first.plannedReps) reps" }
        return "—"
    }

    var rirText: String {
        if let min = targetRIRMin, let max = targetRIRMax {
            return min == max ? "\(min) RIR" : "\(min)–\(max) RIR"
        }
        if let first = sets.first, let rir = first.plannedRIR { return "\(rir) RIR" }
        return "—"
    }

    var prescriptionDetailLine: String {
        "Week \(weekIndex) · \(setsText) · \(repsText) · \(rirText)"
    }

    var isComplete: Bool {
        let workingSets = sets.filter { $0.index <= targetSets }
        guard !workingSets.isEmpty else { return false }
        return workingSets.allSatisfy { $0.status == .completed || $0.status == .skipped }
    }

    init(
        exerciseId: String,
        name: String,
        detail: String,
        weekInMeso: Int,
        waveRaw: String? = nil,
        priorityRaw: String? = nil,
        setMin: Int? = nil,
        setMax: Int? = nil,
        repMin: Int? = nil,
        repMax: Int? = nil,
        targetRIRMin: Int? = nil,
        targetRIRMax: Int? = nil,
        intensifierRaw: String? = nil,
        intensifierNotes: String? = nil,
        prescriptionNotes: String? = nil,
        targetSets: Int,
        sets: [UISessionSet],
        coachMessage: String = ""
    ) {
        // Derive a stable UUID from exerciseId so ForEach identity is consistent
        // across republishes of viewModel.exercises.
        self.id = UUID(uuidString: exerciseId) ?? {
            var hash = exerciseId.utf8.reduce(UInt64(14695981039346656037)) { acc, byte in
                (acc ^ UInt64(byte)) &* 1099511628211
            }
            let a = UInt32(hash & 0xFFFFFFFF)
            let b = UInt32((hash >> 32) & 0xFFFFFFFF)
            return UUID(uuid: (
                UInt8(a & 0xFF), UInt8((a >> 8) & 0xFF),
                UInt8((a >> 16) & 0xFF), UInt8((a >> 24) & 0xFF),
                UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF),
                0x40 | UInt8((b >> 16) & 0x0F), UInt8((b >> 24) & 0xFF),
                0x80 | UInt8(a & 0x3F), UInt8((a >> 8) & 0xFF),
                UInt8((a >> 16) & 0xFF), UInt8((a >> 24) & 0xFF),
                UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF),
                UInt8((b >> 16) & 0xFF), UInt8((b >> 24) & 0xFF)
            ))
        }()

        self.exerciseId = exerciseId
        self.name = name
        self.detail = detail
        self.weekInMeso = weekInMeso
        self.waveRaw = waveRaw
        self.priorityRaw = priorityRaw
        self.setMin = setMin
        self.setMax = setMax
        self.repMin = repMin
        self.repMax = repMax
        self.targetRIRMin = targetRIRMin
        self.targetRIRMax = targetRIRMax
        self.intensifierRaw = intensifierRaw
        self.intensifierNotes = intensifierNotes
        self.prescriptionNotes = prescriptionNotes
        self.targetSets = max(1, min(targetSets, 6))
        self.sets = sets.sorted { $0.index < $1.index }
        self.coachMessage = coachMessage
    }
}
struct UISessionSet: Identifiable {
    var id: Int { index }
    let index: Int

    var plannedLoad: Double
    var plannedReps: Int
    let plannedRIR: Int?

    var actualLoad: Double?
    var actualReps: Int?
    var actualRIR: Int?

    var status: SetStatus
    var usedRestPause: Bool
    var restPausePattern: String
    var usedDropSet: Bool
    var dropSetPattern: String  // format: "120x12,100x8" — empty if no drop set

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
        status: SetStatus = .notStarted,
        usedRestPause: Bool = false,
        restPausePattern: String = "",
        usedDropSet: Bool = false,
        dropSetPattern: String = ""
    ) {
        self.index = index
        self.plannedLoad = plannedLoad
        self.plannedReps = plannedReps
        self.plannedRIR = plannedRIR
        self.actualLoad = actualLoad
        self.actualReps = actualReps
        self.actualRIR = actualRIR
        self.status = status
        self.usedRestPause = usedRestPause
        self.restPausePattern = restPausePattern
        self.usedDropSet = usedDropSet
        self.dropSetPattern = dropSetPattern
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
    func plannedDescription(with repRange: RepRange) -> String {
        if plannedLoad == 0 && plannedReps == 0 { return "—" }

        let loadText: String
        if plannedLoad == 0 {
            loadText = "0.0"
        } else {
            loadText = String(format: "%.1f", plannedLoad)
        }

        if let plannedRIR {
            return "\(loadText) × \(plannedReps) @ \(plannedRIR) RIR"
        } else {
            return "\(loadText) × \(plannedReps)"
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

    /// Best estimated 1RM across all exercises (top set only).
    var bestE1RM: Double? {
        exercises.compactMap { $0.topE1RM }.max()
    }
}

struct SessionRecapExercise: Identifiable {
    let id = UUID()
    let name: String
    let primaryMuscle: String?
    let sets: Int
    let reps: Int
    let volume: Double
    let lastSetRIR: Int?
    let topE1RM: Double?
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

    private func e1RMString(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f", value)
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
                                        if let top = ex.topE1RM {
                                            Text("e1RM: \(e1RMString(top))")
                                        }
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

            // Top row
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

            if let best = recap.bestE1RM {
                HStack {
                    Text("Best est. 1RM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(e1RMString(best))
                        .font(.caption)
                }
            }

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

// MARK: - Exercise History Sheet (per exercise)



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

            waveRaw: nil,
            priorityRaw: nil,
            setMin: nil,
            setMax: nil,
            repMin: nil,
            repMax: nil,
            targetRIRMin: nil,
            targetRIRMax: nil,
            intensifierRaw: nil,
            intensifierNotes: nil,
            prescriptionNotes: nil,

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

// MARK: - Bottom Complete Bar (UI-only)

private struct SessionCompleteBar: View {
    let isEnabled: Bool
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Divider()

            Button(action: onComplete) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Complete")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(isEnabled ? Color.green : Color.gray.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!isEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
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
