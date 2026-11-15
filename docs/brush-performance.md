# Brush rendering and 4K benchmark

## Interactive Metal completion handoff (2026-11-01)

Interactive continuous-brush updates now commit Metal work without waiting or reading buffers on the input path. Each stroke has at most one submitted command and one coalesced follow-up containing accumulated settled segments and the newest provisional tail. Once the latest command completes, its tiles are copied into the existing stroke-owned contexts and published on the main actor. A canceled stroke invalidates its completion epoch. Metal buffers are retained until command completion, and a GPU error cancels the active stroke before snapshot commit.

Mouse-up remains the synchronous snapshot boundary: it queues the final accepted geometry behind any submitted work, waits once on the same command queue, reads the final tile contents, then uses the existing immutable snapshot and undo handoff. Save/export/undo therefore see committed pixels; mouse-up latency is still a synchronous cost. This implementation covers the existing continuous Metal path. Stamp-dynamic generated brushes such as Bristles still use the CPU renderer and are not improved by this change.

Focused regression coverage drains pending Metal work only when a test needs to inspect a live preview. It checks cross-tile pixels, tail replacement, pressure/opacity coverage, a 10,000 × 10,000 sparse canvas, cancel-then-restart isolation, and cancellation after a reported GPU failure. Run:

```sh
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:CompositorTests/BrushTests \
  -only-testing:CompositorTests/BrushIntersectionTests \
  -only-testing:CompositorTests/BrushPerformanceTests \
  -only-testing:CompositorTests/LargeCanvasBrushTests test
```

The Debug 4K benchmark run (`/tmp/compositor-async-brush-benchmark-debug.log`, isolated DerivedData `/tmp/CompositorBrushAsyncDebug`) reports these input-event intervals. Each frame interval includes `continueBrush`, `synchronizeDisplay`, and `displayIfNeeded`; async GPU completion and actual display presentation happen later and are not included.

| Workload | Configuration | Update median | Update p95 | Update max | Mouse-up per stroke |
| --- | --- | ---: | ---: | ---: | ---: |
| Continuous round, 40 px, blank | Debug | 0.038 ms | 0.236 ms | 0.419 ms | 20.7–24.6 ms |
| Continuous round, 40 px, blank | Release | 0.011 ms | 0.202 ms | 0.307 ms | 19.1–22.3 ms |
| Continuous round, 40 px, opaque | Debug | 0.038 ms | 0.564 ms | 1.824 ms | 16.6–18.0 ms |
| Continuous round, 40 px, opaque | Release | 0.011 ms | 0.537 ms | 0.638 ms | 17.6–17.9 ms |
| Continuous round, 800 px, blank | Debug | 0.055 ms | 0.615 ms | 0.977 ms | 77.2–82.2 ms |
| Continuous round, 800 px, blank | Release | 0.015 ms | 0.509 ms | 0.892 ms | 74.1–78.5 ms |
| Continuous round, 800 px, opaque | Debug | 0.058 ms | 1.696 ms | 2.013 ms | 71.2–72.3 ms |
| Continuous round, 800 px, opaque | Release | 0.016 ms | 1.437 ms | 1.964 ms | 72.7–73.4 ms |
| Stamp-dynamic Bristles, 120 px, zero spacing | Debug | 16.336 ms | 16.336 ms | 16.336 ms | 17.2 ms |
| Stamp-dynamic Bristles, 120 px, zero spacing | Release | 14.617 ms | 14.617 ms | 14.617 ms | 15.0 ms |

In the separate 12-update deterministic matrix, stamp-dynamic Bristles 800 px measured 712.6 ms median / 1,059.1 ms p95 in Debug and 658.4 ms / 1,010.9 ms in Release, with mouse-up at 342.9 ms and 333.2 ms. This confirms that the async continuous Metal change does not accelerate that brush path. The simple round results show that input-event work is now short because GPU completion and tile readback moved off the event path; they are not input-to-photon timings. Mouse-up remains synchronous. Debug and Release benchmark commands and logs: `/tmp/compositor-async-brush-benchmark-debug.log` and `/tmp/compositor-async-brush-benchmark-release.log`; their separate DerivedData folders are `/tmp/CompositorBrushAsyncDebug` and `/tmp/CompositorBrushAsyncRelease`. No after-change Allocations/peak-memory capture, actual display-presentation latency, native hands-on UI check, or physical tablet test was collected.

Acceptance boundaries: **Code** keeps interactive continuous Metal appends asynchronous and mouse-up synchronous. **Automated tests** cover final pixel output and cancel/error behavior; the focused Debug run passed 31 tests in four suites, and the focused Release performance benchmark passed. **Native UI** was exercised through synthetic input in an NSWindow benchmark, without hands-on brush-panel review. **Source visual** was not regenerated because the change does not alter tip sampling or coverage; pixel-level brush previews were checked in the regression suite. **Physical device** testing was not performed; input remains deterministic synthetic mouse/pen data.

The brush now sweeps a continuous round tip along the smoothed pointer path with a Metal compute kernel. Each changed 256 × 256 tile is processed once per update. Permanent coverage and the provisional tail have separate buffers, so replacing a tail cannot leave old pixels behind. Soft coverage accumulates by integrating paint deposition over distance travelled, equivalent to source-over tips at 2.5% diameter spacing. This blends self-crossings and corners smoothly and is independent of pointer-event count. The opacity setting caps the entire accumulated stroke. Hard tips retain their antialiased silhouette; the software fallback uses 2.5% soft / 1.5% hard tip spacing.

Mouse-up installs an immutable `RasterSnapshot` and records the undo entry synchronously. Snapshots share unchanged tiles and flatten their replacement lists using a spatial index. Bounds are found in changed tiles with a small optimized C routine, instead of scanning every document pixel in unoptimized Swift. The canvas and subsequent strokes read the tiles directly. A contiguous CGImage is created lazily when export or an image-processing operation needs its bytes. Masks use the same snapshot handoff, including white coverage in newly expanded areas.

The Metal pipeline is compiled once by the system compiler and warmed when selecting Brush. This does not require Xcode's optional Metal toolchain. Pixel kernels remain optimized in Debug; Swift code retains its normal Debug optimization settings.

## Measured on September 12, 2026

4000 × 4000 document, 800 px brush, 0% hardness, 100% opacity. Two strokes of 120 pointer updates each, 40 document pixels per update, in a native 1000 × 1000 NSWindow at fit zoom. Times include the model update and `CanvasView.synchronizeDisplay()` / `displayIfNeeded()`. Mouse-up includes flush, commit, history, and the following display. These are synchronous CPU timings, not an input-to-photon measurement or a Photoshop benchmark.

| Debug, blank paint layer | Before | After |
| --- | ---: | ---: |
| Median pointer update | 6.54 ms | 2.64 ms |
| 95th percentile update | 11.98 ms | 3.70 ms |
| Mouse-up, first stroke | 1058 ms | 8.71 ms |
| Mouse-up, second stroke | 1002 ms | 8.14 ms |

