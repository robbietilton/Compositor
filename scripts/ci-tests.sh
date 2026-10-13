#!/bin/bash
# Runs the unit tests in CI after `build-for-testing`, in several app processes at once.
#
# Nearly every suite runs on the main actor, so within one process they take turns however parallel testing is set.
# Each process has its own main thread: the suites are split between them, and the window suites, which need a
# quiet machine, run by themselves in a process of their own. New suites land in "rest" without being listed here.
#
# The filter suites run only when FILTERS=true (the workflow decides, from what changed).
#   scripts/ci-tests.sh <DerivedData path>
set -uo pipefail

DERIVED="${1:-DerivedData}"
XCTESTRUN=$(ls "$DERIVED"/Build/Products/*.xctestrun 2>/dev/null | head -1)
[[ -n "$XCTESTRUN" ]] || { echo "No .xctestrun in $DERIVED — run build-for-testing first."; exit 1; }

FILTER_SUITES=(CameraRawTests CameraRawSliderTests HueSaturationTests ImageAdjustmentTests LevelsTests FilterTests
  ScanlinesTests FinishingFilterTests)
WINDOW_SUITES=(FloatingPanelTests SliderSnapTests)
# About half of the rest, alternating down the suites by size so neither half gets all the big ones.
FIRST_SUITES=(PSDRoundTripTests LayerTests SelectionTests SelectionEditTests TransformTests TiledLayerTests
  AdjustmentLayerTests GuideTests SelectionClipboardTests ImageImportTests CompositorTests ExternalChangeTests
  HistoryTests GradientTests CropToCanvasImportTests MaskTransformTests LiveMaskTests MaskAloneTests
  BrushIntersectionTests ShapeToolTests CanvasEntryTests PSBImportTests SmartEditTests CommandPaletteTests
  CanvasRotationTests CanvasThumbnailTests ProjectTabLayoutTests ResizeSnapTests SpotHealingTests
  PSDAdjustmentTests NewCanvasUnitTests SelectionFeatherTests BlurBrushTests)

# macOS's bash is 3.2: no mapfile, so the arguments are gathered in `args`.
only() { args=(); for suite; do args+=("-only-testing:CompositorTests/$suite"); done; }
skip() { args=(); for suite; do args+=("-skip-testing:CompositorTests/$suite"); done; }

names=() pids=()
run() {
  local name=$1; shift
  rm -rf "$name.xcresult"
  ( start=$SECONDS
    xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS' \
      -resultBundlePath "$name.xcresult" "$@" > "$name.log" 2>&1
    status=$?
    echo "$((SECONDS - start))" > "$name.seconds"
    exit $status ) &
  names+=("$name") pids+=($!)
}

only "${FIRST_SUITES[@]}"; run first -parallel-testing-enabled YES "${args[@]}"
skip "${FIRST_SUITES[@]}" "${FILTER_SUITES[@]}" "${WINDOW_SUITES[@]}"; run rest -parallel-testing-enabled YES "${args[@]}"
only "${WINDOW_SUITES[@]}"; run windows -parallel-testing-enabled NO "${args[@]}"
if [[ "${FILTERS:-true}" == true ]]; then
  only "${FILTER_SUITES[@]}"; run filters -parallel-testing-enabled YES "${args[@]}"
else
  echo "Filter suites skipped: nothing they cover changed."
fi

failed=0
for i in "${!names[@]}"; do
  name=${names[$i]}
  if wait "${pids[$i]}"; then result=passed; else result=FAILED; failed=1; fi
  echo "::group::$name — $result in $(cat "$name.seconds" 2>/dev/null)s"
  # Slowest suites, to keep the split even.
  xcrun xcresulttool get test-results tests --path "$name.xcresult" 2>/dev/null | python3 -c '
import json, sys
suites = {}
def walk(node, suite=None):
    if node.get("nodeType") == "Test Suite": suite = node["name"]
    if node.get("nodeType") == "Test Case" and suite: suites[suite] = suites.get(suite, 0) + node.get("durationInSeconds", 0)
    for child in node.get("children", []): walk(child, suite)
for node in json.load(sys.stdin).get("testNodes", []): walk(node)
for suite, seconds in sorted(suites.items(), key=lambda s: -s[1])[:10]: print(f"{seconds:7.1f}s  {suite}")
' || true
  if [[ $result == FAILED ]]; then cat "$name.log"; else grep -E "^(Test run|\*\* TEST)" "$name.log" | tail -2; fi
  echo "::endgroup::"
  [[ $result == FAILED ]] && echo "::error::$name failed — open its group above for the log."
done
exit $failed
