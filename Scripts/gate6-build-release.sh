#!/bin/zsh
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: gate6-build-release.sh \
  --frozen-source ABSOLUTE_PATH \
  --evidence-root ABSOLUTE_PATH \
  --work-root ABSOLUTE_NEW_PATH \
  --output-root ABSOLUTE_NEW_PATH \
  --sfm-object-id sha256:DIGEST \
  --release-id ID \
  --code-sign-identity IDENTITY \
  --certificate-sha256 DIGEST \
  --entitlements-sha256 DIGEST \
  --inventory-policy-id ID \
  --fragment-output ABSOLUTE_NEW_JSON_PATH

The command consumes an already sealed Source Freeze Manifest. It never seals
an SFM or AM, pushes, notarizes, installs, or contacts a target host.
EOF
}

fail() {
    echo "FAIL Gate6 Umbra release: $1" >&2
    exit 1
}

typeset -A arguments
while (( $# > 0 )); do
    case "$1" in
        --frozen-source|--evidence-root|--work-root|--output-root|--sfm-object-id|--release-id|--code-sign-identity|--certificate-sha256|--entitlements-sha256|--inventory-policy-id|--fragment-output)
            (( $# >= 2 )) || fail "missing value for $1"
            arguments[${1#--}]="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
done

for required in \
    frozen-source evidence-root work-root output-root sfm-object-id release-id \
    code-sign-identity certificate-sha256 entitlements-sha256 \
    inventory-policy-id fragment-output; do
    [[ -n "${arguments[$required]:-}" ]] || fail "missing --$required"
done

script_path="${0:A}"
frozen_source="${arguments[frozen-source]:A}"
evidence_root="${arguments[evidence-root]:A}"
work_root="${arguments[work-root]:A}"
output_root="${arguments[output-root]:A}"
fragment_output="${arguments[fragment-output]:A}"
sfm_object_id="${arguments[sfm-object-id]}"
release_id="${arguments[release-id]}"
code_sign_identity="${arguments[code-sign-identity]}"
certificate_sha256="${arguments[certificate-sha256]:l}"
entitlements_sha256="${arguments[entitlements-sha256]:l}"
inventory_policy_id="${arguments[inventory-policy-id]}"
provenance_root="$frozen_source/Scripts/Provenance"
package_script="$frozen_source/Scripts/package-app.sh"
app_root="$output_root/Umbra.app"
archive_path="$output_root/Umbra-$release_id-macos-arm64.zip"

[[ "$script_path" == "$frozen_source/Scripts/gate6-build-release.sh" ]] || {
    fail "the release driver must be executed from the verified frozen source"
}
[[ "$certificate_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid certificate SHA-256"
[[ "$entitlements_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid entitlements SHA-256"
[[ "$code_sign_identity" != "-" ]] || fail "ad-hoc signing is not qualifying"
[[ -d "$frozen_source" && -d "$evidence_root" ]] || fail "frozen source or evidence root is missing"
[[ -f "$provenance_root/gate6.py" && -x "$package_script" ]] || {
    fail "frozen provenance core or package script is missing"
}
[[ ! -e "$work_root" && ! -e "$output_root" && ! -e "$fragment_output" ]] || {
    fail "work, output, and fragment paths must be new"
}

python3 -B - \
    "$provenance_root" "$evidence_root" "$sfm_object_id" "$release_id" \
    "$frozen_source" "$work_root" "$output_root" "$fragment_output" \
    "$certificate_sha256" "$entitlements_sha256" "$code_sign_identity" \
    "$inventory_policy_id" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

provenance_root, evidence_root, sfm_id, release_id = map(str, sys.argv[1:5])
frozen_source, work_root, output_root, fragment_output = map(Path, sys.argv[5:9])
certificate_sha256, entitlements_sha256, code_sign_identity, inventory_policy_id = map(
    str, sys.argv[9:13]
)
sys.path.insert(0, provenance_root)
import gate6  # noqa: E402


def disjoint(first: Path, second: Path) -> bool:
    first = first.resolve()
    second = second.resolve()
    return first != second and first not in second.parents and second not in first.parents


roots = [frozen_source, Path(evidence_root), work_root, output_root]
for index, first in enumerate(roots):
    for second in roots[index + 1 :]:
        if not disjoint(first, second):
            raise gate6.ValidationError(f"release roots must be disjoint: {first} and {second}")
if Path(fragment_output).parent.resolve() != Path(evidence_root).resolve():
    raise gate6.ValidationError("fragment output must be a direct child of evidence root")

store = gate6.ObjectStore(evidence_root)
sfm_bytes = store.read_bytes(sfm_id)
sfm = gate6.load_json_bytes(sfm_bytes)
gate6.validate_source_freeze_manifest(sfm)
if sfm["release_id"] != release_id:
    raise gate6.ValidationError("release id differs from the sealed SFM")
if not any(
    event["kind"] == "source_freeze_sealed" and event["object_id"] == sfm_id
    for event in store.verify_events()
):
    raise gate6.ValidationError("SFM object is not sealed")

repository = next((row for row in sfm["repositories"] if row["name"] == "Umbra"), None)
if repository is None:
    raise gate6.ValidationError("SFM has no Umbra repository")
store.verify_ref(
    {key: repository["archive"][key] for key in ("id", "sha256", "bytes", "media_type")},
    "Umbra source archive",
)
tree_ref = store.verify_ref(repository["tree_manifest"], "Umbra tree manifest")
tree = store.read_json(tree_ref.id)
if (
    tree.get("schema") != gate6.TREE_SCHEMA
    or tree.get("repository") != "Umbra"
    or tree.get("commit") != repository["commit"]
    or tree.get("tree") != repository["tree"]
):
    raise gate6.ValidationError("Umbra tree manifest identity mismatch")
rows = gate6.validate_tree_rows(tree.get("rows"), "Umbra tree rows")

expected_paths = {row["path"] for row in rows if row["mode"] != "160000"}
actual_paths: set[str] = set()
for current, directories, files in os.walk(frozen_source, followlinks=False):
    current_path = Path(current)
    for name in list(directories) + files:
        path = current_path / name
        if path.is_symlink() or path.is_file():
            actual_paths.add(path.relative_to(frozen_source).as_posix())
if actual_paths != expected_paths:
    raise gate6.ValidationError("frozen extraction paths differ from the SFM tree")
for row in rows:
    if row["mode"] == "160000":
        raise gate6.ValidationError("Umbra frozen extraction contains an unsupported gitlink")
    path = frozen_source / row["path"]
    metadata = path.lstat()
    if row["mode"] == "120000":
        target = os.readlink(path)
        data = target.encode()
        if not stat.S_ISLNK(metadata.st_mode) or target != row["symlink_target"]:
            raise gate6.ValidationError(f"frozen symlink mismatch: {row['path']}")
    else:
        if not stat.S_ISREG(metadata.st_mode):
            raise gate6.ValidationError(f"frozen file is not regular: {row['path']}")
        data = path.read_bytes()
        executable = bool(metadata.st_mode & stat.S_IXUSR)
        if executable != (row["mode"] == "100755"):
            raise gate6.ValidationError(f"frozen mode mismatch: {row['path']}")
    if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise gate6.ValidationError(f"frozen content mismatch: {row['path']}")

frozen_signer = next(
    (row for row in sfm["signing_identities"] if row["purpose"] == "umbra-app"),
    None,
)
if frozen_signer is None or frozen_signer["certificate_sha256"] != certificate_sha256:
    raise gate6.ValidationError("requested signer differs from the frozen Umbra identity")
if not any(row["id"] == inventory_policy_id for row in sfm["inventory_policies"]):
    raise gate6.ValidationError("requested inventory policy is not frozen by the SFM")

required_runs = {
    "umbra-debug-build-werror",
    "umbra-debug-tests-werror",
    "umbra-release-build-werror",
    "umbra-package-release",
    "umbra-package-validate",
}
planned = {row["run_id"] for row in sfm["build_plans"] if row["repository"] == "Umbra"}
missing = sorted(required_runs - planned)
if missing:
    raise gate6.ValidationError(f"SFM is missing Umbra release run plans: {missing}")
plans = {row["run_id"]: row for row in sfm["build_plans"] if row["repository"] == "Umbra"}
required_package_environment = {
    "CONFIGURATION": "release",
    "UMBRA_QUALIFYING_BUILD": "1",
    "UMBRA_APP_OUTPUT_PATH": str(output_root / "Umbra.app"),
    "UMBRA_BUILD_SCRATCH_PATH": str(work_root / "package-build"),
    "CODE_SIGN_IDENTITY": code_sign_identity,
    "UMBRA_APPROVED_SIGNING_CERTIFICATE_SHA256": certificate_sha256,
    "UMBRA_APPROVED_ENTITLEMENTS_SHA256": entitlements_sha256,
}
for run_id in ("umbra-package-release", "umbra-package-validate"):
    environment = plans[run_id]["environment"]
    for key, expected in required_package_environment.items():
        if environment.get(key) != expected:
            raise gate6.ValidationError(
                f"{run_id} environment differs from the qualifying contract: {key}"
            )
toolchains = {row["id"] for row in sfm["toolchains"]}
for required in ("macos-swift", "macos-clang", "macos-codesign"):
    if required not in toolchains:
        raise gate6.ValidationError(f"SFM is missing toolchain: {required}")
PY

mkdir -p "$work_root" "$output_root"
typeset -a run_files=()

capture_run() {
    local run_id="$1"
    local toolchain_ids="$2"
    local run_file="$work_root/$run_id.json"
    shift 2
    python3 -B - \
        "$provenance_root" "$evidence_root" "$sfm_object_id" "$run_id" \
        "$toolchain_ids" "$run_file" "$frozen_source" "$@" <<'PY'
import sys
from pathlib import Path

provenance_root, evidence_root, sfm_id, run_id, raw_tools, output, cwd = sys.argv[1:8]
argv = sys.argv[8:]
sys.path.insert(0, provenance_root)
import gate6  # noqa: E402

store = gate6.ObjectStore(evidence_root)
sfm = store.read_json(sfm_id)
plans = [row for row in sfm["build_plans"] if row["run_id"] == run_id]
if len(plans) != 1:
    raise gate6.ValidationError(f"missing or duplicate build plan: {run_id}")
plan = plans[0]
if plan["argv"] != argv:
    raise gate6.ValidationError(
        f"runtime argv differs from frozen plan: {run_id}; planned={plan['argv']!r}; actual={argv!r}"
    )
record = gate6.capture_run(
    store,
    run_id=run_id,
    argv=argv,
    cwd=cwd,
    environment=plan["environment"],
    toolchain_ids=raw_tools.split(","),
)
Path(output).write_bytes(gate6.canonical_json_bytes(record))
if record["result"] != "pass":
    raise SystemExit(record["exit_code"] or 1)
PY
    run_files+=("$run_file")
}

debug_scratch="$work_root/debug-build"
test_scratch="$work_root/debug-tests"
release_scratch="$work_root/release-build"
capture_run umbra-debug-build-werror macos-swift,macos-clang \
    /usr/bin/env -u CC -u CXX swift build -c debug \
    --scratch-path "$debug_scratch" -Xswiftc -warnings-as-errors -Xcc -Werror \
    -Xlinker -fatal_warnings
capture_run umbra-debug-tests-werror macos-swift,macos-clang \
    /usr/bin/env -u CC -u CXX swift test -c debug \
    --scratch-path "$test_scratch" -Xswiftc -warnings-as-errors -Xcc -Werror \
    -Xlinker -fatal_warnings
capture_run umbra-release-build-werror macos-swift,macos-clang \
    /usr/bin/env -u CC -u CXX swift build -c release \
    --scratch-path "$release_scratch" -Xswiftc -warnings-as-errors -Xcc -Werror \
    -Xlinker -fatal_warnings
capture_run umbra-package-release macos-swift,macos-clang,macos-codesign \
    Scripts/package-app.sh
capture_run umbra-package-validate macos-clang,macos-codesign \
    Scripts/package-app.sh --validate-only "$app_root"

python3 -B - \
    "$provenance_root" "$evidence_root" "$sfm_object_id" "$release_id" \
    "$frozen_source" "$output_root" "$app_root" "$archive_path" \
    "$fragment_output" "$certificate_sha256" "$entitlements_sha256" \
    "$inventory_policy_id" "${run_files[@]}" <<'PY'
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import zipfile
from pathlib import Path

(
    provenance_root,
    evidence_root,
    sfm_id,
    release_id,
    frozen_source,
    output_root,
    app_root,
    archive_path,
    fragment_output,
    certificate_sha256,
    entitlements_sha256,
    inventory_policy_id,
    *run_files,
) = sys.argv[1:]
sys.path.insert(0, provenance_root)
import gate6  # noqa: E402

store = gate6.ObjectStore(evidence_root)
sfm_data = store.read_bytes(sfm_id)
sfm = gate6.load_json_bytes(sfm_data)
runs = [gate6.load_json_file(path) for path in run_files]
for run in runs:
    gate6.validate_run_record(run)
validation = next(row for row in runs if row["run_id"] == "umbra-package-validate")
validation_stdout = store.read_bytes(validation["stdout"]["id"])
certificate_match = re.search(rb"^QUALIFYING_SIGNATURE_IDENTITY_SHA256=([0-9a-f]{64})$", validation_stdout, re.M)
entitlements_match = re.search(rb"^QUALIFYING_ENTITLEMENTS_SHA256=([0-9a-f]{64})$", validation_stdout, re.M)
if not certificate_match or certificate_match.group(1).decode() != certificate_sha256:
    raise gate6.ValidationError("qualifying certificate evidence is missing or mismatched")
if not entitlements_match or entitlements_match.group(1).decode() != entitlements_sha256:
    raise gate6.ValidationError("qualifying entitlements evidence is missing or mismatched")

app = Path(app_root)
if not app.is_dir() or app.is_symlink():
    raise gate6.ValidationError("Umbra.app root must be a regular directory")
root_xattrs = subprocess.run(
    ["/usr/bin/xattr", "-l", str(app)],
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
if root_xattrs.returncode != 0 or root_xattrs.stdout:
    raise gate6.ValidationError("Umbra.app root has unbound extended attributes")
rows = []
for current, directories, files in os.walk(app, followlinks=False):
    current_path = Path(current)
    for name in sorted(directories + files, key=lambda item: item.encode()):
        path = current_path / name
        relative = path.relative_to(app.parent).as_posix()
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise gate6.ValidationError(f"app inventory forbids symlink: {relative}")
        xattrs = subprocess.run(
            ["/usr/bin/xattr", "-l", str(path)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if xattrs.returncode != 0:
            raise gate6.ValidationError(f"unable to inventory extended attributes: {relative}")
        if xattrs.stdout:
            raise gate6.ValidationError(f"app inventory forbids unbound extended attributes: {relative}")
        row = {
            "path": relative,
            "kind": "directory" if stat.S_ISDIR(metadata.st_mode) else "file",
            "mode": format(stat.S_IMODE(metadata.st_mode), "04o"),
        }
        if row["kind"] == "file":
            data = path.read_bytes()
            row |= {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        rows.append(row)
rows.sort(key=lambda row: row["path"].encode())
inventory = {
    "schema": "umbra/gate6-app-tree-inventory/1",
    "root": app.name,
    "root_mode": format(stat.S_IMODE(app.stat().st_mode), "04o"),
    "no_symlinks": True,
    "no_extended_attributes": True,
    "rows": rows,
}
inventory_ref = store.put_json(inventory)

archive = Path(archive_path)
with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
    for row in rows:
        name = row["path"] + ("/" if row["kind"] == "directory" else "")
        info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = (int(row["mode"], 8) & 0xFFFF) << 16
        if row["kind"] == "directory":
            info.external_attr |= 0x10
            bundle.writestr(info, b"")
        else:
            bundle.writestr(info, (Path(output_root) / row["path"]).read_bytes())
with zipfile.ZipFile(archive) as bundle:
    expected_names = [row["path"] + ("/" if row["kind"] == "directory" else "") for row in rows]
    if bundle.namelist() != expected_names:
        raise gate6.ValidationError("transport archive inventory differs from app inventory")
    for row in rows:
        info = bundle.getinfo(
            row["path"] + ("/" if row["kind"] == "directory" else "")
        )
        if ((info.external_attr >> 16) & 0o7777) != int(row["mode"], 8):
            raise gate6.ValidationError(f"transport archive mode mismatch: {row['path']}")
        if row["kind"] == "file":
            data = bundle.read(row["path"])
            if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
                raise gate6.ValidationError(f"transport archive content mismatch: {row['path']}")
archive_ref = store.put_file(archive, "application/zip")

repository = next(row for row in sfm["repositories"] if row["name"] == "Umbra")
inventory_policy = next(row for row in sfm["inventory_policies"] if row["id"] == inventory_policy_id)
sfm_ref = {
    "id": sfm_id,
    "sha256": sfm_id.split(":", 1)[1],
    "bytes": len(sfm_data),
    "media_type": "application/json",
}
evidence_ref = {key: validation["stdout"][key] for key in ("id", "sha256", "bytes", "media_type")}
package_run_id = "umbra-package-release"
validate_run_id = "umbra-package-validate"
fragment = {
    "schema": "umbra-lumen/artifact-manifest-fragment/1",
    "kind": "artifact-fragment",
    "release_id": release_id,
    "source_freeze": sfm_ref,
    "repository_commit": repository["commit"],
    "repository_archive_id": repository["archive"]["id"],
    "runs": runs,
    "artifacts": [
        {
            "artifact_id": "umbra-app-tree",
            "kind": "umbra-app-tree",
            "path": "artifacts/Umbra.app.tree.json",
            "object": inventory_ref.as_dict(),
            "producer_run_id": package_run_id,
            "architecture": "arm64",
            "format": "canonical-tree-inventory",
            "signature_ids": ["umbra-app-signature"],
            "source_refs": [sfm_id, repository["archive"]["id"]],
        },
        {
            "artifact_id": "umbra-app-archive",
            "kind": "umbra-app-archive",
            "path": f"artifacts/{archive.name}",
            "object": archive_ref.as_dict(),
            "producer_run_id": package_run_id,
            "architecture": "arm64",
            "format": "deterministic-zip",
            "signature_ids": [],
            "source_refs": [sfm_id, inventory_ref.id],
        },
    ],
    "inventories": [
        {
            "inventory_id": "umbra-app-inventory",
            "artifact_id": "umbra-app-tree",
            "policy": inventory_policy["object"],
            "actual": inventory_ref.as_dict(),
            "validator_run_id": validate_run_id,
            "missing": [],
            "unexpected": [],
            "mismatched": [],
        }
    ],
    "test_summaries": [
        {"run_id": "umbra-debug-tests-werror", "passed": 1, "failed": 0, "skipped": 0}
    ],
    "signatures": [
        {
            "signature_id": "umbra-app-signature",
            "artifact_id": "umbra-app-tree",
            "verified": True,
            "identity_sha256": certificate_sha256,
            "entitlements_sha256": entitlements_sha256,
            "hardened_runtime": True,
            "evidence": evidence_ref,
        }
    ],
    "transport_binding": {
        "archive_artifact_id": "umbra-app-archive",
        "tree_inventory_object_id": inventory_ref.id,
        "verified": True,
    },
}
fragment_bytes = gate6.canonical_json_bytes(fragment)
fragment_ref = store.put_bytes(fragment_bytes, "application/json")
with Path(fragment_output).open("xb") as output:
    output.write(fragment_bytes)
result = {
    "status": "pass",
    "app": str(app),
    "transport_archive": str(archive),
    "fragment_path": fragment_output,
    "fragment_object": fragment_ref.as_dict(),
}
sys.stdout.buffer.write(gate6.canonical_json_bytes(result))
PY
