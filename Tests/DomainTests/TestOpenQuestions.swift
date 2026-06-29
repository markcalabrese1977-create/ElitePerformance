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
//   where pct = weekIndex / totalWeeks. IMPLEMENTED: MesoPhaseBandTests
//   .test_D1_phaseBands / test_D2_boundaryOwnership / test_D3_weekIndexBase
//   in StubTests.swift lock this in directly against Session.mesoPhase.
//   See OPEN Q6 for the mesoPhase/isDeloadWeek contradiction this also
//   surfaces (test_D5, escalated from _KNOWN_GAP to BUG_CONFIRMED).

// OPEN Q4: T-B.10 — Three addExercise paths
//   Today "+", ProgramDayDetailView, PlannedSessionEditorView. Known to
//   diverge silently. RESOLVED:
//     - SessionScreenViewModel.addExercise (SessionView.swift) — correctly
//       seeds exerciseNameSnapshot and non-empty actual/planned arrays (fixed
//       earlier this session). Directly unit-tested in LoadWriteTests
//       .test_B10_sessionScreenViewModelAddExerciseSeedsNameAndArrays.
//     - ProgramDayDetailView.addExercise(from:) — also correct (this was the
//       reference/"known good" implementation used to fix the SessionView
//       path earlier this session) — but it's `private`, so it cannot be
//       unit-tested directly without changing source visibility.
//     - PlannedSessionEditorView.addExercise(_:) — had the exact same bug
//       class that was fixed in SessionScreenViewModel (never set
//       exerciseNameSnapshot, left actualReps/actualLoads/actualRIRs at
//       SessionItem's empty-array default). Grepped for live references
//       before touching anything: zero call sites anywhere in the app —
//       confirmed dead code, not a reachable bug. Deleted
//       (Features/Planner/PlannedSessionEditorView.swift and its now-empty
//       Planner group) rather than fixed, since fixing dead code just teaches
//       it to hide better. Two paths remain, both correct.

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
//   RESOLVED (this commit): implemented T-G.6 scoped specifically to
//   same-session, real-time accumulation (calling CoachingEngine.recommend
//   repeatedly within one in-progress session never mutates targetSets) —
//   confirmed via a full read of CoachingEngine.recommend and
//   SessionScreenViewModel.handleSetLogged that neither touches targetSets
//   based on setFeedbackBySet at all. This is a real, narrower claim than
//   the original catalog entry and does NOT contradict
//   volumeRegulationSignal's carry-forward behavior above — they're
//   different mechanisms (same-session vs. next-session). See
//   VolumeAutoRegulationStubTests.test_G6_accumulatedSorenessWithinASessionDoesNotChangeSetCounts
//   in StubTests.swift.

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
//   InvariantTests.test_N9_*; the asymmetric one was originally named
//   _KNOWN_GAP rather than treated as a bug, since it wasn't clear which of
//   the two properties (if either) is "wrong" — they're just answering
//   different questions (position-in-block percentage vs. literal-last-week)
//   that happen to usually, but not always, agree.
//   ESCALATED while implementing T-D.5: the D-section catalog explicitly
//   demands "they must never contradict," and the contradiction reproduces
//   at totalWeeks == 10 (week 9) — the length used by every DUP template in
//   this codebase, not just ChestArmsLowBackMesoProfile's 11-week default.
//   MesoPhaseBandTests.test_D5_BUG_phaseContradictsIsDeloadWeekAtLateBand
//   (StubTests.swift) asserts the strict invariant and was left failing with
//   a BUG CONFIRMED comment.
//   RESOLVED (this commit): Session.isDeloadWeek (Domain/Models/Session.swift)
//   now derives directly from mesoPhase instead of comparing weekIndex to
//   totalWeeks independently, so the two can never disagree again. Confirmed
//   via grep this property is computed, not stored, and had zero production
//   call sites — no historical data repair was needed. test_D5 and the
//   updated InvariantTests.test_N9_mesoPhaseDeloadNowImpliesIsDeloadWeekToo
//   (renamed from _KNOWN_GAP, which asserted the old broken behavior) both
//   pass now.

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

