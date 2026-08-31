# Umbra architecture

Umbra is an Apple Silicon macOS 14+ application. Qt, QML, SDL, and OpenMAX are
not part of its runtime.

## Production path

```text
UmbraApp
  UI, windows, commands, stream lifecycle
    |
    +-- UmbraCore / UmbraServices
    |     preferences, persistence, host and session state
    +-- UmbraNetworking / UmbraPairing
    |     discovery, GameStream HTTP(S), legacy pairing
    +-- UmbraPlatform
    |     windows, input, controllers, power assertions
    +-- UmbraIntegration / UmbraStreaming
          session adapters and bounded media delivery
            |
            +-- CMoonlightBridge -> pinned moonlight-common-c
            +-- UmbraMedia -> VideoToolbox + Metal + AudioQueue
            +-- UmbraOpus / UmbraMicrophone
    +-- UmbraLSP -> UmbraLSPTransport -> CLSPCore
          native discovery, invitation pairing, auth, and app browsing
          over raw UDP + kqueue + wolfSSL DTLS 1.3 + libSRTP
```

`moonlight-common-c` owns the production GameStream RTSP/RTP/control wire,
encryption, FEC, depacketization, and input transport. The C facade converts its
callbacks into bounded Swift-facing media and lifecycle interfaces. Per-frame
work does not run on a Swift actor or the main thread.

SwiftUI owns application composition. AppKit owns stream windows, fullscreen,
pointer capture, event monitoring, menu commands, and display selection.
VideoToolbox decodes compressed frames. Metal imports `CVPixelBuffer` planes as
textures without a CPU pixel copy. AudioQueue is the production PCM output
path.

The separate native LSP path owns `_lumen-stream._udp` discovery, strict
invitation import, a stable owner-private LSP-only Ed25519 identity, fresh LSP
trust, a nonblocking UDP/kqueue worker, exact-policy wolfSSL 5.9.2 DTLS 1.3,
SPKI pinning, DTLS-SRTP export, libSRTP 2.8.0 replay/authentication contexts,
reliable LSPC control, and the input-only START slice. Swift receives
authenticated control responses, not UDP packets. Pairing, reconnect
authentication, application browsing, START, the neutral baseline, cumulative
pointer state, exactly-once keyboard/pointer-button edges, SRTP protection, and
LSPI retirement are wired into the product. Focused-window AppKit capture is
the active fallback and restores the prior mouse-coalescing setting at stop.
IOHID and GameController native adapters remain the next capture upgrade.

## Session policies

An immutable effective policy is resolved once per session and passed through
bootstrap, retries, the Moonlight bridge, decode, render, input, and telemetry.

| Concern | Latency | Quality |
| --- | --- | --- |
| Legacy input | Removes the deliberate 1 ms mouse/stylus batching wait | Preserves historical 1 ms pacing |
| Compressed video | One queued frame | Two queued frames |
| Decoder submissions | Two in flight | Five in flight |
| Presentation | Immediate when requested; tearing may be allowed | Display-linked, tear-free pacing |

These are bounded scheduling objectives, not performance guarantees. Explicit
advanced settings can change the effective result and must be recorded with
the measurement.

Both modes retain legacy Moonlight packet ordering and reliable ENet delivery.
Codec, HDR, and YUV 4:4:4 remain explicit preferences rather than implicit mode
changes.

Fidelity is a separate decision. `codec-lossless-required` is available only
with Quality mode and must fail closed when the exact client decoder and host
encoder tuple is not proven. Even when accepted, it does not prove RGB-to-YUV,
chroma, bit-depth conversion, color management, transport, or display scanout
lossless.

Client microphone forwarding is optional by default. Umbra resolves paired-host
permission, current macOS authorization, and the host's selected endpoint before
advertising an active microphone path; unavailable optional capture is reported
while connecting and the stream continues without it. Users can instead require
the microphone, which makes the same preflight fail closed before streaming.

## Concurrency and ownership

- UI state and presentation are `@MainActor` isolated.
- Discovery, persistence, polling, and host requests use actors or Sendable
  values.
- Each stream has one generation and one idempotent owner for teardown.
- C callbacks use an opaque context and synchronize teardown before release.
- Decode, render, audio, microphone, and input queues are bounded.
- Session-generation checks prevent callbacks from an old stream entering a
  replacement stream.
- Merged player-one metadata stays stable while the virtual controller is active,
  avoiding heterogeneous hot-plug rebind races. A full disconnect/rearrival
  advances the generation, and stale feedback is rejected.

## Trust and identity

Legacy Moonlight pairing remains available for compatibility. Its four-digit
PIN transcript is not a modern password-authenticated key exchange and must not
be described as brute-force resistant.

Umbra stores the legacy RSA identity in its private Application Support
directory with mode `0600`; it does not use the login Keychain. Paired host
certificates are pinned.

LSP uses separate `lsp-client-identity-v1.json`, `lsp-trust-v1.json`, and
`lsp-hosts-v1.json` owner-private atomic files. It never reuses legacy identity
or trust. The invitation/stored leaf SubjectPublicKeyInfo digest is checked
before control or SRTP authority is exposed.

## Measurement boundaries

Production telemetry records stage durations and p50/p95/p99 summaries using
monotonic clocks. Cross-machine values require exact trace correlation. A WAN
run may decompose matched client, host, and combined two-leg network durations,
but ping or RTT cannot be subtracted from a percentile to infer processing
latency. Actual scanout and input-to-photon require a synchronized physical
input and optical rig.

## Verification gates

1. Swift and C unit tests for state, parsing, ownership, queue bounds, and
   teardown.
2. Warnings-as-errors debug and release builds.
3. Self-contained package, code-signature, and static-dependency checks.
4. Legacy integration with an unmodified Moonlight client and a deployed Lumen
   or Sunshine host.
5. Hardware evidence for codec/HDR tuples, audio compatibility, controllers,
   fullscreen, and display behavior.
6. Causally correlated latency runs on a declared mode, protocol, hardware,
   refresh-rate, and network matrix.
7. Optical evidence before any input-to-photon claim.
