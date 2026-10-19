import SwiftUI
import SwiftData

/// Root router for the app.
/// MainTabView is always the root.
/// If no sessions exist yet, we automatically show onboarding as a sheet.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFirstRunOnboarding = false

    var body: some View {
        MainTabView()
            .sheet(isPresented: $showFirstRunOnboarding) {
                NavigationStack {
                    OnboardingFlowView { result, overrides in
                        MesoSeedingCoordinator.applyOnboardingResult(
                            result,
                            context: modelContext,
                            overrides: overrides
                        )
                    }
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
                SyncFieldBackfillService.runIfNeeded(in: modelContext)
                AppStateBridge.importFromUserDefaultsIfNeeded(in: modelContext)
                AppStateBridge.restoreUserDefaultsFromAppStateIfAvailable(in: modelContext)

                // First launch behavior: if there are no sessions yet, show onboarding
                if sessions.isEmpty {
                    showFirstRunOnboarding = true
                }

                requestHealthKitAccessIfNeeded()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { requestHealthKitAccessIfNeeded() }
            }
            .onChange(of: showFirstRunOnboarding) { showing in
                if !showing { requestHealthKitAccessIfNeeded() }
            }
    }

    /// HealthKit permissions are requested from here (never from workout completion): after
    /// onboarding, with nothing presented, once per launch. If something is presented the coordinator
    /// defers, and the next active moment tries again.
    private func requestHealthKitAccessIfNeeded() {
        Task { @MainActor in
            // Let sheet transitions settle before probing for presented controllers.
            try? await Task.sleep(nanoseconds: 700_000_000)
            await HealthKitAuthorizationCoordinator.shared.attemptIfNeeded(
                onboardingComplete: !showFirstRunOnboarding && !sessions.isEmpty,
                isNothingPresented: { PresentationProbe.nothingPresented() }
            )
        }
    }
}

#Preview {
    ContentView()
}