// OPEN Q8 (NEW): MesoPerformanceAnalyzer.analyze has no warmup or deload
//   exclusion anywhere in source
//   Discovered while building T-E.3/T-E.4. Confirmed via direct read of
//   Domain/Logic/MesoPerformanceAnalyzer.swift: every set with load > 0 &&
//   reps > 0 contributes to a session's e1RM peak via plain max() — no
//   <50%-of-max warmup filter like CoachingEngine's exists here. Separately,
//   completedSessions is every `.completed` session in the block with zero
//   waveRaw/isDeloadWeek filtering — a deload week counts the same as a
//   working week for both peak and verdict purposes.
//   Two confirmed, reproducible consequences, both left failing with BUG
//   CONFIRMED comments in MesoAnchoringAndAnalyzerTests (StubTests.swift):
//     - test_E3_BUG_peakIncludesWarmupSets: a low-load/very-high-rep set can
//       produce a higher raw Epley e1RM than the true top set and win
//       peakE1RM outright.
//     - test_E4_BUG_verdictContaminatedByTrailingDeloadSession: since the
//       verdict is a first-vs-last e1RM delta (see Q9), a meso whose last
//       completed session is a deload week gets its necessarily-lower load
//       read as "last," which can flip a genuinely progressing meso to a
//       false "declining" verdict.
//   test_E7 confirms the orphan-UUID exclusion (catalog == nil && no
//   exerciseNameSnapshot) DOES work correctly for per-exercise summaries —
//   only the warmup/deload side is broken.
//   RESOLVED (this commit): Domain/Logic/MesoPerformanceAnalyzer.swift now
//   (1) computes each session's own max load first and excludes any set
//   below 50% of it from e1RM/peak computation (same threshold
//   CoachingEngine uses), and (2) filters completedSessions down to
//   nonDeloadCompletedSessions (via the now-fixed Session.isDeloadWeek, see
//   Q6) before building exerciseIds/sessionsWithExercise, so deload weeks
//   never reach per-exercise e1RM/verdict computation. Neither fix touches
//   the meso-level completedSessions.isEmpty gate, per-exercise
//   exSets/exReps/exVolume totals, or opening/closing load — out of scope
//   per the task. test_E3 and test_E4 both pass now; test_E7 is unaffected
//   (its fixture's session is week 1 of 8, not positionally a deload week,
//   so the new deload filter correctly leaves it alone — it's still only
//   testing the orphan-UUID half).

// OPEN Q9 (NEW): MesoPerformanceAnalyzer's verdict is a first-vs-last delta,
//   not a net/regression slope
//   Discovered while building T-E.6/T-E.8 — both catalog entries assumed a
//   trend-aware computation ("net slope," "false-negative guard at exactly
//   2 sessions"). Actual source (MesoPerformanceAnalyzer.swift:247-255):
//     guard e1rmBySession.count >= 2 else { return .insufficient }
//     delta = (e1rmBySession.last.e1rm - e1rmBySession.first.e1rm) / first.e1rm
//     delta >= 0.03 -> .progressing, delta <= -0.03 -> .declining, else .plateaued
//   So: insufficient requires FEWER than 2 sessions (i.e. exactly 1 — not 2,
//   as T-E.6 assumed), and the verdict only ever compares the first and last
//   data points — any middle noise is structurally irrelevant, not because
//   the analyzer is slope-aware but because it never looks at the middle at
//   all. Both corrected behaviors are tested directly (not as bugs) in
//   test_E6_analyzerVerdictThresholds and
//   test_E8_verdictUsesFirstVsLastDeltaNotARegressionSlope.
//   RESOLVED (this commit): not a code bug, no production change needed —
//   the catalog's assumption was wrong, not the source. Documented here so
//   the corrected mechanism (first-vs-last delta, >=2 sessions for a real
//   verdict) is the answer anyone reads going forward, not the original
//   guess.

