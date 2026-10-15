import XCTest
import SwiftData
@testable import ElitePerformance

/// V53AlignmentRepair: program v5.3 over weeks 4-12 of the converted block, planned and unlogged sessions only.
///
/// Every behavioural test runs on a real backup (TEST_RUNNER_EP_BACKUP_FIXTURE → EP_BACKUP_FIXTURE) that already carries
/// the converted 12-week block with V52 applied, and is skipped when it is unset. The backup file is never modified.
final class V53AlignmentRepairTests: XCTestCase {

    typealias R = V53AlignmentRepair

    // MARK: - Isolation

    private var suiteNames: [String] = []
    private var containers: [ModelContainer] = []

    override func tearDown() {
        for n in suiteNames { UserDefaults().removePersistentDomain(forName: n) }
        suiteNames = []
        containers = []
        super.tearDown()
    }

    /// Fresh defaults with the V52 completion flag set (the production state on the device).
    private func freshDefaults(v52Done: Bool = true) -> UserDefaults {
        let name = "v53tests.\(UUID().uuidString)"
        suiteNames.append(name)
        let d = UserDefaults(suiteName: name)!
        if v52Done { d.set(true, forKey: V52AlignmentRepair.completionKey) }
        return d
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        return c
    }

    private func importFixture() throws -> (ModelContext, MesoBlock, URL) {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let url = URL(fileURLWithPath: path)
        print("V53 FIXTURE|\(url.lastPathComponent)")
        let c = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: c)
        let ctx = ModelContext(c)
        ctx.autosaveEnabled = false
        let active = try ctx.fetch(FetchDescriptor<MesoBlock>()).filter { $0.status == .active && !$0.isMaintenance }
        let block = try XCTUnwrap(active.first, "no active regular block")
        guard block.totalWeeks == 12 else { throw XCTSkip("fixture is not a converted (12-week) backup") }
        return (ctx, block, url)
    }

    // MARK: - Helpers

    private let slp = V53AlignmentRepair.singleLegPressId
    private let calf = V53AlignmentRepair.seatedCalfId
    private let adduction = V53AlignmentRepair.hipAdductionId

    private func allSessions(_ ctx: ModelContext) throws -> [Session] {
        try ctx.fetch(FetchDescriptor<Session>()).sorted { ($0.date, $0.id?.uuidString ?? "") < ($1.date, $1.id?.uuidString ?? "") }
    }

    private func blockSessions(_ ctx: ModelContext, _ block: MesoBlock) throws -> [Session] {
        try allSessions(ctx).filter { $0.meso === block }
    }

    private func session(_ ctx: ModelContext, week: Int, day: String) throws -> Session {
        try XCTUnwrap(try allSessions(ctx).first { $0.weekIndex == week && $0.dayLabel == day && $0.meso?.totalWeeks == 12 }, "no \(day) wk\(week)")
    }

    private func item(_ s: Session, _ exerciseId: String) throws -> SessionItem {
        try XCTUnwrap(s.items.first { $0.exerciseId == exerciseId }, "no \(exerciseId) in \(s.dayLabel ?? "?") wk\(s.weekIndex)")
    }

    /// Every field of every session and item: "the store" for unchanged checks.
    private func storeFingerprint(_ ctx: ModelContext) throws -> String {
        var out: [String] = []
        for b in try ctx.fetch(FetchDescriptor<MesoBlock>()).sorted(by: { $0.name < $1.name }) {
            out.append("B|\(b.name)|\(b.status.rawValue)|\(b.totalWeeks.map(String.init) ?? "nil")")
        }
        for c in try ctx.fetch(FetchDescriptor<CustomExercise>()).sorted(by: { $0.id < $1.id }) { out.append("C|\(c.id)|\(c.name)") }
        for s in try allSessions(ctx) {
            out.append("S|" + R.sessionFingerprint(s))
            for i in s.items.sorted(by: { ($0.order, $0.id?.uuidString ?? "") < ($1.order, $1.id?.uuidString ?? "") }) { out.append("I|" + R.fingerprint(i)) }
        }
        return out.joined(separator: "\n")
    }

    private func itemFingerprints(_ ctx: ModelContext) throws -> [String: String] {
        var out: [String: String] = [:]
        for s in try allSessions(ctx) { for i in s.items { out[i.id!.uuidString] = R.fingerprint(i) } }
        return out
    }

    private func waveLetter(_ week: Int) -> Int { (week - 4) % 3 }   // 0 A, 1 B, 2 C

    private let legsDay = "Legs A"

    /// The items the spec says change, selected independently of the repair's own report.
    private func expectedChangedItemIds(_ ctx: ModelContext, _ block: MesoBlock) throws -> (changed: Set<String>, deleted: Set<String>) {
        var changed = Set<String>(), deleted = Set<String>()
        for s in try blockSessions(ctx, block) where s.weekIndex >= 4 && s.status == .planned {
            for i in s.items {
                let id = i.id!.uuidString
                switch (s.dayLabel ?? "", i.exerciseId) {
                case ("Legs A", "hack_squat"), ("Legs A", V53AlignmentRepair.smithSplitSquatId), ("Legs A", "leg_extension"),
                     ("Legs A", V53AlignmentRepair.seatedCalfId), ("Legs A", "lying_leg_curl"): changed.insert(id)
                case ("Legs A", V53AlignmentRepair.hipAdductionId): deleted.insert(id)
                case ("Pull A", "pull_up") where s.weekIndex % 3 == 1: changed.insert(id)       // weeks 4, 7, 10
                case ("Push A", "cable_tricep_rope_pushdown"), ("Push B", "cable_tricep_rope_pushdown"): changed.insert(id)
                case ("Push B", "decline_bench_press"), ("Push A", V53AlignmentRepair.longHeadId),
                     ("Legs B", V53AlignmentRepair.hipThrustId), ("Pull B", V53AlignmentRepair.saPulldownId),
                     ("Pull B", "dumbbell_lateral_raise"): changed.insert(id)
                default: break
                }
            }
        }
        return (changed, deleted)
    }

    // MARK: - Shipping state

    func test_shipsArmed_andHasItsOwnKeys() {
        XCTAssertFalse(R.dryRun, "shipped armed (dryRun = false)")
        XCTAssertEqual(R.logHeader(dryRun: true, blockName: "B"), "🧪 V53 alignment DRY RUN for 'B':")
        XCTAssertEqual(R.logHeader(dryRun: false, blockName: "B"), "🧪 V53 alignment APPLY for 'B':")
        XCTAssertNotEqual(R.completionKey, V52AlignmentRepair.completionKey)
        XCTAssertNotEqual(R.dryRunLoggedKey, V52AlignmentRepair.dryRunLoggedKey)
        XCTAssertNotEqual(R.reportKey, V52AlignmentRepair.reportKey)
    }

    func test_specTable_hasTheStatedShape() {
        XCTAssertEqual(R.l1Rx.a.label, "4x6-8 @1-2"); XCTAssertEqual(R.l1Rx.b.label, "3x8-10 @2"); XCTAssertEqual(R.l1Rx.c.label, "3x10-15 @2")
        XCTAssertEqual(R.l2Rx.a.label, "2x8-10 @2"); XCTAssertEqual(R.l2Rx.b.label, "2x10-12 @2"); XCTAssertEqual(R.l2Rx.c.label, "2x12-15 @2")
        XCTAssertEqual([WaveType.a, .b, .c].map(R.l1Load), [440, 410, 385])
        XCTAssertEqual((4...12).map { R.wave(forWeek: $0).rawValue }, ["a", "b", "c", "a", "b", "c", "a", "b", "c"])
        XCTAssertEqual(R.opKeys, ["L1", "L2", "L3", "L4", "P1", "S1", "N1", "N2", "N3", "N4", "N5"])
        XCTAssertEqual(R.legsPostShape.map(\.order), [1, 2, 3, 4, 5])
        XCTAssertEqual(R.legPressId, "leg_press", "the built-in, never 'Leg Press [Gym]'")
        XCTAssertTrue(ExerciseCatalog.all.contains { $0.id == "leg_press" && $0.name == "Leg Press" })
    }

    // MARK: - Dry run

    func test_fixture_dryRun_writesNothing_printsTheFullPerItemReport_andHitsTheCounts() throws {
        let (ctx, block, url) = try importFixture()
        let fileBefore = try Data(contentsOf: url)
        let before = try storeFingerprint(ctx)
        let d = freshDefaults()

        let report = R.dryRun(block: block, context: ctx, defaults: d)
        print("V53 FIXTURE DRY RUN|\n\(report.text)")

        XCTAssertTrue(report.isSafe, report.blockers.joined(separator: "\n"))
        XCTAssertTrue(report.gates.allSatisfy { $0.status == .passed }, report.gates.map { "\($0.status.rawValue) \($0.name)" }.joined(separator: "\n"))
        XCTAssertEqual(report.counts, ["L1": 9, "L2": 9, "L3": 9, "L4": 9, "P1": 3, "S1": 18, "N1": 9, "N2": 9, "N3": 9, "N4": 9, "N5": 9])
        XCTAssertEqual(report.planEditedInScope, 4, "the four edited Oct 16 Push A items")
        XCTAssertEqual(report.planEditedNoteOnly, 1, "only the long-head extension takes its note")
        XCTAssertTrue(report.skipped.isEmpty, report.skipped.joined(separator: "\n"))
        XCTAssertFalse(report.alreadyAligned)
        // One line per item written or deleted: 5 Legs A items + 1 deleted per session (45 + 9), P1 3, S1 18, N 45... minus overlaps (none).
        XCTAssertEqual(report.opLines.count, 9 * 6 + 3 + 18 + 45)

        XCTAssertEqual(try storeFingerprint(ctx), before, "dry run writes nothing")
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(try Data(contentsOf: url), fileBefore, "the backup file is never modified")
    }

    func test_fixture_runIfNeeded_dryRun_logsOnce_writesNothing_setsOnlyTheLoggedFlag() throws {
        let (ctx, _, _) = try importFixture()
        let d = freshDefaults()
        let before = try storeFingerprint(ctx)

        R.runIfNeeded(in: ctx, dryRun: true, defaults: d)
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertTrue(d.bool(forKey: R.dryRunLoggedKey))
        XCTAssertFalse(d.bool(forKey: R.completionKey), "a dry run never sets the completion flag")
        let stored = try XCTUnwrap(d.string(forKey: R.reportKey))
        XCTAssertTrue(stored.contains("== WRITES, per item"))

        d.set("sentinel", forKey: R.reportKey)
        R.runIfNeeded(in: ctx, dryRun: true, defaults: d)
        XCTAssertEqual(d.string(forKey: R.reportKey), "sentinel", "second dry run does not report again")
        XCTAssertEqual(try storeFingerprint(ctx), before)
    }

    // MARK: - Live apply

    func test_fixture_liveApply_hitsTheCounts_keepsTheEditedOct16Items_leavesEverythingElseByteIdentical_andIsIdempotent() throws {
        let (ctx, block, url) = try importFixture()
        let fileBefore = try Data(contentsOf: url)
        let d = freshDefaults()

        // Selected independently of the repair.
        let (expectChanged, expectDeleted) = try expectedChangedItemIds(ctx, block)
        XCTAssertEqual(expectDeleted.count, 9)
        let itemsBefore = try itemFingerprints(ctx)
        let sessionsBefore = try allSessions(ctx).count

        let push4 = try session(ctx, week: 4, day: "Push A")
        let editedBefore = push4.items.filter(\.planEdited).map { ($0.id!.uuidString, $0.exerciseId, R.fields($0)) }
        XCTAssertEqual(editedBefore.count, 4)

        let report = try R.apply(block: block, context: ctx, defaults: d)
        print("V53 FIXTURE LIVE|\n" + report.verification.joined(separator: "\n") + "\n" + report.postWriteChainTable.joined(separator: "\n"))
        XCTAssertTrue(report.didWrite)
        XCTAssertEqual(report.counts, ["L1": 9, "L2": 9, "L3": 9, "L4": 9, "P1": 3, "S1": 18, "N1": 9, "N2": 9, "N3": 9, "N4": 9, "N5": 9])
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("[PASS]") }, report.verification.joined(separator: "\n"))
        XCTAssertFalse(ctx.hasChanges, "saved")

        // The changed set is exactly what the spec says; the 9 deleted are gone; nothing else differs.
        let itemsAfter = try itemFingerprints(ctx)
        let changed = Set(itemsBefore.filter { itemsAfter[$0.key] != nil && itemsAfter[$0.key] != $0.value }.keys)
        let gone = Set(itemsBefore.keys).subtracting(itemsAfter.keys)
        XCTAssertEqual(changed, expectChanged.subtracting(expectDeleted))
        XCTAssertEqual(gone, expectDeleted)
        XCTAssertEqual(Set(itemsAfter.keys).subtracting(itemsBefore.keys), [], "no item is created")
        XCTAssertEqual(try allSessions(ctx).count, sessionsBefore)
        for s in try allSessions(ctx) where s.weekIndex <= 3 || s.meso !== block {
            for i in s.items { XCTAssertEqual(itemsBefore[i.id!.uuidString], itemsAfter[i.id!.uuidString], "week \(s.weekIndex) \(s.dayLabel ?? "?")") }
        }
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<CustomExercise>()).contains { $0.id == adduction }, "the Cable Hip Adduction row stays")

        // The four edited Oct 16 Push A items keep their numbers; only the long head takes its note.
        for (id, exerciseId, was) in editedBefore {
            let now = R.fields(try XCTUnwrap(push4.items.first { $0.id!.uuidString == id }))
            let differing = Set(now.filter { was[$0.key] != $0.value }.keys)
            if exerciseId == R.longHeadId {
                XCTAssertEqual(differing, ["prescriptionNotes", "updatedAt"], "long head: note only")
                XCTAssertTrue(now["prescriptionNotes"]!.hasPrefix("Light fixed load first 2 exposures"))
                for k in ["targetSets", "repMin", "repMax", "targetRIRMin", "targetRIRMax", "suggestedLoad", "plannedLoadsBySet", "plannedRIRsBySet", "plannedRepsBySet", "planEdited"] {
                    XCTAssertEqual(now[k], was[k], "long head \(k)")
                }
            } else {
                XCTAssertTrue(differing.isEmpty, "\(exerciseId) is byte-identical, differing: \(differing)")
            }
        }

        // Spot values per wave.
        for week in 4...12 {
            let legs = try session(ctx, week: week, day: "Legs A")
            let items = legs.items.sorted { $0.order < $1.order }
            XCTAssertEqual(items.map(\.order), [1, 2, 3, 4, 5], "wk\(week)")
            XCTAssertEqual(items.map(\.exerciseId), ["lying_leg_curl", slp, "leg_press", "leg_extension", calf], "wk\(week)")
            let w = waveLetter(week)
            let a = items[1], b = items[2]
            XCTAssertEqual([a.targetSets, a.repMin!, a.repMax!, a.targetRIRMin!, a.targetRIRMax!], [[4, 6, 8, 1, 2], [3, 8, 10, 2, 2], [3, 10, 15, 2, 2]][w], "wk\(week) single-leg press")
            XCTAssertEqual(a.suggestedLoad, [440, 410, 385][w]); XCTAssertEqual(a.plannedLoadsBySet, Array(repeating: [440, 410, 385][w], count: a.targetSets))
            XCTAssertEqual(a.exerciseNameSnapshot, "Single Leg Press"); XCTAssertEqual(a.prescriptionNotes, R.l1Note)
            XCTAssertEqual([b.targetSets, b.repMin!, b.repMax!, b.targetRIRMin!, b.targetRIRMax!], [[2, 8, 10, 2, 2], [2, 10, 12, 2, 2], [2, 12, 15, 2, 2]][w], "wk\(week) leg press")
            XCTAssertEqual(b.suggestedLoad, 0); XCTAssertEqual(b.plannedLoadsBySet, [0, 0])
            XCTAssertEqual(b.exerciseNameSnapshot, "Leg Press"); XCTAssertEqual(b.prescriptionNotes, R.l2Note)
            XCTAssertEqual(items[0].prescriptionNotes, R.l3Note)

            let pull = try item(try session(ctx, week: week, day: "Pull A"), "pull_up")
            if w == 0 {
                XCTAssertEqual([pull.targetRIR, pull.targetRIRMin!, pull.targetRIRMax!], [2, 2, 2]); XCTAssertEqual(pull.plannedRIRsBySet, [2, 2, 2, 2])
            }
            for day in ["Push A", "Push B"] {
                let pd = try item(try session(ctx, week: week, day: day), "cable_tricep_rope_pushdown")
                XCTAssertEqual(pd.suggestedLoad, 75, "wk\(week) \(day)"); XCTAssertEqual(pd.plannedLoadsBySet, [75, 75, 75])
            }
            XCTAssertEqual(try item(try session(ctx, week: week, day: "Push B"), "decline_bench_press").prescriptionNotes, "4th set earnable (see Earned Volume).")
        }

        // Chains, independent of the repair's own verification.
        let sessions = try blockSessions(ctx, block)
        let all = try allSessions(ctx)
        for (id, name) in [(slp, "single-leg press"), ("leg_press", "leg press")] {
            for start in [4, 5, 6] {
                var week = start
                var current = try item(sessions.first { $0.weekIndex == week && $0.dayLabel == "Legs A" }!, id)
                var currentSession = sessions.first { $0.weekIndex == week && $0.dayLabel == "Legs A" }!
                var visited = [week]
                while let next = PlanMemoryEngine.nextTargetItem(for: current, after: currentSession, in: all) {
                    let ns = try XCTUnwrap(sessions.first { $0.items.contains { $0 === next } })
                    visited.append(ns.weekIndex); current = next; currentSession = ns; week = ns.weekIndex
                }
                XCTAssertEqual(visited, [start, start + 3, start + 6], "\(name) \(start)")
            }
        }
        let deletedStillReachable = sessions.flatMap(\.items).contains { i in
            WavePrescriptionGuard.isWaveLetter(i.waveRaw)
                && PlanMemoryEngine.nextTargetItem(for: i, after: sessions.first { $0.items.contains { $0 === i } }!, in: all)
                    .map { expectDeleted.contains($0.id!.uuidString) } == true
        }
        XCTAssertFalse(deletedStillReachable, "no target points at a deleted item")

        // Idempotent: a second apply is a no-op, and the armed launch marks it complete without writing.
        let stored = try storeFingerprint(ctx)
        XCTAssertTrue(R.dryRun(block: block, context: ctx, defaults: d).alreadyAligned)
        let second = try R.apply(block: block, context: ctx, defaults: d)
        XCTAssertFalse(second.didWrite)
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertTrue(d.bool(forKey: R.completionKey))
        XCTAssertEqual(try storeFingerprint(ctx), stored)
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertEqual(try storeFingerprint(ctx), stored)
        XCTAssertEqual(try Data(contentsOf: url), fileBefore, "the backup file is never modified")
    }

    func test_fixture_armedLaunch_appliesOnce_setsCompletionAfterTheSave() throws {
        let (ctx, block, _) = try importFixture()
        let d = freshDefaults()
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertTrue(d.bool(forKey: R.completionKey))
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertTrue(R.dryRun(block: block, context: ctx, defaults: d).alreadyAligned)
        // The persisted store, read through a brand-new context, is the aligned one.
        let fresh = ModelContext(try XCTUnwrap(containers.last))
        let legs = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Session>()).first { $0.dayLabel == "Legs A" && $0.weekIndex == 4 && $0.meso?.totalWeeks == 12 })
        XCTAssertEqual(legs.items.map(\.order).sorted(), [1, 2, 3, 4, 5])
    }

    // MARK: - Rollback

    func test_fixture_forcedSaveFailure_restoresTheStore_flagUnset_andARetrySucceeds() throws {
        let (ctx, block, _) = try importFixture()
        let d = freshDefaults()
        let before = try storeFingerprint(ctx)
        struct Boom: Error {}
        let failing = R.ApplyHooks(save: { _ in throw Boom() })

        XCTAssertThrowsError(try R.apply(block: block, context: ctx, defaults: d, hooks: failing)) {
            guard case R.ApplyError.saveFailed = $0 else { return XCTFail("expected saveFailed, got \($0)") }
        }
        XCTAssertEqual(try storeFingerprint(ctx), before, "every field restored, every deleted item back in its session")
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        // Nothing reached the persistent store either.
        let fresh = ModelContext(try XCTUnwrap(containers.last))
        let legsFresh = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Session>()).first { $0.dayLabel == "Legs A" && $0.weekIndex == 4 && $0.meso?.totalWeeks == 12 })
        XCTAssertEqual(legsFresh.items.count, 6)

        // The restore leaves the context dirty (every field was re-assigned). Saving it must persist exactly the original store,
        // deleted items included.
        XCTAssertTrue(ctx.hasChanges)
        try ctx.save()
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertEqual(try storeFingerprint(ModelContext(try XCTUnwrap(containers.last))), before, "what the restore persists is the original store")

        // The armed launch with a failing save leaves the flag unset too.
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d, hooks: failing)
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        try ctx.save()
        XCTAssertEqual(try storeFingerprint(ctx), before)

        // After the restore the plan is intact: a retry applies cleanly.
        let retry = try R.apply(block: block, context: ctx, defaults: d)
        XCTAssertTrue(retry.didWrite)
        XCTAssertTrue(retry.verification.allSatisfy { $0.hasPrefix("[PASS]") }, retry.verification.joined(separator: "\n"))
    }

    func test_fixture_aFailedVerification_rollsBack_storeUnchanged() throws {
        let (ctx, block, _) = try importFixture()
        let d = freshDefaults()
        let before = try storeFingerprint(ctx)
        // Tamper with a written item after the mutation: the value check must catch it.
        let hooks = R.ApplyHooks(beforeVerify: { c in
            let s = try! c.fetch(FetchDescriptor<Session>()).first { $0.dayLabel == "Legs A" && $0.weekIndex == 5 && $0.meso?.totalWeeks == 12 }!
            s.items.first { $0.exerciseId == "leg_press" }!.suggestedLoad = 123
        })
        XCTAssertThrowsError(try R.apply(block: block, context: ctx, defaults: d, hooks: hooks)) {
            guard case R.ApplyError.verificationFailed = $0 else { return XCTFail("expected verificationFailed, got \($0)") }
        }
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertFalse(d.bool(forKey: R.completionKey))
    }

    func test_fixture_pendingChanges_areRefused() throws {
        let (ctx, block, _) = try importFixture()
        let s = try session(ctx, week: 1, day: "Push A")
        s.sessionNotes = "unsaved"
        XCTAssertThrowsError(try R.apply(block: block, context: ctx, defaults: freshDefaults())) {
            guard case R.ApplyError.pendingChanges = $0 else { return XCTFail("expected pendingChanges, got \($0)") }
        }
    }

    // MARK: - Gates and skips

    func test_fixture_v52FlagUnset_isABlocker_nothingWritten() throws {
        let (ctx, block, _) = try importFixture()
        let d = freshDefaults(v52Done: false)
        let before = try storeFingerprint(ctx)
        let report = R.dryRun(block: block, context: ctx, defaults: d)
        XCTAssertFalse(report.isSafe)
        XCTAssertTrue(report.blockers.contains { $0.contains(V52AlignmentRepair.completionKey) })
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertEqual(try storeFingerprint(ctx), before)
        XCTAssertFalse(d.bool(forKey: R.completionKey))
        XCTAssertThrowsError(try R.apply(block: block, context: ctx, defaults: d))
    }

    func test_fixture_aLegsARosterThatIsNotTheSpecShape_abortsEverything() throws {
        let (ctx, block, _) = try importFixture()
        let d = freshDefaults()
        let legs = try session(ctx, week: 8, day: "Legs A")
        let extra = try item(legs, "leg_extension")
        extra.exerciseId = "seated_leg_curl"            // not the v5.2 roster any more
        try ctx.save()
        let before = try storeFingerprint(ctx)
        let report = R.dryRun(block: block, context: ctx, defaults: d)
        XCTAssertFalse(report.isSafe)
        XCTAssertTrue(report.blockers.contains { $0.contains("wk8") && $0.contains("neither") }, report.blockers.joined(separator: "\n"))
        R.runIfNeeded(in: ctx, dryRun: false, defaults: d)
        XCTAssertEqual(try storeFingerprint(ctx), before, "abort writes nothing, even the sessions that pass")
        XCTAssertFalse(d.bool(forKey: R.completionKey))
    }

    func test_fixture_aSecondActiveBlock_isABlocker() throws {
        let (ctx, block, _) = try importFixture()
        let other = MesoBlock(name: "Another", startDate: Date(), status: .active, totalWeeks: 6)
        ctx.insert(other)
        try ctx.save()
        let report = R.dryRun(block: block, context: ctx, defaults: freshDefaults())
        XCTAssertFalse(report.isSafe)
        XCTAssertTrue(report.blockers.contains { $0.contains("active non-maintenance") })
    }

    func test_fixture_planEditedNumbers_areSkippedAndListed_notesStillApply() throws {
        let (ctx, block, _) = try importFixture()
        let d = freshDefaults()
        // Hand-edit the week 5 Push A rope pushdown (S1) and the week 4 Pull A pull-up (P1).
        let pd = try item(try session(ctx, week: 5, day: "Push A"), "cable_tricep_rope_pushdown")
        pd.planEdited = true
        let pu = try item(try session(ctx, week: 4, day: "Pull A"), "pull_up")
        pu.planEdited = true
        try ctx.save()
        let pdBefore = R.fields(pd), puBefore = R.fields(pu)

        let report = try R.apply(block: block, context: ctx, defaults: d)
        XCTAssertEqual(report.counts["S1"], 17); XCTAssertEqual(report.counts["P1"], 2)
        XCTAssertEqual(report.skipped.filter { $0.contains("numbers skipped — planEdited") }.count, 2, report.skipped.joined(separator: "\n"))
        for (i, was) in [(pd, pdBefore), (pu, puBefore)] {
            let now = R.fields(i)
            let differing = Set(now.filter { was[$0.key] != $0.value }.keys)
            XCTAssertTrue(differing.isSubset(of: ["prescriptionNotes", "updatedAt"]), "numbers untouched, differing: \(differing)")
        }
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("[PASS]") })
    }

    func test_fixture_aPlanEditedHackSquat_skipsThatWholeLegsASession_othersApply() throws {
        let (ctx, block, _) = try importFixture()
        let d = freshDefaults()
        let legs7 = try session(ctx, week: 7, day: "Legs A")
        try item(legs7, "hack_squat").planEdited = true
        try ctx.save()
        let before = Dictionary(uniqueKeysWithValues: legs7.items.map { ($0.id!.uuidString, R.fingerprint($0)) })

        let report = try R.apply(block: block, context: ctx, defaults: d)
        XCTAssertEqual([report.counts["L1"], report.counts["L2"], report.counts["L3"], report.counts["L4"]].map { $0 ?? 0 }, [8, 8, 8, 8])
        XCTAssertTrue(report.skipped.contains { $0.contains("wk7 Legs A") && $0.contains("planEdited") }, report.skipped.joined(separator: "\n"))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: legs7.items.map { ($0.id!.uuidString, R.fingerprint($0)) }), before, "wk7 Legs A untouched")
        XCTAssertTrue(report.verification.allSatisfy { $0.hasPrefix("[PASS]") })
    }

    func test_fixture_aLoggedSession_isSkippedWhole_andListed() throws {
        let (ctx, block, _) = try importFixture()
        let d = freshDefaults()
        let pushB = try session(ctx, week: 4, day: "Push B")
        pushB.status = .completed
        try item(pushB, "decline_bench_press").isCompleted = true
        try ctx.save()
        let before = Dictionary(uniqueKeysWithValues: pushB.items.map { ($0.id!.uuidString, R.fingerprint($0)) })

        let report = try R.apply(block: block, context: ctx, defaults: d)
        XCTAssertEqual(report.counts["S1"], 17); XCTAssertEqual(report.counts["N1"], 8)
        XCTAssertTrue(report.skipped.contains { $0.contains("wk4 Push B") && $0.contains("completed") }, report.skipped.joined(separator: "\n"))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: pushB.items.map { ($0.id!.uuidString, R.fingerprint($0)) }), before)
    }

    // MARK: - Registration

    /// V53 was applied on the device (492b7fa) and is no longer registered: a launch through `StartupBackfills` leaves a
    /// not-yet-aligned store alone and sets none of its flags.
    func test_fixture_startupBackfills_doNotRunV53AnyMore() throws {
        let (_, _, _) = try importFixture()
        let container = try XCTUnwrap(containers.last)
        let standard = UserDefaults.standard
        let keys = [V52AlignmentRepair.completionKey, R.completionKey, R.dryRunLoggedKey, R.reportKey]
        let saved = keys.map { ($0, standard.object(forKey: $0)) }
        defer { for (k, v) in saved { if let v { standard.set(v, forKey: k) } else { standard.removeObject(forKey: k) } } }
        for k in keys { standard.removeObject(forKey: k) }
        standard.set(true, forKey: V52AlignmentRepair.completionKey)   // V53's precondition, as on the device

        StartupBackfills.run(using: container)     // settle the older migrations
        let settled = try storeFingerprint(ModelContext(container))
        StartupBackfills.run(using: container)
        XCTAssertEqual(try storeFingerprint(ModelContext(container)), settled)
        let legs = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Session>()).first { $0.dayLabel == "Legs A" && $0.weekIndex == 4 && $0.meso?.totalWeeks == 12 })
        XCTAssertEqual(legs.items.count, 6, "still the v5.2 Legs A roster: V53 did not run")
        XCTAssertFalse(standard.bool(forKey: R.completionKey))
        XCTAssertFalse(standard.bool(forKey: R.dryRunLoggedKey))
        XCTAssertNil(standard.string(forKey: R.reportKey))
    }
}
