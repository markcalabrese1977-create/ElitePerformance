import SwiftUI
import SwiftData

// MARK: - Goal labels used in onboarding

extension Goal {
    var title: String {
        switch self {
        case .fatLoss:     return "Lose fat"
        case .hypertrophy: return "Build muscle"
        case .strength:    return "Get stronger"
        case .longevity:   return "Maintain / move better"
        }
    }

    var subtitle: String {
        switch self {
        case .fatLoss:
            return "Lean out while maintaining strength."
        case .hypertrophy:
            return "Add muscle with structured training."
        case .strength:
            return "Push heavier weights on key lifts."
        case .longevity:
            return "Stay consistent with moderate volume."
        }
    }
}

// MARK: - Result model

struct OnboardingResult: Codable {
    var goal: Goal
    var experience: TrainingExperience
    var daysPerWeek: Int
    /// 1 = Sunday ... 7 = Saturday (Calendar weekday values)
    var trainingDaysOfWeek: [Int]
    var equipmentProfile: EquipmentProfile
    var sessionLengthMinutes: Int
    var injuryFlags: [InjuryFlag]
    var minLoadIncrement: Double
    /// User-chosen meso start date from the date picker on the final page.
    var startDate: Date
}

// MARK: - Flow

struct OnboardingFlowView: View {
    @Environment(\.dismiss) private var dismiss

    let onComplete: (OnboardingResult, PreviewOverrides) -> Void

    @State private var pageIndex: Int = 0

    // Page 1 — Goal
    @State private var selectedGoal: Goal = .hypertrophy

    // Page 2 — Experience
    @State private var selectedExperience: TrainingExperience = .intermediate

    // Page 3 — Schedule
    @State private var daysPerWeek: Int = 4
    @State private var selectedWeekdays: Set<Int> = []

    // Page 4 — Equipment + Session length
    @State private var selectedEquipment: EquipmentProfile = .commercial
    @State private var sessionLengthMinutes: Int = 60
    @State private var selectedLoadIncrement: Double = 2.5

    // Page 5 — Joint limitations
    @State private var selectedInjuryFlags: Set<InjuryFlag> = []

    // Page 6 — Start date picker
    @State private var mesoStartDate: Date = Date()

    // Page 6 — Per-exercise overrides, add, and delete
    @State private var previewOverrides: PreviewOverrides = .empty
    @State private var customizingExercise: (dayId: String, exerciseId: String)? = nil
    @State private var swappingExercise: (dayId: String, exerciseId: String)? = nil
    @State private var addingToDayId: String? = nil
    // Staged during picker selection; promoted to pendingNewExercise in picker's onDismiss,
    // which fires only after the picker animation fully completes — eliminating the
    // asyncAfter overlap that caused onDisappear flicker on the customize sheet.
    @State private var pendingAdd: (dayId: String, exercise: AddedExercise)? = nil
    @State private var pendingNewExercise: (dayId: String, exercise: AddedExercise)? = nil
    @State private var customizingAddedExercise: (dayId: String, instanceId: String)? = nil

    private let totalPages = 6

    var body: some View {
        VStack(spacing: 0) {
            progressBar

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch pageIndex {
                                        case 0: goalPage
                                        case 1: experiencePage
                                        case 2: schedulePage
                                        case 3: equipmentPage
                                        case 4: jointPage
                                        case 5: programPreviewPage
                                        default: goalPage
                                        }
                }
                .padding()
            }

