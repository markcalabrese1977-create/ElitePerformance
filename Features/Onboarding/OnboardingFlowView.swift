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
    /// nil = no limit.
    var sessionLengthMinutes: Int?
    var injuryFlags: [InjuryFlag]
    var minLoadIncrement: Double
    /// User-chosen meso start date from the date picker on the final page.
    var startDate: Date
    /// Equipment the fitter works from. Defaults (full gym, no checklist) mean "no limits".
    var equipmentPreset: EquipmentPreset = .fullGym
    /// Explicit gear checklist; empty means "use the preset's defaults".
    var equipmentChecklist: [GearTag] = []
    /// The unit the lifter sees loads in; `minLoadIncrement` is in this unit. Results encoded before kg support decode as lb.
    var unit: LoadUnit = .lb
    /// Set by "Use my own program": the lifter's own days and exercises, no waves. nil for every generated program.
    var ownProgram: OwnProgramSpec? = nil
}

extension OnboardingResult {
    private enum CodingKeys: String, CodingKey {
        case goal, experience, daysPerWeek, trainingDaysOfWeek, equipmentProfile, sessionLengthMinutes
        case injuryFlags, minLoadIncrement, startDate, equipmentPreset, equipmentChecklist, unit, ownProgram
    }

    /// Results encoded before the preset and checklist existed decode as full gym with no checklist.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            goal: try c.decode(Goal.self, forKey: .goal),
            experience: try c.decode(TrainingExperience.self, forKey: .experience),
            daysPerWeek: try c.decode(Int.self, forKey: .daysPerWeek),
            trainingDaysOfWeek: try c.decode([Int].self, forKey: .trainingDaysOfWeek),
            equipmentProfile: try c.decode(EquipmentProfile.self, forKey: .equipmentProfile),
            sessionLengthMinutes: try c.decodeIfPresent(Int.self, forKey: .sessionLengthMinutes),
            injuryFlags: try c.decode([InjuryFlag].self, forKey: .injuryFlags),
            minLoadIncrement: try c.decode(Double.self, forKey: .minLoadIncrement),
            startDate: try c.decode(Date.self, forKey: .startDate),
            equipmentPreset: try c.decodeIfPresent(EquipmentPreset.self, forKey: .equipmentPreset) ?? .fullGym,
            equipmentChecklist: try c.decodeIfPresent([GearTag].self, forKey: .equipmentChecklist) ?? [],
            unit: try c.decodeIfPresent(LoadUnit.self, forKey: .unit) ?? .lb,
            ownProgram: try c.decodeIfPresent(OwnProgramSpec.self, forKey: .ownProgram)
        )
    }
}

// MARK: - Equipment labels and editor

extension EquipmentPreset {
    var title: String {
        switch self {
        case .fullGym:        return "Full gym"
        case .homeBarbell:    return "Home gym"
        case .dumbbellsBench: return "Dumbbells + bench"
        case .machinesOnly:   return "Machines only"
        }
    }

    var summary: String {
        switch self {
        case .fullGym:        return "Barbells, dumbbells, machines and cables."
        case .homeBarbell:    return "Barbell and rack, dumbbells, bench and a pull-up bar."
        case .dumbbellsBench: return "Dumbbells and a bench, nothing else."
        case .machinesOnly:   return "Selectorized machines, cables and a Smith machine."
        }
    }
}

extension GearTag {
    var label: String {
        switch self {
        case .barbell:    return "Barbell"
        case .ezBar:      return "EZ bar"
        case .dumbbell:   return "Dumbbells"
        case .bench:      return "Bench"
        case .rack:       return "Rack"
        case .cable:      return "Cable machine"
        case .machine:    return "Machines"
        case .smith:      return "Smith machine"
        case .pullUpBar:  return "Pull-up bar"
        case .dipStation: return "Dip station"
        }
    }
}

/// Preset cards plus a "Customize equipment" checklist pre-filled from the preset. Shared by onboarding and Settings.
/// The checklist reads as "no checklist" (empty) whenever it equals the preset's defaults.
struct EquipmentEditor: View {
    @Binding var preset: EquipmentPreset
    @Binding var checklist: Set<GearTag>
    @State private var customizing = false

