import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var context

    /// Called after we finish seeding the program and storing units/goal info.
    /// Signature stays the same so Home/MainTab don't need to change.
    var onComplete: (Goal, Int, User.Units) -> Void

    @State private var goal: Goal = .hypertrophy
    @State private var days: Int = 4
    @State private var units: User.Units = .lb

    /// Number of "hard" weeks before deload.
    @State private var blockLengthWeeks: Int = 6

    /// Whether to add a lighter deload week at the end of the block.
    @State private var includeDeloadWeek: Bool = true

    /// Computed summary for the block, shown under the controls.
    private var blockSummaryText: String {
        let hard = blockLengthWeeks
        if includeDeloadWeek {
            let total = hard + 1
            return "Block: \(hard) hard week\(hard == 1 ? "" : "s") + 1 deload (\(total) weeks total)"
        } else {
            return "Block: \(hard) hard week\(hard == 1 ? "" : "s")"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Let's set up a sensible starting plan.")
                .foregroundStyle(.secondary)

            // Goal
            VStack(alignment: .leading, spacing: 8) {
                Text("Main goal")
                    .font(.headline)

                Picker("Main goal", selection: $goal) {
                    Text("Strength").tag(Goal.strength)
                    Text("Hypertrophy").tag(Goal.hypertrophy)
                    Text("Fat-loss").tag(Goal.fatLoss)
                }
                .pickerStyle(.segmented)
            }

            // Days per week
            VStack(alignment: .leading, spacing: 8) {
                Text("Training frequency")
                    .font(.headline)

                Stepper("Days per week: \(days)", value: $days, in: 2...6)
                    .accessibilityIdentifier("daysPerWeekStepper")
            }

            // Block length + deload + summary
            VStack(alignment: .leading, spacing: 8) {
                Text("Block length")
                    .font(.headline)

                Stepper("Hard weeks: \(blockLengthWeeks)", value: $blockLengthWeeks, in: 1...8)

                Toggle("Add deload week at end", isOn: $includeDeloadWeek)
                    .font(.subheadline)

                Text(blockSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Units
            VStack(alignment: .leading, spacing: 8) {
                Text("Units")
                    .font(.headline)

                Picker("Units", selection: $units) {
                    Text("lb").tag(User.Units.lb)
                    Text("kg").tag(User.Units.kg)
                }
                .pickerStyle(.segmented)
            }

            Spacer()

            PrimaryButton(title: "Create Program") {
                let clampedWeeks = max(1, min(blockLengthWeeks, 8))

                // Seed the full program block
                ProgramGenerator.seedInitialProgram(
                    goal: goal,
                    daysPerWeek: days,
                    totalWeeks: clampedWeeks,
                    includeDeloadWeek: includeDeloadWeek,
                    context: context
                )

                // Bubble up core onboarding info (goal, days, units)
                onComplete(goal, days, units)
                Haptics.success()
            }
        }
        .padding()
    }
}
