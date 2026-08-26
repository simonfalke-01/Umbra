# Gate 6 provenance core

`gate6.py` is the source-local trust core for the Umbra/Lumen Gate 6 release
chain. It uses only Python's standard library and does not build, package,
install, push, or contact a remote.

The release driver must first commit and push both repositories, fetch the
approved refs, initialize every recursive submodule, and verify clean state.
It then stores deterministic `git archive` tar files and canonical tree
manifests in an evidence root outside both source/build trees. The immutable
Source Freeze Manifest (SFM) is sealed before any qualifying build. A later
Artifact Manifest (AM) may reference that SFM only after all mandatory runs,
inventories, hashes, and signature checks pass.

Every frozen `build_plans[].run_id` must appear exactly once in the AM, no
additional run is admitted, and each run's mandatory or capability-conditional
classification must match the SFM. AM validation therefore always requires the
object store that contains the sealed SFM; structural validation without the
frozen plan set is intentionally rejected.
Capability-conditional plans still require a passing evidence run: that run
proves either the supported path or the explicit unsupported/degraded path.

Objects live at `objects/sha256/<prefix>/<digest>`. No object is overwritten.
`events.jsonl` is append-only; each line references a separately
content-addressed event object that chains to its predecessor.

Useful commands:

```sh
python3 Scripts/Provenance/gate6.py validate-sfm sfm.json \
  --policy Scripts/Provenance/policies/gate6-policy-v1.json

python3 Scripts/Provenance/gate6.py store-git-source . \
  --commit "$COMMIT" --name Umbra --prefix Umbra/ \
  --store /absolute/external/evidence/root --output source-record.json

python3 Scripts/Provenance/gate6.py seal-sfm sfm.json \
  --store /absolute/external/evidence/root \
  --policy Scripts/Provenance/policies/gate6-policy-v1.json

python3 Scripts/Provenance/gate6.py seal-am am.json \
  --store /absolute/external/evidence/root \
  --policy Scripts/Provenance/policies/gate6-policy-v1.json
```

Never seal a manifest from a dirty, unpushed, detached, partially initialized,
or post-freeze-mutated source tree. Never place the evidence root inside a
repository or generated build directory.
