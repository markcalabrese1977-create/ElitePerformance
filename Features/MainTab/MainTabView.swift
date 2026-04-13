import SwiftUI
import SwiftData

// MARK: - Main Tab View



import SwiftUI
import SwiftData

// MARK: - Main Tab View

struct MainTabView: View {
    @AppStorage(AppStorageKeys.appMode) private var appModeRaw: String = AppMode.mark.rawValue
    private var mode: AppMode { AppMode(rawValue: appModeRaw) ?? .mark }

    var body: some View {
        TabView {
            switch mode {
            case .mark:
                markTabs
            case .angela:
                plannerTabs
            }
        }
    }

    // MARK: - Tab Groups

    @ViewBuilder
    private var markTabs: some View {
        TodayTabView()
            .tabItem { Label("Today", systemImage: "bolt.circle") }

        ExtrasTabView()
            .tabItem { Label("Extras", systemImage: "heart.circle") }

        HomeView()
            .tabItem { Label("Program", systemImage: "list.bullet.rectangle") }

        HistoryView()
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

        // ✅ NEW: Analytics tab v1
        AnalyticsView()
            .tabItem { Label("Analytics", systemImage: "chart.bar") }

        SettingsView()
            .tabItem { Label("Settings", systemImage: "gearshape") }
    }

    @ViewBuilder
    private var plannerTabs: some View {
        PlannerHomeView()
            .tabItem { Label("Planner", systemImage: "calendar") }

        HistoryView()
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

        // ✅ NEW: Analytics tab v1 (available in planner mode too)
        AnalyticsView()
            .tabItem { Label("Analytics", systemImage: "chart.bar") }

        SettingsView()
            .tabItem { Label("Settings", systemImage: "gearshape") }
    }
}

// MARK: - Today Tab

struct TodayTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    private var activeBlockSessions: [Session] {
        sessions.filter { $0.meso?.status == .active }
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
    
    private func dayIndexInWeek(for session: Session) -> Int? {
        let sameWeek = visibleSessions
            .filter { $0.weekIndex == session.weekIndex }
            .sorted { lhs, rhs in
                if let l = lhs.programIndex, let r = rhs.programIndex {
                    return l < r
                }
                return lhs.date < rhs.date
            }

        guard let idx = sameWeek.firstIndex(where: { $0.id == session.id }) else { return nil }
        return idx + 1
    }

    private func plannedZone2Targets(forWeek week: Int) -> [Int] {
        // Your rule:
        // - This week (week 8): 2 sessions
        // - Weeks 9+ (and 10): 3 sessions
        //
        // Sessions happen on: after D2 and D4 + rest day (Thu).
        // We'll represent "after D2" as dayIndex 2, "after D4" as 4.
        // Rest day is handled separately via weekday check.
        if week <= 8 { return [2] }          // after D2 only
        return [2, 4]                        // after D2 and after D4
    }

    private var isRestDayToday: Bool {
        // Your rest day is Thursday
        Calendar.current.component(.weekday, from: Date()) == 5 // 1=Sun ... 5=Thu
    }

    var body: some View {
        NavigationStack {
            List {
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
            .navigationTitle("Today")
        }
    }

    // MARK: - Header / Up Next Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Elite Performance")
                    .font(.headline)

                if let session = todaySession {
                    Text(session.weekDayLabel)
                        .font(.subheadline)
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

            // ✅ Always show the Extras card daily
            Zone2AndCoreCard(
                todaySession: todaySession,
                todayDayIndex: todaySession.flatMap { dayIndexInWeek(for: $0) },
                isRestDayToday: isRestDayToday,
                todayDate: Date()
            )
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
            Text("Today’s Session")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            Text(session.date, style: .date)
                .font(.headline)

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
                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)

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
struct Zone2AndCoreCard: View {
    let todaySession: Session?      // ✅ now optional
    let todayDayIndex: Int?         // optional
    let isRestDayToday: Bool
    let todayDate: Date             // pass Date() from parent

    private var week: Int {
        todaySession?.weekIndex ?? 0
    }

    private func isLoggedToday(_ kind: ExtrasEntry.Kind) -> Bool {
        let cal = Calendar.current
        return ExtrasLogStore.load().contains { entry in
            entry.kind == kind && cal.isDate(entry.date, inSameDayAs: todayDate)
        }
    }

    // ✅ Week logic: week 8 = 2 sessions, week 9+ = 3 sessions
    private var zone2ShouldShowToday: Bool {
        // Rest day always eligible
        if isRestDayToday { return true }

        // If we don't have a lift session/day index, we can't know D2/D4
        guard week > 0, let d = todayDayIndex else { return false }

        let afterD2 = (d == 2)
        let afterD4 = (week >= 9 && d == 4)
        return afterD2 || afterD4
    }

    private var zone2Label: String {
        if isRestDayToday { return "Zone 2 (Rest Day)" }
        if todayDayIndex == 2 { return "Zone 2 (After D2)" }
        if todayDayIndex == 4 { return "Zone 2 (After D4)" }
        return "Zone 2"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Zone 2 prompt
            if zone2ShouldShowToday {
                VStack(alignment: .leading, spacing: 6) {
                    Text(zone2Label)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text("Easy conversational pace · 30–45 min · keep it smooth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        if isLoggedToday(.zone2) {
                            Text("Zone 2 logged ✅")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(Color(.tertiarySystemBackground))
                                )
                        } else {
                            Button("Log Zone 2") {
                                ExtrasLogStore.add(
                                    ExtrasEntry(
                                        kind: .zone2,
                                        date: todayDate,
                                        durationMinutes: 35,
                                        notes: "Zone 2"
                                    )
                                )
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Spacer()
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                )
            }

            // Core stability prompt (daily light dose)
            VStack(alignment: .leading, spacing: 6) {
                Text("Core Stability (Carries + Bracing)")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("Pick 1 carry + 1 brace (6–10 min total). No fatigue spiral.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("• Carry: farmer / suitcase / front rack · 3–5 x 30–60s\n• Brace: dead bug / bird dog / Pallof press · 2–3 sets")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    if isLoggedToday(.core) {
                        Text("Core logged ✅")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(Color(.tertiarySystemBackground))
                            )
                    } else {
                        Button("Log Core") {
                            ExtrasLogStore.add(
                                ExtrasEntry(
                                    kind: .core,
                                    date: todayDate,
                                    durationMinutes: 8,
                                    notes: "Carry + brace"
                                )
                            )
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }
}
