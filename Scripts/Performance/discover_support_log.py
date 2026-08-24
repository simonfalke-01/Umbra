#!/usr/bin/env python3
"""Discover exactly one support log opened by an exact process PID."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import subprocess
import time


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--timeout-ms", type=int, default=5_000)
    parser.add_argument("--lsof", default="lsof")
    parser.add_argument("--expected-fd")
    parser.add_argument("--expected-device", type=int)
    parser.add_argument("--expected-inode", type=int)
    return parser.parse_args()


def opened_files(executable: str, pid: int) -> list[dict[str, object]]:
    result = subprocess.run(
        [executable, "-a", "-p", str(pid), "-FfDin"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode not in {0, 1}:
        raise RuntimeError(f"lsof failed with exit {result.returncode}: {result.stderr.strip()}")
    files: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    for line in result.stdout.splitlines():
        if line.startswith("f"):
            if current is not None:
                files.append(current)
            current = {"fd": line[1:]}
        elif current is not None and line.startswith("D") and line[1:]:
            current["device"] = int(line[1:], 0)
        elif current is not None and line.startswith("i") and line[1:].isdigit():
            current["inode"] = int(line[1:])
        elif current is not None and line.startswith("n") and line[1:]:
            current["name"] = line[1:]
    if current is not None:
        files.append(current)
    return files


def main() -> int:
    options = parse_arguments()
    if not 1 <= options.timeout_ms <= 30_000:
        raise ValueError("timeout must be between 1 and 30000 ms")
    root = Path(options.root).resolve()
    deadline = time.monotonic() + options.timeout_ms / 1_000
    while time.monotonic() < deadline:
        candidates: dict[tuple[int, int], tuple[Path, str]] = {}
        for opened_file in opened_files(options.lsof, options.pid):
            raw_name = opened_file.get("name")
            descriptor = opened_file.get("fd")
            device = opened_file.get("device")
            inode = opened_file.get("inode")
            if (
                not isinstance(raw_name, str)
                or not raw_name
                or not isinstance(descriptor, str)
                or not descriptor
                or not isinstance(device, int)
                or not isinstance(inode, int)
            ):
                continue
            if options.expected_fd is not None and descriptor != options.expected_fd:
                continue
            if options.expected_device is not None and device != options.expected_device:
                continue
            if options.expected_inode is not None and inode != options.expected_inode:
                continue
            candidate = Path(raw_name)
            if candidate.parent.resolve() != root or not candidate.name.startswith("Umbra-"):
                continue
            metadata = candidate.lstat()
            if candidate.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise ValueError("PID-opened support log is not an owned regular file")
            if metadata.st_dev != device or metadata.st_ino != inode:
                raise ValueError("lsof identity does not match support-log path identity")
            candidates[(device, inode)] = (candidate, descriptor)
        if len(candidates) == 1:
            (device, inode), (candidate, descriptor) = next(iter(candidates.items()))
            print(f"{candidate}\t{descriptor}\t{device}\t{inode}")
            return 0
        if len(candidates) > 1:
            raise ValueError("PID has multiple distinct Umbra support-log inodes open")
        time.sleep(0.01)
    raise TimeoutError("PID did not open an Umbra support log before timeout")


if __name__ == "__main__":
    raise SystemExit(main())