On an existing opaque 4K layer, the new 800 px brush measured 2.80 ms median / 5.38 ms p95, with 5.2–6.2 ms mouse-up. The 40 px brush measured 0.36–0.47 ms median, with 1.3–4.8 ms mouse-up. Timing varies with hardware, viewport, layer stack, and system load; no resolution-independent frame-rate guarantee is implied.

Release also built and passed the benchmark. Its 800 px blank-layer median was 2.81 ms and mouse-up was 9.6–11.0 ms (the original Release mouse-up was 87–111 ms). The opaque-layer run measured 4.35 ms median and 7.4–15.9 ms mouse-up; this variation reinforces using measured ranges rather than promising a fixed frame rate.

The final Debug unit run passed **171 tests in 25 suites**. Logs for this change are `/tmp/compositor-brush-final-tests.log`, `/tmp/compositor-brush-new-debug.log`, `/tmp/compositor-brush-new-release.log`, and `/tmp/compositor-brush-baseline-debug.log`.

## Reproduce

Run performance tests alone, so other main-actor tests do not contend with the benchmark. `TEST_RUNNER_` forwards the environment variable into the Xcode test host.

```sh
TEST_RUNNER_BRUSH_BENCHMARK=1 xcodebuild \
  -project Compositor.xcodeproj -scheme Compositor -configuration Debug \
  -derivedDataPath /tmp/CompositorBrush -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  -parallel-testing-enabled NO \
  -only-testing:CompositorTests/BrushPerformanceTests test
```

The benchmark logs `BRUSH BENCH` lines and exports `/tmp/compositor-brush-benchmark.png` for visual inspection. It exercises both blank and opaque layers. The exported example contains both benchmark passes.

Functional coverage includes continuous soft coverage at 800 px, tile boundaries, curve/tail replacement, opacity, selections, transformed layers, immediate subsequent strokes, mask painting/expansion, immutable snapshots, display/export agreement, undo/redo, save/reopen, and the software fallback. Snapshots are verified not to materialize during commit, display, or the next stroke.

## Self-intersection correction

The initial continuous-tip implementation took the maximum falloff at each pixel. That removed stamp ridges, but the meeting point of two feathered edges formed a sharp crease. Soft tips now integrate optical density along each curve segment, then convert the accumulated density to coverage. Permanent density is stored in floating-point tile buffers; provisional tails remain separate and are replaced, never double-counted. Hard tips keep their solid silhouette. The existing opacity cap and immediate snapshot commits are unchanged.

Crossing tests compare the joined stroke against source-over coverage, verify the opacity cap, repeated flushes, the software fallback, and equivalent output at sparse/dense sampling for 12, 120, and 520 px tips. The matching 520 px / 4K example is exported to `/tmp/compositor-brush-crossing.png` by `BrushIntersectionTests/exportCrossingExample` with `TEST_RUNNER_BRUSH_BENCHMARK=1`.

With this correction, the 800 px / 4K Debug benchmark measured 3.08–3.12 ms median update and 6.3–9.7 ms mouse-up across blank and opaque layers. Log: `/tmp/compositor-intersection-bench.log`.

The post-correction full Debug suite passed **175 tests in 26 suites** (`/tmp/compositor-intersection-full.log`).

## Experimental baseline — November 1, 2026

Branch `codex/experimental-brush-performance`, starting commit `450639a67a7dec518c56a113af64a80b4405bb59`; Apple M1 Mac mini, 16 GB; Debug, arm64, 4K canvas, 1000×1000-point window at backing scale 2, fit zoom. The reusable `BrushPerformanceTests` workload was run in isolated `/tmp/CompositorBrushBaseline` DerivedData with the cached Sparkle package graph. Raw test log: `/tmp/compositor-brush-bristles-zero.log`; result bundle: `/tmp/CompositorBrushBaseline/Logs/Test/Test-Compositor-2026.11.01_16-45-04-+0200.xcresult`.

| Workload | Median update | p95 | Max | Mouse-up |
| --- | ---: | ---: | ---: | ---: |
| Legacy round, 40 px, blank | 0.61 ms | 1.10 ms | 1.39 ms | 5.7–6.5 ms |
| Legacy round, 40 px, opaque | 0.59 ms | 1.36 ms | 2.70 ms | 1.8 ms |
| Legacy round, 800 px, blank | 4.49 ms | 6.32 ms | 8.70 ms | 13.8–16.4 ms |
| Legacy round, 800 px, opaque | 4.28 ms | 7.16 ms | 10.27 ms | 9.0–9.5 ms |
| Generated Bristles, 120 px, zero spacing, None filtering, one 10 px move | 15.09 ms | 15.09 ms* | 15.09 ms* | 15.44 ms |

`*` Single-sample probe, so p95/max are the same sample and are not stable estimates. A later 12-update matrix captured the 800 px zero-spacing case; its initial six-update attempt had exceeded the time bound.

The current advanced path is shared C CPU stamping. `BrushStroke.append` routes stamp dynamics through `walk`/`place`, and `publish` converts dirty coverage to images for canvas display; `brush_render_stamp` in `Compositor/Rendering/BrushPixels.c` loops every pixel in each dab bound, samples the tip and grain, and performs filtering/effects inline. Zero spacing can make dabs overlap heavily, repeating this work over the same pixels. First optimization candidate is avoiding redundant per-pixel sampling/work without changing dab placement, filtering, or output; baseline instrumentation must separate placement, C raster, publication, and display before patching.

The earlier 800 px advanced blend/grain probe (120 updates) measured 376.7 ms median / 396.1 ms p95 in one Debug run. It is historical and uses a different path from the bounded matrix below. The September legacy-round numbers also remain historical.

Reproduce the current focused suite:

```sh
TEST_RUNNER_BRUSH_BENCHMARK=1 xcodebuild \
  -project Compositor.xcodeproj -scheme Compositor -configuration Debug \
  -derivedDataPath /tmp/CompositorBrushBaseline \
  -clonedSourcePackagesDirPath /Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/SourcePackages \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  -parallel-testing-enabled NO -only-testing:CompositorTests/BrushPerformanceTests test
```

## Experimental profiling baseline — November 1, 2026

The branch is `codex/experimental-brush-performance`, HEAD `450639a67a7dec518c56a113af64a80b4405bb59`. Hardware is an Apple M1 Mac mini with 16 GB RAM, running macOS 27.0.1 (26A434) and Xcode 27.2. The baseline build from that unchanged commit is preserved at `/tmp/CompositorBrushOriginalBaselineSource` and `/tmp/CompositorBrushOriginalBaselineDerivedData`; `/tmp/compositor-brush-original-baseline-build.log` reports `BUILD SUCCEEDED`. Experimental Debug and Release builds use separate `/tmp/CompositorBrushBaseline` and `/tmp/CompositorBrushBaselineRelease` DerivedData, both reusing the cached Sparkle package graph. Release tests set `ENABLE_TESTABILITY=YES` so the `@testable` test target can import the optimized app module.

