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
    // A session missed in the last two days: Do today / Move / Skip.
    @State private var placing: OverdueRequest?
    @State private var skipping: Session?
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

    private var recentlyMissed: [Session] { SessionItemEditService.recentlyMissed(in: sessions) }

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

                if !recentlyMissed.isEmpty {
                    Section(header: Text("Missed")) {
                        ForEach(recentlyMissed) { session in
                            OverdueSessionCard(session: session, onPlace: { placing = $0 }, onSkip: { skipping = $0 })
                        }
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
            .sheet(item: $placing) { request in
                OverdueMoveFlow(request: request, onFinish: { placing = nil })
            }
            .alert("Skip this session?", isPresented: Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } })) {
                Button("Skip", role: .destructive) {
                    if let s = skipping { try? SessionItemEditService.skip(s, in: context) }
                    skipping = nil
                }
                Button("Cancel", role: .cancel) { skipping = nil }
            } message: {
                Text("It stays in your history as missed, and still counts toward the missed-session check.")
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

// MARK: - Overdue (missed) planned sessions

/// What the lifter asked to do with a missed session; opens `OverdueMoveFlow`.
struct OverdueRequest: Identifiable {
    let session: Session
    let toToday: Bool
    var id: PersistentIdentifier { session.persistentModelID }
}

/// Text for the overdue surfaces. Pure, so the tests read the same strings the screens show.
enum OverdueText {
    static func weekday(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated)) }
    static func day(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    /// "Missed Tue" (Today card) - the W#D# label rides along as the subtitle.
    static func title(_ s: Session) -> String { "Missed \(weekday(s.date))" }
    static func subtitle(_ s: Session) -> String { "\(s.dayLabel ?? "Session") · \(s.weekDayLabel)" }
    static let prompt = "Do today, move, or skip"
    static func rowTitle(_ s: Session) -> String { "\(day(s.date)) · \(s.dayLabel ?? "Session") · \(s.weekDayLabel)" }
    static func missedRow(_ n: Int) -> String { "Missed (\(n))" }
    static let footer = "Only dates change: loads, weeks, exercises and logged work stay as they are, and the W#D# label stays with the session. A skipped session still counts as missed."

    /// The same move list as Rest today: the placed session, then every session it pushes to the next free day.
    static func moveLines(_ plan: SessionItemEditService.SlidePlan) -> [String] { RestTodayModel.moveLines(plan) }

    static func refusalText(_ refusal: SessionItemEditService.SlideRefusal) -> String { RestTodayModel.refusalText(refusal) }

    static func errorText(_ error: SessionItemEditService.SlideError) -> String {
        switch error {
        case .refused(let r): return refusalText(r) + " Nothing was changed."
        case .planStale: return "The schedule changed since the preview. Nothing was changed - review the updated preview."
        case .verificationFailed: return "The change would alter this lift's history order, so nothing was written."
        case .saveFailed: return "The change couldn't be saved, so nothing was written."
        }
    }
}

/// Three ways out of a missed session. Compact enough for a 375-pt screen: the buttons wrap under each other when they do not fit.
struct OverdueActions: View {
    let session: Session
    let onPlace: (OverdueRequest) -> Void
    let onSkip: (Session) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder private var buttons: some View {
        Button("Do today") { onPlace(OverdueRequest(session: session, toToday: true)) }
            .buttonStyle(.borderedProminent)
        Button("Move") { onPlace(OverdueRequest(session: session, toToday: false)) }
        Button("Skip", role: .destructive) { onSkip(session) }
    }
}

/// The card on Today for a session missed in the last two days.
struct OverdueSessionCard: View {
    let session: Session
    let onPlace: (OverdueRequest) -> Void
    let onSkip: (Session) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(OverdueText.title(session))
                .font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
            Text(OverdueText.subtitle(session))
                .font(.headline)
            Text(OverdueText.prompt)
                .font(.subheadline).foregroundStyle(.secondary)
            OverdueActions(session: session, onPlace: onPlace, onSkip: onSkip)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("overdueCard")
    }
}

/// Preview and confirm for Do today / Move: the same shape as the Rest-today screen.
struct OverdueMoveFlow: View {
    @Environment(\.modelContext) private var modelContext

    let request: OverdueRequest
    let onFinish: () -> Void

    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var errorMessage: String?

    private var target: Date { request.toToday ? Date() : date }

    var body: some View {
        let plan = SessionItemEditService.planPlaceOverdue(request.session, on: target, context: modelContext)
        NavigationStack {
            Form {
                if !request.toToday {
                    Section {
                        DatePicker("Move to", selection: $date, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    }
                }
                if let refusal = plan.refusal {
                    Section { Text(OverdueText.refusalText(refusal)).foregroundStyle(.secondary) }
                } else {
                    Section {
                        if !plan.pushed.isEmpty { Text(RestTodayModel.moveHeading(plan)).font(.callout).foregroundStyle(.secondary) }
                        ForEach(Array(OverdueText.moveLines(plan).enumerated()), id: \.offset) { _, l in Text(l) }
                        if let end = RestTodayModel.blockEndLine(plan) { Text(end).font(.callout) }
                    } header: {
                        Text(request.toToday ? "Do it today" : "Move it")
                    } footer: {
                        Text(OverdueText.footer)
                    }
                    if !plan.warnings.isEmpty {
                        Section("Heads up") {
                            ForEach(Array(RestTodayModel.warningLines(plan).enumerated()), id: \.offset) { _, w in
                                Text(w).font(.callout).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle(request.toToday ? "Do today" : "Move session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) }
                // A refused plan has nothing to confirm: Cancel is the one way out (pick another day and Move comes back).
                if plan.refusal == nil { ToolbarItem(placement: .confirmationAction) {
                    Button(request.toToday ? "Do today" : "Move") {
                        do {
                            try SessionItemEditService.applySlide(plan, in: modelContext)
                            onFinish()
                        } catch let e as SessionItemEditService.SlideError {
                            errorMessage = OverdueText.errorText(e)
                        } catch {
                            errorMessage = "The change couldn't be saved, so nothing was written."
                        }
                    }
                    .disabled(!plan.isApplicable)
                } }
            }
        }
    }
}

/// The Program tab's collapsed row for sessions missed more than two days ago.
struct MissedSessionsRow: View {
    let sessions: [Session]
    let onPlace: (OverdueRequest) -> Void
    let onSkip: (Session) -> Void

    var body: some View {
        DisclosureGroup(OverdueText.missedRow(sessions.count)) {
            ForEach(sessions) { s in
                VStack(alignment: .leading, spacing: 6) {
                    Text(OverdueText.rowTitle(s)).font(.subheadline)
                    OverdueActions(session: s, onPlace: onPlace, onSkip: onSkip)
                }
                .padding(.vertical, 4)
            }
        }
        .accessibilityIdentifier("missedRow")
    }
}
