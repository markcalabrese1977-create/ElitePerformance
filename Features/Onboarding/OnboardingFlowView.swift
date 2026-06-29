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
}

// MARK: - Flow

struct OnboardingFlowView: View {
    @Environment(\.dismiss) private var dismiss

    let onComplete: (OnboardingResult) -> Void

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

                    VStack(spacing: 6) {
                        ForEach(template.dayTemplates.sorted { $0.dayNumber < $1.dayNumber }, id: \.id) { day in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(day.title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(day.role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(day.exerciseTemplates.filter { $0.priority != .optional }.count) exercises")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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

                Text("You can swap any exercise at any time. Your schedule and loads are yours to adjust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
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
            minLoadIncrement: selectedLoadIncrement
        )

        onComplete(result)
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
