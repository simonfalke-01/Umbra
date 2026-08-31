# CLSPCore mirror

`src/core/`, `src/input_plane/`, `src/media/`, and `src/transport/` are a
source-identical mirror of Lumen's portable C++23 LSP core. Do not edit those
headers in Umbra.

From the Umbra repository root:

```sh
Scripts/sync-lsp-core.sh --check
Scripts/sync-lsp-core.sh --sync
```

The check hashes each explicitly ordered relative path followed by that file's
SHA-256, then hashes the resulting manifest stream and compares the aggregate
with `source-digest.sha256`. When Lumen is available as a sibling repository it
also requires the canonical and mirrored trees to match. SwiftPM runs the check
before compiling `CLSPCore`.

`include/CLSPCore.h` is Umbra's independently versioned C ABI. It is not part
of the source-identical portable mirror.
