// TestOpenQuestions.swift
//
// Reference only — no test methods. Open pins discovered while building this
// suite, both the ones the source prompt flagged up front and new ones found
// during recon. Update this file as each is resolved.

// OPEN Q1: T-B.6/T-K.4/T-N.12 — Post-restore seeding fidelity
//   Is Machine Hip Thrust (410x10) and RDL (225x10-13) correctly seeded after
//   a Jayson-style restore? Flagged May 26. RESOLVED AND FIXED: root cause was
//   ProgramGenerator.anchorLoadsForNewMeso (the Path-A maintenance loader)
//   anchoring suggestedLoad by calling LoadProjectionService.project(
//   currentWaveRaw: item.waveRaw). Every maintenance item is seeded with
//   waveRaw == "deload" (MaintenanceProgramSeeder.makeMaintenanceItem), and
//   project()'s deload guard (added earlier the same session, for the
//   unrelated maintenance-overload bug) unconditionally returned nil for
//   every one of them. Fix: anchorLoadsForNewMeso no longer calls project()
//   at all — it now reads e1RM directly from session history
//   (decay-weighted), mirroring the sibling Path-B loader,
//   MaintenanceProgramSeeder.anchorLoadsFromFullHistory, which never had
//   this problem because it never routed through project() either. The
//   guard itself was correct for its actual intended caller
//   (PlanMemoryEngine.carryForwardPlans) — this caller just shouldn't have
//   been going through it, since anchoring a new block's initial loads is a
//   one-time read-from-history operation, not an ongoing progression
//   decision. InvariantTests.test_N12_maintenanceSeedingAnchorsLoadFromHistory
//   and LoadWriteTests.test_B6_restoredHistoryAnchorsMaintenanceLoad both
//   pass now.

// OPEN Q2: T-A.8 — Guard precedence
//   When pain + deload + extra-reserve all fire, what is the exact evaluation
//   order? RESOLVED via direct read of CoachingEngine.swift: the catalog's
//   assumed order ("pain -> deload -> extra-reserve") is backwards for the
//   first two. Real order is:
//     1) Deload/maintenance (waveRaw == "deload")
//     2) No baseline (suggestedLoad <= 0)
//     3) First session / no actual data
//     4) Pain flag
//     ... (downshift, stage-gating, failure+repcrash, under-target-reps,
//          harder-than-planned, over-performing, fatigue override,
//          clean-execution increase, drop-set increase, on-target repeat)
//     11) Extra-reserve increase (5.5, just before the catch-all)
//   Deload wins over both pain and extra-reserve, since it's checked first
//   and returns unconditionally whenever suggestedLoad > 0 and there's any
//   actual data — pain and extra-reserve are never reached in that case.
//   Pinned and tested in CoachingEngineGuardTests.test_A8_*.

// OPEN Q3: T-D.2/T-D.3 — weekIndex base and band boundary ownership
//   Is weekIndex 0-based or 1-based? Which band owns the boundary values
//   (30, 70, 90)? RESOLVED via direct read of Session.swift's `mesoPhase`
//   computed property: weekIndex is 1-based (week 1 of N), and the bands use
//   Swift's `..<` ranges — lower-inclusive, upper-exclusive:
//     pct < 0.30        -> .early
//     0.30 <= pct < 0.70 -> .mid
//     0.70 <= pct < 0.90 -> .late
//     pct >= 0.90        -> .deload
//   where pct = weekIndex / totalWeeks. Confirmed answer; T-D.1/T-D.2 remain
//   stubbed per the priority ordering, but the answer is locked for whoever
//   implements them next.