The deterministic matrix uses a 4000 × 4000 px document, one blank paint layer unless marked opaque, and an NSWindow/CanvasView 1000 × 1000 points at backing scale 2 and fit zoom. Opaque cases use one full-canvas imported gray image layer. Samples start at (800, 2000), then make 12 ten-pixel updates with a fixed seed (`0xB71571E5`), pressure ramp, tilt, rotation, device ID, and 16 ms timestamp increments. Generated Bristles uses zero spacing and None filtering. The asymmetric tip is a generated 64 × 64 L mask with Improved filtering. The transformed-mask case uses a 7° layer transform, selected 3000 × 3000 px selection, 40 px generated Bristles, and zero spacing. No local brush archive or Warptuner fixture is used.

Each matrix row reports 12 update samples. With nearest-rank p95, p95 equals max for this sample count; treat these as a reproducible first baseline, not a stable cross-machine guarantee. Times are synchronous CPU wall times for `continueBrush`, canvas synchronization, and `displayIfNeeded`, except mouse-up, which is measured separately.

| Workload | Touched tiles | Debug median / p95 / max | Release median / p95 / max |
| --- | ---: | ---: | ---: |
| Legacy round, 40 px, blank | 1 | 0.637 / 1.258 / 3.204 ms | 0.570 / 2.163 / 3.081 ms |
| Legacy round, 40 px, opaque | 1 | 0.570 / 1.324 / 1.825 ms | 0.561 / 2.711 / 6.186 ms |
| Legacy round, 800 px, blank | 16 | 4.376 / 6.875 / 10.766 ms | 4.429 / 6.715 / 7.738 ms |
| Legacy round, 800 px, opaque | 16 | 4.541 / 7.387 / 9.527 ms | 4.281 / 7.089 / 9.190 ms |
| Generated Bristles, zero spacing, 40 px | 1 | 4.061 / 4.628 / 4.628 ms | 3.450 / 4.039 / 4.039 ms |
| Generated Bristles, zero spacing, 800 px | 36 | 682.021 / 1024.232 / 1024.232 ms | 675.375 / 1033.575 / 1033.575 ms |
| Generated Speckle, 40 px | 1 | 1.594 / 1.818 / 1.818 ms | 1.394 / 1.621 / 1.621 ms |
| Generated Speckle, 800 px | 36 | 25.612 / 34.119 / 34.119 ms | 25.119 / 27.412 / 27.412 ms |
| Asymmetric image + Improved filter, 40 px | 1 | 2.518 / 2.940 / 2.940 ms | 2.282 / 2.613 / 2.613 ms |
| Asymmetric image + Improved filter, 800 px | 36 | 51.211 / 70.178 / 70.178 ms | 51.026 / 71.352 / 71.352 ms |
| High count (8), 40 px | 1 | 0.888 / 0.909 / 0.909 ms | 0.804 / 0.854 / 0.854 ms |
| High count (8), 800 px | 16 | 4.786 / 5.012 / 5.012 ms | 4.709 / 5.357 / 5.357 ms |
| Intense blend + wet/burnt edges, 40 px, opaque | 1 | 5.557 / 5.894 / 5.894 ms | 5.195 / 5.331 / 5.331 ms |
| Intense blend + wet/burnt edges, 800 px, opaque | 20 | 97.528 / 101.446 / 101.446 ms | 94.977 / 97.819 / 97.819 ms |
| Transformed, selected mask, 40 px Bristles zero spacing | 3 | 16.842 / 19.910 / 19.910 ms | 15.588 / 19.067 / 19.067 ms |

The separate one-update 120 px Bristles probe measured 15.414 ms in Debug and 15.562 ms in Release; one sample is not a percentile estimate. In the matrix, 800 px zero-spacing Bristles has roughly 1.0 s p95 and 340 ms mouse-up in both builds. This is the clearest reproduced stall and the first optimization target.

Debug and Release pixel hashes match for all 11 deterministic matrix outputs. Example visual outputs are `/tmp/compositor-brush-generated-bristles-800-zero-spacing.png`, `/tmp/compositor-brush-textured-blending-800-opaque.png`, and `/tmp/compositor-brush-benchmark.png`. Representative hashes: Bristles 800 `61e0e1359ce0790c…`, Speckle 800 `616832fd857d2790…`, asymmetric Improved 800 `c92cc6211070821f…`, textured blending 800 `4acf1d1417335d1f…`, transformed selected mask `44b7632dfd2a5227…`. Full hashes are in `/tmp/compositor-brush-debug-rss.log` and `/tmp/compositor-brush-release-matrix-clean.log`.

## Profile phases and resource observations

The live path is `EditorCanvas.mouseDown` / `mouseDragged` / `tabletPoint` → `EditorSession.beginBrush` / `continueBrush` → `BrushStroke.append` → curve and `walk`/`place` → `dab` → `brush_render_stamp` in `BrushPixels.c` → `publishTiles` → `EditorCanvas.synchronizeDisplay` / `draw`. The round continuous path uses `MetalBrushCoverage.render` and synchronously commits, waits, and reads back tiles. Signposts are opt-in via `BRUSH_PROFILE=1`; without it the closures call straight through and emit no signposts.

Points of Interest traces are `/tmp/compositor-brush-profile.trace` (Debug) and `/tmp/compositor-brush-release-profile.trace` (Release). These are profiler runs; do not use their wall times as benchmark results. Paired signpost intervals show the same leading phases in both configurations:

| Phase | Debug median / p95 / max | Release median / p95 / max |
| --- | ---: | ---: |
| Session input continue | 3.404 / 8.210 / 1041.831 ms | 3.267 / 15.240 / 1012.307 ms |
| Dab placement (includes nested raster work) | 0.110 / 12.245 / 94.676 ms | 0.155 / 11.113 / 91.259 ms |
| Individual C raster call | 0.194 / 0.700 / 5.912 ms | 0.183 / 0.672 / 6.899 ms |
| Tile publication | 1.968 / 6.292 / 58.421 ms | 1.892 / 5.860 / 49.990 ms |
| Canvas CPU draw callback | 50.838 / 112.915 / 112.915 ms | 31.528 / 97.549 / 97.549 ms |
| Mouse-up commit and undo | 8.033 / 337.640 / 337.640 ms | 8.320 / 95.877 / 332.201 ms |
| GPU completion wait | 0.927 / 1.397 / 2.565 ms | 1.045 / 1.549 / 3.414 ms |

The separate Debug Metal System Trace is `/tmp/compositor-brush-debug-metal.trace`. For 976 Compositor compute intervals it reports 170 µs median, 384 µs p95, 2.77 ms max GPU execution, and at most two overlapping GPU intervals. This makes the CPU-side stamp path the leading bottleneck; GPU work is not close to the 1 s Bristles update. A Canvas draw callback is CPU wall time, not a display swap. No hardware tablet-to-photon latency was measured.

