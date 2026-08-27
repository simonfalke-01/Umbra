# G007 independent Artifact Manifest verification

This checklist is the fail-closed acceptance boundary for the Windows half of
Gate 6 (Ultragoal G007). It is intentionally read-only. The verifier does not
access the Windows host, rebuild artifacts, install packages, mutate services
or devices, or advance Gate 7.

## Frozen identity

All returned evidence must resolve to the following immutable source freeze:

- Shared Source Freeze Manifest (SFM):
  `/Users/brandonli/Documents/Repositories/.umbra-lumen-gate6/20260826T060000Z/source-freeze-manifest-v2.json`
- SFM SHA-256:
  `58b1509d146b926e454d7f60c7fb07ef21e96ae73e653d4d9781be97d5e9c290`
- Lumen commit: `56c0e7ac0fcb95e4075bae48645d3ead2da150fe`
- Simple-Web-Server commit: `6ca4fa8d3ba96bbbc1cf90d9dabb52830b391c0a`
- Expected Lumen build-plan runs: 31, matched case-sensitively by `run_id`

Any different SFM, commit, policy, build-plan set, or package input is a hard
failure. CI overlay evidence may corroborate the result but cannot replace or
alter this frozen identity.

## Required handoff

The host operator must return paths or copied read-only bundles for:

1. `lumen-gate6-artifact-manifest.json` and its complete artifact evidence
   root.
2. `lumen-gate6-assembly-fragment.json` and its complete assembly-fragment
   root.
3. The final full-profile terminal output and its MSI/ZIP paths and SHA-256
   values.
4. Certificate rollback evidence for temporary thumbprint
   `7A294E242689213E368E6532BF18A9B649C9DB28`.
5. Before/after evidence proving the installed application, service, and
   device state did not change during G007.

Paths alone are not evidence if the verifier cannot read the files. A partial
copy, screenshot-only result, or prose summary is insufficient.

## Fail-closed checks

### 1. Shared freeze binding

- Recompute the shared SFM SHA-256 and require the exact value above.
- Validate the SFM with `Scripts/Provenance/gate6.py validate-sfm` and the
  committed Gate 6 policy.
- Require every retained shared-SFM reference in the signed-driver receipt,
  toolchain identities, Lumen artifact manifest, and assembly fragment to
  resolve to the same exact bytes.
- Require the retained Lumen full-profile source freeze, files manifest, and
  source archive to agree on commit, tree, file hashes, and archive hash.

### 2. Exact run set and terminal state

- Extract the 31 Lumen `build_plans[].run_id` values from the shared SFM.
- Require the assembly fragment to contain each ID exactly once, with no
  missing, extra, duplicate, or case-colliding run.
- Require the recorded classification to equal the SFM classification.
- Require every mandatory run to have exit code `0`, result `pass`, complete
  stdout/stderr, and matching stream byte counts and SHA-256 values.
- Require the downstream application build, nonhardware tests, MSI/ZIP
  package, MSI table validation, MSI administrative extraction, and ZIP
  extraction runs to be terminal and passing.
- Retained earlier driver/signature runs are acceptable only when their bytes,
  receipt, and source bindings still validate. A disconnected process or a
  transport failure without a terminal run record is not a pass.

### 3. Artifact Manifest and package inventories

- Run the frozen `validate-gate6-artifact-manifest.ps1` against the returned
  manifest and evidence root using the frozen inventory policy.
- Require schema `lumen-gate6-artifact-manifest/1` and the exact policy hash.
- Require every manifested file to exist with matching bytes and SHA-256; no
  unmanifested file, reparse point, unsafe path, duplicate path, or
  case-colliding path is allowed.
- Require exactly one versioned MSI and one versioned lite ZIP.
- Require the manifest package SHA-256 values to equal the terminal output and
  the independently recomputed file hashes.
- Require complete MSI and ZIP extracted inventories, including required app,
  runtime, shim, license, script, asset, shader, vector, and driver entries.
- Require the lite ZIP to contain no driver payload and no VHID/VMIC tools.
- Require driver-bound rows to match the signed-driver submission manifest and
  signed-return receipt; non-driver rows must not carry a driver binding.

### 4. Assembly-fragment integrity

- Run `Assert-Gate6AssemblyFragment` from the frozen
  `scripts/windows/gate6-evidence.ps1`.
- Require schema `lumen-gate6-assembly-fragment/1` and the exact shared
  assembler contract for `umbra-lumen/artifact-manifest/1`.
- Recompute every referenced fragment file hash and byte count.
- Require the fragment to retain the shared SFM, signed-return receipt, Lumen
  Artifact Manifest, toolchain identities, and record/stdout/stderr for every
  expected run.
- Require no missing, extra, detached, or mutated fragment file.

### 5. Host rollback boundary

These checks are required for G007 closure but do not authorize Gate 7:

- Require explicit no-match results for the temporary certificate thumbprint
  in every certificate store touched by the approved test-signing procedure.
- Require evidence that the corresponding private key is absent after cleanup.
- Compare before/after installed application, service, and device state and
  require exact equality.
- Require evidence of no MSI install, service mutation, device mutation,
  driver-store mutation, or reboot during this resume.

## Independent command shape

```sh
shasum -a 256 "$SFM"
python3 Scripts/Provenance/gate6.py validate-sfm "$SFM" \
  --policy Scripts/Provenance/policies/gate6-policy-v1.json

pwsh -NoLogo -NoProfile -NonInteractive \
  -File /path/to/frozen/Lumen/scripts/windows/validate-gate6-artifact-manifest.ps1 \
  -ManifestPath "$ARTIFACT_MANIFEST" \
  -EvidenceRoot "$ARTIFACT_EVIDENCE"

pwsh -NoLogo -NoProfile -NonInteractive -Command \
  '. /path/to/frozen/Lumen/scripts/windows/gate6-evidence.ps1; \
   Assert-Gate6AssemblyFragment \
     -FragmentRoot $env:ASSEMBLY_ROOT \
     -ManifestPath $env:ASSEMBLY_MANIFEST'
```

The independent verifier must additionally compare the assembly-fragment run
set to the SFM's 31 Lumen build-plan IDs. The fragment validator verifies the
integrity and pass state of retained runs, but this separate comparison proves
coverage of the entire frozen plan set.

## Rejection conditions

Reject G007 if any required bundle is missing, any hash or byte count differs,
the run set is incomplete, a mandatory run lacks a terminal pass record, the
package inventories differ, source or driver bindings are foreign, certificate
residue remains, installed state changed, or a host mutation crossed the Gate
7 boundary. Do not infer a pass from elapsed time, process absence, retained
prerequisite counts, CI status, or operator prose.
