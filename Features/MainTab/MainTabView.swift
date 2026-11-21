import SwiftUI
import Combine
import SwiftData

// MARK: - Main Tab View

/// Cross-screen requests that are not tied to one view: "open the Restore screen" from the welcome sheet and "open
/// onboarding again" from Today. Views observe it and consume what they own.
@MainActor
final class AppRoute: ObservableObject {
    static let shared = AppRoute()

    enum Tab: Int { case today = 0, program, history, analytics, settings }

    @Published var selectedTab: Int = Tab.today.rawValue
    /// Set by `openRestore()`, cleared by Settings once it has opened the Restore screen.
    @Published var restoreRequested = false
    /// Bumped by `openOnboarding()`; the root view shows the welcome sheet on every change.
    @Published var onboardingRequests = 0

    func openRestore() {
        selectedTab = Tab.settings.rawValue
        restoreRequested = true
    }

    func openOnboarding() { onboardingRequests += 1 }
}

struct MainTabView: View {
    @ObservedObject private var route = AppRoute.shared

    var body: some View {
        TabView(selection: $route.selectedTab) {
            TodayTabView()
                .tabItem { Label("Today", systemImage: "bolt.circle") }
                .tag(AppRoute.Tab.today.rawValue)

            HomeView()
                .tabItem { Label("Program", systemImage: "list.bullet.rectangle") }
                .tag(AppRoute.Tab.program.rawValue)

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppRoute.Tab.history.rawValue)

            AnalyticsView()
                .tabItem { Label("Analytics", systemImage: "chart.bar") }
                .tag(AppRoute.Tab.analytics.rawValue)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppRoute.Tab.settings.rawValue)
        }
    }
}

// MARK: - Today Tab

