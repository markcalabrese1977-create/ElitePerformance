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
    @StateObject private var seedGuard = SeedBackupGuard()

    var body: some View {
        MainTabView()
            .injectLoadUnit()
            .seedBackupGuard(seedGuard)
            .sheet(isPresented: $showFirstRunOnboarding) {
                NavigationStack {
                    OnboardingFlowView { result, overrides in
                        // A verified backup first (an empty store has nothing to protect and goes straight through).
                        seedGuard.run(container: modelContext.container) {
                            MesoSeedingCoordinator.applyOnboardingResult(
                                result,
                                context: modelContext,
                                overrides: overrides
                            )
                        }
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
                if sessions.isEmpty && !RestoreActivity.inProgress {
                    showFirstRunOnboarding = true
                }

                requestHealthKitAccessIfNeeded()
                AutoBackupService.shared.foregrounded(container: modelContext.container)
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    requestHealthKitAccessIfNeeded()
                    AutoBackupService.shared.foregrounded(container: modelContext.container)
                }
            }
            // Data arriving (a restore on a new phone rebuilds this view while the store is still empty) ends first-run:
            // the welcome sheet must not sit on top of the restored program.
            .onChange(of: sessions.isEmpty) { empty in
                if !empty { showFirstRunOnboarding = false }
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
