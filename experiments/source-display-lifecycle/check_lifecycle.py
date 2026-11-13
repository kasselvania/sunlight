#!/usr/bin/env python3
"""Opt-in native lifecycle check: creates two displays, without app windows."""
import hashlib
import json
import pathlib
import select
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "build/sip-redesign/display-lifecycle"
OUT.mkdir(parents=True, exist_ok=True)
PROBE = OUT / "probe"
subprocess.run([
    "xcrun", "clang", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-Werror", "-O2",
    "-mmacosx-version-min=15.0", "-framework", "AppKit", "-framework", "ColorSync",
    "-I", str(ROOT / "Sources/SourceDisplay/include"),
    str(ROOT / "Sources/SourceDisplay/SLSourceDisplay.m"), str(ROOT / "experiments/source-display-lifecycle/main.m"),
    "-o", str(PROBE),
], check=True)


def snapshot():
    # ColorSync can finish an in-flight owner-death notification after Quartz
    # has removed the displays. Bound that read separately from display release.
    return json.loads(subprocess.check_output([str(PROBE), "--snapshot"], text=True, timeout=15))


def cpu_times():
    result = {}
    for line in subprocess.check_output(["ps", "-axo", "pid=,time=,comm="], text=True).splitlines():
        pid, elapsed, path = line.strip().split(maxsplit=2)
        if pathlib.Path(path).name not in {"colorsyncd", "colorsync.displayservices", "colorsync.useragent"}:
            continue
        seconds = 0.0
        for part in elapsed.split(":"):
            seconds = seconds * 60 + float(part)
        result[pid] = seconds
    return result


baseline = snapshot()
receipt = {"baseline": baseline, "runs": [], "probe_sha256": hashlib.sha256(PROBE.read_bytes()).hexdigest()}
identities = None
warmed = None
try:
    for operation in ["normal", "process-death", "normal"]:
        child = None
        run = {"operation": operation}
        receipt["runs"].append(run)
        with (OUT / "native.log").open("a") as log:
            try:
                child = subprocess.Popen([str(PROBE), "--hold"], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=log, text=True)
                assert select.select([child.stdout], [], [], 12)[0], "Display creation did not become ready"
                ready = json.loads(child.stdout.readline())
                run["ready"] = ready
                assert ready.get("state") == "ready", ready
                slots = ready["slots"]
                current = [{k: v for k, v in slot.items() if k != "id"} for slot in slots]
                assert len(slots) == 2 and len({s["uuid"] for s in slots}) == 2
                assert all(s["uuid"] for s in slots)
                if identities is None:
                    identities = current
                assert current == identities, "A restarted bank acquired a different persistent identity"
                busy = subprocess.run([str(PROBE), "--busy"], capture_output=True, text=True, timeout=5)
                assert busy.returncode == 0 and json.loads(busy.stdout) == {"busy": True}, busy.stdout
                run["concurrent_owner_refused"] = True

                start = time.monotonic()
                before_cpu = cpu_times()
                time.sleep(2)
                after_cpu = cpu_times()
                elapsed = time.monotonic() - start
                busy_seconds = sum(max(0, after_cpu[p] - before_cpu[p]) for p in before_cpu.keys() & after_cpu.keys())
                run["colorsync_cpu_cores"] = busy_seconds / elapsed
                assert busy_seconds / elapsed < 0.8, "ColorSync did not settle; stop further display exercises"

                if operation == "process-death":
                    child.kill()
                    child.communicate(timeout=5)
                    assert child.returncode == -9
                else:
                    output, _ = child.communicate("stop\n", timeout=8)
                    stopped = json.loads(output)
                    assert child.returncode == 0 and stopped.get("state") == "stopped", stopped

                deadline = time.monotonic() + 5
                query_start = time.monotonic()
                while True:
                    after = snapshot()
                    if after["online"] == baseline["online"]:
                        break
                    assert time.monotonic() < deadline, "Displays or physical mode did not restore"
                    time.sleep(0.1)
                run["after"] = after
                run["post_release_query_seconds"] = time.monotonic() - query_start
                assert set(after["profile_uuids"]) - set(baseline["profile_uuids"]) <= {s["uuid"] for s in slots}
                assert len(set(after["profile_files"]) - set(baseline["profile_files"])) <= 2
                if warmed is None:
                    warmed = after
                assert after["profile_uuids"] == warmed["profile_uuids"], "ColorSync registrations accumulated"
                assert after["profile_files"] == warmed["profile_files"], "ColorSync profile files accumulated"
                run["passed"] = True
                print("PASS", operation, "same two UUIDs; displays removed; profile set bounded", flush=True)
            finally:
                if child and child.poll() is None:
                    child.terminate()
                    try:
                        child.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.communicate(timeout=3)
    receipt["passed"] = True
finally:
    (OUT / "result.json").write_text(json.dumps(receipt, indent=2))