    /// The gear actually in play: the checklist when present, else the preset's defaults.
    private var shown: Set<GearTag> { checklist.isEmpty ? preset.defaultEquipment : checklist }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(EquipmentPreset.allCases, id: \.self) { option in
                Button {
                    preset = option
                    checklist = []
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(.headline).foregroundColor(.primary)
                            Text(option.summary).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: preset == option ? "checkmark.circle.fill" : "circle")
                            .imageScale(.large)
                            .foregroundColor(preset == option ? .blue : .secondary)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 16)
                        .fill(preset == option ? Color.blue.opacity(0.08) : Color(.systemGray6)))
                }
                .buttonStyle(.plain)
            }

            DisclosureGroup("Customize equipment", isExpanded: $customizing) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(GearTag.allCases, id: \.self) { gear in
                        Toggle(gear.label, isOn: Binding(
                            get: { shown.contains(gear) },
                            set: { on in
                                var next = shown
                                if on { next.insert(gear) } else { next.remove(gear) }
                                checklist = next == preset.defaultEquipment ? [] : next
                            }
                        ))
                        .font(.subheadline)
                    }
                    Text("Starts from the preset. Exercises that need gear you untick are swapped out.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.subheadline.bold())
            .padding(.top, 4)
        }
    }
}

// MARK: - Draft

/// The answers onboarding starts from: the saved profile when one exists, today's defaults on first run.
struct OnboardingDraft: Equatable {
    var goal: Goal = .hypertrophy
    var experience: TrainingExperience = .intermediate
    var daysPerWeek: Int = 4
    var preset: EquipmentPreset = .fullGym
    var checklist: Set<GearTag> = []
    /// No limit by default.
    var sessionLengthMinutes: Int? = nil
    var loadIncrement: Double = 2.5
    var unit: LoadUnit = .lb
    var injuryFlags: Set<InjuryFlag> = []
    /// Training weekdays (1 = Sunday ... 7 = Saturday) to pre-select; empty means "use the default pattern".
    var weekdays: Set<Int> = []

    init() {}

    /// The profile's answers plus the weekdays of the active block. When `activeWeekdays` holds 2...6 days they are
    /// pre-selected and set the day count; otherwise (no active block, or an unusable set) nothing changes.
    init(profile: UserProfile?, activeWeekdays: Set<Int>) {
        self.init(profile: profile)
        let valid = activeWeekdays.filter { (1...7).contains($0) }
        if (2...6).contains(valid.count) {
            weekdays = valid
            daysPerWeek = valid.count
        }
    }

    /// The distinct weekdays of every session (planned and completed) in a block.
    static func weekdays(of meso: MesoBlock?, calendar: Calendar = .current) -> Set<Int> {
        guard let meso else { return [] }
        return Set(meso.sessions.map { calendar.component(.weekday, from: $0.date) })
    }

    init(profile: UserProfile?) {
        guard let profile else { return }
        goal = Goal(rawValue: profile.primaryGoal.rawValue) ?? .hypertrophy
        experience = profile.experience
        daysPerWeek = min(max(profile.daysPerWeek, 2), 6)
        preset = profile.equipmentPreset
        checklist = profile.equipmentChecklist
        sessionLengthMinutes = profile.sessionLengthMinutes
        loadIncrement = profile.minLoadIncrement
        unit = profile.loadUnit
        injuryFlags = Set(profile.injuryFlags)
    }

    /// Weekdays (1 = Sunday ... 7 = Saturday) used when the lifter has not picked any.
    static func defaultTrainingDays(for days: Int) -> Set<Int> {
        switch days {
        case 2:  return [2, 5]
        case 3:  return [2, 4, 6]
        case 4:  return [2, 3, 5, 6]
        case 5:  return [2, 3, 4, 5, 6]
        case 6:  return [2, 3, 4, 5, 6, 7]
        default: return [2, 4, 6]
        }
    }

    /// The schedule page is complete only when the chosen weekdays match the stepper: the program is picked by the
    /// weekday count and the seeder refuses any other number of days.
    static func scheduleIsComplete(weekdays: Set<Int>, daysPerWeek: Int) -> Bool {
        weekdays.count == daysPerWeek
    }