App-process RSS was sampled every 100 ms during unprofiled matrix runs: Debug peak 827,248 KiB (about 808 MiB), Release peak 700,928 KiB (about 684 MiB). This is process RSS, including shared mappings.

Allocations traces attached to the test host and covered the complete focused suite in both configurations: `/tmp/compositor-brush-debug-allocations.trace` and `/tmp/compositor-brush-release-allocations-full.trace`; exported aggregate tables are `/tmp/compositor-brush-debug-allocations-statistics.xml` and `/tmp/compositor-brush-release-allocations-full-statistics.xml`. The profiler-only build used an isolated ad-hoc signature with `get-task-allow` and no app sandbox so Instruments could attach and the benchmark could export PNGs under `/tmp`. It did not change the app's source or shipped entitlements. Allocations profiling adds substantial timing overhead, so these traces are memory evidence only.

| Configuration | Cumulative heap allocations | Heap still live at trace end | Allocated then freed |
| --- | ---: | ---: | ---: |
| Debug | 1,810,707,640 bytes (1,726.8 MiB) | 135,406,504 bytes (129.1 MiB) | 1,675,301,136 bytes (1,597.7 MiB) |
| Release | 1,166,028,552 bytes (1,112.0 MiB) | 135,512,104 bytes (129.2 MiB) | 1,030,516,448 bytes (982.8 MiB) |

These are whole-suite totals over roughly 138 seconds, including app/test setup and every workload, not per-brush allocation rates or peak RSS. The Allocations template also reports cumulative `VM: CG Raster Data` backing of 3,440,345,088 bytes (Debug) and 1,249,476,608 bytes (Release); this is allocated raster backing, not a count of bytes copied. Exact `memcpy`/copy-on-write transfer volume and per-workload allocation attribution remain unmeasured. Touched-tile counts above are exact for the workload geometry; they do not substitute for copy-byte accounting.

The signpost phase histograms above are synchronous main-actor wall intervals for input receipt at `EditorSession.beginBrush`/`continueBrush`, placement, raster, publication, canvas synchronization/draw, and commit/undo. They show how long the event path occupies the main thread, including synchronous waits, but do not decompose scheduler descheduling from running time. GPU queue overlap was at most two intervals in the Metal System Trace; CPU brush input is processed synchronously with no separate queued work list. Canvas draw is a CPU callback measurement, not a display swap. No input-to-photon or physical-tablet latency was measured; that remains outside these synthetic NSWindow runs.

## Async renderer regression follow-up

The focused Debug regression run passed 28 tests across `BrushTests` and `BrushIntersectionTests`. Added checks cover explicit CPU fallback, cancellation/session release with GPU work pending, and mouse-up flushing pending work before a project snapshot and undo. Per-stroke GPU submissions are serialized: the next render is submitted only from the previous command buffer's completion callback, so delayed completion cannot reorder stroke segments. The callback-injected GPU error path remains covered; a real Metal command-buffer/device failure is not reliably inducible in this test environment.

Mouse-up remains the documented synchronous snapshot boundary. It waits once for outstanding GPU work, copies the final preview into the CPU-owned tile context, and only then publishes the immutable document/history state consumed by snapshot, save, and undo. Preview updates do not block on command completion.

Existing after-change Instruments evidence above remains the basis for memory and GPU execution results: Debug/Release peak process RSS was 808/684 MiB; whole-suite Allocations totals and the Debug Metal System Trace are linked above. A new focused Allocations attach was attempted during this follow-up but did not produce a valid trace after the test host exited. The new `Brush GPU Completion` signpost now spans command submission through Metal's completed callback, and `Brush Display If Needed` marks the CPU display callback. The existing Metal System Trace reports GPU execution durations, but no actual screen presentation/vsync or input-to-photon latency was measured. A successful new trace correlating the completion signpost with presentation remains outstanding.

## Acceptance targets for the optimization phase

- Keep every 40 px workload's update p95 at or below 16.7 ms, including the transformed selected-mask case.
- Keep simple 800 px round and high-count update p95 at or below 16.7 ms; bring generated/image/textured 800 px updates and zero-spacing Bristles to at or below 16.7 ms on this reference machine.
- Keep mouse-up commit and undo p95 at or below 16.7 ms for all matrix workloads. Record measured lower-tier hardware separately rather than promise universal 60 Hz.
- Bound queued GPU intervals to at most two and avoid unbounded pending input work.
- Preserve deterministic sample ordering and all baseline pixel hashes. Do not meet timing targets by skipping dabs, raising spacing, or downgrading filtering.

These are proposal thresholds for the follow-on optimization, not claims that the baseline already meets them. The 800 px Bristles p95 target requires about a 98% reduction from baseline and remains an aggressive acceptance gate.

## Bristles GPU kernel prototype

`MetalBristlesPrototype` is an isolated benchmark experiment, not wired into brush input or canvas publication. It batches 13 overlapping, axis-aligned 800 px Dry Bristles dabs at zero spacing into one Metal compute dispatch over an 832,000-pixel crop. It implements the current `.none` nearest-sample mask lookup and normal-flow optical-density accumulation. The test compares against `brush_render_stamp` and then compares final coverage bytes.

On the reference M1 Mac, one Debug run measured 143.6 ms for the C reference and 2.8 ms for the GPU prototype wall time (1.9 ms from command submission through completion), with a maximum density difference of 0.0000191 and zero final-byte differences. This demonstrates that this restricted pixel kernel is GPU-suitable; it is not a live stroke latency result. In particular, the prototype does not yet handle rotated/tilted tips, grain, improved filtering, pressure opacity, tail rollback, tile publication, or display. It also allocates and reads back a compact crop per call. Those integration costs and full brush behavior need measurement before using this result to predict product performance.

The grayscale visual comparison is [bristles-cpu-vs-gpu.png](bristles-cpu-vs-gpu.png): CPU reference on the left, GPU prototype on the right. The dense center is expected from 13 fully opaque, closely overlapping dabs; the Bristles texture is visible around the perimeter. The panels are pixel-identical after coverage conversion.

### Tile-local affine stamp prototype follow-up

This section records the initial isolated prototype before the production integration checkpoint below. The Metal primitive accepts the already-evaluated ordered dab transforms and dispatches a bounded 256×256 tile. It supports nearest (`.none`), bilinear (`.classic`) and four-sample (`.improved`) mask sampling and applies each dab's flow/strength before ordered optical-density accumulation. Its renderer reuses the compute pipeline and caches uploaded mask buffers by SHA-256 content hash for its lifetime.

