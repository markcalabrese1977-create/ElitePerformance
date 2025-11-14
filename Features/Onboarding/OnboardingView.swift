import SwiftUI

struct OnboardingView: View {
    var onComplete: (Goal, Int, User.Units) -> Void

    @State private var goal: Goal = .hypertrophy
    @State private var days: Int = 4
    @State private var units: User.Units = .lb

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome").font(.largeTitle).fontWeight(.bold)
            Text("Let's set up a sensible starting plan.").foregroundStyle(.secondary)

            Picker("Main goal", selection: $goal) {
                Text("Strength").tag(Goal.strength)
                Text("Hypertrophy").tag(Goal.hypertrophy)
                Text("Fat-loss").tag(Goal.fatLoss)
            }.pickerStyle(.segmented)

            Stepper("Days per week: \(days)", value: $days, in: 2...6)

            Picker("Units", selection: $units) {
                Text("lb").tag(User.Units.lb)
                Text("kg").tag(User.Units.kg)
            }.pickerStyle(.segmented)

            Spacer()

            PrimaryButton(title: "Create Program") {
                onComplete(goal, days, units)
                Haptics.success()
            }
        }
        .padding()
    }
}
