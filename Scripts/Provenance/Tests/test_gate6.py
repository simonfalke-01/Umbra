from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROVENANCE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROVENANCE_ROOT))

import gate6  # noqa: E402


FIXED_TIME = "2026-08-26T00:00:00.000000Z"


def run(*argv: str, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        list(argv),
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


def init_pushed_repo(root: Path, name: str) -> tuple[Path, Path]:
    repository = root / name
    remote = root / f"{name}.git"
    repository.mkdir()
    run("git", "init", "-b", "main", cwd=repository)
    run("git", "config", "user.name", "Provenance Test", cwd=repository)
    run("git", "config", "user.email", "provenance@example.invalid", cwd=repository)
    (repository / "tracked.txt").write_text(f"{name}\n", encoding="utf-8")
    executable = repository / "executable.sh"
    executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    executable.chmod(0o755)
    try:
        (repository / "tracked-link").symlink_to("tracked.txt")
    except OSError:
        pass
    run("git", "add", "-A", cwd=repository)
    run("git", "commit", "-m", "initial", cwd=repository)
    run("git", "init", "--bare", str(remote))
    run("git", "remote", "add", "origin", str(remote), cwd=repository)
    run("git", "push", "-u", "origin", "main", cwd=repository)
    return repository, remote


def object_ref(
    store: gate6.ObjectStore,
    data: bytes = b"data",
    media_type: str = "application/octet-stream",
) -> dict:
    return store.put_bytes(data, media_type).as_dict()


def tree_ref(
    store: gate6.ObjectStore,
    *,
    name: str,
    commit: str,
    tree: str,
    prefix: str,
    rows: list[dict] | None = None,
) -> dict:
    rows = rows or [
        {
            "path": "tracked.txt",
            "mode": "100644",
            "type": "blob",
            "blob_oid": "c" * 40,
            "sha256": gate6.sha256_bytes(b"tracked\n"),
            "bytes": len(b"tracked\n"),
        }
    ]
    manifest = {
        "schema": gate6.TREE_SCHEMA,
        "repository": name,
        "commit": commit,
        "tree": tree,
        "prefix": prefix,
        "rows": rows,
    }
    return store.put_json(manifest).as_dict()


def minimal_policy() -> dict:
    return {
        "schema": gate6.POLICY_SCHEMA,
        "source_freeze": {
            "required_repositories": ["Umbra", "Lumen"],
            "required_vector_ids": ["quic-v3"],
            "required_toolchain_ids": ["test-tool"],
            "required_signing_purposes": ["umbra-app"],
        },
        "artifact": {
            "required_artifact_kinds": ["umbra-app-tree"],
            "required_run_ids": ["test-run"],
        },
    }


def minimal_sfm(store: gate6.ObjectStore, release_id: str = "release-test") -> dict:
    status = object_ref(store, b"", "application/x-git-status-porcelain-v2")
    repositories = []
    for name, commit_char, tree_char, prefix in (
        ("Umbra", "a", "b", "Umbra/"),
        ("Lumen", "d", "e", "Lumen/"),
    ):
        commit = commit_char * 40
        tree = tree_char * 40
        archive = object_ref(store, f"archive-{name}".encode(), "application/x-tar") | {
            "format": "git-archive-tar",
            "prefix": prefix,
        }
        repositories.append(
            {
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
                "status_evidence": status,
                "archive": archive,
                "tree_manifest": tree_ref(
                    store,
                    name=name,
                    commit=commit,
                    tree=tree,
                    prefix=prefix,
                ),
                "submodules": [],
            }
        )
    vector_hash = gate6.sha256_bytes(b"vector")
    tool = object_ref(store, b"tool")
    version = object_ref(store, b"tool 1\n", "text/plain")
    return {
        "schema": gate6.SFM_SCHEMA,
        "kind": "source_freeze",
        "release_id": release_id,
        "created_at_utc": FIXED_TIME,
        "digest_algorithm": "sha256",
        "repositories": repositories,
        "protocol_vectors": [
            {
                "id": "quic-v3",
                "schema": "umbra-lumen-quic-v3-vectors/1",
                "byte_identical": True,
                "producer": {
                    "repository": "Lumen",
                    "commit": "d" * 40,
                    "path": "docs/protocols/vectors/quic.json",
                    "sha256": vector_hash,
                },
                "consumers": [
                    {
                        "repository": "Umbra",
                        "commit": "a" * 40,
                        "path": "Tests/Fixtures/quic.json",
                        "sha256": vector_hash,
                    }
                ],
                "generator": {
                    "argv": ["python3", "generate.py"],
                    "source_sha256": gate6.sha256_bytes(b"generator"),
                },
            }
        ],
        "source_inputs": [
            {"id": "locked-input", "object": object_ref(store, b"input")}
        ],
        "toolchains": [
            {
                "id": "test-tool",
                "host": "disposable",
                "os": "test",
                "architecture": "arm64",
                "executable": tool,
                "version_argv": ["tool", "--version"],
                "version_stdout": version,
                "version": "1",
            }
        ],
        "signing_identities": [
            {
                "purpose": "umbra-app",
                "certificate_sha256": gate6.sha256_bytes(b"certificate"),
                "subject": "Developer ID Application: Test",
                "issuer": "Test CA",
                "serial": "01",
                "not_before_utc": FIXED_TIME,
                "not_after_utc": "2027-08-26T00:00:00.000000Z",
                "policy": "developer-id-application",
            }
        ],
        "build_plans": [
            {
                "run_id": "test-run",
                "repository": "Umbra",
                "target": "tests",
                "configuration": "release",
                "architecture": "arm64",
                "argv": ["python3", "-m", "unittest"],
                "cwd": "Umbra",
                "environment": {"SDKROOT": "/sdk"},
                "input_ids": ["locked-input"],
            }
        ],
        "inventory_policies": [
            {
                "id": "umbra-inventory",
                "source_path": "Scripts/Provenance/policies/inventory.json",
                "object": object_ref(store, b"inventory-policy", "application/json"),
            }
        ],
    }


def passing_run(store: gate6.ObjectStore) -> dict:
    return {
        "schema": gate6.RUN_SCHEMA,
        "run_id": "test-run",
        "classification": "mandatory",
        "argv": ["test", "--all"],
        "cwd": "/frozen/Umbra",
        "environment": {"SDKROOT": "/sdk"},
        "toolchain_ids": ["test-tool"],
        "started_at_utc": FIXED_TIME,
        "ended_at_utc": "2026-08-26T00:00:01.000000Z",
        "monotonic_duration_ns": 1_000_000_000,
        "exit_code": 0,
        "stdout": object_ref(store, b"PASS\n") | {"complete": True},
        "stderr": object_ref(store, b"") | {"complete": True},
        "result": "pass",
    }


def minimal_am(
    store: gate6.ObjectStore, sfm_ref: gate6.ObjectRef, release_id: str = "release-test"
) -> dict:
    run_record = passing_run(store)
    artifact = object_ref(store, b"app-tree")
    inventory_policy = object_ref(store, b"inventory-policy")
    inventory_actual = object_ref(store, b"inventory-actual")
    signature_evidence = object_ref(store, b"signature-pass\n", "text/plain")
    return {
        "schema": gate6.AM_SCHEMA,
        "kind": "artifact",
        "release_id": release_id,
        "created_at_utc": "2026-08-26T00:00:02.000000Z",
        "source_freeze": sfm_ref.as_dict(),
        "runs": [run_record],
        "artifacts": [
            {
                "artifact_id": "umbra-tree",
                "kind": "umbra-app-tree",
                "path": "artifacts/Umbra.app.tree.json",
                "object": artifact,
                "producer_run_id": "test-run",
                "architecture": "arm64",
                "format": "canonical-tree-manifest",
                "signature_ids": ["umbra-signature"],
                "source_refs": ["repository:Umbra"],
            }
        ],
        "inventories": [
            {
                "inventory_id": "umbra-app-inventory",
                "artifact_id": "umbra-tree",
                "policy": inventory_policy,
                "actual": inventory_actual,
                "validator_run_id": "test-run",
                "missing": [],
                "unexpected": [],
                "mismatched": [],
            }
        ],
        "test_summaries": [
            {"run_id": "test-run", "passed": 1, "failed": 0, "skipped": 0}
        ],
        "signatures": [
            {
                "signature_id": "umbra-signature",
                "artifact_id": "umbra-tree",
                "verified": True,
                "identity_sha256": gate6.sha256_bytes(b"certificate"),
                "evidence": signature_evidence,
            }
        ],
    }


class CanonicalStoreTests(unittest.TestCase):
    def test_canonical_json_is_stable_and_integer_only(self) -> None:
        self.assertEqual(
            gate6.canonical_json_bytes({"z": 1, "a": "é"}), b'{"a":"\xc3\xa9","z":1}\n'
        )
        with self.assertRaisesRegex(gate6.ValidationError, "floating-point"):
            gate6.canonical_json_bytes({"bad": 1.5})
        with self.assertRaisesRegex(gate6.ValidationError, "duplicate JSON key"):
            gate6.load_json_bytes(b'{"a":1,"a":2}\n')

    def test_object_store_is_idempotent_and_detects_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            first = store.put_bytes(b"opaque\x00\xff")
            second = store.put_bytes(b"opaque\x00\xff")
            self.assertEqual(first, second)
            path = store.object_path(first.id)
            path.chmod(0o644)
            path.write_bytes(b"corrupt")
            with self.assertRaises(gate6.StoreCorruptionError):
                store.read_bytes(first.id)

    def test_event_chain_detects_object_mutation_and_truncation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            subject = store.put_bytes(b"subject")
            event = store.append_event("test", subject.id, "release")
            self.assertEqual(len(store.verify_events()), 1)
            event_path = store.object_path(event.id)
            event_path.chmod(0o644)
            event_path.write_bytes(b"mutated\n")
            with self.assertRaises(gate6.StoreCorruptionError):
                store.verify_events()

        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            subject = store.put_bytes(b"subject")
            store.append_event("test", subject.id, "release")
            with store.events.open("ab") as stream:
                stream.write(b'{"event_object":"partial"}')
            with self.assertRaisesRegex(gate6.StoreCorruptionError, "truncated"):
                store.verify_events()


class TreeAndGitTests(unittest.TestCase):
    def test_paths_case_modes_and_symlinks_fail_closed(self) -> None:
        base = {
            "path": "bin/tool",
            "mode": "100644",
            "type": "blob",
            "blob_oid": "a" * 40,
            "sha256": "b" * 64,
            "bytes": 1,
        }
        with self.assertRaisesRegex(gate6.ValidationError, "unsafe"):
            gate6.validate_tree_rows([base | {"path": "../tool"}])
        with self.assertRaisesRegex(gate6.ValidationError, "case-colliding"):
            gate6.validate_tree_rows(
                [base, base | {"path": "Bin/Tool", "blob_oid": "c" * 40}]
            )
        with self.assertRaisesRegex(gate6.ValidationError, "unsupported Git mode"):
            gate6.validate_tree_rows([base | {"mode": "100664"}])
        symlink = base | {
            "path": "link",
            "mode": "120000",
            "symlink_target": "../../outside",
        }
        with self.assertRaisesRegex(gate6.ValidationError, "escaping symlink"):
            gate6.validate_tree_rows([symlink])

    def test_git_archive_and_tree_manifest_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, _ = init_pushed_repo(root, "source")
            commit = run("git", "rev-parse", "HEAD", cwd=repository)
            first_store = gate6.ObjectStore(root / "store-one")
            second_store = gate6.ObjectStore(root / "store-two")
            first = gate6.store_git_source(
                first_store, repository, commit, "Source", "Source/"
            )
            second = gate6.store_git_source(
                second_store, repository, commit, "Source", "Source/"
            )
            self.assertEqual(first["archive"]["id"], second["archive"]["id"])
            self.assertEqual(
                first["tree_manifest"]["id"], second["tree_manifest"]["id"]
            )
            manifest = first_store.read_json(first["tree_manifest"]["id"])
            modes = {row["mode"] for row in manifest["rows"]}
            self.assertIn("100755", modes)
            if (repository / "tracked-link").is_symlink():
                self.assertIn("120000", modes)
            with self.assertRaisesRegex(gate6.ValidationError, "must be disjoint"):
                gate6.store_git_source(
                    gate6.ObjectStore(repository / "evidence"),
                    repository,
                    commit,
                    "Source",
                    "Source/",
                )

    def test_dirty_and_unpushed_repository_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, _ = init_pushed_repo(root, "source")
            store = gate6.ObjectStore(root / "store")
            metadata = gate6.inspect_git_repository(repository, store=store)
            self.assertTrue(metadata["clean"])
            self.assertTrue(metadata["pushed"])
            store.verify_ref(metadata["status_evidence"])

            (repository / "tracked.txt").write_text(
                "post-freeze mutation\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(gate6.ValidationError, "changes"):
                gate6.inspect_git_repository(repository)
            run("git", "checkout", "--", "tracked.txt", cwd=repository)
            (repository / "second.txt").write_text("unpublished\n", encoding="utf-8")
            run("git", "add", "second.txt", cwd=repository)
            run("git", "commit", "-m", "unpushed", cwd=repository)
            with self.assertRaisesRegex(gate6.ValidationError, "not equal"):
                gate6.inspect_git_repository(repository)

    def test_uninitialized_and_unreachable_submodules_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child, child_remote = init_pushed_repo(root, "child")
            parent, parent_remote = init_pushed_repo(root, "parent")
            run(
                "git",
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "add",
                str(child_remote),
                "deps/child",
                cwd=parent,
            )
            run("git", "commit", "-am", "add submodule", cwd=parent)
            run("git", "push", cwd=parent)

            clone = root / "parent-clone"
            run(
                "git",
                "clone",
                "--no-recurse-submodules",
                str(parent_remote),
                str(clone),
            )
            with self.assertRaisesRegex(gate6.ValidationError, "uninitialized"):
                gate6.inspect_git_repository(clone)

            run(
                "git",
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "update",
                "--init",
                "--recursive",
                cwd=parent,
            )
            submodule = parent / "deps/child"
            run("git", "config", "user.name", "Provenance Test", cwd=submodule)
            run(
                "git",
                "config",
                "user.email",
                "provenance@example.invalid",
                cwd=submodule,
            )
            (submodule / "local-only.txt").write_text("not pushed\n", encoding="utf-8")
            run("git", "add", "local-only.txt", cwd=submodule)
            run("git", "commit", "-m", "local child", cwd=submodule)
            run("git", "add", "deps/child", cwd=parent)
            run("git", "commit", "-m", "pin local child", cwd=parent)
            run("git", "push", cwd=parent)
            with self.assertRaisesRegex(
                gate6.ValidationError, "no fetched remote-containing ref"
            ):
                gate6.inspect_git_repository(parent)


class ManifestTests(unittest.TestCase):
    def test_sfm_and_am_seal_in_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            policy = minimal_policy()
            sfm_ref = gate6.seal_source_freeze(store, minimal_sfm(store), policy)
            am_ref = gate6.seal_artifact_manifest(
                store, minimal_am(store, sfm_ref), policy
            )
            events = store.verify_events()
            self.assertEqual(
                [event["kind"] for event in events],
                ["source_freeze_sealed", "artifact_manifest_sealed"],
            )
            self.assertEqual(events[-1]["object_id"], am_ref.id)
            with self.assertRaisesRegex(
                gate6.ValidationError, "already has a sealed AM"
            ):
                gate6.seal_artifact_manifest(store, minimal_am(store, sfm_ref), policy)

    def test_am_before_sfm_and_wrong_release_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            sfm = minimal_sfm(store)
            unsealed = store.put_json(sfm)
            with self.assertRaisesRegex(gate6.ValidationError, "not sealed before"):
                gate6.validate_artifact_manifest(
                    minimal_am(store, unsealed), store=store
                )
            sealed = gate6.seal_source_freeze(store, sfm, minimal_policy())
            with self.assertRaisesRegex(gate6.ValidationError, "release_id differs"):
                gate6.validate_artifact_manifest(
                    minimal_am(store, sealed, "other-release"), store=store
                )

    def test_sfm_rejects_submodule_vector_tool_and_policy_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            policy = minimal_policy()
            sfm = minimal_sfm(store)

            changed = copy.deepcopy(sfm)
            changed["repositories"][0]["submodules"] = [
                {
                    "path": "third-party/dependency",
                    "url": "https://example.invalid/dependency.git",
                    "gitlink_commit": "1" * 40,
                    "checked_out_commit": "2" * 40,
                    "clean": True,
                    "remote_reachable": True,
                    "archive": object_ref(store)
                    | {"format": "git-archive-tar", "prefix": "dependency/"},
                    "tree_manifest": tree_ref(
                        store,
                        name="dependency",
                        commit="1" * 40,
                        tree="2" * 40,
                        prefix="dependency/",
                    ),
                }
            ]
            with self.assertRaisesRegex(gate6.ValidationError, "differs from gitlink"):
                gate6.validate_source_freeze_manifest(changed, policy)

            changed = copy.deepcopy(sfm)
            changed["protocol_vectors"][0]["consumers"][0]["sha256"] = "0" * 64
            with self.assertRaisesRegex(gate6.ValidationError, "byte hash mismatch"):
                gate6.validate_source_freeze_manifest(changed, policy)

            changed = copy.deepcopy(sfm)
            changed["toolchains"][0]["version"] = "unknown"
            with self.assertRaisesRegex(gate6.ValidationError, "placeholder"):
                gate6.validate_source_freeze_manifest(changed, policy)

            changed = copy.deepcopy(sfm)
            changed["protocol_vectors"][0]["id"] = "different-vector"
            with self.assertRaisesRegex(
                gate6.ValidationError, "missing required protocol vector"
            ):
                gate6.validate_source_freeze_manifest(changed, policy)

    def test_sfm_rejects_missing_objects_and_tree_submodule_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            sfm = minimal_sfm(store)
            missing = copy.deepcopy(sfm)
            missing["toolchains"][0]["executable"] = {
                "id": "sha256:" + "0" * 64,
                "sha256": "0" * 64,
                "bytes": 1,
                "media_type": "application/octet-stream",
            }
            with self.assertRaisesRegex(gate6.ValidationError, "object is missing"):
                gate6.seal_source_freeze(store, missing, minimal_policy())

            mismatch = copy.deepcopy(sfm)
            mismatch["repositories"][0]["submodules"] = [
                {
                    "path": "dependency",
                    "url": "https://example.invalid/dependency.git",
                    "gitlink_commit": "1" * 40,
                    "checked_out_commit": "1" * 40,
                    "clean": True,
                    "remote_reachable": True,
                    "archive": object_ref(store)
                    | {"format": "git-archive-tar", "prefix": "dependency/"},
                    "tree_manifest": tree_ref(
                        store,
                        name="dependency",
                        commit="1" * 40,
                        tree="2" * 40,
                        prefix="dependency/",
                    ),
                }
            ]
            with self.assertRaisesRegex(gate6.ValidationError, "submodule map differs"):
                gate6.seal_source_freeze(store, mismatch, minimal_policy())

    def test_run_evidence_is_binary_safe_and_rejects_secrets_or_incomplete_streams(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cwd = root / "cwd"
            cwd.mkdir()
            store = gate6.ObjectStore(root / "store")
            record = gate6.capture_run(
                store,
                run_id="binary-run",
                argv=[
                    sys.executable,
                    "-c",
                    "import os; os.write(1,b'\\xff\\x00'); os.write(2,b'\\xfe')",
                ],
                cwd=cwd,
                environment={"TEST_MODE": "1"},
                toolchain_ids=["python"],
            )
            self.assertEqual(store.read_bytes(record["stdout"]["id"]), b"\xff\x00")
            self.assertEqual(store.read_bytes(record["stderr"]["id"]), b"\xfe")

            secret = copy.deepcopy(record)
            secret["environment"] = {"API_TOKEN": "forbidden"}
            with self.assertRaisesRegex(gate6.ValidationError, "secret-bearing"):
                gate6.validate_run_record(secret)
            incomplete = copy.deepcopy(record)
            incomplete["stdout"]["complete"] = False
            with self.assertRaisesRegex(gate6.ValidationError, "complete"):
                gate6.validate_run_record(incomplete)

    def test_am_rejects_failed_run_inventory_signature_and_object_swap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            sfm_ref = gate6.seal_source_freeze(
                store, minimal_sfm(store), minimal_policy()
            )
            am = minimal_am(store, sfm_ref)

            failed = copy.deepcopy(am)
            failed["runs"][0]["exit_code"] = 1
            failed["runs"][0]["result"] = "fail"
            with self.assertRaisesRegex(gate6.ValidationError, "mandatory run failed"):
                gate6.validate_artifact_manifest(failed, store=store)

            inventory = copy.deepcopy(am)
            inventory["inventories"][0]["unexpected"] = ["foreign.dll"]
            with self.assertRaisesRegex(gate6.ValidationError, "must be empty"):
                gate6.validate_artifact_manifest(inventory, store=store)

            signature = copy.deepcopy(am)
            signature["signatures"][0]["verified"] = False
            with self.assertRaisesRegex(gate6.ValidationError, "not verified"):
                gate6.validate_artifact_manifest(signature, store=store)

            swapped = copy.deepcopy(am)
            swapped["artifacts"][0]["object"] = {
                "id": "sha256:" + "f" * 64,
                "sha256": "f" * 64,
                "bytes": 1,
                "media_type": "application/octet-stream",
            }
            with self.assertRaisesRegex(gate6.ValidationError, "object is missing"):
                gate6.validate_artifact_manifest(swapped, store=store)

    def test_manifest_paths_case_collisions_and_failed_tests_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = gate6.ObjectStore(temporary)
            sfm_ref = gate6.seal_source_freeze(
                store, minimal_sfm(store), minimal_policy()
            )
            am = minimal_am(store, sfm_ref)
            duplicate = copy.deepcopy(am)
            duplicate["artifacts"].append(
                duplicate["artifacts"][0]
                | {
                    "artifact_id": "other",
                    "path": "Artifacts/umbra.APP.tree.json",
                }
            )
            with self.assertRaisesRegex(gate6.ValidationError, "case-colliding"):
                gate6.validate_artifact_manifest(duplicate, store=store)
            failed = copy.deepcopy(am)
            failed["test_summaries"][0]["failed"] = 1
            with self.assertRaisesRegex(gate6.ValidationError, "contains failures"):
                gate6.validate_artifact_manifest(failed, store=store)

    def test_schema_and_policy_documents_are_valid_json(self) -> None:
        for path in sorted(PROVENANCE_ROOT.rglob("*.json")):
            with self.subTest(path=path):
                parsed = json.loads(path.read_text(encoding="utf-8"))
                self.assertIsInstance(parsed, dict)


if __name__ == "__main__":
    unittest.main()
