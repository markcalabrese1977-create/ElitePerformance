import SwiftUI
import SwiftData

/// Root router for the app.
/// MainTabView is always the root.
/// If no sessions exist yet, we automatically show onboarding as a sheet.
struct ContentView: View {
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]
    @State private var showFirstRunOnboarding = false

    var body: some View {
        MainTabView()
            .sheet(isPresented: $showFirstRunOnboarding) {
                NavigationStack {
                    OnboardingFlowView()
                        .navigationTitle("Welcome")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") {
                                    showFirstRunOnboarding = false
                                }
                            }
                        }
                }
            }
            .onAppear {
                // ✅ Anchor meso labeling once (today is W2D2)
                MesoLabel.ensureAnchor(week: 2, day: 2, on: Date())

                // First launch behavior: if there are no sessions yet, show onboarding
                if sessions.isEmpty {
                    showFirstRunOnboarding = true
                }
            }
    }
}

#Preview {
    ContentView()
}
