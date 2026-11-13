#!/usr/bin/env python3
"""Verify a normal LaunchServices launch of the installed app, including pixels."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUTPUT = pathlib.Path(os.environ.get("VIRTUAL_CANVAS_BUILD_DIR", ROOT / "build/virtual-display-canvas"))
BUNDLE = pathlib.Path(sys.argv[1] if len(sys.argv) == 2 else
                      pathlib.Path.home() / "Applications/Sunlight Canvas Lab.app").resolve()
TEMP = pathlib.Path(tempfile.gettempdir())


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else None


def wait_for(predicate, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError(message)


def main():
    if not BUNDLE.is_dir():
        raise RuntimeError(f"App does not exist: {BUNDLE}")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    previous = set(TEMP.glob("sunlight-canvas-launch-*"))
    subprocess.run(["/usr/bin/open", "-g", "-n", str(BUNDLE), "--args", "--trial"], check=True)

    def launched():
        for directory in set(TEMP.glob("sunlight-canvas-launch-*")) - previous:
            record = read_json(directory / "launch.json")
            if record and record["trial"] and pathlib.Path(record["app_path"]).resolve() == BUNDLE:
                return record
        return None

    launch = wait_for(launched, 10, "No launch receipt from this app appeared")
    if launch["ppid"] != 1:
        raise RuntimeError("This was not a LaunchServices launch")
    run = pathlib.Path(launch["run"])
    context = {"launch": launch, "run": str(run), "launch_method": "LaunchServices"}
    (OUTPUT / "verified-trial-context.json").write_text(json.dumps(context, indent=2))

    try:
        wait_for(lambda: (run / "captured-bank.png").exists() or (run / "result.json").exists(),
                 15, "No capture or failure report appeared")
        early = read_json(run / "result.json")
        if early:
            raise RuntimeError(f"App stopped before visual verification: {early}")
        for index in range(2):
            if index:
                wait_for(lambda: (run / "camera.json").exists(), 5,
                         "No camera change was recorded")
                time.sleep(0.15)
            subprocess.run([
                "/usr/sbin/screencapture", "-x", "-o", "-l", str(launch["window_id"]),
                str(OUTPUT / f"verified-viewer-{index + 1}.png"),
            ], check=True, capture_output=True, text=True)

        report = wait_for(lambda: read_json(run / "result.json"), 12,
                          "App did not complete capture and cleanup")
        (OUTPUT / "verified-trial.json").write_text(json.dumps(report, indent=2))
        print(json.dumps({"launch": launch, "report": report, "run": str(run)}, indent=2))
        if not report["passed"]:
            raise RuntimeError("Capture/cleanup failed; retain the report")
        # Inspect both PNGs as well. Decoded source pixels alone do not prove
        # that the viewer's crops were visibly presented.
    finally:
        # Ask this exact owned app process to quit through AppKit if it remains
        # alive, so even a verification failure follows the app's cleanup path.
        alive = True
        try:
            os.kill(launch["pid"], 0)
        except ProcessLookupError:
            alive = False
        if alive:
            subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e",
                            'ObjC.import("AppKit"); '
                            f'$.NSRunningApplication.runningApplicationWithProcessIdentifier({launch["pid"]}).terminate'],
                           check=False, capture_output=True, text=True)


if __name__ == "__main__":
    main()
