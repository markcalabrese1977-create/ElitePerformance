import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var context

    var onComplete: (Goal, Int, User.Units) -> Void

    @State private var goal: Goal = .hypertrophy
    @State private var days: Int = 4
    @State private var units: User.Units = .lb

    /// How many *training* weeks before the reload week.
    @State private var blockLength: Int = 6
    private let allowedBlockLengths = [4, 6, 8]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Let's set up a sensible starting plan.")
                .foregroundStyle(.secondary)

            Picker("Main goal", selection: $goal) {
                Text("Strength").tag(Goal.strength)
                Text("Hypertrophy").tag(Goal.hypertrophy)
                Text("Fat-loss").tag(Goal.fatLoss)
            }
            .pickerStyle(.segmented)

            Stepper("Days per week: \(days)", value: $days, in: 2...6)

            // NEW: block length picker
            VStack(alignment: .leading, spacing: 8) {
                Picker("Block length", selection: $blockLength) {
                    ForEach(allowedBlockLengths, id: \.self) { weeks in
                        Text("\(weeks) weeks").tag(weeks)
                    }
                }
                .pickerStyle(.segmented)

                Text("A lighter reload week will be added automatically after Week \(blockLength).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Units", selection: $units) {
                Text("lb").tag(User.Units.lb)
                Text("kg").tag(User.Units.kg)
            }
            .pickerStyle(.segmented)

            Spacer()

            PrimaryButton(title: "Create Program") {
                // Seed the whole block + reload week
                ProgramGenerator.seedInitialProgram(
                    goal: goal,
                    daysPerWeek: days,
                    blockLengthWeeks: blockLength,
                    context: context
                )

                // Let the parent do whatever it already does
                onComplete(goal, days, units)
                Haptics.success()
            }
        }
        .padding()
    }
}
