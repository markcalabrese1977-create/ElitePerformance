import SwiftUI
import SwiftData
import Combine

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Persistent Rest Timer

final class RestTimer: ObservableObject {
    @Published var isActive: Bool = false
    @Published var elapsedSeconds: Int = 0
    @Published var targetSeconds: Int = 120

    private var startedAt: Date?
    private var timerCancellable: AnyCancellable?
    private var hasNotifiedAtTarget: Bool = false

    func start(targetSeconds: Int) {
        self.targetSeconds = targetSeconds
        self.startedAt = Date()
        self.isActive = true
        self.hasNotifiedAtTarget = false

        timerCancellable?.cancel()

        timerCancellable = Timer
            .publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
        isActive = false
        elapsedSeconds = 0
        startedAt = nil
        targetSeconds = 0
        hasNotifiedAtTarget = false
    }

    func resumeIfNeeded() {
        guard let startedAt = startedAt else { return }
        let diff = Int(Date().timeIntervalSince(startedAt))
        elapsedSeconds = max(diff, 0)
        isActive = true
    }

    private func tick() {
        guard let startedAt = startedAt else { return }
        let diff = Int(Date().timeIntervalSince(startedAt))
        elapsedSeconds = max(diff, 0)

        // Fire a one-time haptic when we hit the target rest time.
        if targetSeconds > 0,
           elapsedSeconds >= targetSeconds,
           !hasNotifiedAtTarget {

            hasNotifiedAtTarget = true

            #if canImport(UIKit)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif
        }
    }

    /// Seconds remaining until target is reached (never negative).
    var remainingSeconds: Int {
        guard targetSeconds > 0 else { return 0 }
        return max(targetSeconds - elapsedSeconds, 0)
    }
}

// MARK: - Session View

struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var session: Session

    @StateObject private var restTimer = RestTimer()
    @State private var showingRecap = false

    // Which exercise we’re swapping right now
    @State private var itemToSwap: SessionItem?

    // Add exercise sheet
    @State private var showingAddExerciseSheet = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            content

            if restTimer.isActive {
                restBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(formattedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Close
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }

            // End Workout
            ToolbarItem(placement: .confirmationAction) {
                Button("End Workout") {
                    finishAndShowRecap()
                }
                .disabled(session.items.isEmpty)
            }

            // Add exercise
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddExerciseSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        // Recap sheet
        .sheet(isPresented: $showingRecap) {
            NavigationStack {
                SessionRecapView(session: session)
            }
        }
        // Swap sheet
        .sheet(item: $itemToSwap) { item in
            NavigationStack {
                swapExerciseSheet(for: item)
            }
        }
        // Add exercise sheet
        .sheet(isPresented: $showingAddExerciseSheet) {
            NavigationStack {
                addExerciseSheet
            }
        }
        .onAppear {
            restTimer.resumeIfNeeded()

            #if canImport(UIKit)
            // Keep screen awake while this session view is on-screen
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onDisappear {
            #if canImport(UIKit)
            // Restore normal screen sleep behavior when leaving the session
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
    }

    // MARK: - Main content

    private var content: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.date, style: .date)
                        .font(.headline)

                    Text(session.status.displayTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if session.readinessStars > 0 {
                        HStack(spacing: 4) {
                            Text("Readiness:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(repeating: "★", count: session.readinessStars))
                                .font(.caption)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(sortedItems, id: \.persistentModelID) { item in
                Section(header: exerciseHeader(for: item)) {
                    exerciseBody(for: item)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteExercise(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var sortedItems: [SessionItem] {
        session.items.sorted { $0.order < $1.order }
    }

    private var formattedTitle: String {
        "Session – Week \(session.weekIndex)"
    }

    // MARK: - Rest bar

    private var restBar: some View {
        HStack {
            let elapsed   = restTimer.elapsedSeconds
            let remaining = restTimer.remainingSeconds

            VStack(alignment: .leading, spacing: 2) {
                Text("Rest timer")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Show countdown + total target
                Text("Remaining: \(timeString(remaining))  ·  Target: \(timeString(restTimer.targetSeconds))")
                    .font(.footnote)
                    .fontWeight(.semibold)

                // Also show how long you've actually been resting (for awareness)
                Text("Elapsed: \(timeString(elapsed))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Reset") {
                restTimer.stop()
            }
            .font(.footnote)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding()
        .shadow(radius: 4)
    }

    private func timeString(_ seconds: Int) -> String {
        guard seconds > 0 else { return "00:00" }
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Exercise sections

    private func exerciseHeader(for item: SessionItem) -> some View {
        let exerciseName = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })?.name
            ?? "Unknown exercise"

        // Planned load from program
        let plannedLoad = plannedLoad(for: item)

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(exerciseName)
                    .font(.headline)

                if let load = plannedLoad {
                    Text("Planned: \(item.plannedSetCount)x\(item.plannedTopReps) @ \(load, specifier: "%.1f") · RIR \(item.targetRIR)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Planned: \(item.plannedSetCount)x\(item.plannedTopReps) · RIR \(item.targetRIR)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Last completed session’s top set + readiness, if available
                if let (prevSession, prevItem) = lastCompletedSessionItem(for: item.exerciseId),
                   let top = prevItem.bestSetDescription {
                    HStack(spacing: 4) {
                        Text("Last: \(top)")
                        if prevSession.readinessStars > 0 {
                            Text("· \(prevSession.readinessStars)★")
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Button("Swap") {
                    itemToSwap = item
                }
                .font(.caption2)

                if item.isCompleted {
                    Text("Done")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                }
            }
        }
    }

    private func exerciseBody(for item: SessionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {

            // Planned load + reps (separate from actual logs)
            HStack(spacing: 8) {
                Text("Plan")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .leading)

                // Planned working load
                TextField(
                    "0",
                    value: Binding(
                        get: { item.suggestedLoad },
                        set: { item.suggestedLoad = $0 }
                    ),
                    format: .number
                )
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)

                // Planned reps
                TextField(
                    "0",
                    value: Binding(
                        get: { item.targetReps },
                        set: { item.targetReps = $0 }
                    ),
                    format: .number
                )
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)

                Spacer()
            }

            // Column labels for ACTUAL sets
            HStack(spacing: 8) {
                Text("Set")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .leading)

                Text("Load")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)

                Text("Reps")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)

                Text("RP")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)

                Text("Pattern")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .leading)

                Spacer()
            }

            // Actual logged sets
            // Per-set rows (allow more than the planned set count)
            ForEach(0..<displaySetCount(for: item), id: \.self) { index in
                setRow(for: item, index: index)
            }

            HStack {
                Text("Logged sets: \(item.loggedSetsCount)/\(item.plannedSetCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(item.isCompleted ? "Mark Not Done" : "Mark Done") {
                    item.isCompleted.toggle()
                    saveContext()
                }
                .font(.caption)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        // Persist plan tweaks even if you back out without logging
        .onChange(of: item.suggestedLoad) { _ in
            saveContext()
        }
        .onChange(of: item.targetReps) { _ in
            saveContext()
        }
    }


    // MARK: - Per-set row (simple, direct bindings)

    private func setRow(for item: SessionItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Set \(index + 1)")
                    .font(.subheadline)
                    .frame(width: 52, alignment: .leading)

                TextField("0",
                          value: bindingLoad(for: item, index: index),
                          format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)

                TextField("0",
                          value: bindingReps(for: item, index: index),
                          format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)

                Toggle("RP", isOn: bindingRestPauseFlag(for: item, index: index))
                    .labelsHidden()

                TextField("RP patt…", text: bindingRestPausePattern(for: item, index: index))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)

                Spacer()
            }

            HStack {
                Spacer()
                Button("Save") {
                    handleSetSaved(for: item, setIndex: index)
                }
                .font(.caption)
            }
        }
    }
    
    // MARK: - How many rows to show per exercise

    private func displaySetCount(for item: SessionItem) -> Int {
        let planned = item.plannedSetCount
        let logged = max(item.actualReps.count, item.actualLoads.count)
        let baseline = 6   // minimum rows we always show

        return max(planned, logged, baseline)
    }
    
    // MARK: - Bindings for per-set arrays

    private func ensureCapacity(for item: SessionItem, upTo index: Int) {
        while item.actualLoads.count <= index {
            item.actualLoads.append(0)
        }
        while item.actualReps.count <= index {
            item.actualReps.append(0)
        }
        while item.actualRIRs.count <= index {
            item.actualRIRs.append(item.targetRIR)
        }
        while item.usedRestPauseFlags.count <= index {
            item.usedRestPauseFlags.append(false)
        }
        while item.restPausePatternsBySet.count <= index {
            item.restPausePatternsBySet.append("")
        }
    }

    private func bindingLoad(for item: SessionItem, index: Int) -> Binding<Double> {
        Binding(
            get: {
                ensureCapacity(for: item, upTo: index)
                return item.actualLoads[index]
            },
            set: { newValue in
                ensureCapacity(for: item, upTo: index)
                item.actualLoads[index] = newValue
            }
        )
    }

    private func bindingReps(for item: SessionItem, index: Int) -> Binding<Int> {
        Binding(
            get: {
                ensureCapacity(for: item, upTo: index)
                return item.actualReps[index]
            },
            set: { newValue in
                ensureCapacity(for: item, upTo: index)
                item.actualReps[index] = newValue
            }
        )
    }

    private func bindingRestPauseFlag(for item: SessionItem, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                ensureCapacity(for: item, upTo: index)
                return item.usedRestPauseFlags[index]
            },
            set: { newValue in
                ensureCapacity(for: item, upTo: index)
                item.usedRestPauseFlags[index] = newValue
            }
        )
    }

    private func bindingRestPausePattern(for item: SessionItem, index: Int) -> Binding<String> {
        Binding(
            get: {
                ensureCapacity(for: item, upTo: index)
                return item.restPausePatternsBySet[index]
            },
            set: { newValue in
                ensureCapacity(for: item, upTo: index)
                item.restPausePatternsBySet[index] = newValue
            }
        )
    }

    // MARK: - Set save → rest timer (no auto-finish)

    private func handleSetSaved(for item: SessionItem, setIndex: Int) {
        // Mark the session as "in progress" once any work is logged
        if session.status == .planned {
            session.status = .inProgress
        }

        // If this exercise now has all its sets logged, you *can* mark it done.
        if item.loggedSetsCount >= item.plannedSetCount {
            item.isCompleted = true
        }

        // Start / restart rest timer whenever you save a set.
        restTimer.start(targetSeconds: 120) // tweak default as you like

        // Just save changes — DO NOT auto-complete the whole session here.
        saveContext()
    }

    private func finishAndShowRecap() {
        session.status = .completed
        saveContext()
        restTimer.stop()
        showingRecap = true
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save session: \(error)")
        }
    }

    // MARK: - Last completed session lookup

    /// Returns the most recent *completed* session before this one that has a
    /// logged item for the given exerciseId, plus that SessionItem.
    private func lastCompletedSessionItem(for exerciseId: String) -> (Session, SessionItem)? {
        let thisDate = session.date

        // Fetch all sessions, newest first; filter in memory.
        var descriptor = FetchDescriptor<Session>()
        descriptor.sortBy = [SortDescriptor(\Session.date, order: .reverse)]

        guard let sessions = try? modelContext.fetch(descriptor) else {
            return nil
        }

        for s in sessions {
            guard s.status == .completed, s.date < thisDate else { continue }

            if let item = s.items.first(where: { $0.exerciseId == exerciseId && $0.loggedSetsCount > 0 }) {
                return (s, item)
            }
        }

        return nil
    }

    // MARK: - Planned load helper

    /// Planned working load from the program for display in the header.
    /// Prefers per-set planned loads; falls back to suggestedLoad.
    private func plannedLoad(for item: SessionItem) -> Double? {
        let nonZeroPlanned = item.plannedLoadsBySet.filter { abs($0) > 0.1 }
        if let first = nonZeroPlanned.first {
            return first
        }
        if item.suggestedLoad > 0 {
            return item.suggestedLoad
        }
        return nil
    }

    // MARK: - Swap exercise sheet

    @ViewBuilder
    private func swapExerciseSheet(for item: SessionItem) -> some View {
        List {
            ForEach(ExerciseCatalog.all) { exercise in
                Button {
                    performSwap(on: item, to: exercise)
                    itemToSwap = nil
                } label: {
                    HStack {
                        Text(exercise.name)
                        Spacer()
                        if exercise.id == item.exerciseId {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Swap Exercise")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    itemToSwap = nil
                }
            }
        }
    }

    private func performSwap(on item: SessionItem, to exercise: CatalogExercise) {
        item.exerciseId = exercise.id
        item.coachNote = nil
        item.nextSuggestedLoad = nil
        item.isCompleted = false
        item.isPR = false
        // Optional: clear logged data when swapping
        item.actualReps = []
        item.actualLoads = []
        item.actualRIRs = []
        item.usedRestPauseFlags = []
        item.restPausePatternsBySet = []
        saveContext()
    }

    // MARK: - Add exercise sheet + helpers

    private var addExerciseSheet: some View {
        List {
            ForEach(ExerciseCatalog.all) { exercise in
                Button {
                    addExercise(exercise)
                } label: {
                    HStack {
                        Text(exercise.name)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Add Exercise")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    showingAddExerciseSheet = false
                }
            }
        }
    }

    private func addExercise(_ exercise: CatalogExercise) {
        let nextOrder = (session.items.map { $0.order }.max() ?? 0) + 1

        // Simple defaults for ad-hoc adds; progression can refine later.
        let newItem = SessionItem(
            order: nextOrder,
            exerciseId: exercise.id,
            targetReps: 10,
            targetSets: 3,
            targetRIR: 2,
            suggestedLoad: 0
        )

        session.items.append(newItem)
        saveContext()
        showingAddExerciseSheet = false
    }

    private func deleteExercise(_ item: SessionItem) {
        // Remove from relationship
        if let idx = session.items.firstIndex(where: { $0 === item }) {
            session.items.remove(at: idx)
        }

        // Delete from model context
        modelContext.delete(item)
        saveContext()
    }
}
