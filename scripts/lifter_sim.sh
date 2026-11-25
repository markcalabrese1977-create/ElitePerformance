#!/bin/bash
# The lifter simulation (LifterSimulationTests): N shards, one simulator each, one JSON line per lifter-block.
#   scripts/lifter_sim.sh [shards=6] [lifters=200]       Output: $OUT_DIR/sim_<shard>.jsonl  (default OUT_DIR ${TMPDIR:-/tmp}/ep_sim)
# Report: scripts/lifter_sim_report.py $OUT_DIR/sim_*.jsonl
cd "$(dirname "$0")/.." || exit 3
SHARDS="${1:-6}"; LIFTERS="${2:-200}"
OUT_DIR="${OUT_DIR:-${TMPDIR:-/tmp}/ep_sim}"; mkdir -p "$OUT_DIR"
DD="$OUT_DIR/DD"
xcodebuild build-for-testing -project ElitePerformance.xcodeproj -scheme ElitePerformance -destination "id=${BUILD_DEVICE:-D6774E79-3948-415D-8D08-F84E585BEFDA}" \
  -derivedDataPath "$DD" > "$OUT_DIR/build.log" 2>&1 || { echo "build failed: $OUT_DIR/build.log"; exit 3; }
PIDS=()
for ((k=0; k<SHARDS; k++)); do
  DEV="$(xcrun simctl create "EP-sim-$k-$$" "iPhone 17 Pro" | tail -1)"; xcrun simctl boot "$DEV"
  ( TEST_RUNNER_EP_SIM_OUT="$OUT_DIR/sim_$k.jsonl" TEST_RUNNER_EP_SIM_SHARD=$k TEST_RUNNER_EP_SIM_SHARDS=$SHARDS TEST_RUNNER_EP_SIM_LIFTERS=$LIFTERS \
      xcodebuild test-without-building -project ElitePerformance.xcodeproj -scheme ElitePerformance -destination "id=$DEV" -derivedDataPath "$DD" \
      -resultBundlePath "$OUT_DIR/result_$k.xcresult" -parallel-testing-enabled NO -only-testing:ElitePerformanceTests/LifterSimulationTests \
      > "$OUT_DIR/shard_$k.log" 2>&1; xcrun simctl shutdown "$DEV" >/dev/null 2>&1; xcrun simctl delete "$DEV" >/dev/null 2>&1 ) &
  PIDS+=($!)
done
wait "${PIDS[@]}"
echo "done: $OUT_DIR"
