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
    @AppStorage(AppStateBridge.warmupHiddenKey) private var isWarmupHidden = false
    // Unified sheet state (swap / recap / history / note / add)
    @State private var activeSheet: ActiveSheet?
    @State private var pendingAddedExerciseForPropagation: (exerciseId: String, exerciseName: String)?
    @State private var showAddExercisePropagationDialog = false
    /// "Last A: 315 x 5, 6, 5, 5" per exerciseId — computed once when the screen loads.
    @State private var lastLetterCaptions: [String: String] = [:]

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
                                rounding: warmupRounding(for: first.name),
                                unit: warmupUnit
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
                        lastLetterCaption: lastLetterCaptions[exercise.exerciseId],
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
                        onDropSetLoadChanged: { [exerciseId = exercise.id] setIndex, dropIndex, text in
                            viewModel.updateDropSetLoad(
                                exerciseID: exerciseId,
                                setIndex: setIndex,
                                dropIndex: dropIndex,
                                text: text
                            )
                        },
                        onDropSetRepsChanged: { [exerciseId = exercise.id] setIndex, dropIndex, text in
                            viewModel.updateDropSetReps(
                                exerciseID: exerciseId,
                                setIndex: setIndex,
                                dropIndex: dropIndex,
                                text: text
                            )
                        },
                        onDropSetAdded: { [exerciseId = exercise.id] setIndex in
                            viewModel.addDropSet(
                                exerciseID: exerciseId,
                                setIndex: setIndex
                            )
                        },
                        onLogTapped: { setIndex in
                            viewModel.handleSetLogged(
                                exerciseID: exercise.id,
                                setIndex: setIndex,
                                context: modelContext
                            )
                        },
                        onSkipTapped: { setIndex, reason in
                                                    viewModel.skipSet(
                                                        exerciseID: exercise.id,
                                                        setIndex: setIndex,
                                                        reason: reason,
                                                        context: modelContext
                                                    )
                                                },
                                                onPumpRated: { setIndex, rating in
                                                    viewModel.setPumpRating(
                                                        exerciseID: exercise.id,
                                                        setIndex: setIndex,
                                                        rating: rating,
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
                        },
                        onBodyweightSettingsTapped: {
                            activeSheet = .settings
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
                    let recap = viewModel.buildRecap(using: modelContext)
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
                        let recap = viewModel.buildRecap(using: modelContext)
                        activeSheet = .recap(recap)
                    }
                )
            }
        }
        .onAppear {
            disableIdleTimerIfNeeded()
            viewModel.refreshFromSession()
            // Once per appearance (not per body evaluation): history is fixed while the screen is open.
            lastLetterCaptions = viewModel.lastLetterCaptions(context: modelContext)
        }
        .onDisappear(perform: restoreIdleTimerIfNeeded)
        .onChange(of: isWarmupHidden) { hidden in
            AppStateBridge.setWarmupHidden(hidden, in: modelContext)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                viewModel.refreshFromSession()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetView(for: sheet)
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
                    viewModel.swapExercise(at: target.exerciseIndex, with: catalogExercise, context: modelContext)
                    viewModel.persist(using: modelContext)
                    activeSheet = nil
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
                            currentWave: viewModel.currentWaveLabel,
                            onClose: { activeSheet = nil }
                        )
                        .presentationDetents([.large])
                        .presentationDragIndicator(.hidden)

        case .note(let exerciseId, let exerciseName):
            ExerciseNoteSheet(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                onClose: { activeSheet = nil }
            )

        case .settings:
            SettingsView()
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

    /// The lifter's unit, for the warm-up ramp rounding.
    private var warmupUnit: LoadUnit {
        (try? modelContext.fetch(FetchDescriptor<UserProfile>()).first?.loadUnit) ?? .lb
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

                Text(completionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                activeSheet = .recap(viewModel.buildRecap(using: modelContext))
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
    private var completionSubtitle: String {
        let allExercises = viewModel.exercises
        let totalPlanned = allExercises.reduce(0) { $0 + $1.targetSets + $1.topCount }
        let totalCompleted = allExercises.reduce(0) { total, ex in
            total + ex.sets.filter { ex.isPlannedRow($0) && $0.status == .completed }.count
        }
        let totalSkipped = allExercises.reduce(0) { total, ex in
            total + ex.sets.filter { ex.isPlannedRow($0) && $0.status.isAnySkip }.count
        }

        if totalSkipped == 0 {
            return "All \(totalPlanned) planned sets logged. Nice work."
        } else if totalCompleted == 0 {
            return "\(totalSkipped) set\(totalSkipped == 1 ? "" : "s") skipped."
        } else {
            return "\(totalCompleted) of \(totalPlanned) sets logged, \(totalSkipped) skipped."
        }
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
    case settings

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
        case .settings:
            return "settings"
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
    @Query private var profiles: [UserProfile]
    let exercise: UISessionExercise
    /// Last same-letter performance caption; nil hides the line.
    let lastLetterCaption: String?

    let onLoadChanged: (_ setIndex: Int, _ text: String) -> Void
    let onRepsChanged: (_ setIndex: Int, _ text: String) -> Void
    let onRIRChanged: (_ setIndex: Int, _ text: String) -> Void
    let onRPToggled: (_ setIndex: Int, _ isOn: Bool) -> Void
    let onRPPatternChanged: (_ setIndex: Int, _ text: String) -> Void
    let onDropSetToggled: (_ setIndex: Int, _ isOn: Bool) -> Void
    let onDropSetLoadChanged: (_ setIndex: Int, _ dropIndex: Int, _ text: String) -> Void
    let onDropSetRepsChanged: (_ setIndex: Int, _ dropIndex: Int, _ text: String) -> Void
    let onDropSetAdded: (_ setIndex: Int) -> Void

    let onLogTapped: (_ setIndex: Int) -> Void
    let onSkipTapped: (_ setIndex: Int, _ reason: SetFeedback) -> Void
    let onPumpRated: (_ setIndex: Int, _ rating: PumpRating) -> Void
    let onEditTapped: (_ setIndex: Int) -> Void

    let onSwapTapped: () -> Void
    let onHistoryTapped: () -> Void
    let onNoteTapped: () -> Void
    let onAddSetTapped: () -> Void
    let onBodyweightSettingsTapped: () -> Void

    // MARK: - Coach v5 (ProgressionEngine) helpers

    private var isBodyweightExercise: Bool {
        let descriptor = FetchDescriptor<CustomExercise>()
        let customExercises = (try? modelContext.fetch(descriptor)) ?? []
        return ExerciseCatalog.isBodyweight(exerciseId: exercise.exerciseId, customExercises: customExercises)
    }

    private var userProfile: UserProfile? {
        let descriptor = FetchDescriptor<UserProfile>()
        return try? modelContext.fetch(descriptor).first
    }

    private var repRange: RepRange {
        if let min = exercise.repMin, let max = exercise.repMax {
            return RepRange(min: min, max: max)
        }
        return RepRangeRulebook.range(
            forExerciseId: exercise.exerciseId,
            exerciseName: exercise.name
        )
    }

    private var topRepRange: RepRange {
        if let lo = exercise.topRepMin, let hi = exercise.topRepMax { return RepRange(min: lo, max: max(lo, hi)) }
        return repRange
    }

    private var todayDetailLine: String {
        let parts = exercise.detail.components(separatedBy: " · ")

        let weekText = parts.indices.contains(0) ? parts[0] : "Week \(exercise.weekIndex)"
        let muscleText = parts.indices.contains(1) ? parts[1] : nil
        let setsText = "\(exercise.targetSets) sets"

        // Key on the wave-correct rep range (repMin/repMax), not plannedReps/targetReps
        // which can be stale from a prior wave's carry-forward. Flag the top as the goal.
        let repsText: String
        if repRange.min != repRange.max {
            repsText = "\(repRange.min)–\(repRange.max) reps · goal \(repRange.max)"
        } else {
            repsText = "\(repRange.min) reps"
        }

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
        NoteFields(intensifier: exercise.intensifierNotes, prescription: exercise.prescriptionNotes).displayed
    }

    private func shouldShowSet(_ set: UISessionSet) -> Bool {
        if exercise.isPlannedRow(set) {
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

                    if let lastLetterCaption {
                        Text(lastLetterCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if UserProfile.isProgressionExempt(exerciseId: exercise.exerciseId, profile: profiles.first) {
                        Text("Fixed load")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                    }

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
                ForEach(exercise.displaySets) { set in
                    if shouldShowSet(set) {
                        SessionSetRowView(
                            uiSet: set,
                            repRange: set.isTop ? topRepRange : repRange,
                            isExtraSet: set.index > exercise.targetSets && !set.isTop,
                            isBodyweightExercise: isBodyweightExercise,
                            bodyWeight: userProfile?.bodyWeight,
                            onBodyweightSettingsTapped: onBodyweightSettingsTapped,
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
                            onDropSetLoadChanged: { dropIndex, text in
                                onDropSetLoadChanged(set.index, dropIndex, text)
                            },
                            onDropSetRepsChanged: { dropIndex, text in
                                onDropSetRepsChanged(set.index, dropIndex, text)
                            },
                            onDropSetAdded: {
                                onDropSetAdded(set.index)
                            },
                            onLog: {
                                onLogTapped(set.index)
                            },
                            onSkip: { reason in
                                                            onSkipTapped(set.index, reason)
                                                        },
                                                        onPumpRated: { rating in
                                                            onPumpRated(set.index, rating)
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
    @Environment(\.loadUnit) private var unit
    let uiSet: UISessionSet
    let repRange: RepRange
    /// A row past the planned set count: shown as an extra set, with no suggested load.
    var isExtraSet: Bool = false
    let isBodyweightExercise: Bool
    let bodyWeight: Double?
    let onBodyweightSettingsTapped: () -> Void

    let onLoadChanged: (String) -> Void
    let onRepsChanged: (String) -> Void
    let onRIRChanged: (String) -> Void
    let onRPToggled: (Bool) -> Void
    let onRPPatternChanged: (String) -> Void
    let onDropSetToggled: (Bool) -> Void
    let onDropSetLoadChanged: (_ dropIndex: Int, _ text: String) -> Void
    let onDropSetRepsChanged: (_ dropIndex: Int, _ text: String) -> Void
    let onDropSetAdded: () -> Void


    let onLog: () -> Void
    let onSkip: (_ reason: SetFeedback) -> Void
    let onPumpRated: (_ rating: PumpRating) -> Void
    let onEdit: () -> Void
    
    private var isLocked: Bool {
            uiSet.status == .completed || uiSet.status.isAnySkip
        }

    private func formattedWeight(_ value: Double) -> String {
        LoadFormatter(unit: unit).compact(value)
    }



    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Top line: Set label + status chip (locked sets only)
            HStack {
                Text(uiSet.isTop ? "Top set" : "Set \(uiSet.index)")
                    .font(.caption)
                    .fontWeight(uiSet.isTop ? .semibold : .regular)
                    .foregroundStyle(uiSet.isTop ? Color.orange : Color.secondary)
                Spacer()
                if isLocked {
                                    if uiSet.status.isAnySkip {
                                        Text(uiSet.status.displayLabel)
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(uiSet.status.displayColor.opacity(0.2))
                                            .foregroundStyle(uiSet.status.displayColor)
                                            .clipShape(Capsule())
                                    } else {
                                        HStack(spacing: 4) {
                                            Text("Done")
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                            if uiSet.pumpRating != .none {
                                                Text("· \(uiSet.pumpRating.label) pump")
                                                    .font(.caption2)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundStyle(.green)
                                        .clipShape(Capsule())
                                    }
                                }
            }

            // PLAN / SUGGESTED line
            Text(isExtraSet
                 ? UISessionSet.extraSetLabel(repRange: repRange, rir: uiSet.plannedRIR)
                 : "\(uiSet.isTop ? "TOP SET" : (uiSet.plannedLoad > 0 ? "SUGGESTED" : "PLAN")) \(uiSet.plannedDescription(with: repRange, isBodyweight: isBodyweightExercise))")
                .font(.caption)
                .foregroundStyle(!isExtraSet && uiSet.plannedLoad > 0 ? Color.blue.opacity(0.8) : Color.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            // ACTUAL inputs row
            HStack(alignment: .bottom, spacing: 8) {
                // Load
                VStack(alignment: .leading, spacing: 2) {
                    Text("Load")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if isBodyweightExercise {
                        if let bodyWeight, bodyWeight > 0 {
                            Text("BW (\(formattedWeight(bodyWeight)) \(unit.label))")
                                .font(.caption)
                                .fontWeight(.semibold)
                        } else {
                            Button(action: onBodyweightSettingsTapped) {
                                Text("BW — set in Settings")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
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
                                                        .foregroundStyle(.green)
                                                        .clipShape(Capsule())
                                                case _ where uiSet.status.isAnySkip:
                                                    Text(uiSet.status.displayLabel)
                                                        .font(.caption)
                                                        .fontWeight(.semibold)
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 6)
                                                        .background(uiSet.status.displayColor.opacity(0.2))
                                                        .foregroundStyle(uiSet.status.displayColor)
                                                        .clipShape(Capsule())
                                                default:
                                                    Text("Log")
                                                        .font(.caption)
                                                        .fontWeight(.semibold)
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 6)
                                                        .background(Color.blue.opacity(0.2))
                                                        .foregroundStyle(.blue)
                                                        .clipShape(Capsule())
                                                }
                    }
                    .buttonStyle(.plain)
                                        .contextMenu {
                                            if isLocked {
                                                Button("Edit set") { onEdit() }
                                            } else {
                                                Button("Skip") { onSkip(.none) }
                                                Button("Pain") { onSkip(.pain) }
                                                Button("Soreness") { onSkip(.soreness) }
                                                Button("Disruption") { onSkip(.disruption) }
                                                Button("Fatigue") { onSkip(.fatigue) }
                                            }
                                        }

                                        if uiSet.status == .completed {
                                            Menu {
                                                Button("Not rated") { onPumpRated(.none) }
                                                Divider()
                                                ForEach(PumpRating.allCases.filter { $0 != .none }, id: \.self) { rating in
                                                    Button(rating.label) { onPumpRated(rating) }
                                                }
                                            } label: {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "drop.fill")
                                                        .font(.caption2)
                                                    Text(uiSet.pumpRating == .none ? "Pump" : uiSet.pumpRating.label)
                                                        .font(.caption2)
                                                }
                                                .foregroundStyle(uiSet.pumpRating == .none ? Color.secondary : Color.blue)
                                            }
                                            .buttonStyle(.borderless)
                                        }

                                        Menu {
                                            Button("Skip") { onSkip(.none) }
                                            Divider()
                                            Button {
                                                onSkip(.pain)
                                            } label: {
                                                Label("Pain", systemImage: "exclamationmark.triangle.fill")
                                            }
                                            Button {
                                                onSkip(.soreness)
                                            } label: {
                                                Label("Soreness", systemImage: "flame.fill")
                                            }
                                            Button {
                                                onSkip(.disruption)
                                            } label: {
                                                Label("Disruption", systemImage: "bolt.slash.fill")
                                            }
                                            Button {
                                                onSkip(.fatigue)
                                            } label: {
                                                Label("Fatigue", systemImage: "zzz")
                                            }
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

            // Drop set inputs (shown when toggle is on)
            if uiSet.usedDropSet {
                VStack(spacing: 4) {
                    ForEach(Array(uiSet.dropSets.enumerated()), id: \.element.id) { dropIndex, drop in
                        HStack(spacing: 8) {
                            Text("Drop \(dropIndex + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Load")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("0", text: Binding(
                                    get: { drop.loadText },
                                    set: { onDropSetLoadChanged(dropIndex, $0) }
                                ))
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .disabled(isLocked)
                                .opacity(isLocked ? 0.6 : 1.0)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reps")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("0", text: Binding(
                                    get: { drop.repsText },
                                    set: { onDropSetRepsChanged(dropIndex, $0) }
                                ))
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 52)
                                .disabled(isLocked)
                                .opacity(isLocked ? 0.6 : 1.0)
                            }

                            Spacer()
                        }
                    }

                    if !isLocked && uiSet.dropSets.count < 3 {
                        Button {
                            onDropSetAdded()
                        } label: {
                            Label("Add Drop", systemImage: "plus.circle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                    }
                }
                .padding(.top, 4)
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
                } footer: {
                    Text(ReplaceExerciseModel.todayInSessionNote)
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
    let session: Session

    // UI state
    @Published var title: String
    @Published var subtitle: String
    @Published var exercises: [UISessionExercise]
    /// The lifter's unit. Every load in this model is stored lb; only the text fields are in this unit.
    var loadUnit: LoadUnit = .lb

    var currentWaveLabel: String? {
            let wave = session.items.compactMap({ $0.waveRaw }).first
            return WaveType.label(forRaw: wave, mesoName: session.meso?.name)
        }
    
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

    /// Read-only: the last same-letter performance caption for each exercise of this session.
    /// Fetches once; the lookup itself is the pure `LastSameLetterPerformance`.
    func lastLetterCaptions(context: ModelContext) -> [String: String] {
        let all = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        return LastSameLetterPerformance.captions(for: session, allSessions: all, customExercises: custom, unit: loadUnit)
    }

    // The app target builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, which makes this class
    // implicitly @MainActor and makes the compiler-synthesized deinit an ISOLATED deinit
    // (swift_task_deinitOnExecutor, reached through the iOS 17.6 back-deploy shim). Releasing the
    // last reference from a plain XCTest method then aborts the host (SIGABRT: "pointer being freed
    // was not allocated" in TaskLocal::StopLookupScope, via SessionScreenViewModel.__deallocating_deinit
    // -> swift_task_deinitOnExecutorMainActorBackDeploy). Verified with swiftc 6.4 at -target
    // ios17.6: implicit deinit and @MainActor emit 2 swift_task_deinitOnExecutor references; an
    // explicit `nonisolated deinit {}` emits 0. Nothing here needs the main actor on teardown (no
    // observers, timers or tasks; only stored values and the SwiftData model reference).
    nonisolated deinit {}

    func refreshFromSession() {
        let refreshed = SessionScreenViewModel(session: session)
        self.title = refreshed.title
        self.subtitle = refreshed.subtitle
        self.exercises = refreshed.exercises
        self.loadUnit = refreshed.loadUnit
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

        let parsedLoad = LoadInput.storedLb(from: set.actualLoadText, unit: loadUnit,
                                            currentStoredLb: set.actualLoad ?? set.plannedLoad)
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
                    
                    while matchingItem.dropSetPatternsBySet.count <= idx {
                        matchingItem.dropSetPatternsBySet.append("")
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
                    matchingItem.dropSetPatternsBySet[idx] = set.usedDropSet && !set.dropSets.isEmpty
                        ? set.dropSets.map { $0.serialized(unit: loadUnit) }.joined(separator: ",")
                        : ""

                    // Size the bump with the SAME inputs the write-back path
                    // (PlanMemoryEngine) uses, so the "increase earned → X" message
                    // equals the value written to the next session's plan. Previously
                    // this call omitted minLoadIncrement (falling to a base-scaled +5)
                    // and the project() data, while the write-back passed the profile's
                    // step (e.g. 2.5) + e1rm floor — two paths, two numbers.
                    let allSessionsForRec = (try? context.fetch(FetchDescriptor<Session>())) ?? []
                    let recProfile = try? context.fetch(FetchDescriptor<UserProfile>()).first
                    let recUnit = recProfile?.loadUnit ?? .lb
                    let recLoadIncrement = recProfile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: recUnit)
                    let recCustomExercises = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
                    let cleanCount = LoadProjectionService.consecutiveCleanCount(
                        exerciseId: matchingItem.exerciseId,
                        waveRaw: matchingItem.waveRaw,
                        repMin: matchingItem.repMin ?? matchingItem.targetReps,
                        allSessions: allSessionsForRec
                    )
                    // Project the SAME next session the write-back writes to, so the
                    // message's floor/peak/lastKnownLoad come from the TARGET wave —
                    // identical to PlanMemoryEngine's write. Falls back to the current
                    // item when no future session is materialized (the write-back
                    // no-ops then too, so there is nothing to disagree with).
                    let recResolvedTarget = PlanMemoryEngine.nextTargetItem(
                        for: matchingItem,
                        after: session,
                        in: allSessionsForRec
                    )
                    let recTargetItem = recResolvedTarget ?? matchingItem
                    // Tell CoachingEngine whether a target actually exists, so the
                    // message can name the week the load lands in — and say nothing
                    // numeric when this is the last session of its wave in the block.
                    // An edited, already-planned target is never written (propagate path), so
                    // the message says its plan stays as set instead of promising a number. An
                    // EMPTY target is seeded regardless of planEdited, so it still reads .exists.
                    let recCarryForwardTarget: CoachingEngine.CarryForwardTarget = {
                        guard let target = recResolvedTarget else { return .endOfChain }
                        let hasPlan = target.suggestedLoad != 0 || target.plannedLoadsBySet.contains { $0 != 0 }
                        return target.planEdited && hasPlan ? .existsEdited : .exists
                    }()
                    let recProjection = LoadProjectionService.project(
                        exerciseId: recTargetItem.exerciseId,
                        targetReps: recTargetItem.targetReps,
                        targetRIR: recTargetItem.targetRIR,
                        repMin: recTargetItem.repMin ?? recTargetItem.targetReps,
                        repMax: recTargetItem.repMax ?? recTargetItem.targetReps,
                        currentWaveRaw: recTargetItem.waveRaw,
                        allSessions: allSessionsForRec,
                        activeMesoSessionIDs: LoadProjectionService.activeMesoSessionIDs(from: context),
                        loadIncrement: recLoadIncrement,
                        unit: recUnit,
                        bodyWeight: recProfile?.bodyWeight,
                        customExercises: recCustomExercises
                    )
                    if let recommendation = CoachingEngine.recommend(
                        for: matchingItem,
                        minLoadIncrement: recLoadIncrement,
                        unit: recUnit,
                        mesoPhase: session.mesoPhase,
                        consecutiveCleanCount: cleanCount,
                        e1rmFloorLoad: recProjection?.e1rmFloorLoad,
                        peakE1RM: recProjection?.peakE1RM,
                        lastKnownLoad: recProjection?.lastLoad,
                        carryForwardTarget: recCarryForwardTarget,
                        isProgressionExempt: UserProfile.isProgressionExempt(
                            exerciseId: matchingItem.exerciseId,
                            profile: recProfile
                        ),
                        loadCap: CoachingEngine.LoadCap.resolve(
                            for: matchingItem, in: session, allSessions: allSessionsForRec,
                            profile: recProfile, customExercises: recCustomExercises
                        )
                    ) {
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
        } else if let value = LoadInput.storedLb(from: trimmed, unit: loadUnit,
                                                 currentStoredLb: exercises[exerciseIdx].sets[setIdx].actualLoad) {
            // nil = unreadable, or the text a stored load already displays as: no write (no drift).
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
        if isOn && exercises[exerciseIdx].sets[setIdx].dropSets.isEmpty {
            exercises[exerciseIdx].sets[setIdx].dropSets = [DropSetEntry()]
        } else if !isOn {
            exercises[exerciseIdx].sets[setIdx].dropSets = []
        }
    }

    func updateDropSetLoad(exerciseID: UUID, setIndex: Int, dropIndex: Int, text: String) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }
        guard dropIndex < exercises[exerciseIdx].sets[setIdx].dropSets.count else { return }
        exercises[exerciseIdx].sets[setIdx].dropSets[dropIndex].loadText = text
    }

    func updateDropSetReps(exerciseID: UUID, setIndex: Int, dropIndex: Int, text: String) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }
        guard dropIndex < exercises[exerciseIdx].sets[setIdx].dropSets.count else { return }
        exercises[exerciseIdx].sets[setIdx].dropSets[dropIndex].repsText = text
    }

    func addDropSet(exerciseID: UUID, setIndex: Int) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }
        guard exercises[exerciseIdx].sets[setIdx].dropSets.count < 3 else { return }
        exercises[exerciseIdx].sets[setIdx].dropSets.append(DropSetEntry())
    }
    
    func skipSet(exerciseID: UUID, setIndex: Int, reason: SetFeedback = .none, context: ModelContext) {
            guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }

            let status: SetStatus = {
                switch reason {
                case .pain: return .skippedPain
                case .soreness: return .skippedSoreness
                case .disruption: return .skippedDisruption
                case .fatigue: return .skippedFatigue
                case .none: return .skipped
                }
            }()

        exercises[exerciseIdx].sets[setIdx].status = status
        exercises[exerciseIdx].sets[setIdx].actualLoad = nil
        exercises[exerciseIdx].sets[setIdx].actualReps = nil
        exercises[exerciseIdx].sets[setIdx].actualRIR = nil
        exercises[exerciseIdx].sets[setIdx].usedRestPause = false
        exercises[exerciseIdx].sets[setIdx].restPausePattern = ""
        exercises[exerciseIdx].sets[setIdx].usedDropSet = false
        exercises[exerciseIdx].sets[setIdx].dropSets = []
        exercises[exerciseIdx].sets[setIdx].actualLoadText = "0"
        exercises[exerciseIdx].sets[setIdx].actualRepsText = "\(exercises[exerciseIdx].sets[setIdx].plannedReps)"

        persist(using: context)
    }
    
    func setPumpRating(exerciseID: UUID, setIndex: Int, rating: PumpRating, context: ModelContext) {
        guard let exerciseIdx = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        guard let setIdx = exercises[exerciseIdx].sets.firstIndex(where: { $0.index == setIndex }) else { return }
        exercises[exerciseIdx].sets[setIdx].pumpRating = rating
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
        exercises[exerciseIdx].sets[setIdx].dropSets = []
        // FIX B — pre-fill the actual-load field from the plan when re-editing a set.
        // The existing plannedLoad == 0 branch already yields "0" for a clean BW plan,
        // but that's incidental. Key on isBodyweight so a stray nonzero plannedLoad can
        // never pre-fill (and, if confirmed, re-pollute actuals) on a BW exercise —
        // mirrors the Cut 0 init logic. Loaded exercises keep the plan-copy behavior.
        let isBodyweight = ExerciseCatalog.isBodyweight(exerciseId: exercises[exerciseIdx].exerciseId)
        exercises[exerciseIdx].sets[setIdx].actualLoadText = (isBodyweight || exercises[exerciseIdx].sets[setIdx].plannedLoad == 0)
            ? "0"
            : LoadFormatter(unit: loadUnit).oneDecimal(exercises[exerciseIdx].sets[setIdx].plannedLoad)
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

        // With a top set the new back-off row goes BEFORE the top tail: every row past the planned
        // back-offs moves down one, so the top set keeps its role and its logged data.
        let hasTop = exercise.sets.contains(where: \.isTop)
        let nextIndex = hasTop ? exercise.targetSets + 1 : (exercise.sets.map(\.index).max() ?? 0) + 1
        if hasTop {
            for i in exercise.sets.indices where exercise.sets[i].index > exercise.targetSets {
                exercise.sets[i].index += 1
            }
        }

        let plannedLoad = seedSet?.plannedLoad ?? 0
        let plannedReps = seedSet?.plannedReps ?? 10
        let plannedRIR = seedSet?.plannedRIR ?? 2

        let newSet = UISessionSet(
            index: nextIndex,
            exerciseId: exercise.exerciseId,
            plannedLoad: plannedLoad,
            plannedReps: plannedReps,
            plannedRIR: plannedRIR,
            actualLoad: nil,
            actualReps: nil,
            actualRIR: nil,
            status: .notStarted,
            usedRestPause: false,
            restPausePattern: "",
            unit: loadUnit
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

    /// The SwiftData item behind a UI row, by identity. Nil when the row has no item yet.
    static func sessionItem(for exercise: UISessionExercise, in session: Session) -> SessionItem? {
        guard let itemID = exercise.itemID else { return nil }
        return session.items.first { $0.id == itemID }
    }

    func swapExercise(at index: Int, with catalogExercise: CatalogExercise, context: ModelContext) {
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


        exercise.detail = "Week \(exercise.weekIndex) · \(catalogExercise.primaryMuscle.rawValue.capitalized) · \(exercise.prescriptionDetailLine.replacingOccurrences(of: "Week \(exercise.weekIndex) · ", with: ""))"
        exercise.coachMessage = ""
        exercise.prescriptionNotes = nil
        exercise.intensifierNotes = nil

        // Re-seed load from history so Guard 2 (suggestedLoad <= 0) doesn't block
        // coaching after a swap. BW guard lives inside lastKnownLoad — swapping in a
        // bodyweight exercise cannot re-manufacture the phantom Fix B eliminated.
        // persist() propagates these values to item.suggestedLoad and item.plannedLoadsBySet.
        let recentLoad = UserProfile.clampedLoad(
            LoadProjectionService.lastKnownLoad(
                for: catalogExercise.id,
                currentSession: session,
                context: context
            ),
            exerciseId: catalogExercise.id,
            profile: try? context.fetch(FetchDescriptor<UserProfile>()).first
        )
        if recentLoad > 0 {
            for i in exercise.sets.indices {
                exercise.sets[i].plannedLoad = recentLoad
                exercise.sets[i].plannedLoadText = formatLoad(recentLoad)
            }
        }

        exercises[index] = exercise

        // Write back to the swapped item by identity — never by exerciseId, which can match another
        // item of the same exercise earlier in the session.
        if let item = Self.sessionItem(for: exercise, in: session) {
            item.exerciseId = catalogExercise.id
            item.exerciseNameSnapshot = catalogExercise.name
            item.prescriptionNotes = nil
            item.intensifierNotes = nil
        }
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
        let defaultLoad = UserProfile.clampedLoad(
            LoadProjectionService.lastKnownLoad(
                for: catalogExercise.id,
                currentSession: session,
                context: context
            ),
            exerciseId: catalogExercise.id,
            profile: try? context.fetch(FetchDescriptor<UserProfile>()).first
        )

        // Maintenance sessions need the deload-style prescription so the coaching
        // engine recognizes the new item as a maintenance exercise (CoachingEngine
        // gates its retention-message branch on waveRaw == "deload"). Without this,
        // exercises added mid-block from the Today tab fall through to normal
        // progression coaching instead of the maintenance retention message.
        let isMaintenanceSession = session.meso?.name.lowercased().contains("maintenance") == true

        let newItem: SessionItem
        if isMaintenanceSession {
            let maintenanceSetCount = 2
            newItem = SessionItem(
                order: nextOrder,
                exerciseId: catalogExercise.id,
                exerciseNameSnapshot: catalogExercise.name,
                targetReps: 10,
                targetSets: maintenanceSetCount,
                targetRIR: 3,
                suggestedLoad: defaultLoad,
                waveRaw: WaveType.deload.rawValue,
                priorityRaw: ExercisePriority.standard.rawValue,
                setMin: 2,
                setMax: 3,
                repMin: 8,
                repMax: 12,
                targetRIRMin: 3,
                targetRIRMax: 4,
                intensifierRaw: IntensifierType.none.rawValue,
                intensifierNotes: nil,
                prescriptionNotes: "Maintenance — hold loads, manage fatigue.",
                plannedRepsBySet: Array(repeating: 10, count: maintenanceSetCount),
                plannedLoadsBySet: Array(repeating: defaultLoad, count: maintenanceSetCount),
                plannedRIRsBySet: Array(repeating: 3, count: maintenanceSetCount),
                actualReps: Array(repeating: 0, count: maintenanceSetCount),
                actualLoads: Array(repeating: 0.0, count: maintenanceSetCount),
                actualRIRs: Array(repeating: 0, count: maintenanceSetCount)
            )
        } else {
            newItem = SessionItem(
                order: nextOrder,
                exerciseId: catalogExercise.id,
                exerciseNameSnapshot: catalogExercise.name,
                targetReps: defaultReps,
                targetSets: defaultSets,
                targetRIR: defaultRIR,
                suggestedLoad: defaultLoad,
                plannedRepsBySet: Array(repeating: defaultReps, count: 4),
                plannedLoadsBySet: Array(repeating: defaultLoad, count: 4),
                plannedRIRsBySet: Array(repeating: defaultRIR, count: 4),
                actualReps: Array(repeating: 0, count: 4),
                actualLoads: Array(repeating: 0.0, count: 4),
                actualRIRs: Array(repeating: 0, count: 4)
            )
        }

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
                exerciseId: catalogExercise.id,
                plannedLoad: (idx <= defaultSets) ? defaultLoad : 0,
                plannedReps: defaultReps,
                plannedRIR: defaultRIR,
                actualLoad: nil,
                actualReps: nil,
                actualRIR: nil,
                status: .notStarted,
                unit: loadUnit
            )
        }

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
            coachMessage: "",
            itemID: newItem.id
        )

        exercises.append(uiExercise)
    }
    
    func propagateAddedExerciseForward(exerciseId: String, context: ModelContext) {
        // The new item below is built from the source item's prescription, wave
        // included. On a wave-based block that injects this week's wave into every
        // other week of the day type, so the added exercise stays here only.
        guard !WavePrescriptionGuard.isWaveBasedBlock(session) else {
            print("⛔️ propagateAddedExerciseForward skipped: wave-based block.")
            return
        }

        guard let sourceItem = session.items.sorted(by: { $0.order < $1.order }).last(where: { $0.exerciseId == exerciseId }) else {
            return
        }

        let calendar = Calendar.current
        let sourceDate = calendar.startOfDay(for: session.date)
        let sourceOrder = sourceItem.order
        // Day-type identity, not calendar weekday — a session's weekday can shift
        // (e.g. the "Rest today" push) without its day type changing, and weekday
        // is not a reliable stand-in for day type once that happens.
        let sourceDayLabel = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !sourceDayLabel.isEmpty else {
            print("⚠️ propagateAddedExerciseForward: source session has no dayLabel to match on.")
            return
        }

        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        do {
            let allSessions = try context.fetch(descriptor)

            let targets = allSessions.filter { other in
                guard other.id != session.id else { return false }
                guard other.status == .planned else { return false }
                guard calendar.startOfDay(for: other.date) > sourceDate else { return false }
                guard other.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) == sourceDayLabel else { return false }

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
                    targetSets: sourceItem.effectivePrescribedSets,
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
        for uiExercise in exercises {
                    guard let item = Self.sessionItem(for: uiExercise, in: session)
                    ?? session.items.first(where: { $0.exerciseId == uiExercise.exerciseId }) else {
                        continue
                    }

            // Sync basic exercise info (including swaps)
            item.exerciseId = uiExercise.exerciseId
            item.exerciseNameSnapshot = uiExercise.name
            item.targetSets = uiExercise.targetSets

            if let firstSet = uiExercise.sets.first {
                item.targetReps = firstSet.plannedReps
                // FIX B — Bodyweight exercises never store a numeric suggested load.
                // Re-stamping firstSet.plannedLoad unconditionally is what re-seeded the
                // phantom on every save (open reads suggestedLoad → plannedLoad, save
                // writes it back). For BW, force 0 so the plan pill stays "BW".
                item.suggestedLoad = ExerciseCatalog.isBodyweight(exerciseId: uiExercise.exerciseId)
                    ? 0
                    : firstSet.plannedLoad
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
            item.dropSetPatternsBySet    = Array(repeating: "", count: setCount)
            item.setFeedbackBySet        = Array(repeating: "", count: setCount)
            item.pumpRatingsBySet        = Array(repeating: 0, count: setCount)

            if uiExercise.sets.contains(where: \.isTop) {
                var roles = Array(repeating: "", count: setCount)
                for uiSet in uiExercise.sets where uiSet.isTop && uiSet.index - 1 < setCount {
                    roles[uiSet.index - 1] = SessionItem.topRole
                }
                item.setRolesBySet = roles
            }

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
                // Skip encoding takes priority; otherwise store the RP pattern text
                                if uiSet.status.isAnySkip {
                                    item.restPausePatternsBySet[idx] = "SKIP"
                                    item.setFeedbackBySet[idx] = uiSet.status.feedbackValue.rawValue
                                } else {
                                    item.restPausePatternsBySet[idx] = uiSet.restPausePattern
                                    item.pumpRatingsBySet[idx] = uiSet.pumpRating.rawValue
                                    // Drop set tracking
                                    if uiSet.usedDropSet && !uiSet.dropSets.isEmpty {
                                        item.dropSetPatternsBySet[idx] = uiSet.dropSets.map { $0.serialized(unit: loadUnit) }.joined(separator: ",")
                                    } else {
                                        item.dropSetPatternsBySet[idx] = ""
                                    }
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
            if session.completedAt == nil {
                let now = Date()
                session.completedAt = now
                session.date = now
            }
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


    private func formatLoad(_ value: Double) -> String {
        LoadFormatter(unit: loadUnit).zeroOrOneDecimal(value)
    }

    // MARK: - Recap + Persistence (History)

    func buildRecap(using context: ModelContext) -> SessionRecap {
        let profileDescriptor = FetchDescriptor<UserProfile>()
        let bodyWeight = try? context.fetch(profileDescriptor).first?.bodyWeight

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

            for set in exercise.sets where exercise.isPlannedRow(set) {
                guard set.status == .completed else { continue }

                let reps = set.actualReps ?? set.plannedReps
                let load = set.actualLoad ?? set.plannedLoad
                let rir  = set.actualRIR ?? set.plannedRIR
                let effLoad = E1RMCalculator.effectiveLoad(
                    actualLoad: load,
                    exerciseId: exercise.exerciseId,
                    bodyWeight: bodyWeight
                )

                setsCompleted += 1
                totalRepsForExercise += reps
                totalVolume += Double(reps) * effLoad

                // Track the last completed set's RIR
                if let rir = rir {
                    lastRIR = rir
                }

                // Epley e1RM estimate for this set
                if effLoad > 0 && reps > 0 {
                    let e1 = effLoad * (1.0 + Double(reps) / 30.0)
                    if let currentTop = topE1RM {
                        if e1 > currentTop {
                            topE1RM = e1
                        }
                    } else {
                        topE1RM = e1
                    }
                }
            }

            let matchingItem = session.items.first { $0.exerciseId == exercise.exerciseId }

            let summary = SessionRecapExercise(
                name: exercise.name,
                primaryMuscle: primary,
                sets: setsCompleted,
                reps: totalRepsForExercise,
                volume: totalVolume,
                lastSetRIR: lastRIR,
                topE1RM: topE1RM,
                sessionItem: matchingItem
            )

            guard setsCompleted > 0 else { continue }
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
        // Also update session.date to today so history and Auto+ reflect when the
        // session was actually performed, not when it was originally seeded.
        if session.completedAt == nil {
            let now = Date()
            session.completedAt = now
            session.date = now
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

        // 🔑 Try to find an existing history entry for this session.
        // Match on sessionId when available (stable across date changes).
        // Fall back to date+week for legacy history entries that predate sessionId.
        let targetSessionId = session.id
        let descriptor = FetchDescriptor<SessionHistory>(
            predicate: #Predicate<SessionHistory> { history in
                history.sessionId == targetSessionId ||
                (history.sessionId == nil && history.date == targetDate && history.weekIndex == targetWeek)
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
            existingHistory.date = session.date
            existingHistory.sessionId = existingHistory.sessionId ?? session.id
            existingHistory.mechanicalLoad = MechanicalLoadHealthKitService.calculateMechanicalLoad(from: session)
            existingHistory.dayLabelSnapshot = normalizedDayLabelSnapshot
            existingHistory.exercises = historyExercises
            existingHistory.mesoBlockId = mesoBlockId
            existingHistory.mesoBlockNameSnapshot = mesoBlockNameSnapshot
        } else {
            // First time completing this session → insert a new history row
            let history = SessionHistory(
                date: session.date,
                weekIndex: recap.weekIndex,
                title: recap.title,
                subtitle: recap.subtitle,
                totalExercises: recap.exerciseCount,
                totalSets: recap.setCount,
                totalVolume: recap.totalVolume,
                sessionId: session.id,
                dayLabelSnapshot: normalizedDayLabelSnapshot,
                mechanicalLoad: MechanicalLoadHealthKitService.calculateMechanicalLoad(from: session),
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
        // ✅ Project mechanical load for HealthDashboard (idempotent day-total).
        MechanicalLoadProjector.projectDay(session.completedAt ?? session.date, in: context)
    }
} // ← closes SessionScreenViewModel

// MARK: - Integration with real Session model

extension SessionScreenViewModel {
    convenience init(session: Session) {
        let unit: LoadUnit = session.modelContext.flatMap { try? $0.fetch(FetchDescriptor<UserProfile>()).first?.loadUnit } ?? .lb
        let title = session.date.formatted(date: .abbreviated, time: .omitted)
        let subtitle = session.weekDayLabel
        let items = session.items.sorted { $0.order < $1.order }

        // Legacy items may predate SessionItem.id; the UI rows key on it, so backfill (saved with the next persist).
        for item in items where item.id == nil { item.id = UUID() }

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
            let setCount = max(4, targetSets + item.topCount)   // keeps “3-to-grow, 1-to-know” UI baseline; top rows ride at the tail
            var uiSets: [UISessionSet] = []
            uiSets.reserveCapacity(setCount)

            for idx in 0..<setCount {
                let setIndex = idx + 1
                let isTop = item.isTopRow(idx)
                let isPlannedWorkingSet = setIndex <= targetSets || isTop

                // ---- Planned values ----
                let plannedReps: Int = {
                    if idx < item.plannedRepsBySet.count, item.plannedRepsBySet[idx] > 0 {
                        return item.plannedRepsBySet[idx]
                    } else {
                        return isTop ? (item.topRepMin ?? baseReps) : baseReps
                    }
                }()

                let plannedLoad: Double = {
                    if idx < item.plannedLoadsBySet.count, item.plannedLoadsBySet[idx] > 0 {
                        return item.plannedLoadsBySet[idx]
                    } else {
                        // A top row never borrows the back-off load: no plan = no suggestion.
                        return isPlannedWorkingSet && !isTop ? baseLoad : 0.0
                    }
                }()

                // A stored 0 is the Program tab's array padding, not a prescription: treat it as
                // unset and show the base RIR (same rule as ProgramDayDetailView's RIR binding).
                let plannedRIR: Int? = {
                    if idx < item.plannedRIRsBySet.count, item.plannedRIRsBySet[idx] > 0 {
                        return item.plannedRIRsBySet[idx]
                    }
                    return isTop ? (item.topRIR ?? baseRIR) : baseRIR
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

                let dropEntries: [DropSetEntry] = {
                    if idx < item.dropSetPatternsBySet.count {
                        return DropSetEntry.parse(from: item.dropSetPatternsBySet[idx], unit: unit)
                    }
                    return []
                }()

                // ---- Feedback + pump ----
                                let feedback: SetFeedback = {
                                    guard idx < item.setFeedbackBySet.count else { return .none }
                                    return SetFeedback(rawValue: item.setFeedbackBySet[idx]) ?? .none
                                }()

                                let pumpRating: PumpRating = {
                                    guard idx < item.pumpRatingsBySet.count else { return .none }
                                    return PumpRating(rawValue: item.pumpRatingsBySet[idx]) ?? .none
                                }()

                                // ---- Status ----
                                let status: SetStatus = {
                                    if isSkipped {
                                        switch feedback {
                                        case .pain: return .skippedPain
                                        case .soreness: return .skippedSoreness
                                        case .disruption: return .skippedDisruption
                                        case .fatigue: return .skippedFatigue
                                        case .none: return .skipped
                                        }
                                    } else if let reps = actualReps, reps > 0 {
                                        return .completed
                                    } else {
                                        return .notStarted
                                    }
                                }()

                uiSets.append(
                                    UISessionSet(
                                        index: setIndex,
                                        exerciseId: item.exerciseId,
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
                                        dropSets: dropEntries,
                                        pumpRating: pumpRating,
                                        isTop: isTop,
                                        unit: unit
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
                coachMessage: item.coachNote ?? "",
                itemID: item.id,
                topRepMin: item.topRepMin,
                topRepMax: item.topRepMax
            )
        }

        self.init(
            session: session,
            title: title,
            subtitle: subtitle,
            exercises: exercises
        )
        self.loadUnit = unit
    }
}

// MARK: - UI Models

enum SetStatus: Equatable {
    case notStarted
    case inProgress
    case completed
    case skipped
    case skippedPain
    case skippedSoreness
    case skippedDisruption
    case skippedFatigue

    var isAnySkip: Bool {
        switch self {
        case .skipped, .skippedPain, .skippedSoreness, .skippedDisruption, .skippedFatigue: return true
        default: return false
        }
    }

    var feedbackValue: SetFeedback {
        switch self {
        case .skippedPain: return .pain
        case .skippedSoreness: return .soreness
        case .skippedDisruption: return .disruption
        case .skippedFatigue: return .fatigue
        default: return .none
        }
    }

    var displayLabel: String {
        switch self {
        case .skipped: return "Skipped"
        case .skippedPain: return "Pain"
        case .skippedSoreness: return "Soreness"
        case .skippedDisruption: return "Disruption"
        case .skippedFatigue: return "Fatigue"
        default: return ""
        }
    }

    var displayColor: Color {
        switch self {
        case .skipped: return .orange
        case .skippedPain: return .red
        case .skippedSoreness: return .yellow
        case .skippedDisruption: return .orange
        case .skippedFatigue: return .purple
        default: return .secondary
        }
    }
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

    /// Identity of the SwiftData item this row shows (`SessionItem.id`). Survives swaps, which change `exerciseId`.
    var itemID: UUID?

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

    /// Top-set rep range (nil on an exercise with no top set).
    var topRepMin: Int?
    var topRepMax: Int?

    var topCount: Int { sets.filter(\.isTop).count }

    /// A planned row: a back-off within targetSets, or a top row.
    func isPlannedRow(_ set: UISessionSet) -> Bool { set.index <= targetSets || set.isTop }

    /// Rows in display order: top rows first, then the back-offs and extras. Storage order (index)
    /// is unchanged; the role comes from the row, never from when it was logged.
    var displaySets: [UISessionSet] { sets.filter(\.isTop) + sets.filter { !$0.isTop } }

    var isComplete: Bool {
        let workingSets = sets.filter { isPlannedRow($0) }
        guard !workingSets.isEmpty else { return false }
        return workingSets.allSatisfy { $0.status == .completed || $0.status.isAnySkip }
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
        coachMessage: String = "",
        itemID: UUID? = nil,
        topRepMin: Int? = nil,
        topRepMax: Int? = nil
    ) {
        self.topRepMin = topRepMin
        self.topRepMax = topRepMax
        // Derive a stable UUID from exerciseId so ForEach identity is consistent
        // across republishes of viewModel.exercises.
        self.id = UUID(uuidString: exerciseId) ?? {
            let hash = exerciseId.utf8.reduce(UInt64(14695981039346656037)) { acc, byte in
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
        self.itemID = itemID
    }
}



struct UISessionSet: Identifiable {
    var id: Int { index }
    var index: Int
    /// This row is a top set (role comes from the row).
    var isTop: Bool = false
    
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
    var dropSets: [DropSetEntry]
    var pumpRating: PumpRating
    
    /// The unit the *Text fields below are shown in (loads themselves are stored lb).
    var unit: LoadUnit = .lb

    var plannedLoadText: String
    var plannedRepsText: String
    var actualLoadText: String
    var actualRepsText: String
    
    init(
        index: Int,
        exerciseId: String,
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
        dropSets: [DropSetEntry] = [],
        pumpRating: PumpRating = .none,
        isTop: Bool = false,
        unit: LoadUnit = .lb
    ) {
        self.unit = unit
        self.isTop = isTop
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
        self.dropSets = dropSets
        self.pumpRating = pumpRating
        let planLoadString: String
        if plannedLoad == 0 {
            planLoadString = "0"
        } else {
            planLoadString = LoadFormatter(unit: unit).oneDecimal(plannedLoad)
        }
        
        self.plannedLoadText = planLoadString
        self.plannedRepsText = "\(plannedReps)"
        
        if let actualLoad {
            self.actualLoadText = LoadFormatter(unit: unit).oneDecimal(actualLoad)
        } else if ExerciseCatalog.isBodyweight(exerciseId: exerciseId) {
            // BW: no external load entered = bodyweight-only. Store 0 so effectiveLoad() returns bodyweight at read time.
            // LANDMINE: weighted-BW (belt plate) support, when built, must seed the added-weight value here instead of 0.
            self.actualLoadText = "0"
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
    /// "EXTRA SET  6-8 reps @ 2 RIR": the line for a row past the planned set count (no load).
    static func extraSetLabel(repRange: RepRange, rir: Int?) -> String {
        let reps = repRange.min == repRange.max ? "\(repRange.min)" : "\(repRange.min)-\(repRange.max)"
        let rirText = rir.map { " @ \($0) RIR" } ?? ""
        return "EXTRA SET  \(reps) reps\(rirText)"
    }

    func plannedDescription(with repRange: RepRange, isBodyweight: Bool = false) -> String {
        if plannedLoad == 0 && plannedReps == 0 { return "—" }

        let loadText: String
        if plannedLoad == 0 {
            loadText = isBodyweight ? "BW" : "—"
        } else {
            loadText = LoadFormatter(unit: unit).oneDecimal(plannedLoad)
        }
        
        // Show range with the top flagged as the goal when min and max differ,
        // otherwise show the single target (no range to climb → no "· goal").
        let repsText: String
        if repRange.min != repRange.max {
            repsText = "\(repRange.min)–\(repRange.max) · goal \(repRange.max)"
        } else {
            repsText = "\(plannedReps)"
        }
        
        if let plannedRIR {
                    return "\(loadText) × \(repsText) @ \(plannedRIR) RIR"
                } else {
                    return "\(loadText) × \(repsText)"
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

        /// Mechanical load: intensity-weighted volume across all sets.
        /// Formula: Σ (load × reps × relative_intensity) where relative_intensity = load / e1RM
        var mechanicalLoad: Double {
            var total = 0.0
            for exercise in exercises {
                guard let item = exercise.sessionItem else { continue }
                let setCount = min(item.actualLoads.count, item.actualReps.count)
                for idx in 0..<setCount {
                    let load = item.actualLoads[idx]
                    let reps = item.actualReps[idx]
                    guard load > 0, reps > 0 else { continue }
                    let e1rm = E1RMCalculator.e1RM(load: load, reps: reps)
                    guard e1rm > 0 else { continue }
                    total += load * Double(reps) * (load / e1rm)
                }
            }
            return total.rounded()
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
        let sessionItem: SessionItem?  // ← add
    }
    
    private struct SessionRecapSheet: View {
        @Environment(\.loadUnit) private var unit
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
            return LoadFormatter(unit: unit).whole(value)
        }
        
        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        headerCard

                        // By exercise
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

                        // Load adjustments — shown after exercise summary
                        if !itemsNeedingPrompt.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Load adjustments")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                VStack(spacing: 12) {
                                    ForEach(itemsNeedingPrompt, id: \.exerciseId) { item in
                                        LoadOverridePromptRow(item: item)
                                            .padding()
                                            .background(
                                                RoundedRectangle(cornerRadius: 20)
                                                    .fill(Color(.systemBackground))
                                            )
                                    }
                                }
                            }
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

                if recap.mechanicalLoad > 0 {
                    HStack {
                        Text("Mechanical load")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(LoadFormatter(unit: unit).whole(recap.mechanicalLoad))
                            .font(.caption)
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
        private var itemsNeedingPrompt: [SessionItem] {
            recap.exercises.compactMap { ex -> SessionItem? in
                guard let item = ex.sessionItem else { return nil }
                let suggested = item.suggestedLoad
                guard suggested > 0 else { return nil }
                let threshold = suggested * 0.85
                let lowSets = item.actualLoads.filter { $0 > 0 && $0 < threshold }.count
                return lowSets >= 2 ? item : nil
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
                UISessionSet(index: 1, exerciseId: "bench", plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
                UISessionSet(index: 2, exerciseId: "bench", plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
                UISessionSet(index: 3, exerciseId: "bench", plannedLoad: 185, plannedReps: 8, plannedRIR: 2),
                UISessionSet(index: 4, exerciseId: "bench", plannedLoad: 185, plannedReps: 8, plannedRIR: 1)
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

