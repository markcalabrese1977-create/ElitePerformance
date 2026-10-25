import XCTest
import SwiftData
@testable import ElitePerformance

/// Imports the backup named by EP_BACKUP_FIXTURE, plans the next meso from its active block (ending the old one
/// now, starting tomorrow), PRINTS the preview, applies it, and checks the result: one active block, an archived
/// old one, clean items, contiguous weeks and programIndex, one weekday per day type, no date collisions, chains
/// inside the new meso, and every completed session of the backup byte-identical. Then exports, imports that
/// export into a fresh store and exports again: the round trip may not differ from the same round trip taken
/// before the apply. Skips without the fixture. The file holds personal data and is never copied.
final class NextMesoRealBackupTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private let lifecycleKeys = ["meso.scheduledStartDateEpoch", "meso.activeStartDateEpoch", "meso.promptSnoozeEpoch",
                                 "meso.anchorDate", "meso.anchorDayNumber"]

    private func out(_ s: String = "") { print("NMR| \(s)") }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            PRIndex.self, SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func export(_ ctx: ModelContext) throws -> (json: [String: Any], url: URL) {
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        json.removeValue(forKey: "exportedAt")
        return (json, result.url)
    }

    private func canonical(_ json: Any) throws -> Data { try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) }

    /// Paths where two JSON values differ (rows matched by id).
    private func diff(_ a: Any, _ b: Any, path: String = "$", into lines: inout [String]) {
        guard lines.count < 400 else { return }
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            for k in Set(x.keys).union(y.keys).sorted() {
                switch (x[k], y[k]) {
                case (let l?, let r?): diff(l, r, path: "\(path).\(k)", into: &lines)
                case (nil, _): lines.append("\(path).\(k): only after")
                default: lines.append("\(path).\(k): only before")
                }
            }
        } else if let x = a as? [Any], let y = b as? [Any] {
            func key(_ v: Any) -> String? { (v as? [String: Any])?["id"] as? String }
            if x.allSatisfy({ key($0) != nil }) && y.allSatisfy({ key($0) != nil }) {
                let xs = Dictionary(x.map { (key($0)!, $0) }, uniquingKeysWith: { f, _ in f })
                let ys = Dictionary(y.map { (key($0)!, $0) }, uniquingKeysWith: { f, _ in f })
                for k in Set(xs.keys).union(ys.keys).sorted() {
                    switch (xs[k], ys[k]) {
                    case (let l?, let r?): diff(l, r, path: "\(path)[\(k.prefix(8))]", into: &lines)
                    case (nil, _): lines.append("\(path)[\(k.prefix(8))]: only after")
                    default: lines.append("\(path)[\(k.prefix(8))]: only before")
                    }
                }
            } else if x.count != y.count {
                lines.append("\(path): count \(x.count) vs \(y.count)")
            } else {
                for (i, pair) in zip(x, y).enumerated() { diff(pair.0, pair.1, path: "\(path)[\(i)]", into: &lines) }
            }
        } else if "\(a)" != "\(b)" {
            lines.append("\(path): \(a) vs \(b)")
        }
    }

    private func normalized(_ json: [String: Any]) -> [String: Any] {
        var out = json
        func byID(_ rows: [[String: Any]]) -> [[String: Any]] { rows.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") } }
        if let history = json["sessionHistory"] as? [[String: Any]] {
            out["sessionHistory"] = byID(history).map { row -> [String: Any] in
                var r = row
                if let ex = row["exercises"] as? [[String: Any]] {
                    r["exercises"] = ex.sorted { ((try? canonical($0)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
                                                  < ((try? canonical($1)).flatMap { String(data: $0, encoding: .utf8) } ?? "") }
                }
                return r
            }
        }
        for key in ["exerciseNotes", "sessions", "mesoBlocks", "customExercises"] {
            if let rows = json[key] as? [[String: Any]] { out[key] = byID(rows) }
        }
        return out
    }

    /// export -> import into a fresh store -> export; the differences between the first and last export.
    private func roundTripDiff(_ url: URL, _ first: [String: Any]) throws -> [String] {
        let fresh = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: fresh)
        let second = try export(ModelContext(fresh)).json
        // Sessions, blocks, history rows and notes. SessionHistory rows are compared sorted by id, and the
        // exercises inside a row sorted by content (they carry no id and come back in import order).
        var lines: [String] = []
        let n1 = normalized(first), n2 = normalized(second)
        for key in ["sessions", "mesoBlocks", "sessionHistory", "exerciseNotes", "customExercises"] {
            diff(n1[key] ?? [], n2[key] ?? [], path: "$.\(key)", into: &lines)
        }
        return lines
    }

    private func day(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "EEE yyyy-MM-dd"
        return f.string(from: d)
    }

    func testNextMesoOnARealBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("EP_BACKUP_FIXTURE not set")
        }
        let defaults = UserDefaults.standard
        let saved = lifecycleKeys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (k, v) in saved { if let v { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) } } }

        let container = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let calendar = Calendar.current
        let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>())
        let old = try XCTUnwrap(blocks.filter { $0.status == .active }.max { $0.sessions.count < $1.sessions.count }
                                    ?? blocks.max { $0.sessions.count < $1.sessions.count }, "no meso in the backup")
        let now = Date()
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))

        let before = try export(ctx)
        let baseline = try roundTripDiff(before.url, before.json)
        out("baseline round trip (before apply): \(baseline.count) differences")

        // --- Preview ---
        let plan = Service.planNextMeso(meso: old, name: "Next meso", startDate: tomorrow, endOldMesoNow: true, context: ctx, now: now)
        out("== PREVIEW: next meso from \"\(old.name)\" (\(old.sessions.count) sessions, \(old.status.rawValue), "
            + "totalWeeks \(old.totalWeeks.map(String.init) ?? "nil")); today \(day(now)); start \(day(tomorrow)) ==")
        out("refusals: \(plan.refusals); collisions: \(plan.collisions.count); remaining old sessions: \(plan.remainingOldSessions.count)")
        plan.previewLines().forEach { out($0) }
        out("first week:")
        for s in plan.firstWeek { out("  \(day(s.date)) \(s.dayLabel ?? "?") [\(s.letter.isEmpty ? "-" : s.letter)]: " + s.items.map { ExerciseCatalog.displayName(for: $0.exerciseId) }.joined(separator: ", ")) }
        let sources = Dictionary(grouping: plan.sessions.flatMap(\.items), by: { $0.seedSource.rawValue }).mapValues(\.count)
        out("seed sources across all items: \(sources.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        // Condensed: one line per exercise (peak e1RM or source, seed per letter).
        do {
            let fixed = (try? ctx.fetch(FetchDescriptor<UserProfile>()).first)?.exemptExerciseIds ?? []
            var order: [String] = []
            var rows: [String: [String: (Double, String)]] = [:]
            for s in plan.sessions {
                for i in s.items {
                    let id = ExerciseCatalog.canonicalExerciseId(for: i.exerciseId)
                    if rows[id] == nil { order.append(id) }
                    let key = s.letter.isEmpty ? "-" : s.letter.uppercased()
                    if rows[id, default: [:]][key] == nil { rows[id, default: [:]][key] = (i.seed, i.seedSource.rawValue) }
                }
            }
            out("== CONDENSED: exercise | peak e1RM or source | seed A / B / C ==")
            for id in order {
                let peak = HistorySeedLoad.peakE1RM(for: id, in: old.sessions)
                let r = rows[id] ?? [:]
                let sources = Set(r.values.map(\.1))
                let head = peak.map { "peak e1RM \(Int($0.rounded()))" } ?? (sources.count == 1 ? sources.first! : sources.sorted().joined(separator: "/"))
                let seeds = ["A", "B", "C", "DELOAD", "-"].compactMap { k in r[k].map { "\(k == "DELOAD" ? "D" : k) \(LoadFormatter.number($0.0))" } }
                let tag = fixed.contains(where: { ExerciseCatalog.canonicalExerciseId(for: $0) == id }) ? " (fixed-load)" : ""
                out("  \(ExerciseCatalog.displayName(for: id))\(tag) | \(head) | \(seeds.joined(separator: " / "))")
            }
            out("== HISTORY FALLBACK: no qualifying completed old-meso working set ==")
            for id in order where rows[id]?.values.contains(where: { $0.1 == "history" }) == true {
                var withExercise = 0, completed = 0, deloadOnly = 0, noSets = 0
                for s in old.sessions {
                    guard let m = s.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == id }) else { continue }
                    withExercise += 1
                    if s.status != .completed { continue }
                    completed += 1
                    if m.waveRaw?.lowercased() == "deload" { deloadOnly += 1 }
                    else if !m.actualLoads.contains(where: { $0 > 0 }) || !m.actualReps.contains(where: { $0 > 0 }) { noSets += 1 }
                }
                out("  \(ExerciseCatalog.displayName(for: id)): in \(withExercise) old-meso sessions, \(completed) completed (\(deloadOnly) deload, \(noSets) with no logged load x reps); "
                    + "the history seed used earlier mesos")
            }
        }
        XCTAssertTrue(plan.isApplicable, "the backup's meso should plan cleanly: \(plan.refusals)")

        // --- Apply ---
        let completedBefore = (before.json["sessions"] as? [[String: Any]] ?? []).filter { $0["statusRaw"] as? String == "completed" }
        let result = try Service.startNextMeso(plan, in: ctx)
        out("== APPLIED: \(result.sessionsCreated) sessions created, \(result.sessionsDeleted) removed from the old meso ==")

        let blocksAfter = try ctx.fetch(FetchDescriptor<MesoBlock>())
        XCTAssertEqual(blocksAfter.filter { $0.status == .active }.count, 1)
        XCTAssertEqual(old.status, .archived)
        let new = result.meso
        XCTAssertEqual(new.status, .active)
        XCTAssertEqual(new.sessions.count, plan.sessions.count)
        XCTAssertEqual(Set(new.sessions.map(\.weekIndex)), Set(1...plan.weeks), "weeks contiguous")
        XCTAssertEqual(new.sessions.compactMap(\.programIndex).sorted(), Array(1...plan.sessions.count), "programIndex contiguous")
        var weekdays: [String: Set<Int>] = [:]
        for s in new.sessions { weekdays[s.dayLabel ?? "", default: []].insert(calendar.component(.weekday, from: s.date)) }
        XCTAssertTrue(weekdays.values.allSatisfy { $0.count == 1 }, "one weekday per day type: \(weekdays)")
        for s in new.sessions {
            XCTAssertTrue(s.date >= tomorrow)
            XCTAssertNotEqual(s.insertedDeload, true)
            for i in s.items {
                XCTAssertFalse(i.planEdited)
                XCTAssertFalse(SessionEditSafety.hasLoggedData(i))
                XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets)
            }
        }
        let allSessions = try ctx.fetch(FetchDescriptor<Session>())
        let newIDs = Set(new.sessions.map(\.persistentModelID))
        let otherDays = Set(allSessions.filter { !newIDs.contains($0.persistentModelID) }.map { calendar.startOfDay(for: $0.date) })
        XCTAssertTrue(new.sessions.allSatisfy { !otherDays.contains(calendar.startOfDay(for: $0.date)) }, "no date collisions")
        XCTAssertEqual(Set(new.sessions.map { calendar.startOfDay(for: $0.date) }).count, new.sessions.count, "one session per day")
        var chains = 0
        for s in new.sessions {
            for i in s.items where WavePrescriptionGuard.isWaveLetter(i.waveRaw) {
                chains += 1
                if let t = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: allSessions) {
                    let owner = allSessions.first { $0.items.contains { $0 === t } }
                    XCTAssertTrue(owner?.meso === new, "chain leaves the new meso")
                    XCTAssertEqual(owner?.dayLabel, s.dayLabel)
                    XCTAssertEqual(t.waveRaw?.lowercased(), i.waveRaw?.lowercased())
                }
            }
        }
        out("chains checked: \(chains) wave items, all inside the new meso; weeks 1...\(plan.weeks); end \(plan.endDate.map(day) ?? "?")")

        let after = try export(ctx)
        let completedAfter = (after.json["sessions"] as? [[String: Any]] ?? []).filter { $0["statusRaw"] as? String == "completed" }
        XCTAssertEqual(try canonical(completedBefore), try canonical(completedAfter), "completed sessions byte-identical")
        out("completed sessions byte-identical: \(completedBefore.count)")

        // --- Round trip ---
        let lines = try roundTripDiff(after.url, after.json)
        let extra = Set(lines).subtracting(baseline)
        out("round trip after apply: \(lines.count) differences (\(baseline.count) already in the baseline); new: \(extra.count)")
        extra.sorted().prefix(30).forEach { out("DIFF \($0)") }
        XCTAssertTrue(extra.isEmpty, "export -> import -> export differs for the new meso: \(extra.sorted().prefix(5))")
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, nil)
        XCTAssertEqual(calendar.startOfDay(for: MesoLifecycle.activeStartDate), tomorrow)
    }
}
