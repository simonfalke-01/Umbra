#!/usr/bin/env python3
"""Content-addressed Gate 6 provenance primitives.

This module deliberately does not know how to build or package Umbra or Lumen.
It provides the smaller trust boundary those build drivers consume:

* canonical, immutable SHA-256 objects;
* deterministic Git archives and SHA-256 tree manifests;
* strict Source Freeze Manifest (SFM) and Artifact Manifest (AM) validation;
* an append-only, content-addressed event chain; and
* binary-safe command evidence capture.

Only Python's standard library is used.  Release evidence must live outside the
source and build trees; tests use disposable temporary directories.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import os
import posixpath
import re
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SFM_SCHEMA = "umbra-lumen/source-freeze-manifest/1"
AM_SCHEMA = "umbra-lumen/artifact-manifest/1"
RUN_SCHEMA = "umbra-lumen/run-evidence/1"
TREE_SCHEMA = "umbra-lumen/git-tree-manifest/1"
EVENT_SCHEMA = "umbra-lumen/provenance-event/1"
POLICY_SCHEMA = "umbra-lumen/gate6-policy/1"

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_GIT_OID_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
_OBJECT_ID_RE = re.compile(r"^sha256:([0-9a-f]{64})$")
_PLACEHOLDER_RE = re.compile(
    r"^(?:tbd|todo|pending|unknown|n/?a|null|placeholder)$", re.I
)
_SECRET_KEY_RE = re.compile(
    r"(?:password|passwd|secret|token|private[_-]?key|credential)", re.I
)
_ALLOWED_GIT_MODES = {"100644", "100755", "120000", "160000"}


class ProvenanceError(RuntimeError):
    """Base error for a provenance contract violation."""


class ValidationError(ProvenanceError):
    """Raised when an object does not satisfy the release contract."""


class StoreCorruptionError(ProvenanceError):
    """Raised when addressed bytes no longer match their object id."""


def _reject_floats_and_non_strings(value: Any, path: str = "$") -> None:
    if isinstance(value, float):
        raise ValidationError(f"floating-point JSON is forbidden at {path}")
    if value is None or isinstance(value, (str, int, bool)):
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _reject_floats_and_non_strings(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise ValidationError(f"JSON object key is not a string at {path}")
            _reject_floats_and_non_strings(item, f"{path}.{key}")
        return
    raise ValidationError(f"unsupported JSON value {type(value).__name__} at {path}")


def canonical_json_bytes(value: Any) -> bytes:
    """Return the sole canonical JSON encoding accepted by the object store."""

    _reject_floats_and_non_strings(value)
    try:
        encoded = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (UnicodeEncodeError, ValueError, TypeError) as error:
        raise ValidationError(
            f"value cannot be canonically encoded: {error}"
        ) from error
    return encoded + b"\n"


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json_bytes(data: bytes) -> Any:
    try:
        value = json.loads(
            data.decode("utf-8"), object_pairs_hook=_reject_duplicate_pairs
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"invalid UTF-8 JSON: {error}") from error
    _reject_floats_and_non_strings(value)
    return value


def load_json_file(path: Path | str) -> Any:
    return load_json_bytes(Path(path).read_bytes())


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


@dataclasses.dataclass(frozen=True)
class ObjectRef:
    id: str
    sha256: str
    bytes: int
    media_type: str

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


def validate_object_ref(value: Any, path: str = "object") -> ObjectRef:
    if not isinstance(value, dict):
        raise ValidationError(f"{path} must be an object reference")
    required = {"id", "sha256", "bytes", "media_type"}
    if set(value) != required:
        raise ValidationError(f"{path} keys must be exactly {sorted(required)}")
    object_id = value["id"]
    digest = value["sha256"]
    size = value["bytes"]
    media_type = value["media_type"]
    match = _OBJECT_ID_RE.fullmatch(object_id) if isinstance(object_id, str) else None
    if not match or match.group(1) != digest or not _SHA256_RE.fullmatch(str(digest)):
        raise ValidationError(f"{path} has an invalid or inconsistent SHA-256 id")
    if isinstance(size, bool) or not isinstance(size, int) or size < 0:
        raise ValidationError(f"{path}.bytes must be a nonnegative integer")
    if not isinstance(media_type, str) or not media_type:
        raise ValidationError(f"{path}.media_type must be nonempty")
    return ObjectRef(object_id, digest, size, media_type)


class ObjectStore:
    """Immutable SHA-256 objects plus an append-only event chain."""

    def __init__(self, root: Path | str):
        self.root = Path(root).expanduser().resolve()
        self.objects = self.root / "objects" / "sha256"
        self.events = self.root / "events.jsonl"
        self.lock = self.root / ".events.lock"

    def _ensure_root(self) -> None:
        self.objects.mkdir(parents=True, exist_ok=True)

    def object_path(self, object_id: str) -> Path:
        match = _OBJECT_ID_RE.fullmatch(object_id)
        if not match:
            raise ValidationError(f"invalid object id: {object_id!r}")
        digest = match.group(1)
        return self.objects / digest[:2] / digest

    def _install_temp(
        self, temporary: Path, digest: str, size: int, media_type: str
    ) -> ObjectRef:
        destination = self.objects / digest[:2] / digest
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(temporary, destination)
        except FileExistsError:
            actual_digest, actual_size = _sha256_file(destination)
            if actual_digest != digest or actual_size != size:
                raise StoreCorruptionError(
                    f"existing object is corrupt: sha256:{digest}"
                )
        finally:
            temporary.unlink(missing_ok=True)
        try:
            destination.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
        except OSError:
            pass
        return ObjectRef(f"sha256:{digest}", digest, size, media_type)

    def put_bytes(
        self, data: bytes, media_type: str = "application/octet-stream"
    ) -> ObjectRef:
        self._ensure_root()
        digest = sha256_bytes(data)
        temporary = self.root / f".{digest}.{uuid.uuid4().hex}.tmp"
        with temporary.open("xb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        return self._install_temp(temporary, digest, len(data), media_type)

    def put_file(
        self, source: Path | str, media_type: str = "application/octet-stream"
    ) -> ObjectRef:
        self._ensure_root()
        source_path = Path(source)
        temporary = self.root / f".incoming.{uuid.uuid4().hex}.tmp"
        digest = hashlib.sha256()
        size = 0
        with source_path.open("rb") as reader, temporary.open("xb") as writer:
            for chunk in iter(lambda: reader.read(1024 * 1024), b""):
                digest.update(chunk)
                size += len(chunk)
                writer.write(chunk)
            writer.flush()
            os.fsync(writer.fileno())
        return self._install_temp(temporary, digest.hexdigest(), size, media_type)

    def put_json(self, value: Any, media_type: str = "application/json") -> ObjectRef:
        return self.put_bytes(canonical_json_bytes(value), media_type)

    def read_bytes(self, object_id: str) -> bytes:
        path = self.object_path(object_id)
        try:
            data = path.read_bytes()
        except FileNotFoundError as error:
            raise ValidationError(f"object is missing: {object_id}") from error
        digest = object_id.split(":", 1)[1]
        if sha256_bytes(data) != digest:
            raise StoreCorruptionError(f"object digest mismatch: {object_id}")
        return data

    def read_json(self, object_id: str) -> Any:
        return load_json_bytes(self.read_bytes(object_id))

    def verify_ref(self, value: Mapping[str, Any], path: str = "object") -> ObjectRef:
        reference = validate_object_ref(dict(value), path)
        data = self.read_bytes(reference.id)
        if len(data) != reference.bytes:
            raise StoreCorruptionError(f"object size mismatch: {reference.id}")
        return reference

    def verify_events(self) -> list[dict[str, Any]]:
        if not self.events.exists():
            return []
        events: list[dict[str, Any]] = []
        previous: str | None = None
        for index, raw_line in enumerate(
            self.events.read_bytes().splitlines(keepends=True), start=1
        ):
            if not raw_line.endswith(b"\n"):
                raise StoreCorruptionError(
                    "events.jsonl contains a truncated final line"
                )
            envelope = load_json_bytes(raw_line)
            if not isinstance(envelope, dict) or set(envelope) != {"event_object"}:
                raise ValidationError(f"invalid event envelope at line {index}")
            object_id = envelope["event_object"]
            event = self.read_json(object_id)
            _validate_event(event, index, previous)
            events.append(event | {"event_object": object_id})
            previous = object_id
        return events

    def append_event(
        self,
        kind: str,
        object_id: str,
        release_id: str,
        created_at_utc: str | None = None,
    ) -> ObjectRef:
        self._ensure_root()
        self.read_bytes(object_id)
        try:
            lock_fd = os.open(self.lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError as error:
            raise ProvenanceError("event chain is locked by another writer") from error
        try:
            os.close(lock_fd)
            existing = self.verify_events()
            event = {
                "schema": EVENT_SCHEMA,
                "sequence": len(existing) + 1,
                "created_at_utc": created_at_utc or utc_now(),
                "kind": kind,
                "release_id": _require_nonempty(release_id, "release_id"),
                "object_id": object_id,
                "previous_event": existing[-1]["event_object"] if existing else None,
            }
            event_ref = self.put_json(event)
            envelope = canonical_json_bytes({"event_object": event_ref.id})
            fd = os.open(self.events, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o644)
            try:
                written = os.write(fd, envelope)
                if written != len(envelope):
                    raise OSError("short append to events.jsonl")
                os.fsync(fd)
            finally:
                os.close(fd)
            return event_ref
        finally:
            self.lock.unlink(missing_ok=True)


def utc_now() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def _validate_utc(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValidationError(f"{path} must be an RFC3339 UTC timestamp ending in Z")
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ValidationError(f"{path} is not a valid timestamp") from error
    if parsed.utcoffset() != dt.timedelta(0):
        raise ValidationError(f"{path} is not UTC")
    return value


def _require_nonempty(value: Any, path: str) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or _PLACEHOLDER_RE.fullmatch(value.strip())
    ):
        raise ValidationError(f"{path} must be a non-placeholder string")
    return value


def _require_git_oid(value: Any, path: str) -> str:
    if not isinstance(value, str) or not _GIT_OID_RE.fullmatch(value):
        raise ValidationError(f"{path} must be a lowercase Git object id")
    return value


def validate_relative_path(value: Any, path: str = "path") -> str:
    if not isinstance(value, str) or not value:
        raise ValidationError(f"{path} must be nonempty")
    if "\\" in value or "\0" in value or "\n" in value or "\r" in value:
        raise ValidationError(f"{path} is not a portable POSIX path: {value!r}")
    if value.startswith("/") or value.endswith("/"):
        raise ValidationError(f"{path} must be relative and must identify an entry")
    components = value.split("/")
    if any(component in {"", ".", ".."} for component in components):
        raise ValidationError(f"{path} contains an unsafe component: {value!r}")
    return value


def _validate_unique_paths(rows: Iterable[Mapping[str, Any]], path: str) -> None:
    exact: set[str] = set()
    folded: set[str] = set()
    for index, row in enumerate(rows):
        relative = validate_relative_path(row.get("path"), f"{path}[{index}].path")
        folded_relative = relative.casefold()
        if relative in exact or folded_relative in folded:
            raise ValidationError(
                f"duplicate or case-colliding path in {path}: {relative}"
            )
        exact.add(relative)
        folded.add(folded_relative)


def _safe_symlink_target(entry_path: str, target: str) -> None:
    if (
        not target
        or "\0" in target
        or "\n" in target
        or "\r" in target
        or "\\" in target
    ):
        raise ValidationError(f"unsafe symlink target for {entry_path}")
    if target.startswith("/"):
        raise ValidationError(f"absolute symlink target for {entry_path}")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(entry_path), target))
    if resolved == ".." or resolved.startswith("../"):
        raise ValidationError(f"escaping symlink target for {entry_path}")


def validate_tree_rows(rows: Any, path: str = "rows") -> list[dict[str, Any]]:
    if not isinstance(rows, list) or not rows:
        raise ValidationError(f"{path} must be a nonempty list")
    if not all(isinstance(row, dict) for row in rows):
        raise ValidationError(f"{path} entries must be objects")
    _validate_unique_paths(rows, path)
    validated: list[dict[str, Any]] = []
    for index, row in enumerate(rows):
        entry_path = validate_relative_path(row.get("path"), f"{path}[{index}].path")
        mode = row.get("mode")
        if mode not in _ALLOWED_GIT_MODES:
            raise ValidationError(f"unsupported Git mode for {entry_path}: {mode!r}")
        if mode == "160000":
            if row.get("type") != "commit":
                raise ValidationError(f"gitlink {entry_path} must have type=commit")
            _require_git_oid(row.get("commit"), f"{path}[{index}].commit")
        else:
            if row.get("type") != "blob":
                raise ValidationError(f"file {entry_path} must have type=blob")
            _require_git_oid(row.get("blob_oid"), f"{path}[{index}].blob_oid")
            digest = row.get("sha256")
            size = row.get("bytes")
            if not isinstance(digest, str) or not _SHA256_RE.fullmatch(digest):
                raise ValidationError(f"invalid SHA-256 for {entry_path}")
            if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                raise ValidationError(f"invalid size for {entry_path}")
            if mode == "120000":
                target = row.get("symlink_target")
                if not isinstance(target, str):
                    raise ValidationError(f"symlink {entry_path} is missing its target")
                _safe_symlink_target(entry_path, target)
        validated.append(row)
    if rows != sorted(rows, key=lambda row: row["path"].encode("utf-8")):
        raise ValidationError(f"{path} must be bytewise path-sorted")
    return validated


def _run_git(repository: Path, *arguments: str, binary: bool = False) -> bytes | str:
    completed = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise ProvenanceError(
            f"git {' '.join(arguments)} failed in {repository}: {detail}"
        )
    return completed.stdout if binary else completed.stdout.decode("utf-8").strip()


def inspect_git_repository(
    repository: Path | str,
    *,
    store: ObjectStore | None = None,
    require_pushed: bool = True,
    require_submodules: bool = True,
    require_submodule_remote_reachability: bool = True,
) -> dict[str, Any]:
    """Return clean/pushed metadata or fail closed.

    Callers must fetch approved remotes before invoking this function.  It does
    not mutate refs or contact a remote.
    """

    root = Path(repository).resolve()
    if store is not None:
        _ensure_disjoint(store.root, root, "evidence store and Git repository")
    status_bytes = _run_git(
        root, "status", "--porcelain=v2", "-z", "--untracked-files=all", binary=True
    )
    assert isinstance(status_bytes, bytes)
    if status_bytes:
        raise ValidationError(
            f"repository has staged, unstaged, or untracked changes: {root}"
        )
    head = str(_run_git(root, "rev-parse", "HEAD"))
    tree = str(_run_git(root, "rev-parse", "HEAD^{tree}"))
    branch = str(_run_git(root, "branch", "--show-current"))
    if not branch:
        raise ValidationError(f"repository is detached: {root}")
    upstream_query = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{u}",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if upstream_query.returncode == 0:
        upstream = upstream_query.stdout.decode("utf-8").strip()
        upstream_commit = str(_run_git(root, "rev-parse", "@{u}"))
        remote_name = upstream.split("/", 1)[0]
        remote_url = str(_run_git(root, "remote", "get-url", remote_name))
    elif require_pushed:
        raise ValidationError(f"repository has no approved upstream: {root}")
    else:
        upstream = "local-only"
        upstream_commit = head
        remotes = str(_run_git(root, "remote"))
        remote_name = remotes.splitlines()[0] if remotes else "local"
        remote_url = (
            str(_run_git(root, "remote", "get-url", remote_name))
            if remotes
            else str(root)
        )
    pushed = upstream_query.returncode == 0 and head == upstream_commit
    if require_pushed and not pushed:
        raise ValidationError(
            f"repository HEAD is not equal to its fetched upstream: {root}"
        )
    status_ref = (
        store.put_bytes(status_bytes, "application/x-git-status-porcelain-v2")
        if store
        else ObjectRef(
            f"sha256:{sha256_bytes(status_bytes)}",
            sha256_bytes(status_bytes),
            len(status_bytes),
            "application/x-git-status-porcelain-v2",
        )
    )

    submodules: list[dict[str, Any]] = []
    gitmodules = root / ".gitmodules"
    if gitmodules.exists():
        raw_status_bytes = _run_git(
            root, "submodule", "status", "--recursive", binary=True
        )
        assert isinstance(raw_status_bytes, bytes)
        raw_status = raw_status_bytes.decode("utf-8").rstrip("\n")
        for line in raw_status.splitlines():
            if not line:
                continue
            prefix = line[0]
            parts = line[1:].strip().split(maxsplit=2)
            if len(parts) < 2:
                raise ValidationError(f"malformed submodule status: {line!r}")
            commit, relative = parts[0], parts[1]
            validate_relative_path(relative, "submodule.path")
            if require_submodules and prefix != " ":
                meaning = {
                    "-": "uninitialized",
                    "+": "commit mismatch",
                    "U": "conflicted",
                }.get(prefix, "invalid")
                raise ValidationError(f"submodule {relative} is {meaning}")
            subroot = root / relative
            if not subroot.is_dir():
                raise ValidationError(f"submodule checkout is missing: {relative}")
            checked_out = str(_run_git(subroot, "rev-parse", "HEAD"))
            if checked_out != commit:
                raise ValidationError(
                    f"submodule checkout differs from gitlink: {relative}"
                )
            sub_status = _run_git(
                subroot,
                "status",
                "--porcelain=v2",
                "-z",
                "--untracked-files=all",
                binary=True,
            )
            assert isinstance(sub_status, bytes)
            if sub_status:
                raise ValidationError(f"submodule is dirty: {relative}")
            url = str(_run_git(subroot, "remote", "get-url", "origin"))
            containing = str(_run_git(subroot, "branch", "-r", "--contains", "HEAD"))
            reachable = bool(containing.strip())
            if require_submodule_remote_reachability and not reachable:
                raise ValidationError(
                    f"submodule commit has no fetched remote-containing ref: {relative}"
                )
            submodules.append(
                {
                    "path": relative,
                    "url": url,
                    "gitlink_commit": commit,
                    "checked_out_commit": checked_out,
                    "clean": True,
                    "remote_reachable": reachable,
                    "status_sha256": sha256_bytes(sub_status),
                }
            )
    submodules.sort(key=lambda row: row["path"].encode("utf-8"))
    return {
        "remote_url": remote_url,
        "commit": head,
        "tree": tree,
        "branch": branch,
        "upstream_ref": upstream,
        "upstream_commit": upstream_commit,
        "clean": True,
        "pushed": pushed,
        "status_evidence": status_ref.as_dict(),
        "submodules": submodules,
    }


def git_tree_manifest(
    repository: Path | str, commit: str, repository_name: str, prefix: str
) -> dict[str, Any]:
    root = Path(repository).resolve()
    _require_git_oid(str(_run_git(root, "rev-parse", commit)), "commit")
    resolved_commit = str(_run_git(root, "rev-parse", commit))
    tree = str(_run_git(root, "rev-parse", f"{resolved_commit}^{{tree}}"))
    raw = _run_git(
        root, "ls-tree", "-rz", "-l", "--full-tree", resolved_commit, binary=True
    )
    assert isinstance(raw, bytes)
    rows: list[dict[str, Any]] = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        try:
            header, raw_path = record.split(b"\t", 1)
            mode_b, type_b, oid_b, _size_b = header.split(maxsplit=3)
            entry_path = raw_path.decode("utf-8")
        except (ValueError, UnicodeDecodeError) as error:
            raise ValidationError(
                "Git tree contains an unsupported path or record"
            ) from error
        mode = mode_b.decode("ascii")
        entry_type = type_b.decode("ascii")
        oid = oid_b.decode("ascii")
        row: dict[str, Any] = {"path": entry_path, "mode": mode, "type": entry_type}
        if mode == "160000":
            row["commit"] = oid
        else:
            contents = _run_git(root, "cat-file", "blob", oid, binary=True)
            assert isinstance(contents, bytes)
            row |= {
                "blob_oid": oid,
                "sha256": sha256_bytes(contents),
                "bytes": len(contents),
            }
            if mode == "120000":
                try:
                    row["symlink_target"] = contents.decode("utf-8")
                except UnicodeDecodeError as error:
                    raise ValidationError(
                        f"symlink target is not UTF-8: {entry_path}"
                    ) from error
        rows.append(row)
    rows.sort(key=lambda row: row["path"].encode("utf-8"))
    validate_tree_rows(rows)
    return {
        "schema": TREE_SCHEMA,
        "repository": _require_nonempty(repository_name, "repository_name"),
        "commit": resolved_commit,
        "tree": tree,
        "prefix": validate_archive_prefix(prefix),
        "rows": rows,
    }


def validate_archive_prefix(prefix: str) -> str:
    if not isinstance(prefix, str) or not prefix.endswith("/"):
        raise ValidationError(
            "Git archive prefix must be a nonempty directory prefix ending in /"
        )
    validate_relative_path(prefix[:-1], "archive prefix")
    return prefix


def _ensure_disjoint(first: Path, second: Path, description: str) -> None:
    try:
        first.relative_to(second)
    except ValueError:
        pass
    else:
        raise ValidationError(
            f"{description} must be disjoint: {first} is inside {second}"
        )
    try:
        second.relative_to(first)
    except ValueError:
        return
    raise ValidationError(f"{description} must be disjoint: {second} is inside {first}")


def store_git_source(
    store: ObjectStore,
    repository: Path | str,
    commit: str,
    repository_name: str,
    prefix: str,
) -> dict[str, Any]:
    root = Path(repository).resolve()
    _ensure_disjoint(store.root, root, "evidence store and Git repository")
    manifest = git_tree_manifest(root, commit, repository_name, prefix)
    tree_ref = store.put_json(manifest)
    temporary = store.root / f".git-archive.{uuid.uuid4().hex}.tar"
    try:
        with temporary.open("xb") as output:
            completed = subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "archive",
                    "--format=tar",
                    f"--prefix={prefix}",
                    manifest["commit"],
                ],
                check=False,
                stdout=output,
                stderr=subprocess.PIPE,
            )
            output.flush()
            os.fsync(output.fileno())
        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", errors="replace").strip()
            raise ProvenanceError(f"git archive failed: {detail}")
        archive_ref = store.put_file(temporary, "application/x-tar")
    finally:
        temporary.unlink(missing_ok=True)
    return {
        "archive": archive_ref.as_dict()
        | {"format": "git-archive-tar", "prefix": prefix},
        "tree_manifest": tree_ref.as_dict(),
    }


def _validate_event(event: Any, index: int, previous: str | None) -> None:
    if not isinstance(event, dict) or event.get("schema") != EVENT_SCHEMA:
        raise ValidationError(f"invalid event object at sequence {index}")
    if event.get("sequence") != index or event.get("previous_event") != previous:
        raise StoreCorruptionError(f"event chain discontinuity at sequence {index}")
    _validate_utc(event.get("created_at_utc"), f"event[{index}].created_at_utc")
    _require_nonempty(event.get("kind"), f"event[{index}].kind")
    _require_nonempty(event.get("release_id"), f"event[{index}].release_id")
    if not isinstance(event.get("object_id"), str) or not _OBJECT_ID_RE.fullmatch(
        event["object_id"]
    ):
        raise ValidationError(f"invalid event object id at sequence {index}")


def _reject_placeholders(value: Any, path: str = "$") -> None:
    if isinstance(value, str) and _PLACEHOLDER_RE.fullmatch(value.strip()):
        raise ValidationError(f"placeholder value is forbidden at {path}")
    if isinstance(value, list):
        for index, item in enumerate(value):
            _reject_placeholders(item, f"{path}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            _reject_placeholders(item, f"{path}.{key}")


def _require_list(value: Any, path: str) -> list[Any]:
    if not isinstance(value, list) or not value:
        raise ValidationError(f"{path} must be a nonempty list")
    return value


def _unique_values(rows: Sequence[Mapping[str, Any]], key: str, path: str) -> None:
    values: set[str] = set()
    for index, row in enumerate(rows):
        value = _require_nonempty(row.get(key), f"{path}[{index}].{key}")
        folded = value.casefold()
        if folded in values:
            raise ValidationError(f"duplicate {key} in {path}: {value}")
        values.add(folded)


def validate_policy(policy: Any) -> dict[str, Any]:
    if not isinstance(policy, dict) or policy.get("schema") != POLICY_SCHEMA:
        raise ValidationError("invalid Gate 6 policy schema")
    for section in ("source_freeze", "artifact"):
        if not isinstance(policy.get(section), dict):
            raise ValidationError(f"policy.{section} must be an object")
    return policy


def validate_source_freeze_manifest(
    manifest: Any, policy: Mapping[str, Any] | None = None
) -> dict[str, Any]:
    if not isinstance(manifest, dict):
        raise ValidationError("SFM must be an object")
    _reject_floats_and_non_strings(manifest)
    _reject_placeholders(manifest)
    if manifest.get("schema") != SFM_SCHEMA or manifest.get("kind") != "source_freeze":
        raise ValidationError("invalid SFM schema or kind")
    release_id = _require_nonempty(manifest.get("release_id"), "release_id")
    _validate_utc(manifest.get("created_at_utc"), "created_at_utc")
    if manifest.get("digest_algorithm") != "sha256":
        raise ValidationError("SFM digest_algorithm must be sha256")

    repositories = _require_list(manifest.get("repositories"), "repositories")
    if not all(isinstance(row, dict) for row in repositories):
        raise ValidationError("repositories entries must be objects")
    _unique_values(repositories, "name", "repositories")
    repository_commits: dict[str, str] = {}
    for index, repository in enumerate(repositories):
        base = f"repositories[{index}]"
        for field in ("remote_url", "branch", "upstream_ref"):
            _require_nonempty(repository.get(field), f"{base}.{field}")
        commit = _require_git_oid(repository.get("commit"), f"{base}.commit")
        repository_commits[repository["name"].casefold()] = commit
        _require_git_oid(repository.get("tree"), f"{base}.tree")
        if (
            _require_git_oid(
                repository.get("upstream_commit"), f"{base}.upstream_commit"
            )
            != commit
        ):
            raise ValidationError(f"{base} is not pushed to its approved upstream")
        if repository.get("clean") is not True or repository.get("pushed") is not True:
            raise ValidationError(f"{base} must be clean and pushed")
        _validate_utc(repository.get("fetched_at_utc"), f"{base}.fetched_at_utc")
        validate_object_ref(
            repository.get("status_evidence"), f"{base}.status_evidence"
        )
        archive = repository.get("archive")
        if not isinstance(archive, dict):
            raise ValidationError(f"{base}.archive must be an object")
        validate_object_ref(
            {key: archive.get(key) for key in ("id", "sha256", "bytes", "media_type")},
            f"{base}.archive",
        )
        if archive.get("format") != "git-archive-tar":
            raise ValidationError(f"{base}.archive must use git-archive-tar")
        validate_archive_prefix(archive.get("prefix"))
        validate_object_ref(repository.get("tree_manifest"), f"{base}.tree_manifest")
        submodules = repository.get("submodules", [])
        if not isinstance(submodules, list) or not all(
            isinstance(row, dict) for row in submodules
        ):
            raise ValidationError(f"{base}.submodules must be a list")
        _validate_unique_paths(submodules, f"{base}.submodules")
        if submodules != sorted(
            submodules, key=lambda row: row["path"].encode("utf-8")
        ):
            raise ValidationError(f"{base}.submodules must be bytewise path-sorted")
        for sub_index, submodule in enumerate(submodules):
            subbase = f"{base}.submodules[{sub_index}]"
            gitlink = _require_git_oid(
                submodule.get("gitlink_commit"), f"{subbase}.gitlink_commit"
            )
            if (
                _require_git_oid(
                    submodule.get("checked_out_commit"), f"{subbase}.checked_out_commit"
                )
                != gitlink
            ):
                raise ValidationError(f"{subbase} checkout differs from gitlink")
            if (
                submodule.get("clean") is not True
                or submodule.get("remote_reachable") is not True
            ):
                raise ValidationError(f"{subbase} must be clean and remotely reachable")
            _require_nonempty(submodule.get("url"), f"{subbase}.url")
            submodule_archive = submodule.get("archive")
            if not isinstance(submodule_archive, dict):
                raise ValidationError(f"{subbase}.archive must be an object")
            validate_object_ref(
                {
                    key: submodule_archive.get(key)
                    for key in ("id", "sha256", "bytes", "media_type")
                },
                f"{subbase}.archive",
            )
            if submodule_archive.get("format") != "git-archive-tar":
                raise ValidationError(f"{subbase}.archive must use git-archive-tar")
            validate_archive_prefix(submodule_archive.get("prefix"))
            validate_object_ref(
                submodule.get("tree_manifest"), f"{subbase}.tree_manifest"
            )

    vectors = _require_list(manifest.get("protocol_vectors"), "protocol_vectors")
    if not all(isinstance(row, dict) for row in vectors):
        raise ValidationError("protocol_vectors entries must be objects")
    _unique_values(vectors, "id", "protocol_vectors")
    for index, vector in enumerate(vectors):
        base = f"protocol_vectors[{index}]"
        _require_nonempty(vector.get("schema"), f"{base}.schema")
        producer = vector.get("producer")
        if not isinstance(producer, dict):
            raise ValidationError(f"{base}.producer must be an object")
        producer_hash = producer.get("sha256")
        if not isinstance(producer_hash, str) or not _SHA256_RE.fullmatch(
            producer_hash
        ):
            raise ValidationError(f"{base}.producer.sha256 is invalid")
        producer_commit = _require_git_oid(
            producer.get("commit"), f"{base}.producer.commit"
        )
        producer_repository = _require_nonempty(
            producer.get("repository"), f"{base}.producer.repository"
        )
        if repository_commits.get(producer_repository.casefold()) != producer_commit:
            raise ValidationError(
                f"{base}.producer does not reference a frozen repository commit"
            )
        validate_relative_path(producer.get("path"), f"{base}.producer.path")
        consumers = _require_list(vector.get("consumers"), f"{base}.consumers")
        for consumer_index, consumer in enumerate(consumers):
            if not isinstance(consumer, dict):
                raise ValidationError(
                    f"{base}.consumers[{consumer_index}] must be an object"
                )
            validate_relative_path(
                consumer.get("path"), f"{base}.consumers[{consumer_index}].path"
            )
            consumer_commit = _require_git_oid(
                consumer.get("commit"), f"{base}.consumers[{consumer_index}].commit"
            )
            consumer_repository = _require_nonempty(
                consumer.get("repository"),
                f"{base}.consumers[{consumer_index}].repository",
            )
            if (
                repository_commits.get(consumer_repository.casefold())
                != consumer_commit
            ):
                raise ValidationError(
                    f"{base}.consumer does not reference a frozen repository commit"
                )
            consumer_hash = consumer.get("sha256")
            if not isinstance(consumer_hash, str) or not _SHA256_RE.fullmatch(
                consumer_hash
            ):
                raise ValidationError(
                    f"{base}.consumers[{consumer_index}].sha256 is invalid"
                )
            if (
                vector.get("byte_identical") is True
                and consumer.get("sha256") != producer_hash
            ):
                raise ValidationError(f"{base} producer/consumer byte hash mismatch")
        generator = vector.get("generator")
        if (
            not isinstance(generator, dict)
            or not isinstance(generator.get("argv"), list)
            or not generator["argv"]
            or not all(isinstance(argument, str) for argument in generator["argv"])
            or not isinstance(generator.get("source_sha256"), str)
            or not _SHA256_RE.fullmatch(generator["source_sha256"])
        ):
            raise ValidationError(f"{base}.generator must record argv")

    source_input_ids: set[str] = set()
    for collection, unique_key in (
        ("source_inputs", "id"),
        ("toolchains", "id"),
        ("signing_identities", "purpose"),
        ("build_plans", "run_id"),
        ("inventory_policies", "id"),
    ):
        rows = _require_list(manifest.get(collection), collection)
        if not all(isinstance(row, dict) for row in rows):
            raise ValidationError(f"{collection} entries must be objects")
        _unique_values(rows, unique_key, collection)
        for index, row in enumerate(rows):
            if collection == "toolchains":
                validate_object_ref(
                    row.get("executable"), f"{collection}[{index}].executable"
                )
                validate_object_ref(
                    row.get("version_stdout"), f"{collection}[{index}].version_stdout"
                )
                _require_nonempty(row.get("version"), f"{collection}[{index}].version")
                for field in ("host", "os", "architecture"):
                    _require_nonempty(row.get(field), f"{collection}[{index}].{field}")
                if (
                    not isinstance(row.get("version_argv"), list)
                    or not row["version_argv"]
                ):
                    raise ValidationError(
                        f"{collection}[{index}].version_argv must be nonempty"
                    )
            elif collection == "source_inputs":
                source_input_ids.add(row["id"])
                validate_object_ref(row.get("object"), f"{collection}[{index}].object")
            elif collection == "inventory_policies":
                validate_relative_path(
                    row.get("source_path"), f"{collection}[{index}].source_path"
                )
                validate_object_ref(row.get("object"), f"{collection}[{index}].object")
            elif collection == "build_plans":
                if not isinstance(row.get("argv"), list) or not row["argv"]:
                    raise ValidationError(
                        f"{collection}[{index}].argv must be nonempty"
                    )
                for field in (
                    "repository",
                    "target",
                    "configuration",
                    "architecture",
                    "cwd",
                ):
                    _require_nonempty(row.get(field), f"{collection}[{index}].{field}")
                if row["repository"].casefold() not in repository_commits:
                    raise ValidationError(
                        f"{collection}[{index}] references an unknown repository"
                    )
                _validate_recorded_environment(
                    row.get("environment", {}), f"{collection}[{index}].environment"
                )
                inputs = row.get("input_ids")
                if not isinstance(inputs, list) or not inputs:
                    raise ValidationError(
                        f"{collection}[{index}].input_ids must be nonempty"
                    )
            elif collection == "signing_identities":
                fingerprint = row.get("certificate_sha256")
                if not isinstance(fingerprint, str) or not _SHA256_RE.fullmatch(
                    fingerprint
                ):
                    raise ValidationError(
                        f"{collection}[{index}].certificate_sha256 is invalid"
                    )
                for field in ("subject", "issuer", "serial", "policy"):
                    _require_nonempty(row.get(field), f"{collection}[{index}].{field}")
                if (
                    row["policy"].casefold() in {"ad-hoc", "adhoc"}
                    or row["subject"] == "-"
                ):
                    raise ValidationError(
                        f"{collection}[{index}] is not a qualifying signing identity"
                    )
                not_before = _validate_utc(
                    row.get("not_before_utc"), f"{collection}[{index}].not_before_utc"
                )
                not_after = _validate_utc(
                    row.get("not_after_utc"), f"{collection}[{index}].not_after_utc"
                )
                if not (not_before <= manifest["created_at_utc"] <= not_after):
                    raise ValidationError(
                        f"{collection}[{index}] is not valid at SFM creation"
                    )

    for index, plan in enumerate(manifest["build_plans"]):
        if any(input_id not in source_input_ids for input_id in plan["input_ids"]):
            raise ValidationError(
                f"build_plans[{index}] references an unknown source input"
            )

    if policy is not None:
        policy_value = validate_policy(dict(policy))
        source_policy = policy_value["source_freeze"]
        _require_policy_values(
            repositories,
            "name",
            source_policy.get("required_repositories", []),
            "repository",
        )
        _require_policy_values(
            vectors,
            "id",
            source_policy.get("required_vector_ids", []),
            "protocol vector",
        )
        _require_policy_values(
            manifest["toolchains"],
            "id",
            source_policy.get("required_toolchain_ids", []),
            "toolchain",
        )
        _require_policy_values(
            manifest["signing_identities"],
            "purpose",
            source_policy.get("required_signing_purposes", []),
            "signing identity",
        )
    manifest["release_id"] = release_id
    return manifest


def _require_policy_values(
    rows: Sequence[Mapping[str, Any]], key: str, required: Any, description: str
) -> None:
    if not isinstance(required, list):
        raise ValidationError(f"required {description} policy must be a list")
    actual = {str(row.get(key)).casefold() for row in rows}
    missing = [
        value
        for value in required
        if not isinstance(value, str) or value.casefold() not in actual
    ]
    if missing:
        raise ValidationError(f"missing required {description}(s): {missing}")


def _verify_sfm_objects(store: ObjectStore, manifest: Mapping[str, Any]) -> None:
    """Resolve every object referenced by an SFM before it becomes sealable."""

    for repository in manifest["repositories"]:
        for field in ("status_evidence", "archive", "tree_manifest"):
            reference = repository[field]
            store.verify_ref(
                {
                    key: reference.get(key)
                    for key in ("id", "sha256", "bytes", "media_type")
                },
                f"repository {repository['name']} {field}",
            )
        tree_manifest = store.read_json(repository["tree_manifest"]["id"])
        if (
            not isinstance(tree_manifest, dict)
            or tree_manifest.get("schema") != TREE_SCHEMA
        ):
            raise ValidationError(
                f"repository {repository['name']} tree manifest schema is invalid"
            )
        if (
            tree_manifest.get("commit") != repository["commit"]
            or tree_manifest.get("tree") != repository["tree"]
        ):
            raise ValidationError(
                f"repository {repository['name']} tree manifest identity mismatch"
            )
        validate_tree_rows(
            tree_manifest.get("rows"), f"repository {repository['name']} tree rows"
        )
        expected_gitlinks = {
            row["path"]: row["commit"]
            for row in tree_manifest["rows"]
            if row["mode"] == "160000"
        }
        actual_gitlinks = {
            submodule["path"]: submodule["gitlink_commit"]
            for submodule in repository["submodules"]
        }
        for submodule in repository["submodules"]:
            submodule_archive = submodule["archive"]
            store.verify_ref(
                {
                    key: submodule_archive.get(key)
                    for key in ("id", "sha256", "bytes", "media_type")
                },
                f"submodule {submodule['path']} archive",
            )
            store.verify_ref(
                submodule["tree_manifest"],
                f"submodule {submodule['path']} tree_manifest",
            )
            submodule_tree = store.read_json(submodule["tree_manifest"]["id"])
            if (
                not isinstance(submodule_tree, dict)
                or submodule_tree.get("schema") != TREE_SCHEMA
            ):
                raise ValidationError(
                    f"submodule {submodule['path']} tree manifest schema is invalid"
                )
            if submodule_tree.get("commit") != submodule["gitlink_commit"]:
                raise ValidationError(
                    f"submodule {submodule['path']} tree manifest identity mismatch"
                )
            validate_tree_rows(
                submodule_tree.get("rows"), f"submodule {submodule['path']} tree rows"
            )
            for row in submodule_tree["rows"]:
                if row["mode"] == "160000":
                    expected_gitlinks[f"{submodule['path']}/{row['path']}"] = row[
                        "commit"
                    ]
        if expected_gitlinks != actual_gitlinks:
            raise ValidationError(
                f"repository {repository['name']} submodule map differs from its Git trees"
            )
    for source_input in manifest["source_inputs"]:
        store.verify_ref(source_input["object"], f"source input {source_input['id']}")
    for toolchain in manifest["toolchains"]:
        store.verify_ref(
            toolchain["executable"], f"toolchain {toolchain['id']} executable"
        )
        store.verify_ref(
            toolchain["version_stdout"], f"toolchain {toolchain['id']} version_stdout"
        )
    for inventory in manifest["inventory_policies"]:
        store.verify_ref(inventory["object"], f"inventory policy {inventory['id']}")


def _validate_recorded_environment(value: Any, path: str) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ValidationError(f"{path} must be an object")
    for key, item in value.items():
        if not isinstance(key, str) or not isinstance(item, str):
            raise ValidationError(f"{path} keys and values must be strings")
        if _SECRET_KEY_RE.search(key):
            raise ValidationError(
                f"secret-bearing environment key is forbidden in evidence: {key}"
            )
    return value


def validate_run_record(run: Any, path: str = "run") -> dict[str, Any]:
    if not isinstance(run, dict) or run.get("schema") != RUN_SCHEMA:
        raise ValidationError(f"{path} has an invalid schema")
    _require_nonempty(run.get("run_id"), f"{path}.run_id")
    classification = run.get("classification")
    if classification not in {"mandatory", "capability_conditional"}:
        raise ValidationError(f"{path}.classification is invalid")
    if (
        not isinstance(run.get("argv"), list)
        or not run["argv"]
        or not all(isinstance(arg, str) for arg in run["argv"])
    ):
        raise ValidationError(f"{path}.argv must be a nonempty string array")
    _require_nonempty(run.get("cwd"), f"{path}.cwd")
    _validate_recorded_environment(run.get("environment"), f"{path}.environment")
    started = _validate_utc(run.get("started_at_utc"), f"{path}.started_at_utc")
    ended = _validate_utc(run.get("ended_at_utc"), f"{path}.ended_at_utc")
    if ended < started:
        raise ValidationError(f"{path} ends before it starts")
    duration = run.get("monotonic_duration_ns")
    if isinstance(duration, bool) or not isinstance(duration, int) or duration < 0:
        raise ValidationError(f"{path}.monotonic_duration_ns must be nonnegative")
    exit_code = run.get("exit_code")
    if isinstance(exit_code, bool) or not isinstance(exit_code, int):
        raise ValidationError(f"{path}.exit_code must be an integer")
    for stream in ("stdout", "stderr"):
        reference = run.get(stream)
        if not isinstance(reference, dict) or reference.get("complete") is not True:
            raise ValidationError(
                f"{path}.{stream} must be a complete object reference"
            )
        validate_object_ref(
            {
                key: reference.get(key)
                for key in ("id", "sha256", "bytes", "media_type")
            },
            f"{path}.{stream}",
        )
    result = run.get("result")
    expected = "pass" if exit_code == 0 else "fail"
    if result != expected:
        raise ValidationError(f"{path}.result disagrees with exit_code")
    if not isinstance(run.get("toolchain_ids"), list) or not run["toolchain_ids"]:
        raise ValidationError(f"{path}.toolchain_ids must be nonempty")
    return run


def validate_artifact_manifest(
    manifest: Any,
    *,
    store: ObjectStore | None = None,
    policy: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    if not isinstance(manifest, dict):
        raise ValidationError("AM must be an object")
    _reject_floats_and_non_strings(manifest)
    _reject_placeholders(manifest)
    if manifest.get("schema") != AM_SCHEMA or manifest.get("kind") != "artifact":
        raise ValidationError("invalid AM schema or kind")
    release_id = _require_nonempty(manifest.get("release_id"), "release_id")
    _validate_utc(manifest.get("created_at_utc"), "created_at_utc")
    sfm_ref = validate_object_ref(manifest.get("source_freeze"), "source_freeze")

    runs = _require_list(manifest.get("runs"), "runs")
    if not all(isinstance(run, dict) for run in runs):
        raise ValidationError("runs entries must be objects")
    _unique_values(runs, "run_id", "runs")
    for index, run in enumerate(runs):
        validate_run_record(run, f"runs[{index}]")
        if run["classification"] == "mandatory" and run["result"] != "pass":
            raise ValidationError(f"mandatory run failed: {run['run_id']}")
    run_ids = {run["run_id"] for run in runs}

    artifacts = _require_list(manifest.get("artifacts"), "artifacts")
    if not all(isinstance(row, dict) for row in artifacts):
        raise ValidationError("artifacts entries must be objects")
    _unique_values(artifacts, "artifact_id", "artifacts")
    _validate_unique_paths(artifacts, "artifacts")
    for index, artifact in enumerate(artifacts):
        base = f"artifacts[{index}]"
        _require_nonempty(artifact.get("kind"), f"{base}.kind")
        validate_relative_path(artifact.get("path"), f"{base}.path")
        validate_object_ref(artifact.get("object"), f"{base}.object")
        if artifact.get("producer_run_id") not in run_ids:
            raise ValidationError(f"{base} references an unknown producer run")
        if (
            not isinstance(artifact.get("source_refs"), list)
            or not artifact["source_refs"]
        ):
            raise ValidationError(f"{base}.source_refs must be nonempty")

    inventories = _require_list(manifest.get("inventories"), "inventories")
    if not all(isinstance(row, dict) for row in inventories):
        raise ValidationError("inventories entries must be objects")
    _unique_values(inventories, "inventory_id", "inventories")
    artifact_ids = {artifact["artifact_id"] for artifact in artifacts}
    for index, inventory in enumerate(inventories):
        base = f"inventories[{index}]"
        validate_object_ref(inventory.get("policy"), f"{base}.policy")
        validate_object_ref(inventory.get("actual"), f"{base}.actual")
        if inventory.get("validator_run_id") not in run_ids:
            raise ValidationError(f"{base} references an unknown validator run")
        if inventory.get("artifact_id") not in artifact_ids:
            raise ValidationError(f"{base} references an unknown artifact")
        for result in ("missing", "unexpected", "mismatched"):
            if inventory.get(result) != []:
                raise ValidationError(
                    f"{base}.{result} must be empty before AM sealing"
                )

    summaries = _require_list(manifest.get("test_summaries"), "test_summaries")
    for index, summary in enumerate(summaries):
        if not isinstance(summary, dict) or summary.get("run_id") not in run_ids:
            raise ValidationError(f"test_summaries[{index}] references an unknown run")
        for count_name in ("passed", "failed", "skipped"):
            count = summary.get(count_name)
            if isinstance(count, bool) or not isinstance(count, int) or count < 0:
                raise ValidationError(
                    f"test_summaries[{index}].{count_name} must be nonnegative"
                )
        if summary["failed"] != 0:
            raise ValidationError(f"test_summaries[{index}] contains failures")
    signatures = _require_list(manifest.get("signatures"), "signatures")
    if not all(isinstance(row, dict) for row in signatures):
        raise ValidationError("signatures entries must be objects")
    _unique_values(signatures, "signature_id", "signatures")
    for index, signature in enumerate(signatures):
        if not isinstance(signature, dict) or signature.get("verified") is not True:
            raise ValidationError(f"signatures[{index}] is not verified")
        if signature.get("artifact_id") not in artifact_ids:
            raise ValidationError(f"signatures[{index}] references an unknown artifact")
        validate_object_ref(signature.get("evidence"), f"signatures[{index}].evidence")
    signature_ids = {signature["signature_id"] for signature in signatures}
    for index, artifact in enumerate(artifacts):
        listed = artifact.get("signature_ids")
        if not isinstance(listed, list) or any(
            value not in signature_ids for value in listed
        ):
            raise ValidationError(
                f"artifacts[{index}].signature_ids contains an unknown signature"
            )

    if store is not None:
        sfm = store.read_json(sfm_ref.id)
        validate_source_freeze_manifest(sfm, policy)
        if sfm.get("release_id") != release_id:
            raise ValidationError("AM release_id differs from referenced SFM")
        events = store.verify_events()
        if not any(
            event["kind"] == "source_freeze_sealed" and event["object_id"] == sfm_ref.id
            for event in events
        ):
            raise ValidationError("referenced SFM was not sealed before the AM")
        for run in runs:
            planned_runs = {plan["run_id"] for plan in sfm["build_plans"]}
            frozen_toolchains = {toolchain["id"] for toolchain in sfm["toolchains"]}
            if run["run_id"] not in planned_runs:
                raise ValidationError(
                    f"run was not declared in the SFM: {run['run_id']}"
                )
            if any(
                toolchain_id not in frozen_toolchains
                for toolchain_id in run["toolchain_ids"]
            ):
                raise ValidationError(
                    f"run references an unknown SFM toolchain: {run['run_id']}"
                )
            for stream in ("stdout", "stderr"):
                reference = run[stream]
                store.verify_ref(
                    {
                        key: reference.get(key)
                        for key in ("id", "sha256", "bytes", "media_type")
                    },
                    f"run {run['run_id']} {stream}",
                )
        for artifact in artifacts:
            store.verify_ref(artifact["object"], f"artifact {artifact['artifact_id']}")
        frozen_policies = {row["object"]["id"] for row in sfm["inventory_policies"]}
        for inventory in inventories:
            if inventory["policy"]["id"] not in frozen_policies:
                raise ValidationError(
                    f"inventory uses a policy not frozen by the SFM: {inventory['inventory_id']}"
                )
            store.verify_ref(
                inventory["policy"], f"inventory {inventory['inventory_id']} policy"
            )
            store.verify_ref(
                inventory["actual"], f"inventory {inventory['inventory_id']} actual"
            )
        frozen_signers = {
            row["certificate_sha256"] for row in sfm["signing_identities"]
        }
        for signature in signatures:
            if signature.get("identity_sha256") not in frozen_signers:
                raise ValidationError(
                    f"signature uses an identity not frozen by the SFM: {signature['signature_id']}"
                )
            store.verify_ref(
                signature["evidence"], f"signature {signature['signature_id']} evidence"
            )
    if policy is not None:
        artifact_policy = validate_policy(dict(policy))["artifact"]
        _require_policy_values(
            artifacts,
            "kind",
            artifact_policy.get("required_artifact_kinds", []),
            "artifact kind",
        )
        _require_policy_values(
            runs, "run_id", artifact_policy.get("required_run_ids", []), "run"
        )
    return manifest


def seal_source_freeze(
    store: ObjectStore,
    manifest: Mapping[str, Any],
    policy: Mapping[str, Any] | None = None,
) -> ObjectRef:
    validated = validate_source_freeze_manifest(dict(manifest), policy)
    _verify_sfm_objects(store, validated)
    reference = store.put_json(validated)
    if any(
        event["kind"] == "source_freeze_sealed"
        and event["release_id"] == validated["release_id"]
        for event in store.verify_events()
    ):
        raise ValidationError(
            f"release already has a sealed SFM: {validated['release_id']}"
        )
    store.append_event("source_freeze_sealed", reference.id, validated["release_id"])
    return reference


def seal_artifact_manifest(
    store: ObjectStore,
    manifest: Mapping[str, Any],
    policy: Mapping[str, Any] | None = None,
) -> ObjectRef:
    validated = validate_artifact_manifest(dict(manifest), store=store, policy=policy)
    if any(
        event["kind"] == "artifact_manifest_sealed"
        and event["release_id"] == validated["release_id"]
        for event in store.verify_events()
    ):
        raise ValidationError(
            f"release already has a sealed AM: {validated['release_id']}"
        )
    reference = store.put_json(validated)
    store.append_event(
        "artifact_manifest_sealed", reference.id, validated["release_id"]
    )
    return reference


def capture_run(
    store: ObjectStore,
    *,
    run_id: str,
    argv: Sequence[str],
    cwd: Path | str,
    environment: Mapping[str, str],
    toolchain_ids: Sequence[str],
    classification: str = "mandatory",
) -> dict[str, Any]:
    """Execute one command while retaining stdout/stderr as opaque bytes."""

    _require_nonempty(run_id, "run_id")
    if not argv or not all(isinstance(argument, str) for argument in argv):
        raise ValidationError("argv must be a nonempty string sequence")
    recorded_environment = _validate_recorded_environment(
        dict(environment), "environment"
    )
    if not toolchain_ids or not all(
        isinstance(item, str) and item for item in toolchain_ids
    ):
        raise ValidationError("toolchain_ids must be nonempty strings")
    root = Path(cwd).resolve()
    if not root.is_dir():
        raise ValidationError(f"run cwd does not exist: {root}")
    _ensure_disjoint(store.root, root, "evidence store and run cwd")
    store._ensure_root()
    stdout_path = store.root / f".stdout.{uuid.uuid4().hex}.tmp"
    stderr_path = store.root / f".stderr.{uuid.uuid4().hex}.tmp"
    started_at = utc_now()
    started_ns = time.monotonic_ns()
    try:
        with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
            completed = subprocess.run(
                list(argv),
                cwd=root,
                env=os.environ | recorded_environment,
                stdout=stdout,
                stderr=stderr,
                check=False,
            )
            stdout.flush()
            stderr.flush()
            os.fsync(stdout.fileno())
            os.fsync(stderr.fileno())
        ended_ns = time.monotonic_ns()
        ended_at = utc_now()
        stdout_ref = store.put_file(stdout_path)
        stderr_ref = store.put_file(stderr_path)
    finally:
        stdout_path.unlink(missing_ok=True)
        stderr_path.unlink(missing_ok=True)
    record = {
        "schema": RUN_SCHEMA,
        "run_id": run_id,
        "classification": classification,
        "argv": list(argv),
        "cwd": str(root),
        "environment": dict(sorted(recorded_environment.items())),
        "toolchain_ids": list(toolchain_ids),
        "started_at_utc": started_at,
        "ended_at_utc": ended_at,
        "monotonic_duration_ns": ended_ns - started_ns,
        "exit_code": completed.returncode,
        "stdout": stdout_ref.as_dict() | {"complete": True},
        "stderr": stderr_ref.as_dict() | {"complete": True},
        "result": "pass" if completed.returncode == 0 else "fail",
    }
    return validate_run_record(record)


def _write_json_output(value: Any, output: str | None) -> None:
    data = canonical_json_bytes(value)
    if output:
        destination = Path(output)
        with destination.open("xb") as stream:
            stream.write(data)
    else:
        sys.stdout.buffer.write(data)


def _load_policy(path: str | None) -> Mapping[str, Any] | None:
    return validate_policy(load_json_file(path)) if path else None


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_sfm_parser = subparsers.add_parser("validate-sfm")
    validate_sfm_parser.add_argument("manifest")
    validate_sfm_parser.add_argument("--policy")

    validate_am_parser = subparsers.add_parser("validate-am")
    validate_am_parser.add_argument("manifest")
    validate_am_parser.add_argument("--store")
    validate_am_parser.add_argument("--policy")

    seal_sfm_parser = subparsers.add_parser("seal-sfm")
    seal_sfm_parser.add_argument("manifest")
    seal_sfm_parser.add_argument("--store", required=True)
    seal_sfm_parser.add_argument("--policy")

    seal_am_parser = subparsers.add_parser("seal-am")
    seal_am_parser.add_argument("manifest")
    seal_am_parser.add_argument("--store", required=True)
    seal_am_parser.add_argument("--policy")

    git_source_parser = subparsers.add_parser("store-git-source")
    git_source_parser.add_argument("repository")
    git_source_parser.add_argument("--commit", required=True)
    git_source_parser.add_argument("--name", required=True)
    git_source_parser.add_argument("--prefix", required=True)
    git_source_parser.add_argument("--store", required=True)
    git_source_parser.add_argument("--output")

    verify_parser = subparsers.add_parser("verify-store")
    verify_parser.add_argument("store")

    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "validate-sfm":
            validate_source_freeze_manifest(
                load_json_file(arguments.manifest), _load_policy(arguments.policy)
            )
        elif arguments.command == "validate-am":
            store = ObjectStore(arguments.store) if arguments.store else None
            validate_artifact_manifest(
                load_json_file(arguments.manifest),
                store=store,
                policy=_load_policy(arguments.policy),
            )
        elif arguments.command == "seal-sfm":
            reference = seal_source_freeze(
                ObjectStore(arguments.store),
                load_json_file(arguments.manifest),
                _load_policy(arguments.policy),
            )
            _write_json_output(reference.as_dict(), None)
        elif arguments.command == "seal-am":
            reference = seal_artifact_manifest(
                ObjectStore(arguments.store),
                load_json_file(arguments.manifest),
                _load_policy(arguments.policy),
            )
            _write_json_output(reference.as_dict(), None)
        elif arguments.command == "store-git-source":
            result = store_git_source(
                ObjectStore(arguments.store),
                arguments.repository,
                arguments.commit,
                arguments.name,
                arguments.prefix,
            )
            _write_json_output(result, arguments.output)
        elif arguments.command == "verify-store":
            store = ObjectStore(arguments.store)
            events = store.verify_events()
            for object_path in store.objects.glob("*/*"):
                if object_path.is_file():
                    store.read_bytes(f"sha256:{object_path.name}")
            _write_json_output({"events": len(events), "status": "pass"}, None)
    except (OSError, ProvenanceError) as error:
        print(f"FAIL provenance: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