// OPEN Q10 (NEW): mode-per-label weekday derivation lives in a private View
//   method, not in MaintenanceProgramSeeder
//   Discovered while building T-F.7. The actual "mode weekday per dayLabel,
//   not a union" logic (and its documenting comment) lives entirely inside
//   MesoSummaryView.seedMaintenanceBlock() (Features/History/MesoSummaryView
//   .swift:95-129) — a `private` method on a SwiftUI View. MaintenanceProgramSeeder
//   .seed itself does zero weekday derivation: trainingWeekdays is a literal
//   caller-supplied array (Array(Set(trainingWeekdays)).sorted()), applied
//   uniformly to every day label. This is the same class of testability gap
//   as OPEN Q4's ProgramDayDetailView.addExercise(from:) — correct production
//   code, but not directly reachable from this test target without changing
//   source visibility (out of scope for a test-only task).
//   Handled in MaintenanceBlockSeedingTests.test_F7_weekdayDerivationIsModePerLabelNotUnion
//   (StubTests.swift) by transcribing the documented algorithm directly (and
//   confirming it produces the documented mode-vs-union divergence), plus
//   confirming the seeder faithfully uses only the weekdays it's given. If
//   MesoSummaryView's logic is ever refactored, this test's transcribed copy
//   needs to be kept in sync by hand — it cannot drift-detect automatically.

// OPEN Q11 (NEW): "the rollover guard" has no persisted, testable state
//   Discovered while building T-F.11. showMesoRolloverGuard
//   (Features/Home/HomeView.swift) is a private `@State` Bool local to a
//   SwiftUI View — pure presentation state with no SwiftData/UserDefaults
//   backing. Grepped MaintenanceProgramSeeder.swift fully: neither seed nor
//   seedFromNewProgram references HomeView, MesoRolloverGuardSheet, or any
//   rollover-related identifier at all. There is no "rollover guard state"
//   reachable from a model-layer unit test to assert against, in either
//   direction.
//   Handled in MaintenanceBlockSeedingTests.test_F11_seedingHasNoUndocumentedSideEffects
//   (StubTests.swift) via the closest verifiable proxy: seeding touches only
//   what's documented (archives active mesos, leaves completed sessions
//   alone, creates exactly one new MesoBlock) and nothing else. This does
//   not prove the rollover guard specifically stays untriggered — that would
//   require SwiftUI view-hosting test infrastructure this target doesn't have.

// OPEN Q12 (NEW): three History display sites use `load == 0` as a
//   bodyweight-exercise proxy instead of ExerciseCatalog.isBodyweight()
//   Discovered while building T-H.1/T-H.3. Confirmed via direct read:
//   Features/History/ExerciseSessionDetailView.swift:109 (formatLoad),
//   Features/History/ExerciseHistorySheet.swift:477 (formatSetToken), and
//   Features/History/HistoryView.swift:143 (loadText) all show "BW" purely
//   because a load value is 0 — none of them take or check exerciseId. By
//   contrast, the two correct call sites (Domain/Logic/LoadDisplay.swift and
//   Features/Session/SessionView.swift's isBodyweightExercise ->
//   UISessionSet.plannedDescription(isBodyweight:)) both go through
//   ExerciseCatalog.isBodyweight(exerciseId:) properly. Concrete consequence:
//   a non-bodyweight exercise logged with a 0 load for any reason (data
//   entry skip, failed rep, etc.) displays as "BW" in History views, which
//   is simply wrong for that exercise.
//   RESOLVED (2 of 3 sites, prior commit): ExerciseSessionDetailView
//   .formatLoad and ExerciseHistorySheet.formatSetToken both had exerciseId
//   already available as a view-level property in the same struct, so the
//   fix was a straight substitution — `if v == 0,
//   ExerciseCatalog.isBodyweight(exerciseId: ...) { return "BW" }` — matching
//   the pattern already used by Domain/Logic/LoadDisplay.swift and
//   Features/Session/SessionView.swift's isBodyweightExercise.
//   FULLY RESOLVED (this commit): the third site, HistoryView.swift's
//   private HistorySetDetail.loadText, is now fixed too. HistorySetDetail
//   gained a stored `exerciseId: String` property (it had none before), set
//   from uiEx.exerciseId — already in scope at both construction call sites
//   in HistoryView.exerciseDetails (~lines 318 and 333) — so no reach into
//   parent state or new plumbing beyond the struct's own initializer was
//   needed. loadText now checks `ExerciseCatalog.isBodyweight(exerciseId:
//   exerciseId)` before falling back to "BW", same as the other two sites.
//   Test coverage:
//   BodyweightMechanicsTests.test_H1_historyViewsNowConsultCatalogInsteadOfLoadZeroProxy
//   (StubTests.swift) transcribes the same fixed predicate (loadText is
//   still a private method on a private struct, uncallable directly from
//   this test target) and asserts it correctly distinguishes a real
//   bodyweight exercise from a non-bodyweight one logged at load == 0.
//   Actual SwiftUI rendering remains unverified; that would require
//   view-hosting test infrastructure this target doesn't have. All three
//   History display sites now consult the single source of truth.

