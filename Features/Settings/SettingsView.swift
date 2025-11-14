import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var users: [User]

    var body: some View {
        let user = users.first
        Form {
            Section("Coach Voice") {
                Picker("Style", selection: Binding(get: { user?.coachVoice ?? .casual }, set: { v in user?.coachVoice = v })) {
                    Text("Casual").tag(User.CoachVoice.casual)
                    Text("Strict").tag(User.CoachVoice.strict)
                }
                .pickerStyle(.segmented)
            }
            Section("Progression") {
                Toggle("Auto-progression", isOn: Binding(get: { user?.progressionEnabled ?? true }, set: { v in user?.progressionEnabled = v }))
            }
        }
        .navigationTitle("Settings")
    }
}
