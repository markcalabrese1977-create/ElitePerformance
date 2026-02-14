import SwiftUI
import HealthKit

struct HealthWorkoutPickerSheet: View {
    let title: String
    let workouts: [HKWorkout]
    let onSelect: (HKWorkout) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(workouts, id: \.uuid) { workout in
                    Button {
                        onSelect(workout)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activityName(workout.workoutActivityType))
                                .font(.headline)

                            Text("\(workout.startDate.formatted(date: .abbreviated, time: .shortened)) • \(formatDuration(workout.duration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("Source: \(workout.sourceRevision.source.name)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }

    private func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .traditionalStrengthTraining:
            return "Strength Training"
        case .functionalStrengthTraining:
            return "Functional Strength"
        case .highIntensityIntervalTraining:
            return "HIIT"
        case .running:
            return "Running"
        case .walking:
            return "Walking"
        case .cycling:
            return "Cycling"
        default:
            return "Workout"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return "\(m):" + String(format: "%02d", s)
    }
}
