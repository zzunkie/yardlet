#!/usr/bin/env python3
import argparse
import json
import os
import signal
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse


def browser_binary():
    candidates = [
        shutil.which("chromium"),
        shutil.which("chromium-browser"),
        shutil.which("google-chrome"),
        shutil.which("google-chrome-stable"),
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError("no headless Chromium executable is available")


def process_identity(pid):
    completed = subprocess.run(
        ["ps", "-o", "lstart=", "-p", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return ""
    return " ".join(completed.stdout.split())


def wait_for_identity(pid):
    for _ in range(50):
        identity = process_identity(pid)
        if identity:
            return identity
        time.sleep(0.01)
    raise RuntimeError(f"browser pid {pid} never exposed a process identity")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("screenshot")
    parser.add_argument("metadata")
    args = parser.parse_args()

    parsed = urlparse(args.url)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise RuntimeError("browser fixture accepts localhost HTTP URLs only")

    screenshot = Path(args.screenshot).resolve()
    metadata = Path(args.metadata).resolve()
    screenshot.parent.mkdir(parents=True, exist_ok=True)
    metadata.parent.mkdir(parents=True, exist_ok=True)
    profile = tempfile.mkdtemp(prefix="yardlet-local-browser-")
    executable = browser_binary()
    version = subprocess.run(
        [executable, "--version"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    stderr_path = metadata.with_suffix(".stderr.log")
    command = [
        executable,
        "--headless",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-default-apps",
        "--disable-extensions",
        "--disable-gpu",
        "--disable-sync",
        "--metrics-recording-only",
        "--mute-audio",
        "--no-first-run",
        "--no-proxy-server",
        "--no-sandbox",
        f"--user-data-dir={profile}",
        "--window-size=960,720",
        "--timeout=10000",
        f"--screenshot={screenshot}",
        args.url,
    ]
    with stderr_path.open("wb") as stderr_log:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=stderr_log,
            start_new_session=True,
        )
        identity = wait_for_identity(process.pid)
        try:
            deadline = time.monotonic() + 60
            payload = b""
            while time.monotonic() < deadline:
                if screenshot.is_file():
                    payload = screenshot.read_bytes()
                    if payload.startswith(b"\x89PNG\r\n\x1a\n") and payload.endswith(
                        b"\x00\x00\x00\x00IEND\xaeB\x60\x82"
                    ):
                        break
                if process.poll() is not None:
                    raise RuntimeError(
                        f"headless Chromium exited with {process.returncode} before screenshot completion"
                    )
                time.sleep(0.05)
            else:
                raise RuntimeError("headless Chromium screenshot timed out")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            shutil.rmtree(profile, ignore_errors=True)

    metadata.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "pid": process.pid,
                "start_identity": identity,
                "exit_code": process.returncode,
                "url": args.url,
                "browser": executable,
                "browser_version": (version.stdout or version.stderr).strip(),
            },
            indent=2,
        )
        + "\n"
    )
    if not payload.startswith(b"\x89PNG\r\n\x1a\n") or len(payload) <= 1000:
        raise RuntimeError("headless Chromium did not retain a valid rendered PNG")


if __name__ == "__main__":
    main()
