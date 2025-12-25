import SwiftUI
import SwiftData

/// Shows your current block grouped by week.
/// Change-program actions are owned by `HomeView`.
struct ProgramPlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    // MARK: - Meso Anchor (UI + Week math)

    /// If you already store an anchor elsewhere, you can wire these keys to match.
    /// For now: if missing, we default to "today is W2D2".
    @AppStorage("meso_anchor_week") private var anchorWeek: Int = 0
    @AppStorage("meso_anchor_day")  private var anchorDay: Int = 0
    @AppStorage("meso_anchor_date") private var anchorDateEpoch: Double = 0

    @State private var didAttemptRealign = false

    private var anchorDate: Date {
        if anchorDateEpoch > 0 {
            return Date(timeIntervalSince1970: anchorDateEpoch)
        }
        return Date()
    }

    /// Week 1 / Day 1 date computed from the anchor.
    /// Example: if today is W2D2, this returns 8 days ago.
    private var week1Day1: Date {
        let deltaDays = ((effectiveAnchorWeek - 1) * 7) + (effectiveAnchorDay - 1)
        let start = Calendar.current.startOfDay(for: anchorDate)
        return Calendar.current.date(byAdding: .day, value: -deltaDays, to: start) ?? start
    }

    private var effectiveAnchorWeek: Int { max(1, anchorWeek) }
    private var effectiveAnchorDay: Int  { max(1, anchorDay) }

    // MARK: - Body

    var body: some View {
        List {
            if sessions.isEmpty {
                emptyStateSection
            } else {
                ForEach(weekGroups) { weekGroup in
                    Section(
                        header: VStack(alignment: .leading, spacing: 2) {
                            Text("Week \(weekGroup.weekIndex)")
                                .font(.headline)

                            Text(weekGroup.rangeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    ) {
                        ForEach(weekGroup.sessions) { session in
                            NavigationLink {
                                ProgramDayDetailView(session: session)
                            } label: {
                                programRow(for: session, computedWeek: weekIndex(for: session.date), computedDay: dayIndexInWeek(for: session.date))
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addExtraSession()
                } label: {
                    Label("Add Session", systemImage: "plus")
                }
            }
        }
        .onAppear {
            ensureAnchorDefaultsIfMissing()
        }
        .onChange(of: sessions.count) { _ in
            // When sessions arrive/refresh, we can realign once.
            if !didAttemptRealign {
                didAttemptRealign = true
                realignStoredWeekIndexesIfNeeded()
            }
        }
    }

    // MARK: - Anchor defaults

    private func ensureAnchorDefaultsIfMissing() {
        // If nothing set yet, assume "today is W2D2"
        if anchorWeek == 0 { anchorWeek = 2 }
        if anchorDay == 0 { anchorDay = 2 }
        if anchorDateEpoch == 0 {
            anchorDateEpoch = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        }
    }

    // MARK: - Week math

    private func weekIndex(for date: Date) -> Int {
        let start = week1Day1
        let d0 = Calendar.current.startOfDay(for: date)
        let days = Calendar.current.dateComponents([.day], from: start, to: d0).day ?? 0
        // days 0...6 => week 1, 7...13 => week 2, etc.
        return max(1, (days / 7) + 1)
    }

    /// 1–7 within a week (Day 1 = week start)
    private func dayIndexInWeek(for date: Date) -> Int {
        let start = week1Day1
        let d0 = Calendar.current.startOfDay(for: date)
        let days = Calendar.current.dateComponents([.day], from: start, to: d0).day ?? 0
        let mod = ((days % 7) + 7) % 7 // safe mod for past dates
        return mod + 1
    }

    // MARK: - Optional: realign stored weekIndex so other screens match

    private func realignStoredWeekIndexesIfNeeded() {
        guard !sessions.isEmpty else { return }

        // If ANY session's stored weekIndex disagrees with computed weekIndex, we realign all.
        let needsRealign = sessions.contains { s in
            s.weekIndex != weekIndex(for: s.date)
        }

        guard needsRealign else { return }

        for s in sessions {
            s.weekIndex = weekIndex(for: s.date)
        }

        do {
            try modelContext.save()
            print("✅ Realigned stored Session.weekInMeso using meso anchor (W\(effectiveAnchorWeek)D\(effectiveAnchorDay)).")
        } catch {
            print("⚠️ Failed to realign weekIndex: \(error)")
        }
    }

    // MARK: - Extra Session

    /// Adds an extra planned session for "today" in the current week.
    private func addExtraSession() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let computedWeek = weekIndex(for: today)

        let newSession = Session(
            date: today,
            status: .planned,
            readinessStars: 0,
            sessionNotes: nil,
            weekIndex: computedWeek,
            items: [],
            completedAt: nil
        )

        modelContext.insert(newSession)

        do {
            try modelContext.save()
            print("✅ Added extra session on \(today) (week \(computedWeek))")
        } catch {
            print("⚠️ Failed to save extra session: \(error)")
        }
    }

    // MARK: - Empty State

    private var emptyStateSection: some View {
        Section {
            Text("No program scheduled yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Use “Change Program” to create your first training block.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Grouping (computed)

    private var weekGroups: [WeekGroup] {
        let grouped = Dictionary(grouping: sessions) { weekIndex(for: $0.date) }

        return grouped.keys.sorted().map { week in
            let daySessions = (grouped[week] ?? [])
                .sorted { $0.date < $1.date }

            let start = Calendar.current.date(byAdding: .day, value: (week - 1) * 7, to: week1Day1) ?? week1Day1
            let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start

            return WeekGroup(
                weekIndex: week,
                startDate: start,
                endDate: end,
                sessions: daySessions
            )
        }
    }

    private struct WeekGroup: Identifiable {
        let weekIndex: Int
        let startDate: Date
        let endDate: Date
        let sessions: [Session]

        var id: Int { weekIndex }

        var rangeText: String {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return "\(df.string(from: startDate)) – \(df.string(from: endDate))"
        }
    }

    // MARK: - Row view

    @ViewBuilder
    private func programRow(for session: Session, computedWeek: Int, computedDay: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("W\(computedWeek)D\(computedDay) · \(dayName(for: session.date))")
                    .font(.headline)

                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(session.items.count) exercise\(session.items.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(session.status.displayTitle)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor(for: session.status).opacity(0.15))
                .foregroundColor(statusColor(for: session.status))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func dayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func statusColor(for status: SessionStatus) -> Color {
        switch status {
        case .planned:     return .secondary
        case .inProgress:  return .blue
        case .completed:   return .green
        }
    }
}