    /// What the schedule page says while the chips and the stepper disagree; nil when they match.
    static func scheduleMessage(weekdays: Set<Int>, daysPerWeek: Int) -> String? {
        scheduleIsComplete(weekdays: weekdays, daysPerWeek: daysPerWeek) ? nil : "Select \(daysPerWeek) days"
    }

    /// What tapping straight through produces.
    func result(startDate: Date, weekdays: Set<Int> = []) -> OnboardingResult {
        let days = (weekdays.isEmpty ? Self.defaultTrainingDays(for: daysPerWeek) : weekdays)
            .map { min(max($0, 1), 7) }.sorted()
        return OnboardingResult(
            goal: goal,
            experience: experience,
            daysPerWeek: days.count,
            trainingDaysOfWeek: days,
            equipmentProfile: preset.legacyProfile,
            sessionLengthMinutes: sessionLengthMinutes,
            injuryFlags: Array(injuryFlags),
            minLoadIncrement: loadIncrement,
            startDate: startDate,
            equipmentPreset: preset,
            equipmentChecklist: checklist == preset.defaultEquipment ? [] : checklist.sorted { $0.rawValue < $1.rawValue },
            unit: unit
        )
    }
}

// MARK: - Flow

/// How the host answered "Let's go". The flow dismisses only on `.done`.
enum OnboardingFinish {
    case done
    /// Nothing was created; the flow stays on the preview with the reason in an alert.
    case failed(String)
    /// The host stopped before creating anything (for example the lifter declined a backup); the flow stays as it was.
    case cancelled
}

struct OnboardingFlowView: View {
    @Environment(\.dismiss) private var dismiss

    /// The host creates the program and reports back through the third argument.
    let onComplete: (OnboardingResult, PreviewOverrides, @escaping (OnboardingFinish) -> Void) -> Void
    /// Shown under the goal choices when set (the first-run welcome sheet): leave setup and restore a backup instead.
    let onRestore: (() -> Void)?

    @State private var isFinishing = false
    @State private var finishFailure: String?

    @State private var pageIndex: Int = 0
    @State private var showOwnProgram = false

    // Page 1 — Goal
    @State private var selectedGoal: Goal

    // Page 2 — Experience
    @State private var selectedExperience: TrainingExperience

    // Page 3 — Schedule
    @State private var daysPerWeek: Int
    @State private var selectedWeekdays: Set<Int> = []

    // Page 4 — Equipment + Session length
    @State private var selectedPreset: EquipmentPreset
    @State private var selectedChecklist: Set<GearTag>
    @State private var sessionLengthMinutes: Int?
    @State private var selectedLoadIncrement: Double
    @State private var selectedUnit: LoadUnit

    // Page 5 — Joint limitations
    @State private var selectedInjuryFlags: Set<InjuryFlag>

    // Page 6 — Start date picker. Seeded by init(initialStartDate:) so a date
    // chosen upstream (meso summary) survives into this flow.
    @State private var mesoStartDate: Date
    @State private var showStartDatePicker = false

    // Page 6 — Per-exercise overrides, add, and delete
    @State private var previewOverrides: PreviewOverrides = .empty
    /// Slot targets are (day, position in the fitted day), matching `PreviewOverrides.slotKeyed`.
    @State private var customizingExercise: (dayId: String, slotIndex: Int)? = nil
    @State private var swappingExercise: (dayId: String, slotIndex: Int)? = nil
    /// The profile the current overrides were made against; overrides are dropped when it changes.
    @State private var overridesSignature: String = ""
    @State private var addingToDayId: String? = nil
    // Staged during picker selection; promoted to pendingNewExercise in picker's onDismiss,
    // which fires only after the picker animation fully completes — eliminating the
    // asyncAfter overlap that caused onDisappear flicker on the customize sheet.
    @State private var pendingAdd: (dayId: String, exercise: AddedExercise)? = nil
    @State private var pendingNewExercise: (dayId: String, exercise: AddedExercise)? = nil
    @State private var customizingAddedExercise: (dayId: String, instanceId: String)? = nil

    private let totalPages = 6

