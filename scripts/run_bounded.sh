#!/bin/bash
# Bounded test runner: build-for-testing (20 min cap), then test-without-building under a watchdog.
#
# Usage: scripts/run_bounded.sh [-- <extra xcodebuild test flags, e.g. -only-testing:... -skip-testing:...>]
# Env:   SIM_NAME   simulator name (default "iPhone 17 Pro")
#        OUT_DIR    logs + DerivedData (default ${TMPDIR:-/tmp}/ep_bounded; keep it outside the repo)
#        TEST_RUNNER_*  forwarded to the test host by xcodebuild
#
# Test phase: log silent 2 min -> sample; silent 4 min -> sample + kill; 8 min total cap -> sample + kill.
# Crash = a new ElitePerformance-*.ips in DiagnosticReports, or a "Restarting after" message in the log.
# Always samples before killing. Last line is "VERDICT: <PASS|FAIL|CRASH|HANG|TIMEOUT|BUILD_FAILED|BUILD_TIMEOUT>".
# Exit: 0 PASS, 1 FAIL, 2 CRASH/HANG/TIMEOUT, 3 build problem.

cd "$(dirname "$0")/.." || exit 3
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
OUT_DIR="${OUT_DIR:-${TMPDIR:-/tmp}/ep_bounded}"
BUILD_CAP=1200; TEST_CAP=480; SAMPLE_SILENCE=120; KILL_SILENCE=240
EXTRA=(); [ "${1:-}" = "--" ] && { shift; EXTRA=("$@"); }
mkdir -p "$OUT_DIR"; DD="$OUT_DIR/DD"; BLOG="$OUT_DIR/build.log"; TLOG="$OUT_DIR/test.log"
DIAG="$HOME/Library/Logs/DiagnosticReports"
SIM_ID="$(xcrun simctl list devices available | grep -F "$SIM_NAME (" | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | tail -1)"
[ -n "$SIM_ID" ] || { echo "no simulator named '$SIM_NAME'"; echo "VERDICT: BUILD_FAILED"; exit 3; }
DEST="platform=iOS Simulator,id=$SIM_ID"
COMMON=(-project ElitePerformance.xcodeproj -scheme ElitePerformance -destination "$DEST" -derivedDataPath "$DD")

mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
sample_proc() { # sample the test host if alive, else xcodebuild ($1)
  local pid; pid="$(pgrep -nx ElitePerformance || true)"; pid="${pid:-$1}"
  echo "sampling pid $pid -> $OUT_DIR/sample-$2.txt"
  sample "$pid" 5 -file "$OUT_DIR/sample-$2.txt" >/dev/null 2>&1 || true
}

# ---- 1. build (quiet for minutes on a cold tree is normal; only the overall cap applies) ----
echo "[build] build-for-testing, cap ${BUILD_CAP}s"
xcodebuild build-for-testing "${COMMON[@]}" > "$BLOG" 2>&1 &
bpid=$!; start=$SECONDS
while kill -0 "$bpid" 2>/dev/null; do
  if (( SECONDS - start > BUILD_CAP )); then
    pkill -P "$bpid" 2>/dev/null; kill "$bpid" 2>/dev/null
    echo "build exceeded ${BUILD_CAP}s"; echo "VERDICT: BUILD_TIMEOUT"; exit 3
  fi
  sleep 5
done
wait "$bpid"; brc=$?
if [ $brc -ne 0 ] || ! grep -q "TEST BUILD SUCCEEDED" "$BLOG"; then
  tail -20 "$BLOG"; echo "VERDICT: BUILD_FAILED"; exit 3
fi
BUILD_SECS=$((SECONDS - start)); echo "[build] ok in ${BUILD_SECS}s"

# ---- 2. boot ----
xcrun simctl boot "$SIM_ID" 2>/dev/null
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1

# ---- 3. test under watchdog ----
ls "$DIAG"/ElitePerformance-*.ips 2>/dev/null | sort > "$OUT_DIR/ips.before"
echo "[test] test-without-building, cap ${TEST_CAP}s, silence sample ${SAMPLE_SILENCE}s / kill ${KILL_SILENCE}s"
: > "$TLOG"
xcodebuild test-without-building "${COMMON[@]}" -parallel-testing-enabled NO ${EXTRA[@]+"${EXTRA[@]}"} > "$TLOG" 2>&1 &
tpid=$!; start=$SECONDS; sampled=0; verdict=""
while kill -0 "$tpid" 2>/dev/null; do
  sleep 5
  silent=$(( $(date +%s) - $(mtime "$TLOG") ))
  ls "$DIAG"/ElitePerformance-*.ips 2>/dev/null | sort > "$OUT_DIR/ips.now"
  newips="$(comm -13 "$OUT_DIR/ips.before" "$OUT_DIR/ips.now")"
  if [ -n "$newips" ] || grep -q "Restarting after" "$TLOG"; then
    verdict=CRASH; echo "crash detected: ${newips:-restart message}"
  elif (( SECONDS - start > TEST_CAP )); then
    verdict=TIMEOUT
  elif (( silent >= KILL_SILENCE )); then
    verdict=HANG
  elif (( silent >= SAMPLE_SILENCE && sampled == 0 )); then
    sampled=1; echo "silent ${silent}s: sampling"; sample_proc "$tpid" silent
  fi
  if [ -n "$verdict" ]; then
    sample_proc "$tpid" "$verdict"
    pkill -P "$tpid" 2>/dev/null; kill "$tpid" 2>/dev/null; sleep 2; kill -9 "$tpid" 2>/dev/null
    break
  fi
done
wait "$tpid" 2>/dev/null; trc=$?
TEST_SECS=$((SECONDS - start))

if [ -z "$verdict" ]; then
  # also catch a crash report that landed just as the run ended
  ls "$DIAG"/ElitePerformance-*.ips 2>/dev/null | sort > "$OUT_DIR/ips.now"
  newips="$(comm -13 "$OUT_DIR/ips.before" "$OUT_DIR/ips.now")"
  if [ -n "$newips" ]; then verdict=CRASH; echo "crash report: $newips"
  elif [ $trc -eq 0 ]; then verdict=PASS
  else verdict=FAIL; fi
fi
# A FULL run (no extra test selection) is judged against Tests/known_failures.txt: PASS only when there are no NEW FAILURES
# and no KNOWN WITHOUT RESULT (a known test that did not run). A partial run (extra flags) keeps the raw xcodebuild verdict,
# since a subset cannot give every known test a result.
if [ ${#EXTRA[@]} -eq 0 ] && { [ "$verdict" = PASS ] || [ "$verdict" = FAIL ]; }; then
  CMP="$("$(dirname "$0")/../Tests/compare_failures.sh" "$TLOG" 2>&1 || true)"
  echo "$CMP" | head -40
  NEWN="$(echo "$CMP" | sed -n 's/^== NEW FAILURES (\([0-9]*\)).*/\1/p')"
  NORN="$(echo "$CMP" | sed -n 's/^== KNOWN WITHOUT RESULT (\([0-9]*\)).*/\1/p')"
  if [ "${NEWN:-1}" = "0" ] && [ "${NORN:-1}" = "0" ]; then verdict=PASS; else verdict=FAIL; fi
fi
echo "[phase] debug build ${BUILD_SECS}s · test run ${TEST_SECS}s"
echo "logs: $BLOG $TLOG   elapsed ${SECONDS}s"
echo "VERDICT: $verdict"
case $verdict in PASS) exit 0;; FAIL) exit 1;; *) exit 2;; esac
