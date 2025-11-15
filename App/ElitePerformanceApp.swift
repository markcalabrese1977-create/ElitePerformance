import SwiftUI
import SwiftData

// MARK: - Root View

struct RootView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if hasOnboarded {
                MainTabView()
            } else {
                OnboardingView { goal, days, units in
                    // Create user record
                    let user = User(
                        units: units,
                        coachVoice: .casual,
                        progressionEnabled: true
                    )
                    context.insert(user)

                    // Seed initial program based on onboarding answers
                    ProgramGenerator.seedInitialProgram(
                        goal: goal,
                        daysPerWeek: days,
                        context: context
                    )

                    try? context.save()
                    hasOnboarded = true
                }
            }
        }
    }
}

// MARK: - App Entry

@main
struct ElitePerformanceApp: App {

    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            User.self,
            Session.self,
            SessionItem.self,
            SetLog.self,
            PRIndex.self
        ])

        let config = ModelConfiguration(isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(sharedModelContainer)
        }
    }
}
