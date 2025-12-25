import SwiftUI
import SwiftData

// MARK: - Goal labels used in onboarding

extension TrainingGoal {
    var title: String {
        switch self {
        case .fatLoss:     return "Lose fat"
        case .hypertrophy: return "Build muscle"
        case .strength:    return "Get stronger"
        case .maintenance: return "Maintain / move better"
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
        case .maintenance:
            return "Stay consistent with moderate volume."
        }
    }
}

// MARK: - Result model

struct OnboardingResult: Codable {
    var goal: TrainingGoal
    var experience: TrainingExperience
    var daysPerWeek: Int
    /// 1 = Sunday ... 7 = Saturday (Calendar weekday values)
    var trainingDaysOfWeek: [Int]
}

// MARK: - Flow

struct OnboardingFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var pageIndex: Int = 0

    @State private var selectedGoal: TrainingGoal = .hypertrophy
    @State private var selectedExperience: TrainingExperience = .intermediate
    @State private var daysPerWeek: Int = 4

    /// Selected training weekdays (Calendar weekday values: 1=Sun ... 7=Sat)
    @State private var selectedWeekdays: Set<Int> = []

    var body: some View {
        VStack {
            if pageIndex == 0 {
                goalPage
            } else {
                schedulePage
            }

            bottomBar
        }
        .padding()
        .navigationTitle("Welcome")
        .navigationBarTitleDisplayMode(.inline)
        
    }

    // MARK: - Pages

    private var goalPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("What's your main goal right now?")
                .font(.title2.bold())

            Text("We’ll use this to pick a sensible starting program.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(TrainingGoal.allCases, id: \.self) { goal in
                Button {
                    selectedGoal = goal
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(goal.title)
                                .font(.headline)
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
                            .fill(selectedGoal == goal ? Color.blue.opacity(0.08)
                                                       : Color(.systemGray6))
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    private var schedulePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Training schedule")
                .font(.title2.bold())

            Text("We’ll match a block to your schedule and experience.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Days per week
            VStack(alignment: .leading, spacing: 8) {
                Text("Training frequency")
                    .font(.subheadline.bold())

                Stepper(value: $daysPerWeek, in: 2...6) {
                    Text("Days per week: \(daysPerWeek)")
                        .font(.headline)
                }
                .onChange(of: daysPerWeek) { _ in
                    syncSelectedWeekdaysWithDaysPerWeek()
                }
            }

            // Which weekdays
            VStack(alignment: .leading, spacing: 8) {
                Text("Which days do you want to train?")
                    .font(.subheadline.bold())

                Text("Pick up to \(daysPerWeek) days. We’ll repeat this pattern each week.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    ForEach(0..<weekdaySymbols.count, id: \.self) { index in
                        let weekday = index + 1   // 1=Sun ... 7=Sat
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
                                        .fill(
                                            isSelected
                                            ? Color.blue.opacity(0.15)
                                            : Color.secondary.opacity(0.08)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Selected \(selectedWeekdays.count) of \(daysPerWeek) days")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Experience chips
            VStack(alignment: .leading, spacing: 8) {
                Text("Training experience")
                    .font(.subheadline.bold())

                HStack(spacing: 8) {
                    ForEach(TrainingExperience.allCases, id: \.self) { experience in
                        Button {
                            selectedExperience = experience
                        } label: {
                            Text(experience.label)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(
                                            selectedExperience == experience
                                            ? Color.blue.opacity(0.15)
                                            : Color.secondary.opacity(0.08)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
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

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if pageIndex > 0 {
                Button("Back") {
                    withAnimation {
                        pageIndex -= 1
                    }
                }
            }

            Spacer()

            if pageIndex == 0 {
                Button("Next") {
                    withAnimation {
                        pageIndex = 1
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: finish) {
                    Text("Create Program")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 16)
    }

    // MARK: - Weekday helpers

    private static let weekdaySymbolsStatic: [String] = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter.shortWeekdaySymbols
    }()

    private var weekdaySymbols: [String] {
        Self.weekdaySymbolsStatic
    }

    /// Default training pattern for a given frequency (Calendar weekday values).
    private func defaultTrainingDays(for days: Int) -> Set<Int> {
        switch days {
        case 2:  return [2, 5]                 // Mon, Thu
        case 3:  return [2, 4, 6]              // Mon, Wed, Fri
        case 4:  return [2, 3, 5, 6]           // Mon, Tue, Thu, Fri
        case 5:  return [2, 3, 4, 5, 6]        // Mon–Fri
        case 6:  return [2, 3, 4, 5, 6, 7]     // Mon–Sat
        default: return [2, 4, 6]              // fallback: Mon, Wed, Fri
        }
    }

    private func syncSelectedWeekdaysWithDaysPerWeek() {
        let desired = daysPerWeek

        if selectedWeekdays.isEmpty {
            selectedWeekdays = defaultTrainingDays(for: desired)
            return
        }

        if selectedWeekdays.count > desired {
            let sorted = selectedWeekdays.sorted()
            selectedWeekdays = Set(sorted.prefix(desired))
        } else if selectedWeekdays.count < desired {
            var result = selectedWeekdays
            let defaults = defaultTrainingDays(for: desired)
            for w in defaults where result.count < desired {
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
        // Ensure we have a sensible weekday pattern
        if selectedWeekdays.isEmpty {
            selectedWeekdays = defaultTrainingDays(for: daysPerWeek)
        }

        // NOTE: trainingDaysOfWeek is the single source of truth for schedule; daysPerWeek is derived.
        let weekdays = selectedWeekdays
            .map { min(max($0, 1), 7) }
            .sorted()

        let result = OnboardingResult(
            goal: selectedGoal,
            experience: selectedExperience,
            daysPerWeek: weekdays.count,
            trainingDaysOfWeek: weekdays
        )

        // DEBUG
        print("DEBUG Onboarding.finish – goal=\(result.goal), daysPerWeek=\(result.daysPerWeek), weekdays=\(weekdays)")

        // 1) Seed a fresh block
        ProgramCatalog.applyOnboardingResult(
            result,
            context: modelContext
        )

        print("DEBUG Onboarding.finish – completed applyOnboardingResult")

        // 2) Close the sheet / nav stack (no-op on first-run root, but should close sheets)
        dismiss()

        print("DEBUG Onboarding.finish – called dismiss()")
    }
}