// OPEN Q13 (NEW): ProgramCatalog.recommend has zero production call sites,
//   and its scoring function has at least three confirmed real bugs
//   Discovered while building T-I.2/T-I.3. Grepped the whole app: only
//   Features/Home/ProgramPickerView.swift mentions ProgramCatalog at all, in
//   a "Later we can map this into ProgramCatalog / BlockBuilder" comment —
//   it is never instantiated or called. The live onboarding completion path
//   (OnboardingFlowView -> ProgramApplicationService.apply) uses its own,
//   separate, much simpler ProgramApplicationService.selectTemplate(goal:
//   daysPerWeek:), a pure days+goal switch over the real DUP/PPL templates
//   with no experience/equipment/joint-limitation weighting at all.
//   ProgramCatalog.recommend is real, compiles, and is a pure deterministic
//   function (T-I.2 passes) — it's just orphaned, so the three bugs below
//   currently have zero live user-facing impact:
//     - test_I3_BUG_minimalEquipmentBypassesGoalFilterEntirely: every program
//       in ProgramCatalog.all requires .commercialGym equipment, so ANY other
//       equipment profile empties the goal+days filter for every input and
//       falls back to scoring the entire unfiltered catalog — a fat-loss
//       user with minimal equipment can be recommended a hypertrophy
//       program.
//     - test_I3_BUG_jointIssuesIsOnlyASoftBonusNotAHardExclusion:
//       hasJointIssues only adds a +2 bonus to jointFriendly programs, it
//       never excludes non-joint-friendly ones — when goal+days narrows to
//       exactly the one non-joint-friendly program (ppl_6d_hypertrophy),
//       hasJointIssues=true changes nothing.
//     - test_I3_BUG_sessionLengthNeverActuallyChangesTheWinningProgram:
//       hand-traced every shape of input capable of producing a top-two
//       contest in this six-program catalog and could not find one where 30
//       vs 90 minutes changes the winner — the scoring bonus it grants
//       always lands on programs that are either already winning outright or
//       already tied (and tie-broken by declaration order) regardless of it.
//   All three left failing with BUG CONFIRMED comments in
//   ProgramCatalogRecommendationTests (StubTests.swift). Do not fix here,
//   flag for next task — and note any fix should consider whether
//   ProgramCatalog should be wired into onboarding at all, or deleted as
//   superseded dead code, before investing in repairing its scoring logic.

