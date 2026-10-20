#!/usr/bin/env python3
"""Verify the pinned moonlight-common-c tree and Umbra patch reconstruction.

The default verification is fully offline: reverse patches 0004 through 0001
from the vendored tree, check the resulting portable-tree digest, then apply
0001 through 0004 and compare every vendored byte.  ``--source`` adds Git and
submodule identity checks against an existing pristine checkout. ``--fetch``
performs the same stronger check using a temporary GitHub clone.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


MOONLIGHT_COMMON_COMMIT = "874ac9548f1bd6f095ef2b435c42cdde460e7821"
ENET_COMMIT = "aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1"
NANORS_COMMIT = "b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a"
PRISTINE_PORTABLE_DIGEST = "fdd63f02463b1d465e40a24625a7331af15ee475486172f2e023546b867912e0"
PATCHED_PORTABLE_DIGEST = "4faa30a6d7b12afa99e3e24c993c70cb0bc142b72546b312017050d060dd000f"
PATCH_NAMES = (
    "0001-umbra-lumen-client-microphone-rtsp.patch",
    "0002-umbra-video-decode-queue-capacity.patch",
    "0003-umbra-lumen-optimization-mode-rtsp.patch",
    "0004-umbra-lowest-latency-input-fast-lane.patch",
    "0005-umbra-require-real-callbacks.patch",
)
FIXTURE_SOURCE_HASHES = {
    "app/backend/identitymanager.cpp": "81cc5e276635524e65d4cf26887c6052e5e19a2cbb200f68202f2bc26c7e8c52",
    "app/backend/nvhttp.cpp": "3ea8beeee68a38b8f189522275181d2cc9960de55505667c4c0003816ee0ad35",
    "app/backend/nvpairingmanager.cpp": "e0ce6136d0b2133e1fe5282dbe7a262ac7094893572ebe4d9e225c2b9f1de6ae",
    "moonlight-common-c/moonlight-common-c/src/RtspConnection.c": "44cfd110f637c64c1108a10e1c0efbc4dd2c938613979a645a61346d1979e75f",
    "moonlight-common-c/moonlight-common-c/src/SdpGenerator.c": "c0ef395dd701b9f30defc9ae94ba2333c0cf7cdaa7108f7fb1b9300241f1a6aa",
}


def run(*command: str, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


def included_files(root: Path) -> dict[str, Path]:
    files: dict[str, Path] = {}
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if any(component in {".git", ".github"} for component in relative.parts):
            continue
        files[relative.as_posix()] = path
    return files


def portable_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for relative, path in sorted(included_files(root).items()):
        contents = path.read_bytes()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def assert_trees_equal(expected: Path, actual: Path) -> None:
    expected_files = included_files(expected)
    actual_files = included_files(actual)
    if expected_files.keys() != actual_files.keys():
        missing = sorted(expected_files.keys() - actual_files.keys())
        extra = sorted(actual_files.keys() - expected_files.keys())
        raise RuntimeError(f"tree paths differ; missing={missing}, extra={extra}")
    changed = [
        relative
        for relative in expected_files
        if expected_files[relative].read_bytes() != actual_files[relative].read_bytes()
    ]
    if changed:
        raise RuntimeError(f"tree bytes differ: {changed}")


def apply_patch(tree: Path, patch: Path, reverse: bool) -> None:
    command = [
        "git",
        "-C",
        str(tree),
        "apply",
        "--whitespace=nowarn",
    ]
    if reverse:
        command.append("--reverse")
    command.append(str(patch.resolve()))
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        output = (completed.stdout + completed.stderr).decode("utf-8", errors="replace")
        raise RuntimeError(f"failed to {'reverse' if reverse else 'apply'} {patch.name}:\n{output}")


def verify_git_source(source: Path) -> None:
    if run("git", "rev-parse", "HEAD", cwd=source) != MOONLIGHT_COMMON_COMMIT:
        raise RuntimeError("moonlight-common-c checkout is not at the approved commit")
    for relative, expected in (("enet", ENET_COMMIT), ("nanors", NANORS_COMMIT)):
        if run("git", "rev-parse", "HEAD", cwd=source / relative) != expected:
            raise RuntimeError(f"{relative} checkout is not at the approved commit")
    if portable_digest(source) != PRISTINE_PORTABLE_DIGEST:
        raise RuntimeError("approved Git checkout does not match the locked portable-tree digest")


def fetch_source(destination: Path) -> Path:
    source = destination / "moonlight-common-c"
    run(
        "git",
        "clone",
        "--quiet",
        "--filter=blob:none",
        "--no-checkout",
        "https://github.com/moonlight-stream/moonlight-common-c.git",
        str(source),
    )
    run("git", "checkout", "--quiet", MOONLIGHT_COMMON_COMMIT, cwd=source)
    run("git", "submodule", "update", "--init", "--recursive", "--depth", "1", cwd=source)
    return source


def verify_fixture(fixture_path: Path) -> None:
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    provenance = fixture["provenance"]
    if provenance.get("moonlightQtCommit") != "d2f6990be699197385a6458e1231d070da83e665":
        raise RuntimeError("fixture Moonlight Qt commit drifted")
    if provenance.get("moonlightCommonCommit") != MOONLIGHT_COMMON_COMMIT:
        raise RuntimeError("fixture moonlight-common-c commit drifted")
    if provenance.get("generator") != "moonlight-qt-source-derived-v1":
        raise RuntimeError("fixture generator identity drifted")
    if provenance.get("lineEndings") != "CRLF":
        raise RuntimeError("fixture RTSP line-ending contract drifted")
    if provenance.get("sourceFiles") != FIXTURE_SOURCE_HASHES:
        raise RuntimeError("fixture upstream source hashes drifted")
    if fixture.get("rtsp", {}).get("playTarget") != "/":
        raise RuntimeError("fixture Gen 7 PLAY target drifted")


def verify(vendor: Path, source: Path | None) -> None:
    upstream = vendor / "Upstream"
    patches_directory = vendor / "Patches"
    actual_patch_names = tuple(path.name for path in sorted(patches_directory.glob("*.patch")))
    if actual_patch_names != PATCH_NAMES:
        raise RuntimeError(f"unexpected patch series: {actual_patch_names}")
    patches = [patches_directory / name for name in PATCH_NAMES]

    if portable_digest(upstream) != PATCHED_PORTABLE_DIGEST:
        raise RuntimeError("vendored patched tree does not match the locked portable-tree digest")

    with tempfile.TemporaryDirectory(prefix="umbra-moonlight-provenance-") as temporary:
        reconstructed = Path(temporary) / "reconstructed"
        shutil.copytree(upstream, reconstructed)
        for patch in reversed(patches):
            apply_patch(reconstructed, patch, reverse=True)
        if portable_digest(reconstructed) != PRISTINE_PORTABLE_DIGEST:
            raise RuntimeError("reverse patch series does not reconstruct the approved pristine tree")
        for relative in ("src/RtspConnection.c", "src/SdpGenerator.c"):
            fixture_relative = f"moonlight-common-c/moonlight-common-c/{relative}"
            source_digest = hashlib.sha256((reconstructed / relative).read_bytes()).hexdigest()
            if source_digest != FIXTURE_SOURCE_HASHES[fixture_relative]:
                raise RuntimeError(f"reconstructed {relative} drifted from the fixture source hash")
        if source is not None:
            verify_git_source(source)
            assert_trees_equal(source, reconstructed)
        for patch in patches:
            apply_patch(reconstructed, patch, reverse=False)
        if portable_digest(reconstructed) != PATCHED_PORTABLE_DIGEST:
            raise RuntimeError("forward patch series does not reconstruct the approved patched tree")
        assert_trees_equal(upstream, reconstructed)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--vendor",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Vendor/MoonlightCommon directory",
    )
    source_group = parser.add_mutually_exclusive_group()
    source_group.add_argument("--source", type=Path, help="existing pristine moonlight-common-c checkout")
    source_group.add_argument("--fetch", action="store_true", help="fetch the approved checkout into a temporary directory")
    parser.add_argument("--fixture", type=Path, help="optional Lumen compatibility fixture to verify offline")
    arguments = parser.parse_args()

    try:
        if arguments.fixture:
            verify_fixture(arguments.fixture.resolve())
        if arguments.fetch:
            with tempfile.TemporaryDirectory(prefix="umbra-moonlight-source-") as temporary:
                verify(arguments.vendor.resolve(), fetch_source(Path(temporary)))
        else:
            verify(arguments.vendor.resolve(), arguments.source.resolve() if arguments.source else None)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"FAIL moonlight-common-c provenance: {error}", file=sys.stderr)
        return 1

    print("PASS moonlight-common-c provenance and patch reconstruction")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
