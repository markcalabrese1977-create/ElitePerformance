import SwiftUI

// MARK: - Simple program option model

struct ProgramOption: Identifiable {
    let id = UUID()
    let name: String
    let goalTag: String
    let daysPerWeek: Int
    let level: String
    let estimatedSessionMinutes: String
    let description: String
}

// MARK: - Program picker

struct ProgramPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let result: OnboardingResult
    let onChoose: (ProgramOption) -> Void

    // For now, use a small hard-coded catalog.
    // Later we can map this into ProgramCatalog / BlockBuilder.
    private var options: [ProgramOption] {
        [
            ProgramOption(
                name: "Hypertrophy 6-Week (5 Day)",
                goalTag: "Build muscle",
                daysPerWeek: 5,
                level: "Intermediate",
                estimatedSessionMinutes: "60–75",
                description: "Push / Pull / Lower split with structured progression and 3-to-grow-1-to-know logic baked in."
            ),
            ProgramOption(
                name: "Fat Loss Strength (3 Day)",
                goalTag: "Fat loss",
                daysPerWeek: 3,
                level: "Beginner–Intermediate",
                estimatedSessionMinutes: "40–60",
                description: "Full-body strength three times per week to maintain muscle while driving calorie burn."
            ),
            ProgramOption(
                name: "Maintenance Strength (3 Day)",
                goalTag: "Maintenance",
                daysPerWeek: 3,
                level: "Intermediate",
                estimatedSessionMinutes: "40–60",
                description: "Moderate volume program to keep you strong and consistent during busy phases."
            )
        ]
        .filter { option in
            // Simple filter so choices feel “personalized”
            // but we keep it very permissive for now.
            switch result.goal {
            case .fatLoss:
                return option.goalTag == "Fat loss" || option.goalTag == "Maintenance"
            case .hypertrophy:
                return option.goalTag == "Build muscle"
            case .strength:
                return option.goalTag == "Strength" || option.goalTag == "Build muscle"
            case .maintenance:
                return true
            }
        }
    }

    var body: some View {
        List {
            Section {
                header
            }

            Section("Recommended programs") {
                ForEach(options) { option in
                    Button {
                        // 1) Tell the parent which option was chosen
                        onChoose(option)
                        // 2) Dismiss the sheet so HomeView can flip over
                        dismiss()
                    } label: {
                        programRow(option)
                    }
                }
            }
        }
        .navigationTitle("Choose Program")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("We’ve matched a few starting points based on your answers.")
                .font(.subheadline)
            Text("\(result.goal.shortTag) · \(result.daysPerWeek) days/week · \(result.experience.rawValue)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func programRow(_ option: ProgramOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(option.name)
                    .font(.headline)
                Spacer()
                Text(option.goalTag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
            }

            Text(option.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                labelValue("Days", "\(option.daysPerWeek)/week")
                labelValue("Level", option.level)
                labelValue("Session", "\(option.estimatedSessionMinutes) min")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func labelValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .fontWeight(.semibold)
            Text(value)
        }
    }
}
