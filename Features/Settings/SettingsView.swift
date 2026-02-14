import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var users: [User]
    @AppStorage(AppStorageKeys.appMode) private var appModeRaw: String = AppMode.mark.rawValue
    private var mode: AppMode { AppMode(rawValue: appModeRaw) ?? .mark }
    
    var body: some View {
        let user = users.first
        Form {
            Section("App Mode") {
                Picker("Mode", selection: $appModeRaw) {
                    ForEach(AppMode.allCases) { m in
                        Text(m.title).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Switching modes does not change saved workout data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
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
