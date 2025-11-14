import SwiftUI
import SwiftData

@main
struct ElitePerformanceApp: App {
    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - RootView

struct RootView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if hasOnboarded {
                HomeView()
            } else {
                OnboardingView(onComplete: { goal, days, units in
                    // Create user
                    let user = User(units: units, coachVoice: .casual, progressionEnabled: true)
                    context.insert(user)
                    // Seed starter exercises + session
                    ProgramGenerator.seedInitialProgram(goal: goal, daysPerWeek: days, context: context)
                    try? context.save()
                    hasOnboarded = true
                })
            }
        }
    }
}

// MARK: - SwiftData Container

fileprivate var sharedModelContainer: ModelContainer = {
    let schema = Schema([User.self, Exercise.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: false)
    do {
        return try ModelContainer(for: schema, configurations: [config])
    } catch {
        fatalError("Could not create ModelContainer: \(error)")
    }
}()