// OPEN Q4: T-B.10 — Three addExercise paths
//   Today "+", ProgramDayDetailView, PlannedSessionEditorView. Known to
//   diverge silently. RESOLVED (partially) via direct source read:
//     - SessionScreenViewModel.addExercise (SessionView.swift) — correctly
//       seeds exerciseNameSnapshot and non-empty actual/planned arrays (fixed
//       earlier this session). Directly unit-tested in LoadWriteTests
//       .test_B10_sessionScreenViewModelAddExerciseSeedsNameAndArrays.
//     - ProgramDayDetailView.addExercise(from:) — also correct (this was the
//       reference/"known good" implementation used to fix the SessionView
//       path earlier this session) — but it's `private`, so it cannot be
//       unit-tested directly without changing source visibility.
//     - PlannedSessionEditorView.addExercise(_:) (Features/Planner
//       /PlannedSessionEditorView.swift:80-102) — CONFIRMED to have the exact
//       same bug class that was fixed in SessionScreenViewModel: it never
//       sets exerciseNameSnapshot, and leaves actualReps/actualLoads
//       /actualRIRs at SessionItem's empty-array default. This path is
//       un-audited and currently broken the same way the other one used to
//       be. Also `private`, so reproduced by verbatim transcription in
//       LoadWriteTests.test_B10_KNOWN_GAP_plannedSessionEditorViewAddExerciseOmitsNameAndArrays
//       rather than called directly.
//   Decision still deferred: consolidate to one shared function, or keep
//   testing all three for parity each release. Given a THIRD instance of the
//   same bug class just turned up un-audited, consolidation looks like the
//   stronger option, but that's a product/architecture call, not something
//   this test-writing pass should decide unilaterally.

// OPEN Q5: T-G.6 — Volume auto-regulation
//   Accumulated soreness does NOT yet change set counts. Confirm
//   intentionally inert. PARTIALLY RESOLVED, and possibly contradicted:
//   PlanMemoryEngine.volumeRegulationSignal (Domain/Logic/PlanMemoryEngine
//   .swift) DOES reduce set count by 1 on carry-forward after 2+ of the last
//   3 completed sessions flagged soreness/disruption — this is exercised and
//   passing in LoadWriteTests.test_B7_repeatedFatigueSignalsReduceSetCountOnCarryForward.
//   Whether T-G.6's "accumulated soreness" refers to this exact mechanism
//   (in which case the baseline assumption in the original catalog entry is
//   now stale — it's no longer a no-op) or to a separate, longer-horizon
//   signal that's still genuinely inert, isn't clear from the prompt as
//   written. Needs a product decision before T-G.6 can be implemented for
//   real instead of stubbed.

// OPEN Q6 (NEW): mesoPhase == .deload does not imply isDeloadWeek
//   Discovered while building T-N.9. Session.isDeloadWeek is true only on
//   the literal last week (weekIndex == totalWeeks). Session.mesoPhase uses
//   percentage bands and flips to .deload at >=90% of the block (see OPEN
//   Q3). For an 11-week meso (ChestArmsLowBackMesoProfile.totalWeeks, the
//   documented default), week 10 is already 10/11 ~= 0.909 >= 0.90, so
//   mesoPhase == .deload there too — but isDeloadWeek is false (10 != 11).
//   So the relationship is a one-directional implication
//   (isDeloadWeek -> mesoPhase == .deload), not the iff the original catalog
//   entry (T-N.9) assumed. Both directions are tested explicitly in
//   InvariantTests.test_N9_*; the asymmetric one is named _KNOWN_GAP rather
//   than treated as a bug, since it isn't clear which of the two properties
//   (if either) is "wrong" — they're just answering different questions
//   (position-in-block percentage vs. literal-last-week) that happen to
//   usually, but not always, agree.

// OPEN Q7 (NEW): MesoLifecycle.activeStartDate is never moved by the seeders themselves
//   Discovered while building T-N.11. None of the three seeding entry points
//   (DUPProgramSeeder.seed, MaintenanceProgramSeeder.seed,
//   MaintenanceProgramSeeder.seedFromNewProgram) call
//   MesoLifecycle.confirmStartNewMeso or AppStateBridge.setActiveMesoStartDate.
//   That pairing is done by hand at each of (at least) 4 UI call sites
//   instead (SettingsView, MesoRolloverGuardSheet, MesoSummaryView,
//   MaintenanceProgramPickerView) — the same class of bug fixed earlier this
//   session for a different call site. Confirmed via grep there are
//   currently no orphaned seeder calls missing the pairing, but nothing
//   structural stops a future call site from forgetting it again, since the
//   invariant lives at the call site, not inside the seeder. Tested as a
//   confirmed-current-state fact in
//   InvariantTests.test_N11_seederAloneDoesNotMoveActiveStartDate, not as a
//   bug — whether to push the MesoLifecycle call down into the seeders
//   themselves (so this class of bug becomes structurally impossible) is a
//   design decision for later, not made here.