`generatedBristlesMetalPrototype` compares the real Metal output with the C CPU reference for 13 overlapping rotated dabs on the generated Bristles mask. Debug results on the reference M1: all three filters had maximum density error 0 and zero final-byte differences. CPU/GPU execution was 5.68/1.03 ms (`.none`), 6.05/0.37 ms (`.classic`) and 20.33/0.65 ms (`.improved`). This is a small tile-kernel prototype measurement, not a full stroke or mask/image production qualification. It establishes parity only for this generated mask, transform set, tile and flow/strength values.

Run with `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' -parallel-testing-enabled NO test -only-testing:CompositorTests/BrushPerformanceTests`. The `generatedBristlesMetalPrototype` pixel parity check runs as part of that focused suite.

The following acceptance entry is historical for the profiling change: **production code** then included opt-in measurement wrappers and a read-only touched-tile diagnostic; no production brush algorithm or `.comp` contract changed. The Metal Bristles prototype was benchmark-only at that point. **Automated tests**: the focused performance suite passed in Debug and Release; the initial prototype parity check passed in Debug. BrushTests, BrushIntersectionTests, and LargeCanvasBrushTests passed; BrushDynamicsTests reproduced two failures in isolation (`presetsRoundTripAndRejectInvalidDynamicsAtomically`, required-value error; `transformedTipsAndSelectedMasksPreservePixelsUndoAndReopen`, mask alpha expectation). **Native UI** was exercised through a native NSWindow in the benchmark, but no hands-on panel acceptance was performed. **Source visuals** are generated-tip outputs with matching Debug/Release hashes; they do not establish Procreate parity. **Physical device** testing was not performed; pressure/tilt/rotation came from deterministic synthetic input.

Final focused logs: `/tmp/compositor-brush-debug-rss.log`, `/tmp/compositor-brush-release-matrix-clean.log`, `/tmp/compositor-brush-regressions.log`, and `/tmp/compositor-brush-dynamics-rerun.log`. Debug and Release benchmark result bundles are under `/tmp/CompositorBrushBaseline/Logs/Test` and `/tmp/CompositorBrushBaselineRelease/Logs/Test`.

### Production stamp-rendering integration checkpoint

`BrushStroke.dynamicDab` remains the sole placement/randomness evaluator. For eligible stamp strokes it queues its already-computed affine dab records by intersecting tile, runs the shared Metal mask kernel during tile publication, and feeds the existing coverage, color, snapshot, and undo paths. Uploaded masks are reused by content hash in a bounded 16-entry cache. The shader handles procedural radial tips and generated/custom/embedded image masks; `.classic` and `.improved` production routes are enabled. `.none` keeps the existing C renderer in production because the end-to-end embedded-mask parity case exceeded tolerance; the direct kernel matrix passes `.none`, but that production combination is not qualified. Unsupported rendering effects remain on the C path. GPU command creation/completion failures replay the queued dab records through the C renderer and emit one diagnostic per stroke.

Provisional-tail rollback snapshots and restores pending Metal dab queues along with the existing stamped coverage. Without that queue rollback, provisional samples were deposited a second time after the shared coverage snapshot restored. CPU-versus-production-Metal comparisons cover procedural soft tips, generated Bristles with Improved filtering, custom images with Classic filtering, embedded images with CPU fallback for None, flips, rotation, roundness, count/scatter, jitter, path falloff, flow, multi-tile traversal, and color/opacity output. The accepted difference is at most one byte per output channel; qualified GPU cases pass in Debug. The prior embedded/None mismatch reached 21 output levels and is why that combination remains CPU-routed.

The direct renderer matrix was rerun in Debug and Release after the kernel changes: generated Bristles, generated round and a custom mask across all three filters and both accumulation modes had zero density/cap error and zero converted-byte differences. Production-stroke comparisons passed in Debug and Release for qualified combinations, including variable pressure opacity, taper replay and two deterministic seeds. Release `BrushIntersectionTests` passed all 8 integration cases; the latest Debug run passed 9 tests, including a legacy-default assertion that default settings do not opt into Metal stamps. The suite includes sparse (two pointer events) and dense (approximately 95 events) Bristles input on a multi-tile stroke, each compared against forced CPU within one byte per output channel. A transformed, rotated/flipped layer-mask stroke clipped by an elliptical selection also matches CPU at the published tile-patch level within one byte; commit, exported image, undo, redo, save and reopen outputs were verified, with reopened and redone exports byte-identical to the committed export. Preview-bitmap comparison is intentionally omitted because it adds a second transform/resampling pass unrelated to the stored tile output.

End-to-end benchmark: 40 pointer samples across a 1024×512 blank layer; 72 px generated Bristles, four stamps per placement, zero spacing, flow 0.65 and Improved filtering. Debug CPU was 5.82 s total / 148.6 ms median / 152.3 ms p95 / 197.7 ms max; Metal was 4.18 s / 94.1 ms / 185.7 ms / 192.9 ms. Release CPU was 5.59 s / 142.7 ms / 144.5 ms / 191.2 ms; Metal was 2.90 s / 67.0 ms / 129.4 ms / 135.4 ms. These are synchronous `append` wall times and include GPU wait, tile buffer setup/readback, and publication. They show lower total and median time, but Metal's Debug p95 is worse than CPU and both configurations remain far above 16.7 ms. Do not interpret these results as meeting the interactive latency target.

Wide/high-count stress benchmark: 40 pointer samples across a 1536×1024 layer; 96 px generated Bristles, 12 stamps per placement, zero spacing, flow 0.65, scatter 0.3, and Improved filtering. Debug CPU was 42.56 s total / 1,070.3 ms median / 1,179.8 ms p95 / 1,271.0 ms max; Metal was 17.08 s / 391.6 ms / 690.8 ms / 716.6 ms. This is a 60% total-time reduction and 41% p95 reduction. Release CPU was 41.20 s / 1,032.2 ms median / 1,145.5 ms p95 / 1,250.0 ms max; Metal was 12.20 s / 272.9 ms / 501.1 ms / 531.8 ms, a 70% total-time reduction and 56% p95 reduction. Both Metal p95 results remain far above 16.7 ms (about 41× Debug and 30× Release); these are real relative gains, not an interactive-latency pass. Reproduce with `TEST_RUNNER_BRUSH_BENCHMARK=1 TEST_RUNNER_BRUSH_BENCHMARK_CASE=stamp-metal-stress xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' -parallel-testing-enabled NO test -only-testing:CompositorTests/BrushPerformanceTests` (add `-configuration Release CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES` for the optimized local test build). Logs: `/tmp/compositor-stamp-stress-debug.log` and `/tmp/compositor-stamp-stress-release.log`.

The Metal route dispatches only the union of already-computed dirty pixel bounds inside touched tiles. Each tile's full density/cap arrays are still passed through shared Metal buffers and copied back after synchronous command completion. No peak-memory measurement or after-change Instruments Allocations/GPU trace has been captured for this route. Transformed-selection/undo/export/reopen parity is now covered above; real Metal command-buffer failure injection, unsupported-device diagnostic behavior, production-route memory attribution, and physical-device acceptance remain outstanding. Debug and Release focused logs: `/tmp/compositor-brush-stamp-debug-final.log`, `/tmp/compositor-brush-stamp-stroke-benchmark-debug.log`, `/tmp/compositor-brush-stamp-stroke-benchmark-release.log`.