// OPEN Q14 (NEW): there is no persisted propagation toggle anywhere in source
//   Discovered while building T-J.1. Grepped the whole app for
//   propagationEnabled/shouldPropagate/propagateChanges/propagationToggle:
//   the only hit is `propagateChangesToFutureSessions`, a private `@State
//   var ... = true` local to ProgramDayDetailView
//   (Features/Home/ProgramDayDetailView.swift:19) — pure SwiftUI
//   presentation state, not backed by UserDefaults, UserProfile, or
//   AppState. It resets to true every time the view opens fresh; there is
//   no way to "remember" a user's opt-out across view appearances, let
//   alone across app launches. SessionView's swap/add-exercise flows
//   (Features/Session/SessionView.swift:264-304) use an entirely different
//   mechanism — a per-action confirmation dialog ("Apply to future
//   sessions" vs. "Keep this session only") — not a toggle at all.
//   Neither ExerciseSwapPropagationService.apply nor
//   ProgramPlanPropagationService.applyPlanEditsForward has any internal
//   gating logic; both propagate unconditionally whenever called. "Opt-out"
//   is purely a decision about whether the View calls the service, made
//   fresh every time, never persisted, never reaching the domain layer.
//   This is the same class of testability gap as OPEN Q4/Q10/Q11 (private
//   View-local state/logic with no model-layer surface) — not a bug, just a
//   design fact worth knowing before anyone assumes "the user's propagation
//   preference is remembered." Tested as the structural fact it is in
//   PropagationToggleAndServiceTests.test_J1_propagationIsEntirelyACallSiteDecisionNotAServiceInternal
//   (StubTests.swift): calling vs. not calling the service is the entire
//   behavior surface; there is no third state to test.

// OPEN Q15 (NEW): CustomExerciseBackupDTO.isBodyweight does NOT default
//   safely when omitted — old backups with custom exercises fail to import
//   Discovered while building T-K.3. CustomExerciseBackupDTO.isBodyweight is
//   declared as `var isBodyweight: Bool = false` (Domain/Backup
//   /BackupSnapshotV1.swift:216) — a stored property with a default value,
//   but NOT `Bool?` and NOT decoded via `decodeIfPresent` anywhere (unlike
//   setFeedbackBySet/pumpRatingsBySet, which are `[String]?`/`[Int]?` and
//   coalesced with `?? []` in BackupSnapshotImporter, and unlike bodyWeight/
//   dayLabel, which are genuinely Optional). The original assumption when
//   first investigating this — that Swift's compiler-synthesized Codable
//   conformance falls back to a property's declared default value when its
//   JSON key is absent — is WRONG. Empirically confirmed: decoding a
//   customExercises entry that omits "isBodyweight" throws
//   DecodingError.keyNotFound, it does not default to false.
//   Any real backup that predates the isBodyweight field
//   (Domain/Backup/BackupSnapshotV1.swift's customExercises array) and
//   contains at least one custom exercise failed this exact way on import —
//   the entire top-level JSONDecoder().decode(BackupSnapshotV1.self, from:)
//   call threw, so the WHOLE backup failed to import, not just the
//   affected custom exercise.
//   RESOLVED (this commit): Domain/Backup/BackupSnapshotV1.swift now
//   declares `let isBodyweight: Bool?` (matching setFeedbackBySet/
//   pumpRatingsBySet's existing Optional pattern) instead of `var
//   isBodyweight: Bool = false`. Domain/Backup/BackupSnapshotImporter.swift
//   coalesces with `dto.isBodyweight ?? false` at the single
//   CustomExercise construction site that reads it. Both existing
//   CustomExerciseBackupDTO construction call sites
//   (BackupSnapshotExporter.swift and the T-K.2 full-schema test) already
//   passed isBodyweight explicitly, so neither needed a change. Re-merged
//   the isBodyweight-omission case back into
//   BackupRestoreImportTests.test_K3_oldBackupMissingNewerFieldsImportsCleanly
//   (StubTests.swift) alongside the other four "added later" fields, since
//   it's no longer a separate failure mode — the dedicated BUG CONFIRMED
//   test that isolated it is now redundant and was removed.

// OPEN Q16 (NEW): the unsupported custom HKQuantityType path is dead code,
//   not removed code — string + two private functions still exist, unused.
//   Discovered while building T-L.3. The task's premise was that the old
//   custom-HKQuantityType write path had been fully removed from source.
//   That's not quite right: MechanicalLoadHealthKitService.swift:15 still
//   declares `quantityTypeIdentifier = "com.calabrese.eliteperformance
//   .mechanicalLoad"`, and two `private` functions
//   (requestWriteAuthorizationIfNeeded(), writeSample(score:date:)) still
//   reference it. Neither function has a single call site anywhere in the
//   codebase — the real, only public entry point, writeAfterSession(_:),
//   goes straight to MechanicalLoadSharedStore.write(score:for:) (shared
//   App Group UserDefaults), with its own comment explaining why: custom
//   HKQuantityType identifiers aren't supported for third-party apps
//   without special entitlements. So the string and the two functions are
//   harmless, unreachable leftovers from an earlier, abandoned approach —
//   not a live bug, not a security/crash risk, just dead code that a naive
//   "grep for the string" check would flag incorrectly. Tested as the
//   structural fact it is in MechanicalLoadAppGroupTests
//   .test_L3_activeWritePathNeverUsesUnsupportedCustomQuantityType
//   (StubTests.swift): the real write path is exercised end-to-end and
//   confirmed never to throw the custom-quantity-type error path. Same
//   class of finding as OPEN Q13 (ProgramCatalog.recommend) — dead,
//   unreferenced code discovered while testing a "this was removed" claim.

