# Umbra

Umbra is a native Apple Silicon macOS streaming client. Its production path is
compatible with Lumen, Lumen, and other GameStream/GameStream hosts through
the pinned GameStream protocol library core. SwiftUI and AppKit provide the macOS UI;
VideoToolbox, Metal, AudioQueue, Network.framework, and GameController provide
the platform integrations.

Umbra exposes two session policies:

- **Latency** uses a one-frame compressed queue, two decoder submissions,
  immediate presentation, and removes the client's deliberate one-millisecond
  mouse/stylus batching wait.
- **Quality** uses a two-frame compressed queue, five decoder submissions, and
  display-linked presentation while retaining the client's historical input
  pacing and reliability.

Quality mode is not a lossless-stream claim. The separate
`codec-lossless-required` fidelity request fails closed unless both peers prove
the exact codec tuple; it preserves samples only after the encoder-input
conversion boundary.

The current baseline uses the legacy GameStream path for Lumen, Lumen, and
other GameStream-compatible hosts. See
[Architecture](Docs/ARCHITECTURE.md) and [Compatibility and validation
status](Docs/FEATURE_PARITY.md).

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode 16 or later; current development uses Xcode 26
- Homebrew `pkg-config`, `openssl@3`, and `opus` for debug builds

LSP uses the pinned static wolfSSL 5.9.2 and libSRTP 2.8.0 wolfCrypt profile,
not Homebrew's libSRTP package. Bootstrap and select that validated prefix
before a debug build that needs LSP:

```sh
lsp_prefix="$(Scripts/bootstrap-lsp-deps.sh)"
UMBRA_LSP_DEPS_PREFIX="$lsp_prefix" env -u CC -u CXX swift build
```

## Build and test

```sh
env -u CC -u CXX swift build
env -u CC -u CXX swift test
```

Create a self-contained arm64 release bundle with pinned static OpenSSL,
Opus, wolfSSL, and libSRTP builds:

```sh
Scripts/package-app.sh
```

Runtime sources are pinned under `Vendor/` with provenance and license records.

The performance harness is documented in
[`Scripts/Performance/README.md`](Scripts/Performance/README.md). Its reported
presentation values are proxies, not physical scanout or input-to-photon
measurements.

## License

GPL-3.0. See [LICENSE](LICENSE), [NOTICE.md](NOTICE.md), and
[third-party notices](THIRD_PARTY_NOTICES.md).
