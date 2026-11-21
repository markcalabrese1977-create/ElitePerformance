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

                // Below the session card, not above it: on the smallest screen (iPhone SE, 667 pt) a banner above pushed
                // "Start Session" under the floating tab bar, where it needed a second tap.
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
                            HStack {
                                Button(bannerBusy ? "Backing up…" : "Back up now") {
                                    bannerBusy = true
                                    Task {
                                        _ = await autoBackup.backUpNow(container: context.container)
                                        bannerBusy = false
                                        bannerTick += 1
                                    }
                                }
                                .disabled(bannerBusy)
                                Spacer()
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
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
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
            .task { await autoBackup.refreshICloudAvailability() }   // so the iCloud reason shows on a fresh launch
            .navigationTitle("Today")
            .sheet(isPresented: $showRestToday) {
                if let meso = todaySession?.meso {
                    RestTodayFlow(meso: meso, onFinish: { showRestToday = false })
                }
            }
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