// OPEN Q17 (NEW): CoachingEngine.recommend cannot tell a genuine 0-rep
//   total-failure set apart from a not-yet-logged one — both withhold a
//   verdict entirely instead of producing a hold/reduce recommendation.
//   Discovered while building T-M.6. workingIndices (Domain/Logic
//   /CoachingEngine.swift:79-85) is built from `reps[idx] > 0 && loads[idx]
//   > 0` — a set where the lifter attempted the prescribed load and failed
//   every single rep (reps == 0, load == the attempted weight) fails this
//   filter exactly the same way an entirely unlogged set would. With every
//   set in the item failing to 0 reps, workingIndices ends up empty and
//   `guard !workingIndices.isEmpty else { return nil }` (line 91) returns
//   nil — silence, not a hold/reduce coaching message. SessionItem has no
//   "this set was attempted" flag independent of reps/load to disambiguate
//   the two cases. A user who fails every rep on every set of an exercise
//   gets zero feedback from the coach, same as if they'd skipped it
//   entirely. Do not fix here, flag for next task. Confirmed by
//   ExtraSetsAndFailureTests
//   .test_M6_BUG_totalFailureAllSetsZeroRepsIsIndistinguishableFromUnloggedAndWithholdsEntirely
//   (StubTests.swift) — left failing on purpose. A more realistic partial
//   failure (one set craters but isn't literally 0 reps) is unaffected and
//   correctly produces a hold; see
//   .test_M6_failureWithBigRepCrashHoldsNeverIncreasesNoNaN in the same file.

// OPEN Q18 (NEW): switching UserProfile.usesKilograms doesn't convert
//   anything — it's a pure display-label toggle, with zero lbs<->kg
//   numeric conversion logic anywhere in the codebase.
//   Discovered while building T-M.12. The task's premise was a "canonical
//   storage unit + display conversion" system where switching units might
//   risk a ~2.2x inflation bug. The actual system has no conversion logic
//   at all: usesKilograms (Domain/Models/UserProfile.swift:80-83) only
//   controls which suffix text ("kg" vs "lbs"/"lb") is appended next to a
//   number (e.g. Features/Settings/SettingsView.swift:75,89, Features
//   /Session/SessionView.swift:910) — the underlying SessionItem.
//   suggestedLoad/actualLoads/plannedLoadsBySet values are never touched.
//   Grepped the whole app for an actual conversion factor (2.20462 or
//   equivalent) and found none. Practical effect: a load logged as "225"
//   while in lbs mode displays as "225 kg" after switching the toggle —
//   the same number, now implying a real-world weight roughly 2.2x heavier
//   than what was actually lifted. This is the mirror image of the
//   inflation bug the task catalog worried about (an accidental ×2.2),
//   not an accidental ×2.2, but a missing ÷2.2 — zero conversion where a
//   real one is expected. Do not fix here, flag for next task. Confirmed
//   by UnitAndIncrementChangeTests
//   .test_M12_BUG_unitSwitchNeverConvertsTheDisplayedNumberAtAll
//   (StubTests.swift) — left failing on purpose. The companion test,
//   .test_M12_unitSwitchLeavesStoredLoadUnchanged, passes: at least the
//   stored model value is never mutated by the toggle, which is the
//   correct behavior for the *storage* half of this question even though
//   the *display* half is broken.
