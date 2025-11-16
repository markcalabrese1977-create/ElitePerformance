import SwiftUI
import SwiftData

// MARK: - Main Tab View

struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "bolt.circle")
                }

            HomeView()
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet.rectangle")
                }
        }
    }
}

// MARK: - Today View

/// Shows today's session (if any) plus block position (Week / Day) and upcoming sessions.
struct TodayView: View {
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    private var calendar: Calendar { Calendar.current }

    // MARK: Session buckets

    /// All sessions that fall on today's date.
    private var todaySessions: [Session] {
        sessions.filter { calendar.isDateInToday($0.date) }
            .sorted { $0.date < $1.date }
    }

    /// If there's a non-completed session today, that's the "work to do".
    private var todaysIncompleteSession: Session? {
        todaySessions.first(where: { $0.status != .completed })
    }

    /// If everything for today is done, show the (first) completed one.
    private var todaysCompletedSession: Session? {
        // If there is any non-completed today, we don't treat today as "done".
        guard todaysIncompleteSession == nil else { return nil }
        return todaySessions.first(where: { $0.status == .completed })
    }

    /// Sessions strictly after today, one per calendar day.
    private var upcomingSessions: [Session] {
        guard !sessions.isEmpty else { return [] }

        let todayStart = calendar.startOfDay(for: Date())
        let sorted = sessions.sorted { $0.date < $1.date }

        var seenDays = Set<Date>()
        var result: [Session] = []

        for session in sorted {
            let day = calendar.startOfDay(for: session.date)
            // Only look at days after today
            guard day > todayStart else { continue }

            // Skip additional sessions on the same calendar day
            if !seenDays.contains(day) {
                seenDays.insert(day)
                result.append(session)
            }
        }

        return result
    }

    /// Convenience: the very next upcoming session (for preview when today is empty).
    private var nextUpcomingSession: Session? {
        upcomingSessions.first
    }

    /// Earliest and latest session dates in the current block.
    private var blockStartDate: Date? {
        sessions.map(\.date).min()
    }

    private var blockEndDate: Date? {
        sessions.map(\.date).max()
    }

    // MARK: - Block position (Week / Day / Weekday)

    private struct BlockPosition {
        let currentWeek: Int
        let totalWeeks: Int
        let dayInWeek: Int
        let weekdayName: String
    }

    private var blockPosition: BlockPosition? {
        guard
            let start = blockStartDate,
            let end = blockEndDate
        else {
            return nil
        }

        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        guard
            let totalDaySpan = calendar.dateComponents([.day], from: startDay, to: endDay).day
        else {
            return nil
        }

        // inclusive span
        let totalDaysInclusive = totalDaySpan + 1
        let totalWeeks = max(1, Int(ceil(Double(totalDaysInclusive) / 7.0)))

        // Reference date: today's session if available, otherwise next upcoming
        let referenceDate: Date? =
            todaysIncompleteSession?.date ??
            todaysCompletedSession?.date ??
            nextUpcomingSession?.date

        guard let ref = referenceDate else { return nil }

        let refDay = calendar.startOfDay(for: ref)
        guard
            let offsetDays = calendar.dateComponents([.day], from: startDay, to: refDay).day
        else {
            return nil
        }

        let currentWeekIndex = max(1, min(totalWeeks, (offsetDays / 7) + 1))
        let dayInWeek = (offsetDays % 7) + 1

        let weekdayIndex = calendar.component(.weekday, from: refDay) - 1
        let weekdayName = calendar.weekdaySymbols[safe: weekdayIndex] ?? ""

        return BlockPosition(
            currentWeek: currentWeekIndex,
            totalWeeks: totalWeeks,
            dayInWeek: dayInWeek,
            weekdayName: weekdayName
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                // HERO / TODAY SECTION
                Section {
                    headerCard
                }

                // UPCOMING SECTION
                if !upcomingSessions.isEmpty {
                    Section(header: Text("Upcoming")) {
                        ForEach(upcomingSessions) { session in
                            NavigationLink {
                                SessionView(session: session)
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
            // Strapline & Week/Day info
            VStack(alignment: .leading, spacing: 4) {
                Text("3 TO GROW 1 TO KNOW")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                if let pos = blockPosition {
                    Text("Week \(pos.currentWeek) of \(pos.totalWeeks)")
                        .font(.headline)

                    Text("Day \(pos.dayInWeek) · \(pos.weekdayName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("No program scheduled")
                        .font(.headline)
                }
            }

            // Up Next / Today content
            if let session = todaysIncompleteSession {
                upNextCard(for: session, mode: .start)
            } else if let session = todaysCompletedSession {
                upNextCard(for: session, mode: .recap)
            } else {
                emptyTodayCard
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05))
        )
    }

    private enum TodayCardMode {
        case start
        case recap
    }

    private func upNextCard(for session: Session, mode: TodayCardMode) -> some View {
        let exerciseCount = session.items.count
        let exercisesText = "\(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s")"

        return VStack(alignment: .leading, spacing: 12) {
            Text(mode == .start ? "Up Next" : "Completed Today")
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
                        SessionView(session: session)
                    } label: {
                        Text("Start Session")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    NavigationLink {
                        SessionRecapView(session: session)
                    } label: {
                        Text("View Recap")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
    }

    private var emptyTodayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today is an off day.")
                .font(.subheadline)
            Text("No training session scheduled.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let next = nextUpcomingSession {
                Divider().padding(.vertical, 4)

                Text("Next session")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SessionSummaryRow(session: next)
            }
        }
    }
}

// MARK: - Summary UI

struct SessionSummaryCard: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.date, style: .date)
                .font(.headline)

            Text(session.status.displayTitle)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("\(session.items.count) exercises")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct SessionSummaryRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.date, style: .date)
                .font(.subheadline)

            Text(session.status.displayTitle)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("\(session.items.count) exercises")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Safe array index helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
