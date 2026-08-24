#!/usr/bin/env python3
"""Retain and snapshot one support-log inode without following path replacement."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import stat
import tempfile
import time


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--binding", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--first-frame-marker", required=True)
    parser.add_argument("--expected-device", type=int, required=True)
    parser.add_argument("--expected-inode", type=int, required=True)
    parser.add_argument("--expected-client-fd", required=True)
    return parser.parse_args()


def atomic_write(path: Path, payload: bytes) -> None:
    descriptor, temporary_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)


def main() -> int:
    os.umask(0o077)
    options = parse_arguments()
    log_path = Path(options.log)
    snapshot_path = Path(options.snapshot)
    binding_path = Path(options.binding)
    ready_path = Path(options.ready)
    first_frame_marker = Path(options.first_frame_marker)

    descriptor = os.open(log_path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        initial = os.fstat(descriptor)
        if (
            not stat.S_ISREG(initial.st_mode)
            or initial.st_uid != os.getuid()
            or initial.st_dev != options.expected_device
            or initial.st_ino != options.expected_inode
        ):
            raise ValueError("opened support-log identity does not match the PID-bound inode")
        atomic_write(
            binding_path,
            (
                json.dumps(
                    {
                        "path_at_open": str(log_path),
                        "device": initial.st_dev,
                        "inode": initial.st_ino,
                        "owner_uid": initial.st_uid,
                        "client_fd_at_discovery": options.expected_client_fd,
                        "binding": "retained O_NOFOLLOW file descriptor",
                    },
                    sort_keys=True,
                )
                + "\n"
            ).encode(),
        )
        marker_descriptor = os.open(
            ready_path,
            os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
            0o600,
        )
        os.close(marker_descriptor)

        stopped = False

        def stop(_signal: int, _frame: object) -> None:
            nonlocal stopped
            stopped = True

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while not stopped:
            os.lseek(descriptor, 0, os.SEEK_SET)
            contents = os.read(descriptor, max(initial.st_size, os.fstat(descriptor).st_size, 1 << 16))
            if b"Video decoder produced frame 1" in contents and not first_frame_marker.exists():
                marker_descriptor = os.open(
                    first_frame_marker,
                    os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
                    0o600,
                )
                os.close(marker_descriptor)
            time.sleep(0.05)

        final = os.fstat(descriptor)
        if final.st_dev != initial.st_dev or final.st_ino != initial.st_ino:
            raise ValueError("retained support-log descriptor identity changed")
        os.lseek(descriptor, 0, os.SEEK_SET)
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
        atomic_write(snapshot_path, b"".join(chunks))
    finally:
        os.close(descriptor)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
