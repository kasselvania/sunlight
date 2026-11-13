#!/usr/bin/env python3
"""Run one finite native trial and capture only its own viewer before/after zoom."""
import json
import pathlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "build/virtual-display-canvas"
EXECUTABLE = OUTPUT / "Virtual Display Canvas.app/Contents/MacOS/VirtualDisplayCanvas"


def main():
    started = time.time()
    process = subprocess.Popen(
        [str(EXECUTABLE), "--trial"], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True,
    )
    run = None
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and process.poll() is None:
            candidates = sorted(
                pathlib.Path(tempfile.gettempdir()).glob("sunlight-virtual-canvas-*"),
                key=lambda path: path.stat().st_mtime, reverse=True,
            )
            for candidate in candidates[:2]:
                image, metadata = candidate / "captured-bank.png", candidate / "display.json"
                if image.exists() and image.stat().st_mtime >= started and metadata.exists():
                    context = json.loads(metadata.read_text())
                    if context.get("viewer_pid") == process.pid:
                        run = candidate
                        break
            if run:
                break
            time.sleep(0.05)
        if run is None:
            raise RuntimeError("No captured source image from this trial became available")

        for index in range(2):
            if index:
                deadline = time.monotonic() + 4
                while not (run / "camera.json").exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not (run / "camera.json").exists():
                    raise RuntimeError("The trial did not record its camera change")
                time.sleep(0.15)
            subprocess.run([
                "/usr/sbin/screencapture", "-x", "-o", "-l",
                str(context["viewer_window_id"]),
                str(OUTPUT / f"verified-viewer-{index + 1}.png"),
            ], check=True, capture_output=True, text=True)

        stdout, stderr = process.communicate(timeout=10)
        (OUTPUT / "verified-trial.json").write_text(stdout)
        (OUTPUT / "verified-trial-stderr.txt").write_text(stderr)
        (OUTPUT / "verified-trial-context.json").write_text(json.dumps({
            "run": str(run), "viewer_pid": process.pid,
            "viewer_window_id": context["viewer_window_id"],
        }, indent=2))
        report = json.loads(stdout)
        print(json.dumps({"exit_code": process.returncode, "report": report, "run": str(run)}, indent=2))
        if process.returncode or not report["passed"]:
            raise RuntimeError("Capture/cleanup trial failed; retain the report")
        # The PNGs must still be inspected. An accepted capture frame does not
        # establish that a correctly cropped image was displayed by the viewer.
    finally:
        if process.poll() is None:
            try:
                process.communicate(timeout=12)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=3)


if __name__ == "__main__":
    main()