            bottomBar
        }
        .navigationTitle("Setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(height: 3)
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: geo.size.width * CGFloat(pageIndex + 1) / CGFloat(totalPages), height: 3)
                    .animation(.easeInOut(duration: 0.2), value: pageIndex)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Page 1: Goal

    private var goalPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                title: "What's your main goal?",
                subtitle: "We'll use this to build a program that fits your objective."
            )

            ForEach(Goal.allCases, id: \.self) { goal in
                Button {
                    selectedGoal = goal
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(goal.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(goal.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: selectedGoal == goal ? "checkmark.circle.fill" : "circle")
                            .imageScale(.large)
                            .foregroundColor(selectedGoal == goal ? .blue : .secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(selectedGoal == goal ? Color.blue.opacity(0.08) : Color(.systemGray6))
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Page 2: Experience

    private var experiencePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                title: "How long have you been training?",
                subtitle: "This helps set the right starting volume and intensity."
            )

            ForEach(TrainingExperience.allCases, id: \.self) { exp in
                Button {
                    selectedExperience = exp
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exp.label)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(experienceSubtitle(exp))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: selectedExperience == exp ? "checkmark.circle.fill" : "circle")
                            .imageScale(.large)
                            .foregroundColor(selectedExperience == exp ? .blue : .secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(selectedExperience == exp ? Color.blue.opacity(0.08) : Color(.systemGray6))
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    private func experienceSubtitle(_ exp: TrainingExperience) -> String {
        switch exp {
        case .new:          return "Under 1 year of consistent training."
        case .intermediate: return "1–3 years. Comfortable with the basics."
        case .advanced:     return "3+ years. Familiar with periodization and progressive overload."
        }
    }

    // MARK: - Page 3: Schedule

    private var schedulePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                title: "How do you want to train?",
                subtitle: "Pick your frequency and the days that work for you."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Days per week")
                    .font(.subheadline.bold())

                Stepper(value: $daysPerWeek, in: 2...6) {
                    Text("\(daysPerWeek) days")
                        .font(.headline)
                }
                .onChange(of: daysPerWeek) { _, _ in
                    syncSelectedWeekdaysWithDaysPerWeek()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Which days?")
                    .font(.subheadline.bold())

                Text("Pick up to \(daysPerWeek) days. This pattern repeats each week.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    ForEach(0..<weekdaySymbols.count, id: \.self) { index in
                        let weekday = index + 1
                        let label = String(weekdaySymbols[index].prefix(3))
                        let isSelected = selectedWeekdays.contains(weekday)

                        Button {
                            toggleWeekday(weekday)
                        } label: {
                            Text(label)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Selected \(selectedWeekdays.count) of \(daysPerWeek) days")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .onAppear {
            if selectedWeekdays.isEmpty {
                selectedWeekdays = defaultTrainingDays(for: daysPerWeek)
            }
        }
    }

    // MARK: - Page 4: Equipment + Session length

    private var equipmentPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                title: "Your setup",
                subtitle: "This shapes exercise selection and load progressions."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Where do you train?")
                    .font(.subheadline.bold())

                ForEach(EquipmentProfile.allCases, id: \.self) { profile in
                    Button {
                        selectedEquipment = profile
                        // Auto-set sensible load increment defaults
                        if selectedLoadIncrement == 2.5 || selectedLoadIncrement == 1.25 || selectedLoadIncrement == 5.0 {
                            selectedLoadIncrement = defaultLoadIncrement(for: profile)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(equipmentLabel(profile))
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(equipmentSubtitle(profile))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedEquipment == profile ? "checkmark.circle.fill" : "circle")
                                .imageScale(.large)
                                .foregroundColor(selectedEquipment == profile ? .blue : .secondary)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(selectedEquipment == profile ? Color.blue.opacity(0.08) : Color(.systemGray6))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Smallest weight increment available")
                    .font(.subheadline.bold())

                Text("Used to calculate load progressions accurately.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ForEach([1.25, 2.5, 5.0], id: \.self) { increment in
                        Button {
                            selectedLoadIncrement = increment
                        } label: {
                            Text(formatIncrement(increment))
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(selectedLoadIncrement == increment ? Color.blue.opacity(0.15) : Color(.systemGray6))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Session length")
                    .font(.subheadline.bold())

                Stepper(value: $sessionLengthMinutes, in: 30...120, step: 15) {
                    Text("\(sessionLengthMinutes) minutes")
                        .font(.headline)
                }
            }

            Spacer()
        }
    }

    private func equipmentLabel(_ profile: EquipmentProfile) -> String {
        switch profile {
        case .commercial:     return "Commercial gym"
        case .homeGym:        return "Home gym"
        case .dumbbellsOnly:  return "Dumbbells only"
        }
    }

    private func equipmentSubtitle(_ profile: EquipmentProfile) -> String {
        switch profile {
        case .commercial:     return "Full access to machines, cables, and free weights."
        case .homeGym:        return "Barbell, rack, and select machines or cables."
        case .dumbbellsOnly:  return "Dumbbells and bodyweight only."
        }
    }

    private func defaultLoadIncrement(for profile: EquipmentProfile) -> Double {
        switch profile {
        case .commercial:    return 2.5
        case .homeGym:       return 2.5
        case .dumbbellsOnly: return 5.0
        }
    }

    private func formatIncrement(_ value: Double) -> String {
        value == 1.25 ? "1.25 lb" : value == 2.5 ? "2.5 lb" : "5 lb"
    }

    // MARK: - Page 5: Joint limitations

    private var jointPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(
                title: "Any areas to be mindful of?",
                subtitle: "The coaching engine uses this to flag exercises and adjust suggestions. You can update this anytime in Settings."
            )

            VStack(spacing: 10) {
                ForEach(InjuryFlag.allCases, id: \.self) { flag in
                    Button {
                        if selectedInjuryFlags.contains(flag) {
                            selectedInjuryFlags.remove(flag)
                        } else {
                            selectedInjuryFlags.insert(flag)
                        }
                    } label: {
                        HStack {
                            Text(injuryFlagLabel(flag))
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: selectedInjuryFlags.contains(flag) ? "checkmark.circle.fill" : "circle")
                                .imageScale(.large)
                                .foregroundColor(selectedInjuryFlags.contains(flag) ? .orange : .secondary)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(selectedInjuryFlags.contains(flag) ? Color.orange.opacity(0.08) : Color(.systemGray6))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                selectedInjuryFlags = []
            } label: {
                Text("None right now")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selectedInjuryFlags.isEmpty ? Color.blue.opacity(0.08) : Color(.systemGray6))
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    private func injuryFlagLabel(_ flag: InjuryFlag) -> String {
        switch flag {
        case .lowBack:   return "Low back"
        case .knees:     return "Knees"
        case .shoulders: return "Shoulders"
        case .elbows:    return "Elbows"
        case .wrists:    return "Wrists"
        }
    }

    // MARK: - Page 6: Program Preview

        private var programPreviewPage: some View {
            let weekdays = selectedWeekdays.map { min(max($0, 1), 7) }.sorted()
            let template = ProgramApplicationService.selectTemplate(
                goal: selectedGoal,
                daysPerWeek: weekdays.count
            )
            let reason = ProgramApplicationService.recommendationReason(
                        goal: selectedGoal,
                        daysPerWeek: weekdays.count
                    )

            return VStack(alignment: .leading, spacing: 24) {
                pageHeader(
                    title: "Your program",
                    subtitle: "Based on your answers, here's what we're building."
                )

                // Program card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.name)
                                .font(.headline)
                            Text("\(template.totalWeeks) weeks · \(template.trainingDaysPerWeek) days/week")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }

                    Divider()

                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.blue.opacity(0.06))
                )

                // Week 1 structure
                VStack(alignment: .leading, spacing: 8) {
                    Text("Week 1 structure")
                        .font(.subheadline.bold())

                    VStack(spacing: 12) {
                        ForEach(template.dayTemplates.sorted { $0.dayNumber < $1.dayNumber }, id: \.id) { day in
                            VStack(alignment: .leading, spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(day.title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(day.role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                ForEach(day.exerciseTemplates.filter { $0.priority != .optional }, id: \.id) { exercise in
                                    exerciseRow(day: day, exercise: exercise, template: template)
                                }

                                ForEach(previewOverrides.addedByDay[day.id] ?? []) { added in
                                    addedExerciseRow(dayId: day.id, added: added)
                                }

                                Button {
                                    addingToDayId = day.id
                                } label: {
                                    Label("Add Exercise", systemImage: "plus.circle")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.systemGray6))
                            )
                        }
                    }
                }

                Text("Tap an exercise to customize its reps, RIR, and sets before your program starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Start date picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start date")
                        .font(.subheadline.bold())
                    DatePicker(
                        "Start date",
                        selection: $mesoStartDate,
                        in: MesoLifecycle.mesoStartDateRange,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }

                Spacer()
            }
            .sheet(isPresented: Binding(
                get: { customizingExercise != nil },
                set: { isPresented in
                    if !isPresented { customizingExercise = nil }
                }
            )) {
                if let target = customizingExercise,
                   let dayTemplate = template.dayTemplates.first(where: { $0.id == target.dayId }),
                   let exerciseTemplate = dayTemplate.exerciseTemplates.first(where: { $0.exerciseId == target.exerciseId }) {
                    ExerciseCustomizationSheet(
                        exerciseId: target.exerciseId,
                        exerciseTemplate: exerciseTemplate,
                        template: template,
                        existingOverride: previewOverrides.slotOverrides[target.exerciseId],
                        onApply: { newOverride in
                            let existing = previewOverrides.slotOverrides[target.exerciseId] ?? ExerciseWaveOverride()
                            previewOverrides.slotOverrides[target.exerciseId] = existing.applyingPrescription(
                                wavePrescriptions: newOverride.wavePrescriptions,
                                setsByWeek: newOverride.setsByWeek
                            )
                        },
                        onReset: {
                            if let existing = previewOverrides.slotOverrides[target.exerciseId],
                               existing.substituteExerciseId != nil {
                                previewOverrides.slotOverrides[target.exerciseId] = existing.prescriptionCleared
                            } else {
                                previewOverrides.slotOverrides.removeValue(forKey: target.exerciseId)
                            }
                        }
                    )
                }
            }
            .sheet(isPresented: Binding(
                get: { swappingExercise != nil },
                set: { isPresented in
                    if !isPresented { swappingExercise = nil }
                }
            )) {
                if let target = swappingExercise {
                    let displayId = previewOverrides.slotOverrides[target.exerciseId]?.substituteExerciseId ?? target.exerciseId
                    ProgramExerciseSwapSheet(
                        currentExerciseId: displayId,
                        currentExerciseName: ExerciseCatalog.displayName(for: displayId),
                        onSelect: { catalogExercise in
                            let existing = previewOverrides.slotOverrides[target.exerciseId] ?? ExerciseWaveOverride()
                            previewOverrides.slotOverrides[target.exerciseId] = existing.applyingSubstitute(catalogExercise.id)
                            swappingExercise = nil
                        },
                        onCancel: {
                            swappingExercise = nil
                        }
                    )
                }
            }
            // Catalog picker for net-new add flow.
            // onSelect stages the new exercise in pendingAdd; onDismiss promotes it to
            // pendingNewExercise only after the picker's dismissal animation has completed,
            // preventing the transient present/dismiss flicker that caused onApply to fire
            // multiple times.
            .sheet(isPresented: Binding(
                get: { addingToDayId != nil },
                set: { if !$0 { addingToDayId = nil } }
            ), onDismiss: {
                if let staged = pendingAdd {
                    pendingAdd = nil
                    pendingNewExercise = staged
                }
            }) {
                if let dayId = addingToDayId {
                    ProgramExerciseSwapSheet(
                        currentExerciseId: "",
                        currentExerciseName: "Add Exercise",
                        onSelect: { catalogExercise in
                            pendingAdd = (
                                dayId: dayId,
                                exercise: AddedExercise(
                                    id: UUID().uuidString,
                                    exerciseId: catalogExercise.id,
                                    priority: .standard,
                                    wavePrescriptions: AddedExercise.defaultWavePrescriptions,
                                    setsByWeek: AddedExercise.defaultSetsByWeek
                                )
                            )
                            addingToDayId = nil
                        },
                        onCancel: {
                            pendingAdd = nil
                            addingToDayId = nil
                        }
                    )
                }
            }
            // Customize sheet that opens immediately after picking a new exercise
            .sheet(isPresented: Binding(
                get: { pendingNewExercise != nil },
                set: { if !$0 { pendingNewExercise = nil } }
            )) {
                if let pending = pendingNewExercise {
                    let synth = syntheticTemplate(for: pending.exercise.exerciseId)
                    ExerciseCustomizationSheet(
                        exerciseId: pending.exercise.exerciseId,
                        exerciseTemplate: synth,
                        template: template,
                        existingOverride: nil,
                        onApply: { newOverride in
                            let committed = AddedExercise(
                                id: pending.exercise.id,
                                exerciseId: pending.exercise.exerciseId,
                                priority: .standard,
                                wavePrescriptions: newOverride.wavePrescriptions ?? AddedExercise.defaultWavePrescriptions,
                                setsByWeek: newOverride.setsByWeek ?? AddedExercise.defaultSetsByWeek
                            )
                            previewOverrides.addExercise(committed, toDay: pending.dayId)
                        },
                        onReset: { }
                    )
                }
            }
            // Customize sheet for editing an existing added exercise
            .sheet(isPresented: Binding(
                get: { customizingAddedExercise != nil },
                set: { if !$0 { customizingAddedExercise = nil } }
            )) {
                if let target = customizingAddedExercise,
                   let added = previewOverrides.addedByDay[target.dayId]?.first(where: { $0.id == target.instanceId }) {
                    let synth = syntheticTemplate(for: added.exerciseId)
                    let existingAsOverride = ExerciseWaveOverride(
                        wavePrescriptions: added.wavePrescriptions,
                        setsByWeek: added.setsByWeek
                    )
                    ExerciseCustomizationSheet(
                        exerciseId: added.exerciseId,
                        exerciseTemplate: synth,
                        template: template,
                        existingOverride: existingAsOverride,
                        onApply: { newOverride in
                            let updated = AddedExercise(
                                id: added.id,
                                exerciseId: added.exerciseId,
                                priority: added.priority,
                                wavePrescriptions: newOverride.wavePrescriptions ?? AddedExercise.defaultWavePrescriptions,
                                setsByWeek: newOverride.setsByWeek ?? AddedExercise.defaultSetsByWeek
                            )
                            if var exercises = previewOverrides.addedByDay[target.dayId] {
                                exercises = exercises.map { $0.id == added.id ? updated : $0 }
                                previewOverrides.addedByDay[target.dayId] = exercises
                            }
                        },
                        onReset: {
                            let reset = AddedExercise(
                                id: added.id,
                                exerciseId: added.exerciseId,
                                priority: added.priority,
                                wavePrescriptions: AddedExercise.defaultWavePrescriptions,
                                setsByWeek: AddedExercise.defaultSetsByWeek
                            )
                            if var exercises = previewOverrides.addedByDay[target.dayId] {
                                exercises = exercises.map { $0.id == added.id ? reset : $0 }
                                previewOverrides.addedByDay[target.dayId] = exercises
                            }
                        }
                    )
                }
            }
        }

        private func exerciseRow(day: ProgramDayTemplate, exercise: ProgramExerciseTemplate, template: ProgramTemplate) -> some View {
            let override = previewOverrides.slotOverrides[exercise.exerciseId]
            let isDeleted = override?.isDeleted == true
            let effectiveId = override?.substituteExerciseId ?? exercise.exerciseId
            let isSwapped = !isDeleted && override?.substituteExerciseId != nil
            let isCustomized = !isDeleted && (override?.wavePrescriptions != nil || override?.setsByWeek != nil)

            return HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ExerciseCatalog.displayName(for: effectiveId))
                            .font(.footnote)
                            .fontWeight(.medium)
                            .strikethrough(isDeleted)

                        if isSwapped {
                            Image(systemName: "arrow.left.arrow.right.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if isCustomized {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.teal)
                        }
                    }

                    Text(waveSummaryText(for: exercise, override: isDeleted ? nil : override, template: template))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .opacity(isDeleted ? 0.4 : 1.0)

                Spacer()

                if isDeleted {
                    Button("Undo") {
                        let existing = previewOverrides.slotOverrides[exercise.exerciseId]!
                        previewOverrides.slotOverrides[exercise.exerciseId] = existing.unmarkedDeleted
                    }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            swappingExercise = (dayId: day.id, exerciseId: exercise.exerciseId)
                        } label: {
                            Image(systemName: "arrow.left.arrow.right.circle")
                                .font(.body)
                        }
                        .buttonStyle(.plain)

                        Button {
                            customizingExercise = (dayId: day.id, exerciseId: exercise.exerciseId)
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.body)
                        }
                        .buttonStyle(.plain)

                        Button {
                            let existing = previewOverrides.slotOverrides[exercise.exerciseId] ?? ExerciseWaveOverride()
                            previewOverrides.slotOverrides[exercise.exerciseId] = existing.markedDeleted
                        } label: {
                            Image(systemName: "trash")
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
            }
        }

        private func addedExerciseRow(dayId: String, added: AddedExercise) -> some View {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ExerciseCatalog.displayName(for: added.exerciseId))
                            .font(.footnote)
                            .fontWeight(.medium)
                        Image(systemName: "plus.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Text(addedWaveSummary(added))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        customizingAddedExercise = (dayId: dayId, instanceId: added.id)
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.body)
                    }
                    .buttonStyle(.plain)

                    Button {
                        if var exercises = previewOverrides.addedByDay[dayId] {
                            exercises.removeAll { $0.id == added.id }
                            previewOverrides.addedByDay[dayId] = exercises.isEmpty ? nil : exercises
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
        }

        private func addedWaveSummary(_ added: AddedExercise) -> String {
            [WaveType.a, .b, .c].compactMap { wave -> String? in
                guard let p = added.wavePrescriptions[wave] else { return nil }
                return "\(wave.displayName): \(p.repMin)-\(p.repMax) @\(p.targetRIR)RIR"
            }.joined(separator: "  ")
        }

        private func syntheticTemplate(for exerciseId: String) -> ProgramExerciseTemplate {
            ProgramExerciseTemplate(
                id: UUID().uuidString,
                order: 0,
                exerciseId: exerciseId,
                priority: .standard,
                notes: nil,
                prescriptions: [
                    WavePrescription(wave: .a, setMin: 3, setMax: 3, repMin: 8, repMax: 12, targetRIRMin: 3, targetRIRMax: 3),
                    WavePrescription(wave: .b, setMin: 3, setMax: 3, repMin: 8, repMax: 12, targetRIRMin: 2, targetRIRMax: 2),
                    WavePrescription(wave: .c, setMin: 3, setMax: 3, repMin: 6, repMax: 10, targetRIRMin: 1, targetRIRMax: 1),
                    WavePrescription(wave: .deload, setMin: 2, setMax: 2, repMin: 10, repMax: 15, targetRIRMin: 4, targetRIRMax: 4)
                ],
                setsByWeek: AddedExercise.defaultSetsByWeek
            )
        }

        private func waveSummaryText(
            for exercise: ProgramExerciseTemplate,
            override: ExerciseWaveOverride?,
            template: ProgramTemplate
        ) -> String {
            [WaveType.a, .b, .c].compactMap { wave -> String? in
                guard let basePrescription = exercise.prescription(for: wave) else { return nil }
                let weekNumber = template.weekRules.first(where: { $0.wave == wave })?.weekNumber ?? 1

                let repMin: Int
                let repMax: Int
                let rir: Int
                if let waveOverride = override?.wavePrescriptions?[wave] {
                    repMin = waveOverride.repMin
                    repMax = waveOverride.repMax
                    rir = waveOverride.targetRIR
                } else {
                    repMin = basePrescription.repMin
                    repMax = basePrescription.repMax
                    rir = basePrescription.targetRIRMax
                }

                let sets: Int
                if let overriddenSets = override?.setsByWeek, weekNumber - 1 < overriddenSets.count {
                    sets = overriddenSets[weekNumber - 1]
                } else {
                    sets = exercise.sets(forWeek: weekNumber, wave: wave)
                }

                return "\(wave.displayName): \(sets)×\(repMin)-\(repMax) @\(rir)RIR"
            }.joined(separator: "  ")
        }

        private func experienceToProgramLevel(_ exp: TrainingExperience) -> ProgramExperienceLevel {
            switch exp {
            case .new:          return .new
            case .intermediate: return .intermediate
            case .advanced:     return .advanced
            }
        }

        private func equipmentToProgramProfile(_ profile: EquipmentProfile) -> ProgramEquipmentProfile {
            switch profile {
            case .commercial:    return .commercialGym
            case .homeGym:       return .homeGymRack
            case .dumbbellsOnly: return .dumbbellsAndCables
            }
        }   
    
    // MARK: - Shared page header

    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if pageIndex > 0 {
                Button("Back") {
                    withAnimation { pageIndex -= 1 }
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            if pageIndex < totalPages - 1 {
                            Button("Next") {
                                withAnimation { pageIndex += 1 }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(action: finish) {
                                Text("Let's go")
                                    .frame(minWidth: 140)
                            }
                            .buttonStyle(.borderedProminent)
                        }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.systemBackground).shadow(radius: 1, y: -1))
    }

    // MARK: - Weekday helpers

    private static let weekdaySymbolsStatic: [String] = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter.shortWeekdaySymbols
    }()

    private var weekdaySymbols: [String] { Self.weekdaySymbolsStatic }

    private func defaultTrainingDays(for days: Int) -> Set<Int> {
        switch days {
        case 2:  return [2, 5]
        case 3:  return [2, 4, 6]
        case 4:  return [2, 3, 5, 6]
        case 5:  return [2, 3, 4, 5, 6]
        case 6:  return [2, 3, 4, 5, 6, 7]
        default: return [2, 4, 6]
        }
    }

    private func syncSelectedWeekdaysWithDaysPerWeek() {
        let desired = daysPerWeek
        if selectedWeekdays.isEmpty {
            selectedWeekdays = defaultTrainingDays(for: desired)
            return
        }
        if selectedWeekdays.count > desired {
            selectedWeekdays = Set(selectedWeekdays.sorted().prefix(desired))
        } else if selectedWeekdays.count < desired {
            var result = selectedWeekdays
            for w in defaultTrainingDays(for: desired) where result.count < desired {
                result.insert(w)
            }
            selectedWeekdays = result
        }
    }

    private func toggleWeekday(_ weekday: Int) {
        if selectedWeekdays.contains(weekday) {
            selectedWeekdays.remove(weekday)
        } else {
            guard selectedWeekdays.count < daysPerWeek else { return }
            selectedWeekdays.insert(weekday)
        }
    }

    // MARK: - Finish

    private func finish() {
        if selectedWeekdays.isEmpty {
            selectedWeekdays = defaultTrainingDays(for: daysPerWeek)
        }

        let weekdays = selectedWeekdays
            .map { min(max($0, 1), 7) }
            .sorted()

        let result = OnboardingResult(
            goal: selectedGoal,
            experience: selectedExperience,
            daysPerWeek: weekdays.count,
            trainingDaysOfWeek: weekdays,
            equipmentProfile: selectedEquipment,
            sessionLengthMinutes: sessionLengthMinutes,
            injuryFlags: Array(selectedInjuryFlags),
            minLoadIncrement: selectedLoadIncrement,
            startDate: mesoStartDate
        )

        onComplete(result, previewOverrides)
        dismiss()
    }
}

// MARK: - InjuryFlag CaseIterable

extension InjuryFlag: CaseIterable {
    static var allCases: [InjuryFlag] {
        [.lowBack, .knees, .shoulders, .elbows, .wrists]
    }
}

// MARK: - EquipmentProfile CaseIterable

extension EquipmentProfile: CaseIterable {
    static var allCases: [EquipmentProfile] {
        [.commercial, .homeGym, .dumbbellsOnly]
    }
}