struct TodayTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    @State private var showRestToday = false
    // Shown once, when the lifter never chose an effort mode and every RIR they recorded is 0.
    @State private var showEffortPrompt = false
    @State private var effortPromptShown = false
    @Environment(\.scenePhase) private var scenePhase

    // No verified off-device backup for 7 days: a banner, dismissed only until tomorrow.
    @ObservedObject private var autoBackup = AutoBackupService.shared
    @State private var bannerTick = 0
    @State private var bannerBusy = false

    private var showBackupBanner: Bool {
        _ = bannerTick; _ = autoBackup.statusRevision
        return autoBackup.status.shouldShowBanner(now: Date(), hasData: sessions.contains { $0.status == .completed })
    }

    private var activeBlockSessions: [Session] {
        let todayStart = Calendar.current.startOfDay(for: Date())

        let activeSessions = sessions.filter { $0.meso?.status == .active }
        // Carry-over: non-completed sessions still on the most recently archived
        // block, dated from today up to (but not including) the new meso's start.
        // Surfaces prior-block sessions in Today/Upcoming until the new program
        // begins, while leaving them attached to their archived block so their
        // original labels and week structure stay correct in History.
        let activeMesoStartDate = activeSessions.compactMap { $0.meso?.startDate }.min() ?? Date()
        let carryOverSessions = sessions.filter {
            $0.meso?.status == .archived &&
            $0.status != .completed &&
            $0.date >= todayStart &&
            $0.date < activeMesoStartDate
        }
        return (activeSessions + carryOverSessions).sorted { $0.date < $1.date }
    }

    private var visibleSessions: [Session] {
        if !activeBlockSessions.isEmpty {
            return activeBlockSessions
        }
        return sessions
    }

    private var upcomingSessions: [Session] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: todayStart)!

        return visibleSessions.filter { session in
            session.date >= tomorrowStart
        }
    }

    private var todaySession: Session? {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayEnd = Calendar.current.date(byAdding: .day, value: 1, to: todayStart)!

        return visibleSessions.first(where: { session in
            session.date >= todayStart && session.date < todayEnd
        })
    }

    /// True when today has a planned (not started) session that can be pushed.
    private var canRestToday: Bool {
        guard let session = todaySession else { return false }
        return session.status == .planned && session.meso != nil
    }

    var body: some View {
        NavigationStack {
            List {
                if showBackupBanner {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(autoBackup.iCloudAvailability == .available ? "No verified iCloud backup in the last 7 days" : "iCloud backups are unavailable",
                                  systemImage: "exclamationmark.icloud")
                                .font(.subheadline.bold())
                            Text(autoBackup.iCloudAvailability.explanation.map { $0 + " Your training history lives only on this device until a backup reaches iCloud." }
                                 ?? "Your training history lives only on this device until a backup reaches iCloud. Check Settings → Backup.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            // The buttons sit in a row when they fit, one under the other when they do not (iPhone SE width,
                            // accessibility text sizes: a row squeezed "Use local backups only" into a column of single letters).
                            ViewThatFits(in: .horizontal) {
                                HStack { bannerButtons }
                                VStack(alignment: .leading) { bannerButtons }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Closing the welcome sheet (or a failed setup) leaves no program: Today offers the way back in.
                if sessions.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No program yet")
                                .font(.headline)
                            Text("Answer a few questions and get a program built for your schedule and equipment.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Set up your program") { AppRoute.shared.openOnboarding() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    headerCard
                }

                if !upcomingSessions.isEmpty {
                    Section(header: Text("Upcoming")) {
                        ForEach(upcomingSessions) { session in
                            NavigationLink {
                                SessionView(
                                    viewModel: SessionScreenViewModel(session: session)
                                )
                            } label: {
                                SessionSummaryRow(session: session)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .clearsFloatingTabBar()
            .task { await autoBackup.refreshICloudAvailability() }   // so the iCloud reason shows on a fresh launch
            .task { await presentEffortPromptWhenIdle() }
            .alert("How do you want to track effort?", isPresented: $showEffortPrompt) {
                ForEach(EffortMode.allCases, id: \.self) { mode in
                    Button(mode.title) { EffortTracking.choose(mode, in: context) }
                }
            } message: {
                Text(EffortMode.allCases.map { "\($0.title): \($0.oneLine)" }.joined(separator: "\n"))
            }
            .navigationTitle("Today")
            .sheet(isPresented: $showRestToday) {
                if let meso = todaySession?.meso {
                    RestTodayFlow(meso: meso, onFinish: { showRestToday = false })
                }
            }
        }
    }

    /// Polls (cancelled when Today leaves the screen) until nothing else is presented, then raises the effort prompt once.
    private func presentEffortPromptWhenIdle() async {
        while !Task.isCancelled && !effortPromptShown {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
            let needs = EffortTracking.needsModePrompt(profile: profile, in: context)
            if !needs { return }
            if EffortTracking.canPresentPrompt(
                needsPrompt: needs, shownThisLaunch: effortPromptShown, sceneActive: scenePhase == .active,
                nothingPresented: PresentationProbe.nothingPresented(), restoreInProgress: RestoreActivity.inProgress,
                healthKitRequesting: HealthKitAuthorizationCoordinator.shared.isPresentingRequest) {
                effortPromptShown = true
                showEffortPrompt = true
                return
            }
        }
    }

    @ViewBuilder private var bannerButtons: some View {
        Button(bannerBusy ? "Backing up…" : "Back up now") {
            bannerBusy = true
            Task {
                _ = await autoBackup.backUpNow(container: context.container)
                bannerBusy = false
                bannerTick += 1
            }
        }
        .disabled(bannerBusy)
        if autoBackup.iCloudAvailability != .available {
            Button("Use local backups only") {
                autoBackup.status.localOnly = true
                bannerTick += 1
            }
        }
        Button("Dismiss") {
            autoBackup.status.dismissBannerForToday(now: Date())
            bannerTick += 1
        }
    }

    // MARK: - Header / Up Next Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Elite Performance")
                    .font(.headline)

                if let session = todaySession {
                    if let dayLabel = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !dayLabel.isEmpty {
                        Text(dayLabel)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    Text(session.weekDayLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No session planned for today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let session = todaySession {
                TodaySessionCard(session: session)
            } else {
                Text("Tap on a future session to start planning your week.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if canRestToday {
                Button {
                    showRestToday = true
                } label: {
                    HStack {
                        Image(systemName: "bed.double")
                        Text("Rest today")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 4, y: 2)
        )
    }
}

// MARK: - Today Session Card

struct TodaySessionCard: View {
    let session: Session

    private var exercisesText: String {
        let count = session.items.count
        if count == 0 {
            return "No exercises yet"
        } else if count == 1 {
            return "1 exercise"
        } else {
            return "\(count) exercises"
        }
    }

    private enum Mode {
        case start
        case recap
    }

    private var mode: Mode {
        switch session.status {
        case .planned, .inProgress: return .start
        case .completed: return .recap
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Session")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            if let dayLabel = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dayLabel.isEmpty {
                Text(dayLabel)
                    .font(.headline)
            }

            Text(session.date, style: .date)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(exercisesText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                if mode == .start {
                    NavigationLink {
                        SessionView(
                            viewModel: SessionScreenViewModel(session: session)
                        )
                    } label: {
                        Text("Start Session")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    NavigationLink {
                        SessionView(
                            viewModel: SessionScreenViewModel(session: session)
                        )
                    } label: {
                        Text("View Session")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Session Summary Row (Upcoming list)

struct SessionSummaryRow: View {
    let session: Session

    private var exercisesText: String {
        let count = session.items.count
        if count == 0 {
            return "No exercises yet"
        } else if count == 1 {
            return "1 exercise"
        } else {
            return "\(count) exercises"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let dayLabel = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !dayLabel.isEmpty {
                    Text(dayLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(exercisesText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(session.status.displayTitle)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.15))
                .foregroundColor(statusColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch session.status {
        case .planned:    return .secondary
        case .inProgress: return .blue
        case .completed:  return .green
        }
    }
}
