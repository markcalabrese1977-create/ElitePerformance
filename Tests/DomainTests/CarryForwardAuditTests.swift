import XCTest
import SwiftData
@testable import ElitePerformance

/// LOCAL ONLY, READ-ONLY. Replays carry-forward against a real backup and prints every planned
/// target whose stored load differs from what the next completed session would write.
///
///   TEST_RUNNER_EP_BACKUP_FIXTURE=/path/to/ElitePerformance_Backup_v1_….json
///   TEST_RUNNER_EP_AUDIT_REPORT_OUT=/path/to/audit.txt   (optional)
///
/// The backup is imported TWICE into two in-memory containers. The first is the untouched
/// reference ("stored"); the engine runs only on the second (the copy) and is never saved. The
/// reference's fingerprint, its `hasChanges` flag and the fixture file's bytes are asserted
/// unchanged. The fixture holds personal health data: it is never copied into the repo.
final class CarryForwardAuditTests: XCTestCase {

    private static let schema = Schema([
        User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, 
        SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
        MesoBlock.self, UserProfile.self, CustomExercise.self
    ])

    private func importCopy(_ url: URL) throws -> (ModelContainer, ModelContext) {
        let c = try ModelContainer(for: Self.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: c)
        return (c, ModelContext(c))
    }

    /// Every planned-load field of every session, in a stable order.
    private func fingerprint(_ ctx: ModelContext) throws -> String {
        try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
            .flatMap { s in
                s.items.sorted { $0.order < $1.order }.map {
                    "\(s.id?.uuidString ?? "?")|\($0.id?.uuidString ?? "?")|\($0.exerciseId)|\($0.suggestedLoad)|\($0.plannedLoadsBySet)|\($0.planEdited)"
                }
            }
            .joined(separator: "\n")
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    func test_audit_latestBackup_storedVersusWouldWrite() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let url = URL(fileURLWithPath: path)
        let fileBefore = try Data(contentsOf: url)

        let (_, reference) = try importCopy(url)
        let (_, copy) = try importCopy(url)
        copy.autosaveEnabled = false
        let referenceBefore = try fingerprint(reference)
        XCTAssertEqual(try fingerprint(copy), referenceBefore, "the two imports must be identical")

        let blocks = try reference.fetch(FetchDescriptor<MesoBlock>())
        let active = blocks.filter { $0.status == .active && !$0.isMaintenance }
        let block = try XCTUnwrap(active.first, "no active non-maintenance block in the backup")
        XCTAssertEqual(active.count, 1, "expected exactly one active regular block")
        let blockSessionIDs = Set(block.sessions.compactMap(\.id))

        // 1. Sources: completed sessions of the active block that are the same-letter,
        //    same-day predecessor of a PLANNED item (the next completed session would
        //    carry forward into it). Ordered by date, as completion order would be.
        let refAll = try reference.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
        let refBlock = refAll.filter { $0.id.map(blockSessionIDs.contains) == true }
        var sourceIDs: [UUID] = []                              // order-preserving, unique
        var targetOf: [UUID: (source: Session, sourceItem: SessionItem)] = [:]   // planned item id -> predecessor
        for s in refBlock where s.status == .completed {
            for it in s.items {
                guard let t = PlanMemoryEngine.nextTargetItem(for: it, after: s, in: refAll),
                      let tid = t.id,
                      let owner = refBlock.first(where: { $0.items.contains { $0.id == tid } }),
                      owner.status != .completed else { continue }
                // The predecessor is the LATEST completed same-letter session for that target.
                if let existing = targetOf[tid], existing.source.date >= s.date { continue }
                targetOf[tid] = (s, it)
                if let sid = s.id, !sourceIDs.contains(sid) { sourceIDs.append(sid) }
            }
        }

        // 2. Run the engine on the COPY only, from each source, in date order. Never saved.
        let copyAll = try copy.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
        let engine = PlanMemoryEngine(context: copy)
        for s in refBlock where s.status == .completed {
            guard let sid = s.id, sourceIDs.contains(sid),
                  let copySource = copyAll.first(where: { $0.id == sid }) else { continue }
            engine.carryForwardPlans(from: copySource)
        }
        let copyItems = Dictionary(
            copyAll.flatMap { $0.items }.compactMap { i in i.id.map { ($0, i) } },
            uniquingKeysWith: { a, _ in a }
        )

        // 3. Report: stored (reference) vs would-write (copy), where they differ.
        var rows: [(date: Date, line: String)] = []
        var unchanged = 0
        var waveNilRows: [String] = []
        for (tid, pair) in targetOf {
            guard let stored = refBlock.flatMap({ $0.items }).first(where: { $0.id == tid }),
                  let after = copyItems[tid],
                  let owner = refBlock.first(where: { $0.items.contains { $0.id == tid } }) else { continue }
            if abs(stored.suggestedLoad - after.suggestedLoad) < 0.0001,
               stored.plannedLoadsBySet == after.plannedLoadsBySet {
                unchanged += 1
                continue
            }
            let src = pair.sourceItem
            let sets = zip(src.actualReps, src.actualLoads).map { "\($1 == $1.rounded() ? String(Int($1)) : String(format: "%.1f", $1))x\($0)" }.joined(separator: ",")
            let name = stored.exerciseNameSnapshot ?? stored.exerciseId
            let df = DateFormatter(); df.dateFormat = "EEE MMM d"
            let sourceWaveNil = (src.waveRaw ?? "").isEmpty
            if sourceWaveNil { waveNilRows.append("\(df.string(from: owner.date)) \(owner.dayLabel ?? "?") \(name)") }
            rows.append((owner.date,
                "\(df.string(from: owner.date)) wk\(owner.weekIndex) \(owner.dayLabel ?? "?") [\((stored.waveRaw ?? "-").uppercased())] \(name): "
                + "\(fmt(stored.suggestedLoad)) -> \(fmt(after.suggestedLoad))"
                + "   (from \(df.string(from: pair.source.date)) wk\(pair.source.weekIndex): \(sets) @RIR \(src.actualRIRs.map(String.init).joined(separator: "/")); planEdited=\(stored.planEdited), source wave=\(sourceWaveNil ? "NIL" : (src.waveRaw ?? "")))"))
        }
        rows.sort { $0.date < $1.date }

        var out = ["CARRY-FORWARD AUDIT (read-only) — block '\(block.name)'",
                   "planned items with a completed same-letter predecessor: \(targetOf.count)",
                   "stored == would-write: \(unchanged)",
                   "differ: \(rows.count)", ""]
        out += rows.map(\.line)
        out += ["", "rows whose SOURCE is wave-nil (the catch-up skips these): \(waveNilRows.count)"] + waveNilRows.map { "  " + $0 }
        let text = out.joined(separator: "\n")
        print("AUDIT|\n\(text)")
        if let dest = ProcessInfo.processInfo.environment["EP_AUDIT_REPORT_OUT"], !dest.isEmpty {
            try text.write(toFile: dest, atomically: true, encoding: .utf8)
        }

        // 4. Nothing was saved or changed anywhere that matters.
        XCTAssertFalse(reference.hasChanges, "the reference context must never be touched")
        XCTAssertEqual(try fingerprint(reference), referenceBefore, "the stored plan must be unchanged")
        XCTAssertEqual(try Data(contentsOf: url), fileBefore, "the fixture file must be unchanged")
        // The copy is never saved; a fresh fetch of the store would not show its edits.
    }
}
