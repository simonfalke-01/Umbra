# CLSPCore Photon mirror

`src/core/`, `src/input_plane/`, `src/media/`, and `src/transport/` are a
source-identical mirror of the portable C++23 LSP core published by Photon.
Photon is canonical; do not edit those headers in Umbra.

Umbra pins Photon through `photon.lock`. The pin records the repository,
immutable commit, and aggregate source digest. Photon remains a build-time
source origin only: Umbra does not use a Git submodule or runtime dependency.

From the Umbra repository root:

```sh
Scripts/sync-lsp-core.sh --check
Scripts/sync-lsp-core.sh --sync
```

Set `PHOTON_REPOSITORY` to a local Photon checkout when it is not available at
the default sibling path `../Photon`. `--check` is offline: it verifies the
lock, local mirror, digest, and a pinned local Photon checkout when present.
`--sync` copies the exact pinned source set from the local checkout. When no
checkout is available, it clones the locked repository and commit into a
validated temporary directory, copies the sources, and removes the temporary
checkout.

SwiftPM runs the offline check before compiling `CLSPCore`.

`include/CLSPCore.h` is Umbra's independently versioned C ABI. It is not part
of the source-identical Photon mirror.