## Active continuous brush GPU presentation

The active continuous-brush path now emits an immutable shared R8 coverage texture for each touched tile version alongside its mutable compute buffers. For supported simple paint and erase strokes, `BrushStroke.completeContinuousRender` retains those textures without reading coverage into CPU memory. The existing `GPUCanvasRenderer` samples them through Core Image, composes them over the original tile pixels, and writes into the stroke's persistent canvas texture. The shared canvas still applies layer order, layer transforms, viewport scaling, and layer masks. Mask painting, selection clipping, clone, healing, and active round-rendering effects continue through the established CPU publication fallback; direct mask presentation was excluded after the mask-alone parity regression exposed different behavior.

`GPUCanvasTests.continuousBrushCoverageStaysGPUResidentForLiveCanvas` and `continuousBrushGPUCoverageMatchesOpaqueLayerErase` compare live GPU frames with Core Graphics output. The first asserts zero coverage readback bytes before a CPU consumer requests patches, then confirms no CPU patch staging upload was needed for GPU presentation. Its transformed 136×100 tile is 13,600 bytes: the former live path would read back 13,600 coverage bytes and upload a 54,400-byte RGBA staging image per published tile version. The direct route instead retains a 13,600-byte R8 snapshot and performs zero CPU coverage readback and zero CPU patch staging upload on that update. A later CPU consumer or mouse-up still materializes the snapshot. `continuousBrushGPUCoverageMatchesMaskPainting` verifies the fallback. `GPUCanvasTests` and `BrushTests` passed together: 51 tests total, including pending mouse-up/save/export, next-stroke cancellation, close while pending, and texture cache release. `BrushIntersectionTests` and `LargeCanvasBrushTests` then passed 11 additional tests. `BrushDynamicsTests` passed 36/38; its two failures are the preset required-value and selected-mask alpha expectation failures already present in prior benchmark notes. These are parity and transfer-path checks; no Instruments timing, peak-memory, or input-to-photon measurement has been captured for this change. The immutable coverage allocation is one byte per touched tile pixel for the latest tile versions; a fresh version is allocated on each completed render, while replaced versions become releasable after any queued canvas work finishes.

### 4K interactive follow-up — November 2, 2026

The existing `fourKInteractiveStroke` NSWindow harness was rerun after the GPU-resident change in isolated Debug and Release DerivedData. Each frame interval includes `continueBrush`, `synchronizeDisplay`, and `displayIfNeeded`; asynchronous command completion and actual screen presentation/vsync are outside that interval.

| Brush/layer | Build | Frame median | Frame p95 | Frame max | Mouse-up, two passes |
| --- | --- | ---: | ---: | ---: | ---: |
| 40 px, blank | Debug | 0.035 ms | 0.126 ms | 0.220 ms | 18.4 / 17.9 ms |
| 40 px, opaque | Debug | 0.036 ms | 0.445 ms | 0.716 ms | 16.1 / 17.5 ms |
| 800 px, blank | Debug | 0.053 ms | 0.514 ms | 2.122 ms | 82.6 / 76.7 ms |
| 800 px, opaque | Debug | 0.054 ms | 1.385 ms | 1.810 ms | 73.6 / 74.2 ms |
| 40 px, blank | Release | 0.010 ms | 0.096 ms | 0.123 ms | 18.7 / 16.6 ms |
| 40 px, opaque | Release | 0.011 ms | 0.433 ms | 0.705 ms | 15.7 / 15.0 ms |
| 800 px, blank | Release | 0.014 ms | 0.339 ms | 0.437 ms | 71.1 / 71.0 ms |
| 800 px, opaque | Release | 0.015 ms | 1.415 ms | 1.782 ms | 67.0 / 65.3 ms |

Compared with the prior async-only results immediately above, frame p95 declined 16–47% in Debug and 1–52% in Release across these cases. This supports a reduction in synchronous input/display-call work; it does not measure input-to-photon latency. Mouse-up remains synchronous and reaches 65–83 ms for 800 px tips. This harness reports frame-call wall time rather than Instruments blocked intervals, and does not confirm the GPU command's screen presentation deadline. Logs and reproducible invocations: `/tmp/compositor-gpu-resident-interactive-debug.log` and `/tmp/compositor-gpu-resident-interactive-release.log`; `TEST_RUNNER_BRUSH_BENCHMARK=1 TEST_RUNNER_BRUSH_BENCHMARK_CASE=interactive xcodebuild -project Compositor.xcodeproj -scheme Compositor -configuration {Debug|Release} -derivedDataPath /tmp/CompositorGPUResident{Debug|Release} -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO -parallel-testing-enabled NO -only-testing:CompositorTests/BrushPerformanceTests test` (Release also used `ENABLE_TESTABILITY=YES`).

### Metal grain checkpoint — November 2, 2026

The production tile-local stamp renderer handles primary grain for eligible single-tip Standard and no-pickup Light/Uniform/Intense/Heavy Glaze strokes with Classic bilinear and Improved four-sample grain filtering. Direct dab comparisons cover all five modes, and Moving/Texturized stroke comparisons passed against the CPU renderer; Texturized caps are included. Wet-tip sampling and burnt-edge accumulation are now included in the ordered Metal pass for eligible no-pickup single-tip strokes, with direct reference comparisons and end-to-end tile-crossing/tail-replay coverage. Nearest grain filtering remains explicitly CPU-only after its discontinuous texture lookup showed a sparse precision mismatch. Blending/pickup, dual tips, stroke/edge blend operators, luminance, and threshold still use CPU rasterization. Backruns is a new Rendering-tab setting applied in the final CPU pixel pass; a grainy Bristles test confirms the seeded static effect and CPU/Metal output within two channel levels. This final pass is not part of the Metal speedup measurement.

Added matched `textured-standard-800-opaque` GPU and `textured-standard-800-opaque-cpu` rows to the 4K matrix, with raw 64 MB layer-byte dumps for CPU/Metal comparison. On the Apple M1 Mac mini (16 GB), with Debug and Release testable app builds, 4K canvas, 800 px grain brush, opaque layer, 12 updates, 20 touched tiles, three runs per path:

| Build | Path | Median update (median of 3 run medians) | p95 (median of run p95s) | Mouse-up (median of 3) |
| --- | --- | ---: | ---: | ---: |
| Debug | CPU | 24.72 ms | 29.26 ms | 126.56 ms |
| Debug | Metal | 14.68 ms | 22.05 ms | 111.92 ms |
| Release | CPU | 24.73 ms | 27.73 ms | 109.84 ms |
| Release | Metal | 13.30 ms | 23.28 ms | 121.78 ms |

