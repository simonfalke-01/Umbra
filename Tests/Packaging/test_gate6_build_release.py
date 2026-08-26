from __future__ import annotations

import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PROVENANCE_ROOT = REPOSITORY_ROOT / "Scripts" / "Provenance"
sys.path.insert(0, str(PROVENANCE_ROOT))
import gate6  # noqa: E402


FIXED_TIME = "2026-08-26T00:00:00.000000Z"
IDENTITY = "Developer ID Application: Umbra Test (ABCDE12345)"
CERTIFICATE_SHA256 = hashlib.sha256(b"certificate").hexdigest()
ENTITLEMENTS_SHA256 = hashlib.sha256(
    plistlib.dumps({}, fmt=plistlib.FMT_BINARY, sort_keys=True)
).hexdigest()


def write_executable(path: Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(contents).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def object_ref(
    store: gate6.ObjectStore,
    data: bytes,
    media_type: str = "application/octet-stream",
) -> dict:
    return store.put_bytes(data, media_type).as_dict()


class Gate6BuildReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.frozen = self.root / "frozen"
        self.evidence = self.root / "evidence"
        self.work = self.root / "work"
        self.output = self.root / "output"
        self.fragment = self.evidence / "umbra-fragment.json"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self._create_frozen_fixture()
        self._create_tools()
        self.store = gate6.ObjectStore(self.evidence)
        self.sfm_ref = gate6.seal_source_freeze(self.store, self._source_freeze())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _create_frozen_fixture(self) -> None:
        driver = self.frozen / "Scripts" / "gate6-build-release.sh"
        driver.parent.mkdir(parents=True)
        shutil.copy2(REPOSITORY_ROOT / "Scripts" / "gate6-build-release.sh", driver)
        driver.chmod(0o755)
        provenance = self.frozen / "Scripts" / "Provenance" / "gate6.py"
        provenance.parent.mkdir(parents=True)
        shutil.copy2(PROVENANCE_ROOT / "gate6.py", provenance)
        write_executable(
            self.frozen / "Scripts" / "package-app.sh",
            r"""
            #!/bin/zsh
            set -euo pipefail
            if [[ "${1:-}" == "--validate-only" ]]; then
                [[ "$2" == "$UMBRA_APP_OUTPUT_PATH" ]]
                echo "QUALIFYING_SIGNATURE_IDENTITY_SHA256=$UMBRA_APPROVED_SIGNING_CERTIFICATE_SHA256"
                echo "QUALIFYING_ENTITLEMENTS_SHA256=$UMBRA_APPROVED_ENTITLEMENTS_SHA256"
                echo "QUALIFYING_CODESIGN_DETAILS_BEGIN"
                echo "Authority=$CODE_SIGN_IDENTITY"
                echo "flags=0x10000(runtime)"
                echo "QUALIFYING_CODESIGN_DETAILS_END"
                exit 0
            fi
            [[ "$UMBRA_QUALIFYING_BUILD" == "1" ]]
            app="$UMBRA_APP_OUTPUT_PATH"
            mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
            printf 'signed-arm64-fixture' > "$app/Contents/MacOS/Umbra"
            chmod 755 "$app/Contents/MacOS/Umbra"
            printf 'fixture' > "$app/Contents/Info.plist"
            echo "$app"
            """,
        )

    def _create_tools(self) -> None:
        write_executable(
            self.tools / "swift",
            """
            #!/bin/zsh
            echo "swift fixture: $*"
            exit 0
            """,
        )

    def _tree_manifest(
        self,
        repository: str,
        commit: str,
        tree: str,
        source_root: Path | None = None,
    ) -> dict:
        rows = []
        if source_root is None:
            data = b"lumen"
            rows.append(
                {
                    "path": "tracked.txt",
                    "mode": "100644",
                    "type": "blob",
                    "blob_oid": "c" * 40,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "bytes": len(data),
                }
            )
        else:
            for path in sorted(
                (entry for entry in source_root.rglob("*") if entry.is_file()),
                key=lambda entry: entry.relative_to(source_root).as_posix().encode(),
            ):
                data = path.read_bytes()
                rows.append(
                    {
                        "path": path.relative_to(source_root).as_posix(),
                        "mode": "100755"
                        if path.stat().st_mode & stat.S_IXUSR
                        else "100644",
                        "type": "blob",
                        "blob_oid": hashlib.sha1(data).hexdigest(),  # noqa: S324 - fixture Git id
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "bytes": len(data),
                    }
                )
        return {
            "schema": gate6.TREE_SCHEMA,
            "repository": repository,
            "commit": commit,
            "tree": tree,
            "prefix": f"{repository}/",
            "rows": rows,
        }

    def _repository(self, name: str, commit_char: str, source: Path | None) -> dict:
        commit = commit_char * 40
        tree = chr(ord(commit_char) + 1) * 40
        manifest = self._tree_manifest(name, commit, tree, source)
        return {
            "name": name,
            "remote_url": f"https://example.invalid/{name}.git",
            "commit": commit,
            "tree": tree,
            "branch": "main",
            "upstream_ref": "origin/main",
            "upstream_commit": commit,
            "fetched_at_utc": FIXED_TIME,
            "clean": True,
            "pushed": True,
            "status_evidence": object_ref(
                self.store, b"", "application/x-git-status-porcelain-v2"
            ),
            "archive": object_ref(
                self.store, f"archive-{name}".encode(), "application/x-tar"
            )
            | {"format": "git-archive-tar", "prefix": f"{name}/"},
            "tree_manifest": self.store.put_json(manifest).as_dict(),
            "submodules": [],
        }

    def _source_freeze(self) -> dict:
        package_environment = {
            "PATH": f"{self.tools}:{os.environ['PATH']}",
            "CONFIGURATION": "release",
            "UMBRA_QUALIFYING_BUILD": "1",
            "UMBRA_APP_OUTPUT_PATH": str(self.output / "Umbra.app"),
            "UMBRA_BUILD_SCRATCH_PATH": str(self.work / "package-build"),
            "CODE_SIGN_IDENTITY": IDENTITY,
            "UMBRA_APPROVED_SIGNING_CERTIFICATE_SHA256": CERTIFICATE_SHA256,
            "UMBRA_APPROVED_ENTITLEMENTS_SHA256": ENTITLEMENTS_SHA256,
        }
        build_environment = {"PATH": f"{self.tools}:{os.environ['PATH']}"}
        plans = [
            {
                "run_id": "umbra-debug-build-werror",
                "target": "debug-build",
                "configuration": "debug",
                "argv": [
                    "/usr/bin/env",
                    "-u",
                    "CC",
                    "-u",
                    "CXX",
                    "swift",
                    "build",
                    "-c",
                    "debug",
                    "--scratch-path",
                    str(self.work / "debug-build"),
                    "-Xswiftc",
                    "-warnings-as-errors",
                    "-Xcc",
                    "-Werror",
                    "-Xlinker",
                    "-fatal_warnings",
                ],
                "environment": build_environment,
            },
            {
                "run_id": "umbra-debug-tests-werror",
                "target": "debug-tests",
                "configuration": "debug",
                "argv": [
                    "/usr/bin/env",
                    "-u",
                    "CC",
                    "-u",
                    "CXX",
                    "swift",
                    "test",
                    "-c",
                    "debug",
                    "--scratch-path",
                    str(self.work / "debug-tests"),
                    "-Xswiftc",
                    "-warnings-as-errors",
                    "-Xcc",
                    "-Werror",
                    "-Xlinker",
                    "-fatal_warnings",
                ],
                "environment": build_environment,
            },
            {
                "run_id": "umbra-release-build-werror",
                "target": "release-build",
                "configuration": "release",
                "argv": [
                    "/usr/bin/env",
                    "-u",
                    "CC",
                    "-u",
                    "CXX",
                    "swift",
                    "build",
                    "-c",
                    "release",
                    "--scratch-path",
                    str(self.work / "release-build"),
                    "-Xswiftc",
                    "-warnings-as-errors",
                    "-Xcc",
                    "-Werror",
                    "-Xlinker",
                    "-fatal_warnings",
                ],
                "environment": build_environment,
            },
            {
                "run_id": "umbra-package-release",
                "target": "package",
                "configuration": "release",
                "argv": ["Scripts/package-app.sh"],
                "environment": package_environment,
            },
            {
                "run_id": "umbra-package-validate",
                "target": "package-validate",
                "configuration": "release",
                "argv": [
                    "Scripts/package-app.sh",
                    "--validate-only",
                    str(self.output / "Umbra.app"),
                ],
                "environment": package_environment,
            },
        ]
        for plan in plans:
            plan |= {
                "repository": "Umbra",
                "architecture": "arm64",
                "cwd": "Umbra",
                "input_ids": ["release-input"],
            }
        executable = object_ref(self.store, b"tool")
        version = object_ref(self.store, b"1\n", "text/plain")
        toolchains = [
            {
                "id": identifier,
                "host": "fixture",
                "os": "macOS",
                "architecture": "arm64",
                "executable": executable,
                "version_argv": [identifier, "--version"],
                "version_stdout": version,
                "version": "1",
            }
            for identifier in ("macos-swift", "macos-clang", "macos-codesign")
        ]
        umbra = self._repository("Umbra", "a", self.frozen)
        lumen = self._repository("Lumen", "d", None)
        vector_hash = hashlib.sha256(b"vector").hexdigest()
        return {
            "schema": gate6.SFM_SCHEMA,
            "kind": "source_freeze",
            "release_id": "release-test",
            "created_at_utc": FIXED_TIME,
            "digest_algorithm": "sha256",
            "repositories": [umbra, lumen],
            "protocol_vectors": [
                {
                    "id": "quic-v3",
                    "schema": "vectors/1",
                    "byte_identical": True,
                    "producer": {
                        "repository": "Lumen",
                        "commit": lumen["commit"],
                        "path": "vector.json",
                        "sha256": vector_hash,
                    },
                    "consumers": [
                        {
                            "repository": "Umbra",
                            "commit": umbra["commit"],
                            "path": "vector.json",
                            "sha256": vector_hash,
                        }
                    ],
                    "generator": {
                        "argv": ["python3", "generate.py"],
                        "source_sha256": hashlib.sha256(b"generator").hexdigest(),
                    },
                }
            ],
            "source_inputs": [
                {"id": "release-input", "object": object_ref(self.store, b"input")}
            ],
            "toolchains": toolchains,
            "signing_identities": [
                {
                    "purpose": "umbra-app",
                    "certificate_sha256": CERTIFICATE_SHA256,
                    "subject": IDENTITY,
                    "issuer": "Test CA",
                    "serial": "01",
                    "not_before_utc": FIXED_TIME,
                    "not_after_utc": "2027-08-26T00:00:00.000000Z",
                    "policy": "developer-id-application",
                }
            ],
            "build_plans": plans,
            "inventory_policies": [
                {
                    "id": "umbra-app-inventory",
                    "source_path": "Scripts/package-app.sh",
                    "object": object_ref(self.store, b"inventory", "application/json"),
                }
            ],
        }

    def command(self, **overrides: Path | str) -> list[str]:
        values = {
            "frozen-source": self.frozen,
            "evidence-root": self.evidence,
            "work-root": self.work,
            "output-root": self.output,
            "sfm-object-id": self.sfm_ref.id,
            "release-id": "release-test",
            "code-sign-identity": IDENTITY,
            "certificate-sha256": CERTIFICATE_SHA256,
            "entitlements-sha256": ENTITLEMENTS_SHA256,
            "inventory-policy-id": "umbra-app-inventory",
            "fragment-output": self.fragment,
        } | overrides
        command = [str(self.frozen / "Scripts" / "gate6-build-release.sh")]
        for key, value in values.items():
            command.extend((f"--{key}", str(value)))
        return command

    def run_driver(self, **overrides: Path | str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.command(**overrides),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_builds_from_frozen_plans_and_writes_unsealed_am_fragment(self) -> None:
        completed = self.run_driver()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        fragment = json.loads(self.fragment.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "pass")
        self.assertEqual(len(fragment["runs"]), 5)
        self.assertEqual(
            {artifact["kind"] for artifact in fragment["artifacts"]},
            {"umbra-app-tree", "umbra-app-archive"},
        )
        self.assertTrue(fragment["transport_binding"]["verified"])
        self.assertEqual(
            fragment["signatures"][0]["identity_sha256"], CERTIFICATE_SHA256
        )
        self.assertEqual(
            [event["kind"] for event in self.store.verify_events()],
            ["source_freeze_sealed"],
        )

    def test_mutated_frozen_source_is_rejected_before_build(self) -> None:
        (self.frozen / "Scripts" / "package-app.sh").write_text(
            "#!/bin/zsh\nexit 0\n", encoding="utf-8"
        )
        completed = self.run_driver()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("frozen content mismatch", completed.stderr)
        self.assertFalse(self.work.exists())
        self.assertFalse(self.output.exists())

    def test_overlapping_roots_are_rejected(self) -> None:
        completed = self.run_driver(**{"work-root": self.evidence / "work"})
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("release roots must be disjoint", completed.stderr)


if __name__ == "__main__":
    unittest.main()
