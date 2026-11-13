# History tab inventory (state at a1de156, before the Block Summary retirement)

Inventory only. It feeds a later layout redesign.

## Top to bottom

### 1. "Block recap" card
- **View / file:** `HistoryView` (Features/History/HistoryView.swift:27), a `NavigationLink` card.
- **Shows:** a title and one sentence. No number.
- **Tap opens:** `HistorySummaryView` ("Block Summary", Features/History/HistorySummaryView.swift).

### 1a. Block Summary screen (`HistorySummaryView`)
- **Data:** `@Query` of all `Session`s (completed only). Scope picker "All-time" / "This meso" (this meso = sessions of the first active block, else dates since `MesoLifecycle.activeStartDate`, a UserDefaults epoch).
- **Numbers:** per-exercise `ExerciseSummary` from `HistorySummaryBuilder.build` (same file). Since P1d the builder reads `AnalyticsEngine.ItemStats` (hard sets, working-set best e1RM, volume at the effective load).
- **Sections:** totals (sets / reps / volume = sums of the per-exercise summaries); "Top lifts" (top 5 compounds and top 5 accessories **ranked by best e1RM**, mixing different lifts); "All exercises" with a sort menu (Most sessions / Most volume / Best e1RM / Recent).
- **Tap opens:** an exercise row opens the exercise history sheet.
- **Overlap:** Meso Summary shows the same per-exercise sets, volume, best e1RM and totals for one block (computed by `MesoPerformanceAnalyzer`, a second path). All-time vs this-meso scopes can disagree with Meso Summary on "this meso" because the scope rule is different (see below).

### 2. Session list (everything else)
- **View / file:** `HistoryView` with `HistoryRow`.
- **Data:** `@Query` of `SessionHistory` (snapshots written at completion by `SessionScreenViewModel.persistCompletion`, SessionView.swift ~2377; or restored by `BackupSnapshotImporter`), sorted by `date` descending.
- **Grouping:** by calendar day (`startOfDay`), day header "December 9, 2025"; sessions of a day sorted by date descending; days sorted descending.
- **Row shows:** date (shown twice, left under "Week N" and right), "Week N" (`history.weekIndex`, a snapshot), "N lifts" (`totalExercises`), "N sets" (`totalSets`), volume (`totalVolume`, in the lifter's unit via `LoadFormatter.volumeInt`).
- **Tap opens:** `HistoryDayDetailView` ("Session Recap").

### 3. Session Recap (`HistoryDayDetailView`, HistoryView.swift ~210)
- **Header card:** day label (snapshot, else the live session's), date, "Week N", Exercises / Sets completed / Total volume (the SessionHistory snapshot values, same as the row), Mechanical load (`history.mechanicalLoad`, from `MechanicalLoadHealthKitService`), Total reps (sum of the reconstructed per-exercise reps).
- **Workout metrics card:** Apple Health summary (HealthKit link button).
- **"Edit this session":** opens `SessionView` for the source `Session` when it still exists (`sourceSession`).
- **"By exercise":** reconstructed from the source `Session` through `SessionScreenViewModel` (per-set loads/reps/RIR, wave label, prescription label, notes). Falls back to the snapshot's `SessionHistoryExercise` list (name, sets, reps, volume only) when the session is gone. Per exercise: Sets / Reps / Vol.
- **Tap opens:** a set row expands; nothing leaves the screen except "Edit this session".

## Where the same figure is computed by different paths

| Figure | Path A | Path B | Disagreement risk |
|---|---|---|---|
| Sets (session) | Row / header: `recap.setCount` = completed UI sets (`set.status == .completed`), reps `actualReps ?? plannedReps` (a completed set with no entered reps counts at its planned reps) | "By exercise" Sets: rows with `actualReps > 0`; Analytics / Meso Summary / Block Summary: hard sets (`WorkingSetFilter`: no warm-ups, skips, RP/drop add-ons) | The list can say 22 sets where the recap's exercises add to 21 and the Block Summary to 20. Three definitions. |
| Volume (session) | `recap.totalVolume`: reps (`actual ?? planned`) × effective load | "By exercise" Vol: load falls back to planned load / body weight; Meso Summary weekly volume: hard sets at the effective load | Planned fallbacks inflate A and B differently. |
| Reps | header Total reps = sum of reconstructed rows | list shows none; Block Summary total reps = hard sets only | Header and Block Summary differ by warm-ups. |
| Week N | `SessionHistory.weekIndex` snapshot | `Session.weekIndex` (live, changes with a mesos-length conversion or insert-deload) | A converted block shows the old week in History and the new one in Program/Meso Summary. |
| Date | `SessionHistory.date` = completion time | `Session.date` (also overwritten at completion); `completedAt`; `plannedDate` | Same value at completion, but a later edit of the session date does not update the history row. |
| Mechanical load | snapshot at completion | recomputed on demand in other screens | stale if the session is edited afterwards. |
| "This meso" | Block Summary: first active block, else `activeStartDate` | Meso Summary: the block itself; Analytics tab: `activeStartDate` cutoff | Three definitions of the current block. |
| Best e1RM | Block Summary / exercise sheet: `AnalyticsEngine` (all completed incl. deload/maintenance) | Meso Summary: `MesoPerformanceAnalyzer` (regular sessions, deloads excluded) | Same lift, different best when a deload or maintenance session was heavier. |
| PR flag | Meso Summary: "PR"/"New" chip | live recap: none; History: none | PRs exist in one place only. |

## Things that could confuse the redesign
- `SessionHistory` is a **snapshot**; edits to the `Session` after completion do not reach it (the list, header cards and Block recap can show different numbers for the same day).
- The list row prints the date twice.
- Block Summary ranks different lifts against each other by e1RM (Top lifts, "Best e1RM" sort); the new Meso Summary rules forbid that.
- Deleting a session leaves its `SessionHistory`; the recap then has only the snapshot (no sets, no Edit button).
