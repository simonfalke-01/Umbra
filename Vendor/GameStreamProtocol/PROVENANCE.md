# moonlight-common-c provenance

The files under `Upstream/` begin from the pinned
`moonlight-common-c/moonlight-common-c` submodule from Moonlight Qt. Umbra's
narrow upstream deltas are recorded as reproducible patches under `Patches/`.

- Moonlight Qt repository: `git@github.com:moonlight-stream/moonlight-qt.git`
- Moonlight Qt commit: `d2f6990be699197385a6458e1231d070da83e665`
- moonlight-common-c commit: `874ac9548f1bd6f095ef2b435c42cdde460e7821`
- bundled ENet commit: `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1`
- bundled nanors commit: `b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a`
- Copied from: `reference/moonlight-qt/moonlight-common-c/moonlight-common-c`
- Portable pristine-tree digest (excluding intentionally omitted `.git` and
  `.github` metadata):
  `fdd63f02463b1d465e40a24625a7331af15ee475486172f2e023546b867912e0`
- Portable patched-tree digest:
  `4faa30a6d7b12afa99e3e24c993c70cb0bc142b72546b312017050d060dd000f`

`Tests/verify_provenance.py` verifies the patch series offline by reversing
`0005` through `0001`, checking the pristine digest, applying `0001` through
`0005`, checking the patched digest, and comparing every vendored byte. Use
`--fetch` for the stronger online check of the pinned Git and nested-submodule
identities, or `--source PATH` with an existing pristine checkout.
Passing `--fixture PATH` additionally locks the source-derived Lumen
compatibility fixture to the approved Moonlight Qt/common-c commits, generator
identity, CRLF contract, Gen 7 PLAY target, and exact SHA-256 hashes of the five
authoritative upstream source files.

The nested Git metadata was intentionally omitted. The complete deltas from
the pinned base are:

- `Patches/0001-umbra-lumen-client-microphone-rtsp.patch` changes only
  `src/RtspConnection.c` (gated negotiation hooks) and `src/RtspParser.c`
  (retention of duplicate microphone credential/transport headers for strict
  rejection). The extension implementation and stable ABI remain under
  `Facade/`.
- `Patches/0002-umbra-video-decode-queue-capacity.patch` replaces the fixed
  15-frame compressed-video queue with a stream configuration bounded to
  1...15 frames and adds a synchronized queue-count snapshot for diagnostics.
  It preserves the existing full-queue behavior: dependent frames are flushed
  and IDR recovery is requested; direct submit is not used. Test-only hooks are
  compiled solely by the focused C harness to exercise that production path.
- `Patches/0003-umbra-lumen-optimization-mode-rtsp.patch` adds one gated
  ANNOUNCE hook for Lumen's `latency` or `quality` stream policy. The stable ABI
  and bounded append implementation remain under `Facade/`. That same hook can
  append one independently validated `visually-lossless-allowed` or
  `codec-lossless-required` fidelity attribute for Lumen Quality sessions; it
  needs no additional upstream patch. Unspecified fidelity in legacy mode leaves
  the original GameStream SDP byte-for-byte unchanged, and the facade clears
  both process-global selections after every blocking connection start attempt.
- `Patches/0004-umbra-lowest-latency-input-fast-lane.patch` snapshots the
  independently validated local input policy into moonlight-common-c's
  per-connection stream configuration. The facade keeps that policy separate
  from the RTSP-advertised host policy: NVIDIA sessions can use local latency
  mode while retaining a byte-identical legacy ANNOUNCE, and extensible Lumen
  sessions advertise their matching latency or quality mode. Local latency mode
  bypasses only the deliberate one-millisecond relative mouse, absolute mouse,
  and pen batching waits (and their clock reads). The 150-packet queue,
  latest-state coalescing, reliable ordered key/button/release edges,
  pointer-before-click ordering, and drain-on-stop behavior are unchanged.
  Legacy and quality modes retain byte-for-byte input packet behavior. Focused
  test-only hooks are compiled solely by the C harness for hostile mode,
  lifecycle, ordering, coalescing, split-policy, and queue-pressure coverage.
- `Patches/0005-umbra-require-real-callbacks.patch` removes upstream's silent
  fake-callback substitution and rejects an incomplete callback table before a
  connection starts. The required-callback validator is implemented by
  `Facade/src/UmbraRequiredCallbacks.c` and linked into every Umbra bridge build;
  production never links the removed fake callback implementation.