The median update cost fell about 41% in Debug and 46% in Release for this grain-only workload. This is a repeatable median improvement over three short runs, while p95 varies because the 12-sample nearest-rank p95 is the maximum update in each run. Mouse-up has no consistent improvement. Metal's measured command submission-through-completion summed to 88.3 ms in the median Debug run and 74.9 ms in the median Release run; this is not GPU kernel duration. The renderer copied 117,440,512 bytes of density/cap buffers back across each stroke (calculated from full readback arrays), which remains substantial. CPU and Metal output buffers are 64,000,000 bytes each; four bytes differ, with maximum channel delta one, in both builds. Raw output: `/tmp/compositor-textured-standard-800-opaque.rgba` and `/tmp/compositor-textured-standard-800-opaque-cpu.rgba` (files are from the latest Release comparison).

The separate documented `textured-blending-800-opaque` CPU-only case (grain, Intense Blending, wet/burnt edges) measured 113.53 ms median / 133.55 ms p95 / 204.16 ms mouse-up in Debug and 98.11 / 105.34 / 170.88 ms in Release. It does not use the grain GPU path because pickup/blending remains unsupported there. Benchmark update wall time covers synchronous `continueBrush`, canvas synchronization and `displayIfNeeded`; it is not input-to-photon latency. Instruments GPU/presentation timing, peak allocation, and device qualification remain unmeasured. Result bundles: `/tmp/CompositorGrainDebug-gpu-bytes.xcresult`, `/tmp/CompositorGrainDebug-cpu-bytes.xcresult`, `/tmp/CompositorGrainDebug-gpu-third.xcresult`, `/tmp/CompositorGrainDebug-cpu-third.xcresult`, `/tmp/CompositorGrainRelease-gpu.xcresult`, `/tmp/CompositorGrainRelease-cpu.xcresult`, `/tmp/CompositorGrainRelease-gpu-third.xcresult`, `/tmp/CompositorGrainRelease-cpu-third.xcresult`, `/tmp/CompositorGrainDebug-intense.xcresult`, and `/tmp/CompositorGrainRelease-intense.xcresult`.

The focused Debug `BrushDynamicsTests` result reports 37 passed and the two known baseline failures (`presetsRoundTripAndRejectInvalidDynamicsAtomically` and `transformedTipsAndSelectedMasksPreservePixelsUndoAndReopen`); the added `gpuGlazeModesMatchCpuForGrainedStrokes` passed. `BrushPerformanceTests` result trees report all eight cases passed, including grain direct-dab parity and nearest-grain CPU fallback. This confirms the Swift Testing suites ran; the XCTest console's “Executed 0 tests” line does not include their Swift Testing case count.

### Stamp scratch-buffer reuse checkpoint — November 2, 2026

`MetalStampRenderer` now serializes its synchronous stamp submissions and reuses per-instance shared buffers for density, cap, optional burnt-edge state, and packed dab records. The existing decoded tip/grain buffer cache remains content-hash keyed and limited to 16 entries. Packed dab uploads up to 1 MiB reuse the retained buffer; larger uploads are one-shot, so a rare large placement does not permanently increase pooled memory. Tile dimensions remain capped at 256 × 256, making the three pixel-state buffers at most 768 KiB total; together with the 1 MiB dab cap, retained scratch stays below 2 MiB. No renderer scratch is reused until its command has completed.

`BrushPerformanceTests.metalStampRendererReusesBoundedScratchBuffers` checks same-size allocation reuse, lazy edge-buffer allocation, a maximum-size tile, and oversized one-shot dab uploads. The full focused `BrushPerformanceTests` suite passed 10/10 in Debug at `/Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/Logs/Test/Test-Compositor-2026.11.02_13-22-59-+0200.xcresult`. This test proves retained allocation bounds and reuse, not a measured reduction in frame time or Instruments allocation volume. Per-event placement is still synchronous for stamp-dynamic brushes; display-cadenced input batching has not been implemented.

`BrushStroke.append(batch:)` accepts up to 4096 ordered samples and publishes changed tiles once per batch on the CPU/stamp path; continuous GPU keeps its existing serialized/coalesced submission path. `orderedBrushInputBatchesMatchIndividualSamples` exercises pressure-only movement at a repeated point, tilt, rotation, tile crossing, wet/burnt edges, and CPU/Metal raster equivalence against one-sample appends. At this checkpoint canvas delivery and pending-input lifecycle had not yet been wired; the following checkpoint records that integration.

### Display-paced input batching checkpoint — November 2, 2026

`EditorCanvas` now queues processed brush samples to a view-bound AppKit display link and applies them to `BrushStroke` in order once per refresh, then synchronizes the canvas once. `EditorSession` retains the bounded 4096-sample pending buffer, so other commit paths flush it too; mouse-up finalizes after the pending batch, cancel discards it, detaching the canvas flushes it, and capacity pressure flushes a full batch before accepting more input. No input sample is dropped. The existing pressure filtering, stabilization, smoothing, event timestamps, tilt/rotation, device gate and warp path remain on their prior session processing path. The view-bound link stays active through contiguous input and invalidates after an idle refresh.

`sessionFrameBatchPreservesInputFilteringAndPixels` compares session output between individual and queued input with pressure, smoothing, stabilization, stationary pressure/orientation change, timestamp ordering and mouse-up commit. `queuedSessionInputIsBoundedAndCancelDropsOnlyPendingTail` drives beyond the cap, verifies a full ordered batch is flushed and cancel releases the remaining sample. This verifies output and lifecycle logic; actual input-to-display latency, allocation volume and live tablet acceptance are still unmeasured. `BrushDynamicsTests` ran 44 cases: 42 passed, including these two cases and ordered CPU/Metal batch parity; the only failures were the two previously recorded baseline cases. Result bundle: `/Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/Logs/Test/Test-Compositor-2026.11.02_14-39-11-+0200.xcresult`.

The brush display tick now takes a fast path through the existing dirty-tile invalidation: it reuses the previous layer display state, requests redraw for `dirtyDocumentRect`, and skips rebuilding the full layer hierarchy while document, viewport, render bounds, overlay geometry and related display state remain stable. Any mismatch falls back to full synchronization. Drawing the dirty canvas region still composites the visible layers that overlap it; no unchanged-layer compositing cache has been added. `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' build` passed after this change. UI-level redraw-area, CPU-time, allocation and live interaction measurements remain open.

### GPU tile and snapshot lifetime audit — November 2, 2026

The existing `GPUCanvasRenderer` already caches raster textures by source identity and mip level, retains recently used entries for up to 90 frames, drops unused entries after three idle seconds, and responds to memory pressure. Its active-stroke composite is one persistent texture updated from changed coverage tiles or CPU patches; cancellation removes that stroke entry. `GPUCanvasTests.continuousBrushCoverageStaysGPUResidentForLiveCanvas` checks live GPU coverage presentation, zero readback and CPU patch uploads before a CPU consumer requests pixels, and cancellation cleanup. `zoomedOutKeepsOnlyTheReductions` exercises reduced-level cache lifetime.

