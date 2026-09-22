#!/usr/bin/env python3
"""Run the project's Swift Testing target using macOS Command Line Tools.

The default run covers Darkroom (Render Finish) and the existing pixel filters.
Use --all for the complete suite, or --suite REGEX to choose tests. A real Sparkle
framework is required; an existing local app build is detected automatically.
No dependencies are downloaded. Xcode's hosted test target remains authoritative
for UI behaviour that relies on the full application lifecycle.

Examples:
    python3 scripts/test-swift.py
    python3 scripts/test-swift.py --all
    python3 scripts/test-swift.py --build-only --sparkle-framework /path/Sparkle.framework
    python3 scripts/test-swift.py --run-only --suite 'RenderFinishTests'

The runner uses Swift Testing's tool integration API, which may need updating when
the toolchain changes. Build logs, a source snapshot/hash, test output and xUnit
results are retained under build/qa/swift-tests by default. Tests need normal macOS
access to Metal, WindowServer, the pasteboard and temporary project directories.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import threading
import time


ROOT = Path(__file__).resolve().parent.parent


def command_output(*args):
    return subprocess.check_output(args, text=True).strip()


def build_step(args, log_path):
    started = time.monotonic()
    with log_path.open("w") as log:
        result = subprocess.run([str(arg) for arg in args], stdout=log, stderr=subprocess.STDOUT)
    elapsed = time.monotonic() - started
    print(f"{log_path.stem}: {elapsed:.1f}s (exit {result.returncode})", flush=True)
    if result.returncode:
        print(log_path.read_text()[-12000:], file=sys.stderr)
        raise SystemExit(result.returncode)
    return elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--all", action="store_true", help="Run all CompositorTests")
    selection.add_argument("--suite", "--filter", action="append", help="Swift Testing regex; repeat to combine filters")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--build-only", action="store_true")
    mode.add_argument("--run-only", action="store_true", help="Use the retained source snapshot/binary")
    parser.add_argument("--list", action="store_true", help="List tests instead of running")
    parser.add_argument("--skip", action="append", default=[], help="Explicit test regex to omit")
    parser.add_argument("--timeout", type=float, default=600, help="Maximum test runtime in seconds (default: 600)")
    parser.add_argument("--sdk", type=Path, help="macOS SDK (defaults to the project's deployment version)")
    parser.add_argument("--sparkle-framework", type=Path, help="Existing Sparkle.framework directory")
    parser.add_argument("--source-root", type=Path, default=ROOT, help="Checkout to snapshot (for baseline comparisons)")
    parser.add_argument("--output", type=Path, default=ROOT / "build/qa/swift-tests")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    source_root = args.source_root.resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    contents = out / "CompositorTests.app/Contents"
    executable = contents / "MacOS/CompositorTests"
    executable.parent.mkdir(parents=True, exist_ok=True)
    timings = {}

    if not args.run_only:
        executable.unlink(missing_ok=True)
        (out / "build-manifest.json").unlink(missing_ok=True)
        developer = Path(command_output("xcode-select", "-p"))
        swiftc = Path(command_output("xcrun", "--find", "swiftc"))
        toolchain = swiftc.parent.parent
        clang = command_output("xcrun", "--find", "clang")
        project = (source_root / "Compositor.xcodeproj/project.pbxproj").read_text()
        deployment = re.search(r"MACOSX_DEPLOYMENT_TARGET = ([\d.]+);", project).group(1)
        sdk = args.sdk
        if sdk is None:
            sdk_candidates = [developer / "SDKs" / f"MacOSX{deployment}.sdk",
                developer / "Platforms/MacOSX.platform/Developer/SDKs" / f"MacOSX{deployment}.sdk"]
            sdk = next((path for path in sdk_candidates if path.exists()),
                       Path(command_output("xcrun", "--sdk", "macosx", "--show-sdk-path")))
        sdk = sdk.resolve()
        framework = args.sparkle_framework
        if framework is None:
            framework = next(iter(sorted(ROOT.glob("build/*.app/Contents/Frameworks/Sparkle.framework"))), None)
        if framework is None or not framework.is_dir():
            parser.error("Pass --sparkle-framework /path/to/Sparkle.framework, or build the app first.")
        framework = framework.resolve()
        test_framework_roots = [developer / "Library/Developer/Frameworks",
            developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"]
        testing = next((path for path in test_framework_roots if (path / "Testing.framework").exists()), None)
        if testing is None:
            parser.error("The selected developer directory does not contain Testing.framework.")
        plugins = toolchain / "lib/swift/host/plugins/testing"
        if not plugins.is_dir():
            parser.error(f"Swift Testing macros were not found at {plugins}")

        # Compile an immutable snapshot so edits in another terminal cannot mix
        # source revisions or cause 'input file modified during the build'.
        snapshot = out / "sources"
        for directory in ["Compositor", "CompositorTests"]:
            destination = snapshot / directory
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(source_root / directory, destination)
        runner = snapshot / "Runner.swift"
        shutil.copy2(ROOT / "scripts/tests/swift_test_main.swift", runner)
        sources = sorted((snapshot / "Compositor").rglob("*.swift"))
        sources = [path for path in sources if path.name != "CompositorApp.swift"]
        tests = sorted((snapshot / "CompositorTests").glob("*.swift"))
        digest = hashlib.sha256()
        for path in sorted(snapshot.rglob("*")):
            if path.is_file():
                digest.update(str(path.relative_to(snapshot)).encode())
                digest.update(path.read_bytes())

        common = ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macos{deployment}",
            "-swift-version", "5", "-default-isolation", "MainActor", "-Onone", "-g",
            "-whole-module-optimization",
            "-module-cache-path", out / "module-cache"]
        for feature in ["MemberImportVisibility", "NonisolatedNonsendingByDefault",
                        "InferIsolatedConformances", "DisableOutwardActorInference",
                        "GlobalActorIsolatedTypesUsability"]:
            common += ["-enable-upcoming-feature", feature]
        objects = []
        for source in sorted((snapshot / "Compositor").rglob("*.c")):
            obj = out / f"{source.stem}.o"
            build_step([clang, "-O2", "-isysroot", sdk, f"-mmacosx-version-min={deployment}",
                "-c", source, "-o", obj], out / f"c-{source.stem}.log")
            objects.append(obj)
        timings["module_seconds"] = build_step([swiftc, "-emit-library", "-static", "-parse-as-library",
            "-enable-testing", "-module-name", "Compositor", "-F", framework.parent,
            "-import-objc-header", snapshot / "Compositor/Compositor-Bridging-Header.h",
            "-emit-module-path", out / "Compositor.swiftmodule", "-o", out / "libCompositor.a",
            *common, *sources], out / "module-build.log")
        timings["tests_compile_seconds"] = build_step([swiftc, "-parse-as-library", "-module-name", "CompositorTests",
            "-I", out, "-L", out, "-lCompositor", "-F", framework.parent, "-framework", "Sparkle",
            "-F", testing, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", testing,
            "-Xlinker", "-rpath", "-Xlinker", testing.parent / "usr/lib",
            "-Xlinker", "-rpath", "-Xlinker", framework.parent, "-plugin-path", plugins,
            "-o", executable, *common, runner, *tests, *objects], out / "tests-build.log")
        # A dedicated bundle identifier keeps UserDefaults.standard separate
        # from both the real editor and other command-line executables.
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.compositor.swift-tests",
            "CFBundleName": "Compositor Tests", "CFBundleExecutable": "CompositorTests",
            "CFBundlePackageType": "APPL", "LSUIElement": True}))
        manifest = {"source_sha256": digest.hexdigest(), "source_root": str(source_root), "sdk": str(sdk), "swiftc": str(swiftc),
            "sparkle_framework": str(framework), "deployment_target": deployment,
            "test_file_count": len(tests), "timings": timings}
        (out / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Source snapshot: {digest.hexdigest()[:16]}", flush=True)

    if args.build_only:
        return 0
    if not executable.exists():
        parser.error("No compiled test runner found; run without --run-only first.")
    options = {"parallel": False, "listTests": args.list, "skip": args.skip,
               "xunitOutput": str(out / "results.xml")}
    if not args.all:
        options["filter"] = args.suite or ["RenderFinishTests|RenderComparisonTests|FilterTests"]
    options_path = out / "test-options.json"
    options_path.write_text(json.dumps(options) + "\n")
    env = os.environ.copy()
    developer = Path(command_output("xcode-select", "-p"))
    runtime_roots = [developer / "Library/Developer/usr/lib",
                     developer / "Platforms/MacOSX.platform/Developer/usr/lib"]
    runtime = next((path for path in runtime_roots if (path / "lib_TestingInterop.dylib").exists()), None)
    if runtime:
        env["DYLD_LIBRARY_PATH"] = str(runtime) + (":" + env["DYLD_LIBRARY_PATH"] if env.get("DYLD_LIBRARY_PATH") else "")
    # ToolDefaults uses this marker to avoid changing the user's editor settings.
    env["XCTestConfigurationFilePath"] = str(options_path)
    env["COMPOSITOR_SWIFT_TEST_OPTIONS"] = str(options_path)
    started = time.monotonic()
    with (out / "test-results.log").open("w") as log:
        process = subprocess.Popen([str(executable)], env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, bufsize=1)
        timed_out = threading.Event()
        def stop_after_timeout():
            if process.poll() is None:
                timed_out.set()
                print(f"Test runner exceeded {args.timeout:g}s; terminating it.", file=sys.stderr, flush=True)
                process.terminate()
        timer = threading.Timer(args.timeout, stop_after_timeout)
        timer.start()
        try:
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
            status = process.wait()
        finally:
            timer.cancel()
        if timed_out.is_set():
            status = 124
    elapsed = time.monotonic() - started
    (out / "run-summary.json").write_text(json.dumps({"exit_code": status, "seconds": elapsed,
        "options": options, "source_build": str(out / "build-manifest.json")}, indent=2) + "\n")
    print(f"Test execution: {elapsed:.1f}s; results: {out / 'test-results.log'}", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