    /// - Parameters:
    ///   - initialStartDate: date to pre-load into the meso start date picker.
    ///     Normalized to the start of its day and floored at today, because the
    ///     picker's own lower bound is today — a carried-in date that has gone
    ///     stale must not open the flow below the range it can select from.
    ///     Defaults to today, which is what first-run onboarding wants.
    ///   - onComplete: receives the finished result and the preview overrides.
    init(
        initialStartDate: Date = Date(),
        profile: UserProfile? = nil,
        activeWeekdays: Set<Int> = [],
        onRestore: (() -> Void)? = nil,
        onComplete: @escaping (OnboardingResult, PreviewOverrides, @escaping (OnboardingFinish) -> Void) -> Void
    ) {
        self.onComplete = onComplete
        self.onRestore = onRestore
        let draft = OnboardingDraft(profile: profile, activeWeekdays: activeWeekdays)
        _selectedWeekdays = State(initialValue: draft.weekdays)
        _selectedGoal = State(initialValue: draft.goal)
        _selectedExperience = State(initialValue: draft.experience)
        _daysPerWeek = State(initialValue: draft.daysPerWeek)
        _selectedPreset = State(initialValue: draft.preset)
        _selectedChecklist = State(initialValue: draft.checklist)
        _sessionLengthMinutes = State(initialValue: draft.sessionLengthMinutes)
        _selectedLoadIncrement = State(initialValue: draft.loadIncrement)
        _selectedUnit = State(initialValue: draft.unit)
        _selectedInjuryFlags = State(initialValue: draft.injuryFlags)
        let calendar = Calendar.current
        _mesoStartDate = State(
            initialValue: max(
                calendar.startOfDay(for: initialStartDate),
                calendar.startOfDay(for: Date())
            )
        )
    }

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
        .onChange(of: fitSignature) { _, newValue in
            // The fitted template changed under the overrides: slot positions no longer mean the same slots.
            if newValue != overridesSignature { previewOverrides = .empty }
            overridesSignature = newValue
        }
        .onAppear { overridesSignature = fitSignature }
        .fullScreenCover(isPresented: $showOwnProgram) {
            OwnProgramFlowView(base: currentBaseResult(), initialWeekdays: selectedWeekdays, onCreate: { result in
                showOwnProgram = false
                submit(result, overrides: .empty)
            }, onCancel: { showOwnProgram = false })
        }
        .alert("Couldn't create your program", isPresented: Binding(
            get: { finishFailure != nil }, set: { if !$0 { finishFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(finishFailure ?? "")
        }
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

            Button { showOwnProgram = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use my own program").font(.headline).foregroundColor(.primary)
                        Text("Enter the days and exercises you already train. No waves, one prescription per exercise.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemGray6)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("useMyOwnProgram")

            if let onRestore {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Already use Elite Performance?")
                        .font(.subheadline.bold())
                    Button("Restore from a backup", action: onRestore)
                        .font(.subheadline)
                }
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
                    // A new count starts from the default evenly spaced pattern (3 -> Mon/Wed/Fri); the lifter then adjusts.
                    selectedWeekdays = defaultTrainingDays(for: daysPerWeek)
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

                if let message = OnboardingDraft.scheduleMessage(weekdays: selectedWeekdays, daysPerWeek: daysPerWeek) {
                    Text("\(message) (\(selectedWeekdays.count) selected)")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                } else {
                    Text("Selected \(selectedWeekdays.count) of \(daysPerWeek) days")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
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
                Text("What equipment do you have?")
                    .font(.subheadline.bold())

                EquipmentEditor(
                    preset: Binding(
                        get: { selectedPreset },
                        set: { newPreset in
                            selectedPreset = newPreset
                            // Auto-set sensible load increment defaults
                            if UnitAwareRounding.incrementChoices(unit: selectedUnit).contains(selectedLoadIncrement) {
                                selectedLoadIncrement = defaultLoadIncrement(for: newPreset.legacyProfile)
                            }
                        }
                    ),
                    checklist: $selectedChecklist
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Units")
                    .font(.subheadline.bold())

                Picker("Units", selection: Binding(
                    get: { selectedUnit },
                    set: { newUnit in
                        guard newUnit != selectedUnit else { return }
                        selectedUnit = newUnit
                        // The increment is in the lifter's unit: reset it to the new unit's default for this gear.
                        selectedLoadIncrement = defaultLoadIncrement(for: selectedPreset.legacyProfile)
                    }
                )) {
                    ForEach(LoadUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Smallest weight increment available")
                    .font(.subheadline.bold())

                Text("Used to calculate load progressions accurately.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ForEach(UnitAwareRounding.incrementChoices(unit: selectedUnit), id: \.self) { increment in
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

                // "No limit" first: the fit then never trims for time.
                Picker("Session length", selection: Binding(
                    get: { sessionLengthMinutes == nil ? 0 : 1 },
                    set: { sessionLengthMinutes = $0 == 0 ? nil : (sessionLengthMinutes ?? 60) }
                )) {
                    Text("No limit").tag(0)
                    Text("Set a limit").tag(1)
                }
                .pickerStyle(.segmented)

                if let minutes = sessionLengthMinutes {
                    Stepper(value: Binding(get: { minutes }, set: { sessionLengthMinutes = $0 }), in: 30...120, step: 15) {
                        Text("\(minutes) minutes")
                            .font(.headline)
                    }
                }
            }

            Spacer()
        }
    }

    private func defaultLoadIncrement(for profile: EquipmentProfile) -> Double {
        // lb: 2.5, or 5 for dumbbells only. kg: 1.25, or 2.5 for dumbbells only.
        UnitAwareRounding.defaultIncrement(unit: selectedUnit, coarse: profile == .dumbbellsOnly)
    }

    private func formatIncrement(_ value: Double) -> String {
        LoadFormatter(unit: selectedUnit).textInUnit(value)
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
        case .hips:      return "Hips"
        }
    }

    // MARK: - Page 6: Program Preview

        private var programPreviewPage: some View {
            let weekdays = selectedWeekdays.map { min(max($0, 1), 7) }.sorted()
            // The same fit seeding runs, so the preview is the program that will be created.
            let fit = currentFit()
            let template = fit.template
            let reason = ProgramApplicationService.recommendationReason(
                        goal: selectedGoal,
                        daysPerWeek: weekdays.count,
                        injuries: selectedInjuryFlags,
                        fit: fit
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

                timeAdviceBanner(fit)

                adjustedForYouSection(fit)

                // Planned weekly hard sets per muscle; it follows every swap, delete, add and set change made below.
                PlannedVolumeCard(input: .template(template, previewOverrides))

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

                                ForEach(Array(day.exerciseTemplates.enumerated()), id: \.element.id) { index, exercise in
                                    exerciseRow(day: day, slotIndex: index, exercise: exercise, template: template)
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

                // Start date — opens a date picker in its own sheet context.
                Button {
                    showStartDatePicker = true
                } label: {
                    HStack {
                        Text("Start date")
                            .font(.subheadline)
                        Spacer()
                        Text(mesoStartDate, format: .dateTime.month().day().year())
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)

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
                   dayTemplate.exerciseTemplates.indices.contains(target.slotIndex) {
                    // The slot of the fitted template is the baseline to edit against: a swap replaces the
                    // exercise but keeps the slot's prescriptions (see DUPProgramSeeder.applying). Only the title
                    // follows the swap.
                    let exerciseTemplate = dayTemplate.exerciseTemplates[target.slotIndex]
                    let key = SlotKey(dayId: target.dayId, slotIndex: target.slotIndex)
                    let titleExerciseId = previewOverrides.slotKeyed[key]?.substituteExerciseId ?? exerciseTemplate.exerciseId
                    ExerciseCustomizationSheet(
                        exerciseId: titleExerciseId,
                        exerciseTemplate: exerciseTemplate,
                        template: template,
                        existingOverride: previewOverrides.slotKeyed[key],
                        onApply: { newOverride in
                            let existing = previewOverrides.slotKeyed[key] ?? ExerciseWaveOverride()
                            previewOverrides.slotKeyed[key] = existing.applyingPrescription(
                                wavePrescriptions: newOverride.wavePrescriptions,
                                setsByWeek: newOverride.setsByWeek
                            )
                        },
                        onReset: {
                            if let existing = previewOverrides.slotKeyed[key],
                               existing.substituteExerciseId != nil {
                                previewOverrides.slotKeyed[key] = existing.prescriptionCleared
                            } else {
                                previewOverrides.slotKeyed.removeValue(forKey: key)
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
                if let target = swappingExercise,
                   let dayTemplate = template.dayTemplates.first(where: { $0.id == target.dayId }),
                   dayTemplate.exerciseTemplates.indices.contains(target.slotIndex) {
                    let key = SlotKey(dayId: target.dayId, slotIndex: target.slotIndex)
                    let displayId = previewOverrides.slotKeyed[key]?.substituteExerciseId
                        ?? dayTemplate.exerciseTemplates[target.slotIndex].exerciseId
                    ExercisePickerList(
                        mode: .swap(currentExerciseId: displayId, currentName: ExerciseCatalog.displayName(for: displayId)),
                        onSelect: { catalogExercise in
                            let existing = previewOverrides.slotKeyed[key] ?? ExerciseWaveOverride()
                            previewOverrides.slotKeyed[key] = existing.applyingSubstitute(catalogExercise.id)
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
                    ExercisePickerList(
                        mode: .add,
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
            .sheet(isPresented: $showStartDatePicker) {
                NavigationStack {
                    VStack {
                        DatePicker("Start date", selection: $mesoStartDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .padding()
                        Spacer()
                    }
                    .navigationTitle("Start date")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showStartDatePicker = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }

        private func exerciseRow(day: ProgramDayTemplate, slotIndex: Int, exercise: ProgramExerciseTemplate, template: ProgramTemplate) -> some View {
            let key = SlotKey(dayId: day.id, slotIndex: slotIndex)
            let override = previewOverrides.slotKeyed[key]
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

                        if exercise.priority == .optional || exercise.priority == .firstCut {
                            Text("Optional")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }

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
                        let existing = previewOverrides.slotKeyed[key]!
                        previewOverrides.slotKeyed[key] = existing.unmarkedDeleted
                    }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            swappingExercise = (dayId: day.id, slotIndex: slotIndex)
                        } label: {
                            Image(systemName: "arrow.left.arrow.right.circle")
                                .font(.body)
                        }
                        .buttonStyle(.plain)

                        Button {
                            customizingExercise = (dayId: day.id, slotIndex: slotIndex)
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.body)
                        }
                        .buttonStyle(.plain)

                        Button {
                            let existing = previewOverrides.slotKeyed[key] ?? ExerciseWaveOverride()
                            previewOverrides.slotKeyed[key] = existing.markedDeleted
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

        /// The checklist as stored on the result: empty unless it differs from the preset's defaults.
        private var resultChecklist: [GearTag] {
            selectedChecklist == selectedPreset.defaultEquipment ? [] : selectedChecklist.sorted { $0.rawValue < $1.rawValue }
        }

        private var currentWeekdayCount: Int { selectedWeekdays.map { min(max($0, 1), 7) }.count }

        private func currentFit() -> FitResult {
            let template = ProgramApplicationService.selectTemplate(goal: selectedGoal, daysPerWeek: currentWeekdayCount)
            return ProgramFitter.fit(template, profile: ProgramApplicationService.fitProfile(
                preset: selectedPreset, checklist: resultChecklist, injuries: Array(selectedInjuryFlags),
                sessionMinutes: sessionLengthMinutes, experience: selectedExperience, goal: selectedGoal))
        }

        /// Everything the fit depends on. Slot-keyed overrides only mean something against the same fitted template,
        /// so they are dropped when this changes.
        private var fitSignature: String {
            [selectedGoal.rawValue, String(currentWeekdayCount), selectedPreset.rawValue,
             resultChecklist.map(\.rawValue).joined(separator: ","),
             selectedInjuryFlags.map(\.rawValue).sorted().joined(separator: ","),
             sessionLengthMinutes.map(String.init) ?? "none", selectedExperience.rawValue].joined(separator: "|")
        }

        @ViewBuilder
        private func timeAdviceBanner(_ fit: FitResult) -> some View {
            if fit.reasons.contains(where: { $0.kind == .overBudget }) {
                let needed = ProgramApplicationService.sessionMinutesNeeded(for: fit.advice)
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        needed.map { "This plan needs about \($0) min per session. Choose \($0) min, or fewer training days." }
                            ?? "This plan needs more than 2 hours per session. Choose fewer training days.",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if let needed {
                            Button("Use \(needed) min") { sessionLengthMinutes = needed }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Change schedule") { withAnimation { pageIndex = 2 } }
                            .buttonStyle(.bordered)
                    }
                    .font(.footnote)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
            }
        }

        @ViewBuilder
        private func adjustedForYouSection(_ fit: FitResult) -> some View {
            if !fit.reasons.isEmpty {
                let titles = Dictionary(uniqueKeysWithValues: fit.template.dayTemplates.map { ($0.dayNumber, $0.title) })
                let groups: [(title: String, lines: [String])] = {
                    var result: [(String, [String])] = []
                    // The same cue on several exercises of one day reads once.
                    func unique(_ lines: [String]) -> [String] { var seen = Set<String>(); return lines.filter { seen.insert($0).inserted } }
                    let general = unique(fit.reasons.filter { $0.dayNumber == nil }.map(\.message))
                    if !general.isEmpty { result.append(("All days", general)) }
                    for day in fit.template.dayTemplates.sorted(by: { $0.dayNumber < $1.dayNumber }) {
                        let lines = unique(fit.reasons.filter { $0.dayNumber == day.dayNumber }.map(\.message))
                        if !lines.isEmpty { result.append((titles[day.dayNumber] ?? day.title, lines)) }
                    }
                    return result
                }()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Adjusted for you")
                        .font(.subheadline.bold())
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.title)
                                .font(.caption.bold())
                            ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                                Text("• \(line)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
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

    /// Next is held on the schedule page until the chips match the stepper.
    private var canAdvance: Bool {
        pageIndex != 2 || OnboardingDraft.scheduleIsComplete(weekdays: selectedWeekdays, daysPerWeek: daysPerWeek)
    }

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
                            .disabled(!canAdvance)
                        } else {
                            Button(action: finish) {
                                Text("Let's go")
                                    .frame(minWidth: 140)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isFinishing)
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

    private func defaultTrainingDays(for days: Int) -> Set<Int> { OnboardingDraft.defaultTrainingDays(for: days) }

    private func toggleWeekday(_ weekday: Int) {
        if selectedWeekdays.contains(weekday) {
            selectedWeekdays.remove(weekday)
        } else {
            guard selectedWeekdays.count < daysPerWeek else { return }
            selectedWeekdays.insert(weekday)
        }
    }

    // MARK: - Finish

    /// The answers so far as a result (goal, experience, equipment ...), before any program is chosen.
    private func currentBaseResult() -> OnboardingResult {
        var draft = OnboardingDraft()
        draft.goal = selectedGoal
        draft.experience = selectedExperience
        draft.daysPerWeek = daysPerWeek
        draft.preset = selectedPreset
        draft.checklist = selectedChecklist
        draft.sessionLengthMinutes = sessionLengthMinutes
        draft.loadIncrement = selectedLoadIncrement
        draft.unit = selectedUnit
        draft.injuryFlags = selectedInjuryFlags
        return draft.result(startDate: mesoStartDate, weekdays: selectedWeekdays)
    }

    private func finish() { submit(currentBaseResult(), overrides: previewOverrides) }

    /// Hands a finished result to the caller (first run: seeds it; Change program: asks before replacing and backs up first).
    private func submit(_ result: OnboardingResult, overrides: PreviewOverrides) {
        isFinishing = true
        onComplete(result, overrides) { finish in
            isFinishing = false
            switch finish {
            case .done:             dismiss()
            case .failed(let why):  finishFailure = why
            case .cancelled:        break
            }
        }
    }
}

// MARK: - InjuryFlag CaseIterable

extension InjuryFlag: CaseIterable {
    static var allCases: [InjuryFlag] {
        [.lowBack, .knees, .shoulders, .elbows, .wrists, .hips]
    }
}

// MARK: - EquipmentProfile CaseIterable

extension EquipmentProfile: CaseIterable {
    static var allCases: [EquipmentProfile] {
        [.commercial, .homeGym, .dumbbellsOnly]
    }
}