The continuous renderer's coverage buffers are intentionally stroke-local. `MetalBrushCoverage.snapshotTextures(for:)` allocates a new shared R8 texture for each tile snapshot; the command completion closure retains snapshots and source buffers through GPU completion, then publishes them to the canvas. This prevents safe immediate reuse of a replaced snapshot. A cross-stroke snapshot/staging pool needs a completion-safe reuse mechanism and measured benefit; this audit does not add one. The task's broad cache-reuse goal is therefore already covered for raster and active-stroke composite textures, while transient snapshot reuse and allocation/RSS measurement remain open. The ordinary focused Debug `BrushPerformanceTests` suite passed 10/10 at `/Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/Logs/Test/Test-Compositor-2026.11.02_14-58-40-+0200.xcresult`; this is functional coverage and not a live cadence or allocation benchmark.

The cadence follow-up extends `sessionFrameBatchPreservesInputFilteringAndPixels` to compare 1, 4, 12, and 48 samples per flush with speed-based spacing active and identical pressure, timestamps, smoothing, stabilization, tilt and rotation. The Debug `BrushDynamicsTests` run passed this case and 41 others; only the two already known baseline cases failed (preset required value and selected-mask alpha expectation). Result: `/Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/Logs/Test/Test-Compositor-2026.11.02_15-05-17-+0200.xcresult`.

The focused Debug `BrushTests` and `GPUCanvasTests` suites passed 51/51 at `/Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/Logs/Test/Test-Compositor-2026.11.02_15-07-19-+0200.xcresult`. Relevant cases cover cancellation isolation, an injected GPU error callback, session deallocation while GPU work is pending, mouse-up/save/export flush, active GPU coverage residency, and reduction-cache retention. The error case invokes the callback directly; it does not exercise a real Metal command-buffer failure.

`queuedBrushSamplesBlockToolAndProjectTransitionsUntilMouseUp` now verifies that queued input keeps tool changes and `ProjectController` operations gated, preserves all eight pending samples, and commits them at mouse-up before those operations become available. The Debug `BrushDynamicsTests` result reports 43 passed and the same two baseline failures; the new transition test passed. Result: `/Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/Logs/Test/Test-Compositor-2026.11.02_15-25-41-+0200.xcresult`. Real Metal command-buffer failure injection remains open.

### Matched Bristles batching benchmark — November 2, 2026

The matrix now compares 48 synthetic 240 Hz samples on a 4000×4000 canvas with an 800 px generated Bristles head at zero spacing. The single-event case synchronizes and presents after each sample; the grouped case queues four samples then synchronizes/presents once. Both produce the same final pixel digest (`0b8abed88018c3703e1c1852a389030861a2402f5711cf9307962c6f7b2e9276`). This `.none` configuration uses the CPU stamp path; `metalCompletion=0` and readback bytes are zero.

| Build | Samples per presentation | Median presentation work | p95 | Max | Mouse-up wait | Tile publications |
|---|---:|---:|---:|---:|---:|---:|
| Debug | 1 | 493 ms | 642 ms | 794 ms | 266 ms | 50 |
| Debug | 4 | 1,957 ms per group (489 ms per input, normalized) | 2,616 ms per group* | 2,616 ms per group | 268 ms | 14 |
| Release | 1 | 481 ms | 628 ms | 775 ms | 258 ms | 50 |
| Release | 4 | 1,888 ms per group (472 ms per input, normalized) | 2,501 ms per group* | 2,501 ms per group | 260 ms | 14 |

Grouping reduced tile publications by 72%, while normalized median work per input changed by under 2% in both builds. A four-input group takes about 1.9 seconds at the median in this deliberately heavy case, so batching reduces publication churn but does not remove the CPU rendering bottleneck or make this workload interactive. The grouped case has only 12 presentation intervals; its nearest-rank p95 is therefore its maximum and should not be compared directly with the 48-event p95. These timings include session processing, flush, canvas synchronization and `displayIfNeeded`; they are not tablet input-to-photon latency. Allocation volume, RSS, live cadence and Instruments presentation timing remain unmeasured.

Debug result bundles: `/Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/Logs/Test/Test-Compositor-2026.11.02_15-28-29-+0200.xcresult` and `/Users/sorin.jurcut/Library/Developer/Xcode/DerivedData/Compositor-clhoszwjpthxcobpsohkkcrysqkn/Logs/Test/Test-Compositor-2026.11.02_15-30-10-+0200.xcresult`. Release result bundles: `/tmp/CompositorBrushBatchRelease/Logs/Test/Test-Compositor-2026.11.02_15-33-48-+0200.xcresult` and `/tmp/CompositorBrushBatchRelease/Logs/Test/Test-Compositor-2026.11.02_15-38-53-+0200.xcresult`. Release required local test-only `CODE_SIGNING_ALLOWED=NO` and `ENABLE_TESTABILITY=YES` overrides because no development signing certificate is installed and the test bundle uses `@testable import`.

### Settled watercolor edge and preset check — November 2, 2026

The bundled Watercolor Wash is tuned toward the prototype's settled straight-line exercise: flow 0.8, wet edges 0.32, burnt edges 1.0, backruns 0.24, hardness 0.52, and shallower/larger-scale native grain (depth 0.34, scale 36). A fixed-seed 512×512 output test paints the preset, a no-burnt-edge control, and a no-flow control against white paper and records the PNGs. Debug `BrushLibraryTests` passed 9/9; the edge changed 6,512 channel values by more than eight levels (maximum delta 36), and the new flow pass changed 4,188 channels. The side-by-side image from the prior preset is `/tmp/Watercolor-Prototype-Comparison-Final.png`; the final flow/edge output is attached to `/tmp/WatercolorFlowPresetVisible.xcresult`. The final result has a visible pale fringe, while remaining broader and more regularly grained than the prototype; preset values cannot reproduce its deformed silhouette or clear-water rewet.

The separate stress case uses 40 points on a 1024×512 layer with a 72 px, four-stamp-per-dab Bristles head at zero spacing; these are not preset-specific interaction timings. CPU totals are process CPU time for appends and mouse-up; edge time is the measured final edge pass. Release without/with full burnt edges: append CPU 358/683 ms, append wall p95 194/201 ms, mouse-up CPU 14/96 ms, mouse-up wall 192/275 ms, edge pass 0/72 ms. Debug without/with edges: append CPU 1,828/2,086 ms, append wall p95 259/255 ms, mouse-up CPU 74/395 ms, mouse-up wall 247/580 ms, edge pass 0/316 ms. Individual append wall maxima exceeded 200 ms in both modes; these results show that the deferred edge pass adds substantial mouse-up work, but do not represent display latency or an Instruments GPU/presentation trace. Debug and Release benchmark suites passed. Result bundles: `/tmp/WatercolorDebugFinal.xcresult` and `/tmp/WatercolorReleaseFinal.xcresult`.
