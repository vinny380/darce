#!/usr/bin/env python3
"""Own native smoke processes directly, including restart and fixture lifetimes.

Failure plan (before implementation):
- LaunchServices may accept a request without starting the expected instance:
  execute the signed bundle's actual executable and retain its Popen handle.
- An app may exit before writing JSON: detect the exit immediately and preserve
  logs, exit code, and a missing-result failure artifact.
- A stale/partial result may claim success: refuse pre-existing result files;
  require valid passed=true JSON AND a clean app exit before success.
- A hang may leave a running instance or signal an unrelated process: bound every
  wait, terminate/kill only the exact subprocess owned by this runner, then reap.
- Network phases may overlap persistent stores or lose their fixture: wait for
  seed exit before verify and own/check/reap the fixture server independently.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import pathlib
import subprocess
import sys
import time


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path: pathlib.Path, value: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def stop_owned(process: subprocess.Popen, record: dict) -> None:
    """Popen owns this unreaped child; never search for or signal other apps."""
    if process.poll() is None:
        record["termination_requested"] = "SIGTERM"
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            record["termination_requested"] = "SIGKILL"
            process.kill()
            process.wait(timeout=3)
    record["exit_code"] = process.poll()


def run_phase(executable: pathlib.Path, directory: pathlib.Path, phase: str,
              timeout: float, base_url: str | None = None,
              fixture: subprocess.Popen | None = None) -> bool:
    result = directory / ("result.json" if phase == "native" else phase + ".json")
    metadata = result.with_suffix(".process.json")
    stdout = result.with_suffix(".stdout.log")
    stderr = result.with_suffix(".stderr.log")
    output_flag = "--window-lifecycle-output" if phase == "window-lifecycle" else "--smoke-output"
    command = [str(executable), "--data-dir", str(directory), output_flag, str(result)]
    if phase == "sidebar-reset-eligibility":
        command += ["--sidebar-reset-eligibility-only"]
    if phase == "semantic-colors":
        command += ["--semantic-colors-only"]
    if phase == "favicon":
        command += ["--favicon-only"]
    if phase == "split-interaction":
        command += ["--split-interaction-only"]
    if phase == "window-lifecycle":
        command += ["--hold-after-window-lifecycle"]
    if base_url is not None:
        command += ["--network-smoke", base_url, "--network-phase", phase]
    record = {"schema_version": 1, "phase": phase, "started_at": now(),
              "command": command, "result_path": str(result), "stdout_path": str(stdout),
              "stderr_path": str(stderr), "timeout_seconds": timeout,
              "pid": None, "exit_code": None, "status": "starting", "passed": False}
    started = time.monotonic()
    process = None
    payload = None
    try:
        if result.exists():
            record["status"] = "preexisting_result"
            record["error"] = "Refusing a stale result file; use a fresh run directory."
            return False
        with stdout.open("wb") as out, stderr.open("wb") as err:
            process = subprocess.Popen(command, stdout=out, stderr=err)
            record.update(pid=process.pid, status="running")
            write_json(metadata, record)
            deadline = started + timeout
            while process.poll() is None:
                if fixture is not None and fixture.poll() is not None:
                    record["status"] = "fixture_exited"
                    record["fixture_exit_code"] = fixture.returncode
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    record["status"] = "timeout"
                    record["error"] = f"Owned app did not exit within {timeout:g} seconds."
                    break
                try:
                    process.wait(timeout=min(0.1, remaining))
                except subprocess.TimeoutExpired:
                    pass
            if record["status"] != "running":
                stop_owned(process, record)
            else:
                record["exit_code"] = process.returncode
                record["status"] = "exited"
            if result.exists():
                try:
                    payload = json.loads(result.read_text())
                    if not isinstance(payload, dict) or not isinstance(payload.get("passed"), bool):
                        raise ValueError("Result must contain a Boolean passed field.")
                    record["result_passed"] = payload["passed"]
                except (OSError, ValueError) as error:
                    record["result_error"] = str(error)
                    if record["status"] == "exited":
                        record["status"] = "invalid_result"
            if record["status"] == "exited":
                if process.returncode != 0:
                    record["status"] = "unexpected_exit"
                    record["error"] = f"Owned app exited with code {process.returncode}."
                elif payload is None:
                    record["status"] = "missing_result"
                    record["error"] = "Owned app exited before writing its result JSON."
                elif payload["passed"]:
                    record.update(status="passed", passed=True)
                else:
                    record["status"] = "failed_checks"
            return record["passed"]
    except KeyboardInterrupt:
        record["status"] = "interrupted"
        raise
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        record.update(status="process_error", error=str(error))
        return False
    finally:
        if process is not None:
            stop_owned(process, record)
        record.update(finished_at=now(), elapsed_seconds=round(time.monotonic() - started, 3))
        write_json(metadata, record)
        if payload is not None:
            print(json.dumps(payload, indent=2), flush=True)
        print(f"{phase}: {record['status']}; PID {record['pid']}; exit {record['exit_code']}", flush=True)
        print(f"Process artifact: {metadata}", flush=True)
        if result.exists():
            print(f"Result artifact: {result}", flush=True)
        if not record["passed"]:
            print(f"Logs: {stdout} | {stderr}", file=sys.stderr, flush=True)


def run_network(executable: pathlib.Path, directory: pathlib.Path, timeout: float) -> bool:
    server_info = directory / "server.json"
    metadata = directory / "fixture.process.json"
    stdout = directory / "fixture.stdout.log"
    stderr = directory / "fixture.stderr.log"
    command = [sys.executable, str(pathlib.Path(__file__).with_name("fixture-server.py")),
               "--port-file", str(server_info)]
    record = {"schema_version": 1, "role": "fixture", "command": command,
              "started_at": now(), "pid": None, "exit_code": None, "status": "starting",
              "stdout_path": str(stdout), "stderr_path": str(stderr)}
    process = None
    try:
        if server_info.exists():
            record.update(status="preexisting_fixture", error="Use a fresh run directory.")
            return False
        with stdout.open("wb") as out, stderr.open("wb") as err:
            process = subprocess.Popen(command, stdout=out, stderr=err)
            record.update(pid=process.pid, status="starting")
            write_json(metadata, record)
            deadline = time.monotonic() + 5
            base_url = None
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    record["status"] = "startup_exit"
                    return False
                if server_info.exists():
                    try:
                        base_url = json.loads(server_info.read_text())["base_url"]
                        break
                    except (OSError, ValueError, KeyError):
                        pass
                time.sleep(0.05)
            if not isinstance(base_url, str) or not base_url.startswith("http://127.0.0.1:"):
                record["status"] = "startup_failed"
                return False
            record.update(status="running", base_url=base_url)
            write_json(metadata, record)
            for phase in ["seed", "verify"]:
                if not run_phase(executable, directory, phase, timeout, base_url, process):
                    return False
            return True
    except KeyboardInterrupt:
        record["status"] = "interrupted"
        raise
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        record.update(status="process_error", error=str(error))
        return False
    finally:
        if process is not None:
            if record["status"] == "running":
                record["status"] = "stopped_after_phases"
            stop_owned(process, record)
        record["finished_at"] = now()
        write_json(metadata, record)
        print(f"Fixture artifact: {metadata}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["native", "network", "window-lifecycle", "favicon", "split-interaction", "semantic-colors", "sidebar-reset-eligibility"], default="native")
    parser.add_argument("--executable", type=pathlib.Path, required=True)
    parser.add_argument("--run-dir", type=pathlib.Path, required=True)
    parser.add_argument("--timeout", type=float, required=True)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0 or args.timeout > 3600:
        parser.error("timeout must be between 0 and 3600 seconds")
    directory = args.run_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    summary = {"schema_version": 1, "mode": args.mode, "started_at": now(), "passed": False}
    code = 1
    try:
        if args.mode == "network":
            summary["passed"] = run_network(args.executable.resolve(), directory, args.timeout)
        else:
            summary["passed"] = run_phase(args.executable.resolve(), directory, args.mode, args.timeout)
        code = 0 if summary["passed"] else 1
    except KeyboardInterrupt:
        summary["error"] = "Interrupted; owned children were terminated."
        code = 130
    finally:
        summary.update(finished_at=now(), exit_code=code)
        write_json(directory / "run.json", summary)
        print(f"Run artifact: {directory / 'run.json'}", flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
