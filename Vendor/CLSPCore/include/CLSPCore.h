/**
 * @file CLSPCore.h
 * @brief Versioned C ABI for Umbra's native Lumen Streaming Protocol core.
 */

#ifndef CLSP_CORE_H
#define CLSP_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @brief C ABI version implemented by CLSPCore. */
#define CLSP_CORE_ABI_VERSION UINT32_C(2)

/** @brief Source digest of the mirrored portable LSP core. */
#define CLSP_CORE_SOURCE_DIGEST "27c71a42a6613fa2b3c8c9f42c986231311371fd9ece62405b9426e66d2757f6"

/** @brief Default LSP UDP application port. */
#define CLSP_DEFAULT_PORT UINT16_C(48030)

  /** @brief Opaque native protocol-core handle. */
  typedef struct clsp_core clsp_core_t;

  /** @brief Opaque native fresh-association reconnect/rekey owner. */
  typedef struct clsp_handoff clsp_handoff_t;

  /** @brief Opaque retained native byte-buffer handle. */
  typedef struct clsp_buffer clsp_buffer_t;

  /** @brief Opaque preferred Apple native input-capture owner. */
  typedef struct clsp_apple_input_capture clsp_apple_input_capture_t;

  /** @brief Borrowed immutable byte span whose lifetime is defined by the containing call. */
  typedef struct clsp_const_byte_span {
    const uint8_t *data;  ///< First byte, or null only when `length` is zero.
    size_t length;  ///< Number of borrowed bytes.
  } clsp_const_byte_span_t;

  /** @brief Typed result returned by every fallible ABI operation. */
  typedef enum clsp_status {
    CLSP_STATUS_OK = 0,  ///< Operation completed successfully.
    CLSP_STATUS_INVALID_ARGUMENT = 1,  ///< A pointer, length, field, or state was invalid.
    CLSP_STATUS_ABI_MISMATCH = 2,  ///< Caller and native ABI versions differ.
    CLSP_STATUS_MISSING_WOLFSSL = 3,  ///< Commercial wolfSSL DTLS 1.3 provider is unavailable.
    CLSP_STATUS_MISSING_LIBSRTP = 4,  ///< libSRTP AES-GCM provider is unavailable.
    CLSP_STATUS_INVALID_CONFIGURATION = 5,  ///< Configuration violates an LSP invariant.
    CLSP_STATUS_INVALID_STATE = 6,  ///< Lifecycle transition is not valid from the current state.
    CLSP_STATUS_REENTRANT_CALLBACK = 7,  ///< A core operation was attempted from its own callback.
    CLSP_STATUS_RESOURCE_EXHAUSTED = 8,  ///< A bounded native resource could not be allocated.
    CLSP_STATUS_UNSUPPORTED = 9,  ///< The requested production capability is not implemented.
    CLSP_STATUS_INTERNAL_FAILURE = 10,  ///< An internal invariant failed without exposing details.
    CLSP_STATUS_INVALID_ENDPOINT = 11,  ///< Remote host, port, or SPKI pin is invalid.
    CLSP_STATUS_SOCKET_FAILURE = 12,  ///< UDP socket or kqueue ownership could not be established.
    CLSP_STATUS_DTLS_FAILURE = 13,  ///< Exact-policy DTLS 1.3 setup or handshake failed.
    CLSP_STATUS_SPKI_MISMATCH = 14,  ///< The authenticated certificate did not match the required SPKI pin.
    CLSP_STATUS_SRTP_FAILURE = 15,  ///< Directional libSRTP contexts could not be installed or used.
    CLSP_STATUS_NOT_AUTHENTICATED = 16,  ///< An operation requires a completed pinned DTLS association.
    CLSP_STATUS_CONTROL_WINDOW_FULL = 17,  ///< The bounded 64-frame control window is full.
    CLSP_STATUS_TIMEOUT = 18,  ///< A bounded handshake or control operation expired.
    CLSP_STATUS_INPUT_PERMISSION_DENIED = 19,  ///< macOS denied preferred raw HID capture.
    CLSP_STATUS_INPUT_UNAVAILABLE = 20,  ///< No supported native HID capture source is available.
    CLSP_STATUS_ROLLBACK_PENDING = 21,  ///< Same-generation rollback awaits an authenticated fresh baseline ACK.
  } clsp_status_t;

  /** @brief Operator-selected congestion-control profile. */
  typedef enum clsp_profile {
    CLSP_PROFILE_ADAPTIVE_LOW_LATENCY = 0,  ///< Safe adaptive low-delay default.
    CLSP_PROFILE_COMPETITION_LAN = 1,  ///< Explicitly provisioned competition profile.
  } clsp_profile_t;

  /** @brief Native lifecycle state visible at coarse product boundaries. */
  typedef enum clsp_lifecycle_state {
    CLSP_LIFECYCLE_CREATED = 0,  ///< Core handle exists but owns no live transport.
    CLSP_LIFECYCLE_CONNECTING = 1,  ///< UDP and DTLS workers are establishing exact-policy security.
    CLSP_LIFECYCLE_AUTHENTICATED = 2,  ///< DTLS, SPKI pinning, exporter, and SRTP contexts are ready.
    CLSP_LIFECYCLE_STOPPED = 3,  ///< Transport workers are quiesced and may be restarted.
    CLSP_LIFECYCLE_FAILED = 4,  ///< Native transport failed and has quiesced.
  } clsp_lifecycle_state_t;

  /** @brief Product reason for creating one fresh authenticated association. */
  typedef enum clsp_handoff_reason {
    CLSP_HANDOFF_REASON_TRANSPORT_LOSS = 1,  ///< The authoritative association was lost.
    CLSP_HANDOFF_REASON_PLANNED_REKEY = 2,  ///< Rekey was initiated before a security lifetime expired.
  } clsp_handoff_reason_t;

  /** @brief Coarse native reconnect/rekey authority phase. */
  typedef enum clsp_handoff_phase {
    CLSP_HANDOFF_PHASE_AUTHORITATIVE = 1,  ///< The active association owns input authority.
    CLSP_HANDOFF_PHASE_ACTIVE_LOST = 2,  ///< The old association is unavailable while a replacement is sought.
    CLSP_HANDOFF_PHASE_CANDIDATE_HANDSHAKE = 3,  ///< A fresh association exists but is not application-authenticated.
    CLSP_HANDOFF_PHASE_CANDIDATE_AUTHENTICATED = 4,  ///< The candidate is authenticated; old input still owns authority.
    CLSP_HANDOFF_PHASE_OLD_INPUT_NEUTRALIZED = 5,  ///< Old producers are drained and ATTACH may commit.
    CLSP_HANDOFF_PHASE_ATTACH_SUBMITTED = 6,  ///< Native ATTACH admission succeeded and its outcome may become ambiguous.
    CLSP_HANDOFF_PHASE_ROLLBACK_PENDING = 7,  ///< Definite rollback awaits a fresh old-generation baseline ACK.
    CLSP_HANDOFF_PHASE_COMMITTED_BASELINE = 8,  ///< ATTACH committed forward; fresh candidate baseline ACK is pending.
    CLSP_HANDOFF_PHASE_TERMINAL = 9,  ///< No association may regain authority through this handoff.
  } clsp_handoff_phase_t;

  /** @brief Cancel outcome determining whether old authority may be restored. */
  typedef enum clsp_handoff_cancel_kind {
    CLSP_HANDOFF_CANCEL_DEFINITE_REJECTION = 1,  ///< Authenticated ATTACH rejection proves the host did not commit.
    CLSP_HANDOFF_CANCEL_AMBIGUOUS = 2,  ///< Timeout or transport loss cannot prove whether ATTACH committed.
  } clsp_handoff_cancel_kind_t;

  /** @brief Coarse input-baseline event kind. */
  typedef enum clsp_handoff_baseline_kind {
    CLSP_HANDOFF_BASELINE_REQUIRED = 1,  ///< Product must configure and transmit a fresh neutral baseline.
    CLSP_HANDOFF_BASELINE_ACKNOWLEDGED = 2,  ///< The host authenticated the exact required baseline.
  } clsp_handoff_baseline_kind_t;

  /** @brief Terminal fail-closed handoff reason. */
  typedef enum clsp_handoff_terminal_reason {
    CLSP_HANDOFF_TERMINAL_ACTIVE_LOST = 1,  ///< No usable replacement exists after active transport loss.
    CLSP_HANDOFF_TERMINAL_CANDIDATE_LOST = 2,  ///< The only forward-authoritative candidate was lost.
    CLSP_HANDOFF_TERMINAL_AMBIGUOUS_ATTACH = 3,  ///< ATTACH outcome was ambiguous and rollback is forbidden.
    CLSP_HANDOFF_TERMINAL_COMMITTED_ASSOCIATION_LOST = 4,  ///< The committed association failed after authority moved.
    CLSP_HANDOFF_TERMINAL_BASELINE_FAILED = 5,  ///< Required baseline recovery could not complete safely.
  } clsp_handoff_terminal_reason_t;

  /** @brief Bit mask describing linked production security providers. */
  typedef enum clsp_provider_flag {
    CLSP_PROVIDER_WOLFSSL = 1U << 0U,  ///< wolfSSL DTLS 1.3 provider is linked.
    CLSP_PROVIDER_LIBSRTP = 1U << 1U,  ///< libSRTP AES-128-GCM provider is linked.
  } clsp_provider_flag_t;

  /** @brief Video codec identifiers frozen by LSP video schema revision three. */
  typedef enum clsp_video_codec {
    CLSP_VIDEO_CODEC_H264 = 1,  ///< H.264/AVC.
    CLSP_VIDEO_CODEC_HEVC = 2,  ///< H.265/HEVC.
    CLSP_VIDEO_CODEC_AV1 = 3,  ///< Alliance for Open Media AV1.
  } clsp_video_codec_t;

  /** @brief Codec profile identifiers frozen by LSP video schema revision three. */
  typedef enum clsp_video_profile {
    CLSP_VIDEO_PROFILE_H264_HIGH = 1,  ///< H.264 High 4:2:0.
    CLSP_VIDEO_PROFILE_H264_HIGH_444 = 2,  ///< H.264 High 4:4:4.
    CLSP_VIDEO_PROFILE_HEVC_MAIN = 3,  ///< HEVC Main 8-bit.
    CLSP_VIDEO_PROFILE_HEVC_MAIN10 = 4,  ///< HEVC Main10.
    CLSP_VIDEO_PROFILE_HEVC_REXT = 5,  ///< HEVC Range Extensions 4:4:4.
    CLSP_VIDEO_PROFILE_AV1_MAIN = 6,  ///< AV1 Main 4:2:0.
    CLSP_VIDEO_PROFILE_AV1_HIGH = 7,  ///< AV1 High 4:4:4.
  } clsp_video_profile_t;

  /** @brief Exact decoded pixel tuples frozen by video schema revision three. */
  typedef enum clsp_video_pixel_format {
    CLSP_VIDEO_PIXEL_420_8 = 1,  ///< 8-bit YUV 4:2:0.
    CLSP_VIDEO_PIXEL_420_10 = 2,  ///< 10-bit YUV 4:2:0.
    CLSP_VIDEO_PIXEL_444_8 = 3,  ///< 8-bit YUV 4:4:4.
    CLSP_VIDEO_PIXEL_444_10 = 4,  ///< 10-bit YUV 4:4:4.
  } clsp_video_pixel_format_t;

  /** @brief Encoded access-unit delivery modes. */
  typedef enum clsp_video_delivery {
    CLSP_VIDEO_DELIVERY_COMPLETE_ACCESS_UNIT = 1,  ///< Publish one retained complete access unit.
    CLSP_VIDEO_DELIVERY_BOUNDED_INCREMENTAL = 2,  ///< Bounded incremental delivery.
  } clsp_video_delivery_t;

  /** @brief Encoded access-unit byte representation crossing the ABI. */
  typedef enum clsp_video_payload_format {
    CLSP_VIDEO_PAYLOAD_ANNEX_B = 1,  ///< Annex-B-prefixed H.264 or HEVC access unit.
    CLSP_VIDEO_PAYLOAD_AV1_LOW_OVERHEAD_OBU = 2,  ///< Canonical AV1 low-overhead OBU stream.
  } clsp_video_payload_format_t;

  /** @brief Fixed-layout construction configuration copied by `clsp_core_create`. */
  typedef struct clsp_configuration {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_configuration_t)`.
    uint16_t port;  ///< Nonzero UDP application port.
    uint16_t reserved_zero;  ///< Reserved and required to be zero.
    uint32_t profile;  ///< One `clsp_profile_t` value.
    uint32_t competition_capacity_mbps;  ///< Required nonzero ceiling only for competition mode.
    uint32_t telemetry_interval_milliseconds;  ///< Coarse snapshot interval, at least 250 ms.
    uint32_t handshake_timeout_milliseconds;  ///< Bounded synchronous start timeout, 1000 through 30000 ms.
    uint32_t reserved_flags;  ///< Reserved and required to be zero.
  } clsp_configuration_t;

  /** @brief Exact remote endpoint and invitation/trust SPKI pin copied at start. */
  typedef struct clsp_endpoint {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_endpoint_t)`.
    clsp_const_byte_span_t host;  ///< UTF-8 DNS name or numeric IP literal, at most 255 bytes.
    uint16_t port;  ///< Nonzero LSP UDP application port.
    uint16_t reserved_zero;  ///< Reserved and required to be zero.
    uint8_t server_spki_sha256[32];  ///< Required nonzero SHA-256 leaf SubjectPublicKeyInfo pin.
  } clsp_endpoint_t;

  /** @brief Coarse native lifecycle notification delivered without core locks held. */
  typedef struct clsp_lifecycle_event {
    uint32_t abi_version;  ///< Event layout version.
    uint32_t structure_size;  ///< Size of this event structure.
    uint32_t state;  ///< One `clsp_lifecycle_state_t` value.
    uint32_t reserved_zero;  ///< Reserved and required to be zero.
  } clsp_lifecycle_event_t;

  /** @brief One authenticated control frame delivered at application frequency. */
  typedef struct clsp_control_event {
    uint32_t abi_version;  ///< Event layout version.
    uint32_t structure_size;  ///< Size of this event structure.
    uint16_t message_type;  ///< LSP/1 control message type.
    uint8_t flags;  ///< Authenticated LSPC flags.
    uint8_t reserved_zero;  ///< Reserved and required to be zero.
    uint32_t connection_generation;  ///< Authenticated LSPC connection generation.
    uint64_t message_id;  ///< Authenticated peer logical-frame identifier.
    uint64_t request_id;  ///< Correlated request identifier, or zero for an event.
    clsp_const_byte_span_t payload;  ///< Transient deterministic-CBOR payload.
  } clsp_control_event_t;

  /** @brief Exact authenticated host-audio configuration installed before semantic ACK. */
  typedef struct clsp_audio_configuration {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_audio_configuration_t)`.
    uint32_t stream_generation;  ///< Nonzero retained stream generation.
    uint32_t audio_generation;  ///< Nonzero audio generation.
    uint32_t audio_ssrc;  ///< Nonzero host audio RTP SSRC.
    uint32_t clock_rate;  ///< Exactly 48,000.
    uint32_t bitrate;  ///< Selected Opus bitrate.
    uint16_t frame_samples;  ///< 120, 240, 480, or 960.
    uint16_t udp_payload_size;  ///< Authenticated path payload size.
    uint8_t audio_payload_type;  ///< Dynamic RTP PT 96 through 127.
    uint8_t channels;  ///< Two, six, or eight.
    uint8_t streams;  ///< Nonzero Opus stream count.
    uint8_t coupled_streams;  ///< Opus coupled stream count.
    uint8_t mapping[8];  ///< Leading `mapping_length` Opus channel mapping bytes.
    uint8_t mapping_length;  ///< Exactly `channels`.
    uint8_t inband_fec;  ///< Boolean.
    uint8_t dtx;  ///< Boolean.
    uint8_t preroll_packets;  ///< Exactly one.
  } clsp_audio_configuration_t;

  /** @brief One authenticated complete Opus RTP payload delivered at packet frequency. */
  typedef struct clsp_audio_packet_event {
    uint32_t abi_version;  ///< Event ABI version.
    uint32_t structure_size;  ///< Size of this event.
    uint32_t audio_generation;  ///< Exact installed audio generation.
    uint32_t ssrc;  ///< Exact installed audio SSRC.
    uint32_t timestamp;  ///< 48-kHz RTP timestamp.
    uint16_t sequence_number;  ///< RTP sequence number.
    uint8_t marker;  ///< RTP marker bit.
    uint8_t reserved_zero;  ///< Reserved and zero.
    clsp_const_byte_span_t opus_packet;  ///< Transient complete Opus packet.
  } clsp_audio_packet_event_t;

  /** @brief Authenticated RTCP sender-report audio clock relation. */
  typedef struct clsp_audio_timing_event {
    uint32_t abi_version;  ///< Event ABI version.
    uint32_t structure_size;  ///< Size of this event.
    uint32_t audio_generation;  ///< Installed audio generation.
    uint32_t ssrc;  ///< Installed audio SSRC.
    uint32_t ntp_seconds;  ///< NTP seconds field.
    uint32_t ntp_fraction;  ///< NTP fractional field.
    uint32_t rtp_timestamp;  ///< Corresponding 48-kHz RTP timestamp.
  } clsp_audio_timing_event_t;

  /** @brief Exact reverse-microphone RTP/SRTP sender mapping. */
  typedef struct clsp_microphone_configuration {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_microphone_configuration_t)`.
    uint32_t stream_generation;  ///< Nonzero stream generation.
    uint32_t microphone_generation;  ///< Nonzero microphone generation.
    uint32_t microphone_ssrc;  ///< Nonzero client microphone SSRC.
    uint32_t clock_rate;  ///< Exactly 48,000.
    uint32_t bitrate;  ///< Selected 6,000 through 128,000 bits/s.
    uint16_t frame_samples;  ///< Exactly 960.
    uint16_t udp_payload_size;  ///< Exactly 1,200.
    uint8_t microphone_payload_type;  ///< Dynamic RTP PT 96 through 127.
    uint8_t channels;  ///< Exactly one.
    uint8_t inband_fec;  ///< Boolean Opus in-band FEC selection.
    uint8_t dtx;  ///< Boolean Opus DTX selection.
  } clsp_microphone_configuration_t;

  /** @brief Exact schema-revision-three native video admission mapping. */
  typedef struct clsp_video_configuration {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_video_configuration_t)`.
    uint32_t stream_generation;  ///< Nonzero stream generation.
    uint32_t video_generation;  ///< Nonzero video configuration generation.
    uint32_t primary_ssrc;  ///< Nonzero primary video SSRC.
    uint32_t clock_rate;  ///< Exactly 90,000.
    uint32_t width;  ///< Selected coded width.
    uint32_t height;  ///< Selected coded height.
    uint32_t refresh_numerator;  ///< Nonzero rational refresh numerator.
    uint32_t refresh_denominator;  ///< Nonzero rational refresh denominator.
    uint32_t bitrate;  ///< Selected source bitrate.
    uint32_t maximum_access_unit_bytes;  ///< Bounded complete-AU size.
    uint32_t maximum_frame_age_microseconds;  ///< Client receive/reassembly deadline budget.
    uint64_t frame_id_origin;  ///< Nonzero initial frame ID.
    uint32_t recovery_epoch;  ///< Nonzero initial recovery-epoch seed.
    uint16_t udp_payload_size;  ///< Exactly 1,200 for the first slice.
    uint8_t primary_payload_type;  ///< Dynamic RTP PT 96 through 127.
    uint8_t codec;  ///< One `clsp_video_codec_t`.
    uint8_t profile;  ///< One `clsp_video_profile_t` valid for `codec`.
    uint8_t pixel_format;  ///< One exact `clsp_video_pixel_format_t`.
    uint8_t color_primaries;  ///< Direct H.273 colour_primaries value.
    uint8_t transfer_characteristics;  ///< Direct H.273 transfer_characteristics value.
    uint8_t matrix_coefficients;  ///< Direct H.273 matrix_coefficients value.
    uint8_t full_range;  ///< Boolean full-range indicator.
    uint8_t delivery;  ///< One `clsp_video_delivery_t`.
    uint8_t payload_format;  ///< One `clsp_video_payload_format_t`.
    uint8_t decoder_surfaces;  ///< Two through four.
    uint8_t frame_marking_extension;  ///< RFC8285 ID.
    uint8_t absolute_capture_extension;  ///< RFC8285 ID.
    uint8_t frame_id_extension;  ///< Encrypted RFC8285 ID.
    uint8_t input_watermark_extension;  ///< Encrypted RFC8285 ID.
    uint8_t encoder_timing_extension;  ///< Encrypted RFC8285 ID.
    uint32_t flexfec_ssrc;  ///< RFC 8627 repair SSRC, or zero when unselected.
    uint32_t flexfec_repair_window_microseconds;  ///< Nonzero only with `flexfec_ssrc`.
    uint32_t rtx_ssrc;  ///< RFC 4588 retransmission SSRC, or zero when unselected.
    uint8_t flexfec_payload_type;  ///< Dynamic repair PT, or zero when unselected.
    uint8_t flexfec_maximum_group_packets;  ///< Exactly fifteen when selected.
    uint8_t rtx_payload_type;  ///< Dynamic retransmission PT, or zero when unselected.
    uint8_t rtx_associated_payload_type;  ///< Exact primary PT, or zero when unselected.
  } clsp_video_configuration_t;

  /** @brief One retained complete encoded access unit transferred across the C ABI. */
  typedef struct clsp_video_access_unit_event {
    uint32_t abi_version;  ///< Event ABI version.
    uint32_t structure_size;  ///< Size of this event.
    uint32_t video_generation;  ///< Exact installed video generation.
    uint32_t rtp_timestamp;  ///< 90-kHz RTP timestamp.
    uint64_t frame_id;  ///< Nonzero frame ID.
    uint64_t receive_time_microseconds;  ///< Client monotonic completion time.
    uint64_t capture_time_microseconds;  ///< Absolute-capture time when present.
    uint64_t input_state_sequence;  ///< Applied input watermark state.
    uint64_t input_edge_id;  ///< Applied input watermark edge.
    uint32_t recovery_epoch;  ///< Authenticated per-frame recovery epoch.
    uint8_t independent;  ///< Codec-independent frame marking.
    uint8_t codec;  ///< One `clsp_video_codec_t`.
    uint8_t payload_format;  ///< One `clsp_video_payload_format_t`.
    uint8_t reserved_zero;  ///< Reserved and zero.
    union {
      clsp_buffer_t *encoded_access_unit;  ///< Owning retained complete encoded-AU handle.
      clsp_buffer_t *frame;  ///< ABI-v2 source-compatibility name for native runtime integration.
    };
  } clsp_video_access_unit_event_t;

  /** @brief Source-compatible native runtime alias for the ABI-v2 encoded-AU event. */
  typedef clsp_video_access_unit_event_t clsp_video_frame_event_t;

  /** @brief Decoder outcome values carried unchanged in protected LSPV. */
  typedef enum clsp_video_decoder_status {
    CLSP_VIDEO_DECODER_READY = 0,  ///< Frame decoded and the hardware decoder remains ready.
    CLSP_VIDEO_DECODER_SURFACE_EXHAUSTED = 1,  ///< Hardware submission capacity is exhausted.
    CLSP_VIDEO_DECODER_RECOVERABLE_ERROR = 2,  ///< Reference repair or bounded recovery is required.
    CLSP_VIDEO_DECODER_UNRECOVERABLE_ERROR = 3,  ///< An independent recovery frame is required.
  } clsp_video_decoder_status_t;

  /** @brief Coarse authenticated path-probe lifecycle event kind. */
  typedef enum clsp_path_probe_event_kind {
    CLSP_PATH_PROBE_SEND_INTENT = 1,  ///< Swift must send the reliable client intent.
    CLSP_PATH_PROBE_RECEIVED = 2,  ///< Swift must send the cached reliable ACK response.
    CLSP_PATH_PROBE_REQUEST_FAILED = 3,  ///< Native optional intent retries exhausted.
  } clsp_path_probe_event_kind_t;

  /** @brief One low-rate native DPLPMTUD control-boundary event. */
  typedef struct clsp_path_probe_event {
    uint32_t abi_version;  ///< Event ABI version.
    uint32_t structure_size;  ///< Size of this event.
    uint64_t probe_id;  ///< Random nonzero probe identifier.
    uint64_t request_id;  ///< Host request ID for `RECEIVED`, otherwise zero.
    uint16_t udp_payload_size;  ///< Exact protected UDP probe size.
    uint8_t kind;  ///< One `clsp_path_probe_event_kind_t`.
    uint8_t reserved_zero;  ///< Reserved and zero.
  } clsp_path_probe_event_t;

  /** @brief Exact input-only START_RESPONSE mapping installed in the native worker. */
  typedef struct clsp_input_configuration {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_input_configuration_t)`.
    uint32_t stream_generation;  ///< Nonzero negotiated stream generation.
    uint32_t input_generation;  ///< Nonzero input authority generation.
    uint32_t input_ssrc;  ///< Nonzero client input RTP SSRC.
    uint32_t acknowledgement_ssrc;  ///< Distinct host LSPI SRTCP sender SSRC.
    uint32_t pointer_rate;  ///< Selected pointer rate in 125 through 16,000 reports/s.
    uint32_t controller_rate;  ///< Selected controller rate in 125 through 2,000 reports/s.
    uint32_t sensor_rate;  ///< Selected sensor rate in 125 through 4,000 reports/s.
    uint32_t reconciliation_rate;  ///< Selected reconciliation rate in 50 through 1,000 reports/s.
    uint64_t reserved_input_wire_bits_per_second;  ///< Nonzero reserved rate no greater than 32 Mbps.
    uint8_t input_payload_type;  ///< Dynamic RTP payload type in 96 through 127.
    uint8_t baseline_required;  ///< Must equal one for a fresh authority.
    uint16_t reserved_zero;  ///< Reserved and required to be zero.
  } clsp_input_configuration_t;

  /** @brief Allocation-free relative-pointer capture record. */
  typedef struct clsp_pointer_sample {
    uint64_t sample_time_microseconds;  ///< Nonzero client monotonic capture time.
    int64_t delta_x;  ///< Relative horizontal delta.
    int64_t delta_y;  ///< Relative vertical delta.
    int64_t vertical_scroll;  ///< Relative vertical scroll delta.
    int64_t horizontal_scroll;  ///< Relative horizontal scroll delta.
  } clsp_pointer_sample_t;

  /** @brief Physical input edge kinds accepted by the native capture boundary. */
  typedef enum clsp_input_edge_kind {
    CLSP_INPUT_EDGE_KEY_DOWN = 1,  ///< Keyboard HID usage became pressed.
    CLSP_INPUT_EDGE_KEY_UP = 2,  ///< Keyboard HID usage became released.
    CLSP_INPUT_EDGE_POINTER_BUTTON_DOWN = 3,  ///< Pointer button became pressed.
    CLSP_INPUT_EDGE_POINTER_BUTTON_UP = 4,  ///< Pointer button became released.
  } clsp_input_edge_kind_t;

  /** @brief Allocation-free keyboard or pointer-button transition. */
  typedef struct clsp_input_edge {
    uint64_t sample_time_microseconds;  ///< Nonzero client monotonic capture time.
    uint16_t control_id;  ///< Keyboard-page HID usage or pointer button one through five.
    uint8_t kind;  ///< One `clsp_input_edge_kind_t`.
    uint8_t reserved_zero;  ///< Reserved and required to be zero.
  } clsp_input_edge_t;

  /** @brief GameController lifecycle or digital-button edge. */
  typedef struct clsp_controller_edge {
    uint64_t sample_time_microseconds;  ///< `lastEventTimestamp` in client monotonic microseconds.
    uint32_t controller_id;  ///< Stable slot one through sixteen.
    uint32_t instance_generation;  ///< Nonzero arrival generation.
    uint16_t control_id;  ///< Profile type for arrival or button bit zero through 31.
    uint8_t kind;  ///< LSP edge kind five through eight.
    uint8_t reserved_zero;  ///< Reserved and required to be zero.
  } clsp_controller_edge_t;

  /** @brief Latest GameController triggers and sticks. */
  typedef struct clsp_controller_state {
    uint64_t sample_time_microseconds;  ///< Profile `lastEventTimestamp`.
    uint32_t controller_id;  ///< Stable slot one through sixteen.
    uint32_t instance_generation;  ///< Exact active controller generation.
    uint8_t left_trigger;  ///< Latest normalized trigger zero through 255.
    uint8_t right_trigger;  ///< Latest normalized trigger zero through 255.
    int16_t left_stick_x;  ///< Latest normalized signed axis.
    int16_t left_stick_y;  ///< Latest normalized signed axis.
    int16_t right_stick_x;  ///< Latest normalized signed axis.
    int16_t right_stick_y;  ///< Latest normalized signed axis.
  } clsp_controller_state_t;

  /** @brief Latest GameController gyro or accelerometer vector. */
  typedef struct clsp_controller_sensor {
    uint64_t sample_time_microseconds;  ///< Motion callback entry timestamp.
    uint32_t controller_id;  ///< Stable slot one through sixteen.
    uint32_t instance_generation;  ///< Exact active controller generation.
    float x;  ///< X component.
    float y;  ///< Y component.
    float z;  ///< Z component.
    uint8_t sensor_type;  ///< One gyro or two accelerometer.
    uint8_t reserved_zero[3];  ///< Reserved and required to be zero.
  } clsp_controller_sensor_t;

  /** @brief Controller touchpad lifecycle edge for one contact. */
  typedef struct clsp_controller_touch_edge {
    uint64_t sample_time_microseconds;  ///< Profile last-event timestamp.
    uint32_t controller_id;  ///< Owning controller one through sixteen.
    uint32_t contact_id;  ///< Contact one through sixteen.
    uint32_t instance_generation;  ///< Owning controller generation.
    uint8_t kind;  ///< Touch begin, end, or cancel kind nine through eleven.
    uint8_t reserved_zero[3];  ///< Reserved and required to be zero.
  } clsp_controller_touch_edge_t;

  /** @brief Latest controller touchpad contact coordinates. */
  typedef struct clsp_controller_touch_state {
    uint64_t sample_time_microseconds;  ///< Profile last-event timestamp.
    uint32_t controller_id;  ///< Owning controller one through sixteen.
    uint32_t contact_id;  ///< Contact one through sixteen.
    uint32_t instance_generation;  ///< Owning controller generation.
    uint32_t x;  ///< Absolute X in Q0.32.
    uint32_t y;  ///< Absolute Y in Q0.32.
    uint32_t pressure;  ///< Normalized pressure in Q0.32.
  } clsp_controller_touch_state_t;

  /** @brief Low-rate telemetry snapshot copied across the ABI. */
  typedef struct clsp_telemetry_snapshot {
    uint32_t abi_version;  ///< Snapshot layout version.
    uint32_t structure_size;  ///< Size of this snapshot structure.
    uint32_t lifecycle_state;  ///< Current `clsp_lifecycle_state_t` value.
    uint32_t provider_flags;  ///< Linked `clsp_provider_flag_t` mask.
    uint64_t received_datagrams;  ///< Authenticated datagrams received by the core.
    uint64_t transmitted_datagrams;  ///< Datagrams submitted by the core.
    uint64_t dropped_datagrams;  ///< Datagrams discarded by bounded policy.
    uint64_t authentication_failures;  ///< DTLS, SRTP, and SRTCP authentication failures.
    uint64_t video_received_ip_bytes;  ///< Authenticated primary-video complete IP-layer bytes.
    uint64_t congestion_feedback_ip_bytes;  ///< Submitted RFC 8888 complete IP-layer bytes.
    uint64_t congestion_feedback_packets;  ///< Submitted protected RFC 8888 packets.
    uint64_t video_ecn_unknown_packets;  ///< Video packets without kernel ECN ancillary evidence.
    uint64_t video_ecn_ce_packets;  ///< Authenticated video packets marked ECN-CE.
    uint64_t path_probes_sent;  ///< Exact protected LSPP kernel submissions.
    uint64_t path_probes_acknowledged;  ///< Exact authenticated PATH_PROBE acknowledgements.
    uint64_t path_probe_timeouts;  ///< Candidates exhausted after three PROBE_TIMER sends.
    uint16_t current_udp_payload_size;  ///< Authenticated confirmed DPLPMTUD ceiling.
    uint16_t reserved_zero;  ///< Reserved and zero.
  } clsp_telemetry_snapshot_t;

  /** @brief Secret-free snapshot of one native reconnect/rekey owner. */
  typedef struct clsp_handoff_snapshot {
    uint32_t abi_version;  ///< Snapshot layout version.
    uint32_t structure_size;  ///< Size of this snapshot structure.
    uint32_t active_connection_generation;  ///< Current or last forward-authoritative connection generation.
    uint32_t active_input_generation;  ///< Current or last authoritative input generation.
    uint32_t input_authority_epoch;  ///< Local callback epoch preventing stale same-generation rollback work.
    uint32_t connection_generation_high_watermark;  ///< Greatest connection generation ever consumed.
    uint32_t candidate_connection_generation;  ///< Pending candidate generation, or zero.
    uint32_t rollback_connection_generation;  ///< Definitely rejected generation binding rollback, or zero.
    uint32_t retiring_connection_generation;  ///< Prior committed association awaiting retirement, or zero.
    uint32_t phase;  ///< One `clsp_handoff_phase_t` value.
    uint32_t reason;  ///< One `clsp_handoff_reason_t` value, or zero before the first handoff.
    uint32_t active_lifecycle_state;  ///< Current active core `clsp_lifecycle_state_t` value.
    uint32_t candidate_lifecycle_state;  ///< Candidate core lifecycle, or `CLSP_LIFECYCLE_STOPPED` when absent.
    uint32_t retiring_lifecycle_state;  ///< Retiring core lifecycle, or `CLSP_LIFECYCLE_STOPPED` when absent.
    uint64_t begun_count;  ///< Fresh-association attempts begun by this owner.
    uint64_t committed_count;  ///< Authenticated ATTACH commits.
    uint64_t definite_rollback_count;  ///< Definitely rejected ATTACH attempts safely rolled back.
    uint64_t terminal_count;  ///< Fail-closed terminal transitions.
    uint8_t active_lost;  ///< Boolean old/new active transport loss marker.
    uint8_t candidate_authenticated;  ///< Boolean application-authenticated candidate marker.
    uint8_t old_input_neutralized;  ///< Boolean producer-drain completion marker.
    uint8_t baseline_required;  ///< Boolean baseline ACK gate.
    uint8_t attach_committed;  ///< Boolean irreversible ATTACH commit marker.
    uint8_t forward_only;  ///< Boolean prohibition on old-association rollback.
    uint8_t has_candidate;  ///< Boolean retained candidate-core ownership marker.
    uint8_t has_retiring;  ///< Boolean retained retiring-core ownership marker.
  } clsp_handoff_snapshot_t;

  /** @brief One coarse authority-phase transition. */
  typedef struct clsp_handoff_phase_event {
    uint32_t abi_version;  ///< Event layout version.
    uint32_t structure_size;  ///< Size of this event structure.
    uint32_t phase;  ///< One `clsp_handoff_phase_t` value.
    uint32_t reason;  ///< One `clsp_handoff_reason_t` value, or zero.
    uint32_t active_connection_generation;  ///< Current or last authoritative connection generation.
    uint32_t active_input_generation;  ///< Current or last authoritative input generation.
    uint32_t candidate_connection_generation;  ///< Pending candidate generation, or zero.
    uint8_t baseline_required;  ///< Boolean baseline-ACK gate.
    uint8_t forward_only;  ///< Boolean rollback prohibition.
    uint8_t reserved_zero[2];  ///< Reserved and zero.
  } clsp_handoff_phase_event_t;

  /** @brief One coarse same-generation or committed-generation baseline event. */
  typedef struct clsp_handoff_baseline_event {
    uint32_t abi_version;  ///< Event layout version.
    uint32_t structure_size;  ///< Size of this event structure.
    uint32_t kind;  ///< One `clsp_handoff_baseline_kind_t` value.
    uint32_t input_generation;  ///< Exact generation whose fresh neutral baseline is gated.
    uint32_t input_authority_epoch;  ///< Local epoch that invalidates pre-neutralization callbacks.
    uint32_t connection_generation;  ///< Association carrying the required or acknowledged baseline.
    uint32_t rollback_connection_generation;  ///< Rejected candidate binding same-generation rollback, or zero.
    uint32_t reserved_zero;  ///< Reserved and zero.
  } clsp_handoff_baseline_event_t;

  /** @brief One coarse fresh-association attempt event. */
  typedef struct clsp_handoff_rekey_event {
    uint32_t abi_version;  ///< Event layout version.
    uint32_t structure_size;  ///< Size of this event structure.
    uint32_t reason;  ///< One `clsp_handoff_reason_t` value.
    uint32_t candidate_connection_generation;  ///< Strictly newer candidate generation.
  } clsp_handoff_rekey_event_t;

  /** @brief One latched fail-closed terminal handoff event. */
  typedef struct clsp_handoff_terminal_event {
    uint32_t abi_version;  ///< Event layout version.
    uint32_t structure_size;  ///< Size of this event structure.
    uint32_t reason;  ///< One `clsp_handoff_terminal_reason_t` value.
    uint32_t last_connection_generation;  ///< Last forward-authoritative connection generation.
  } clsp_handoff_terminal_event_t;

  /** @brief Association-local baseline readiness without exclusive handoff observation. */
  typedef struct clsp_input_baseline_snapshot {
    uint32_t abi_version;  ///< Snapshot layout version.
    uint32_t structure_size;  ///< Size of this snapshot structure.
    uint32_t connection_generation;  ///< Authenticated association generation carrying the baseline.
    uint32_t input_generation;  ///< Exact wire input generation.
    uint32_t input_authority_epoch;  ///< Local callback de-staling epoch.
    uint32_t reserved_zero;  ///< Reserved and zero.
    uint64_t event_generation;  ///< Monotonic association-local readiness change counter.
    uint8_t acknowledged;  ///< Boolean authenticated baseline-ACK state.
    uint8_t reserved_tail[7];  ///< Reserved and zero.
  } clsp_input_baseline_snapshot_t;

  /** @brief Successful atomic native ATTACH queue admission. */
  typedef struct clsp_control_submission {
    uint32_t abi_version;  ///< Submission layout version.
    uint32_t structure_size;  ///< Size of this submission structure.
    uint64_t request_id;  ///< Exact caller-reserved control request identifier.
  } clsp_control_submission_t;

  /**
   * @brief Coarse non-reentrant lifecycle callback.
   *
   * The event is a transient borrowed view valid only for this call. Calling a
   * lifecycle operation on the same core from this callback returns
   * `CLSP_STATUS_REENTRANT_CALLBACK`.
   *
   * @param context Caller-owned context retained by the caller.
   * @param event Transient lifecycle event.
   */
  typedef void (*clsp_lifecycle_callback_t)(void *context, const clsp_lifecycle_event_t *event);

  /**
   * @brief Coarse non-reentrant authenticated-control callback.
   *
   * The payload is valid only for the callback. The native worker has already
   * completed DTLS authentication, SPKI pinning, LSPC validation, duplicate
   * suppression, and ACK processing before invoking it.
   *
   * @param context Caller-owned retained callback context.
   * @param event Transient authenticated control event.
   */
  typedef void (*clsp_control_callback_t)(void *context, const clsp_control_event_t *event);

  /** @brief Complete authenticated Opus packet callback; no UDP fragment crosses the ABI. */
  typedef void (*clsp_audio_packet_callback_t)(void *context, const clsp_audio_packet_event_t *event);

  /** @brief Authenticated low-rate audio sender-report callback. */
  typedef void (*clsp_audio_timing_callback_t)(void *context, const clsp_audio_timing_event_t *event);

  /** @brief Complete retained encoded-access-unit callback; never invoked per RTP packet. */
  typedef void (*clsp_video_access_unit_callback_t)(void *context, const clsp_video_access_unit_event_t *event);

  /** @brief Source-compatible callback alias retained within the native implementation. */
  typedef clsp_video_access_unit_callback_t clsp_video_frame_callback_t;

  /** @brief Low-rate authenticated path-probe lifecycle callback. */
  typedef void (*clsp_path_probe_callback_t)(void *context, const clsp_path_probe_event_t *event);

  /**
   * @brief Retain an explicitly owned callback context.
   *
   * This function must not throw or call back into the core.
   *
   * @param context Context to retain before `clsp_core_create` returns.
   */
  typedef void (*clsp_context_retain_t)(void *context);

  /**
   * @brief Release an explicitly owned callback context.
   *
   * This function must not throw or call back into the core.
   *
   * @param context Context to release when the native core is destroyed.
   */
  typedef void (*clsp_context_release_t)(void *context);

  /** @brief Coarse non-reentrant native handoff phase callback. */
  typedef void (*clsp_handoff_phase_callback_t)(
    void *context,
    const clsp_handoff_phase_event_t *event
  );

  /** @brief Coarse non-reentrant baseline requirement/ACK callback. */
  typedef void (*clsp_handoff_baseline_callback_t)(
    void *context,
    const clsp_handoff_baseline_event_t *event
  );

  /** @brief Coarse non-reentrant fresh-association attempt callback. */
  typedef void (*clsp_handoff_rekey_callback_t)(
    void *context,
    const clsp_handoff_rekey_event_t *event
  );

  /** @brief Latched non-reentrant terminal handoff callback. */
  typedef void (*clsp_handoff_terminal_callback_t)(
    void *context,
    const clsp_handoff_terminal_event_t *event
  );

  /** @brief Callback table copied during core construction. */
  typedef struct clsp_callbacks {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_callbacks_t)`.
    void *context;  ///< Explicitly retained callback context, or null.
    clsp_context_retain_t retain_context;  ///< Required retain operation for nonnull context.
    clsp_context_release_t release_context;  ///< Required release operation for nonnull context.
    clsp_lifecycle_callback_t lifecycle;  ///< Optional coarse lifecycle callback.
    clsp_control_callback_t control;  ///< Optional authenticated control-frame callback.
    clsp_audio_packet_callback_t audio_packet;  ///< Optional complete Opus packet callback.
    clsp_audio_timing_callback_t audio_timing;  ///< Optional authenticated sender-report callback.
    union {
      clsp_video_access_unit_callback_t video_access_unit;  ///< Optional retained complete encoded-AU callback.
      clsp_video_frame_callback_t video_frame;  ///< ABI-v2 native source-compatibility name.
    };
    clsp_path_probe_callback_t path_probe;  ///< Optional coarse DPLPMTUD control callback.
  } clsp_callbacks_t;

  /** @brief Callback table copied during native handoff construction. */
  typedef struct clsp_handoff_callbacks {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_handoff_callbacks_t)`.
    void *context;  ///< Explicitly retained callback context, or null.
    clsp_context_retain_t retain_context;  ///< Required retain operation for nonnull context.
    clsp_context_release_t release_context;  ///< Required release operation for nonnull context.
    clsp_handoff_phase_callback_t phase;  ///< Optional phase transition callback.
    clsp_handoff_baseline_callback_t baseline;  ///< Optional baseline requirement/ACK callback.
    clsp_handoff_rekey_callback_t rekey;  ///< Optional fresh-association attempt callback.
    clsp_handoff_terminal_callback_t terminal;  ///< Optional latched terminal callback.
  } clsp_handoff_callbacks_t;

  /**
   * @brief Return the C ABI version without constructing a core.
   *
   * @return `CLSP_CORE_ABI_VERSION`.
   */
  uint32_t clsp_core_abi_version(void);

  /**
   * @brief Return the portable-core source digest.
   *
   * @return Static null-terminated lowercase SHA-256 string.
   */
  const char *clsp_core_source_digest(void);

  /**
   * @brief Return the linked provider mask.
   *
   * @return Bitwise combination of `clsp_provider_flag_t`.
   */
  uint32_t clsp_core_provider_flags(void);

  /**
   * @brief Construct a native core handle without starting network activity.
   *
   * @param configuration Fixed-layout configuration copied by the core.
   * @param callbacks Optional callback table copied by the core.
   * @param output Receives an owned handle with retain count one on success.
   * @return Typed construction status.
   */
  clsp_status_t clsp_core_create(
    const clsp_configuration_t *configuration,
    const clsp_callbacks_t *callbacks,
    clsp_core_t **output
  );

  /**
   * @brief Add one owning reference to a core handle.
   *
   * @param core Core handle, or null for no operation.
   */
  void clsp_core_retain(clsp_core_t *core);

  /**
   * @brief Release one owning reference to a core handle.
   *
   * @param core Core handle, or null for no operation.
   */
  void clsp_core_release(clsp_core_t *core);

  /**
   * @brief Construct a native reconnect/rekey owner above one active association core.
   *
   * The handoff retains `active` and never exposes packet, key, certificate, endpoint,
   * attach-token, or allocator ownership through its callbacks or snapshots.
   *
   * @param active Current association-specific core.
   * @param active_connection_generation Nonzero authoritative connection generation.
   * @param active_input_generation Nonzero authoritative input generation.
   * @param callbacks Optional coarse callback table copied by the handoff.
   * @param output Receives an owned handoff handle with retain count one.
   * @return Typed construction status.
   */
  clsp_status_t clsp_handoff_create(
    clsp_core_t *active,
    uint32_t active_connection_generation,
    uint32_t active_input_generation,
    const clsp_handoff_callbacks_t *callbacks,
    clsp_handoff_t **output
  );

  /** @brief Add one owning reference to a native handoff handle. */
  void clsp_handoff_retain(clsp_handoff_t *handoff);

  /** @brief Release one owning reference and its retained association cores. */
  void clsp_handoff_release(clsp_handoff_t *handoff);

  /**
   * @brief Retain a fresh candidate association and begin reconnect/rekey.
   *
   * @param handoff Native handoff owner.
   * @param candidate Distinct association-specific candidate core.
   * @param candidate_connection_generation Strictly newer nonzero connection generation.
   * @param reason One `clsp_handoff_reason_t` value.
   * @return Typed transition status.
   */
  clsp_status_t clsp_handoff_begin(
    clsp_handoff_t *handoff,
    clsp_core_t *candidate,
    uint32_t candidate_connection_generation,
    uint32_t reason
  );

  /** @brief Mark the exact candidate identities and authorization authenticated. */
  clsp_status_t clsp_handoff_authenticate(
    clsp_handoff_t *handoff,
    uint32_t candidate_connection_generation
  );

  /**
   * @brief Report terminal transport loss for one retained association core.
   *
   * Pre-neutralization candidate loss may fall back only when the old association
   * was never lost. Old loss and every post-neutralization/committed loss fail closed.
   */
  clsp_status_t clsp_handoff_lost(
    clsp_handoff_t *handoff,
    clsp_core_t *association
  );

  /** @brief Drain old producer leases, Apple callbacks, and held input before ATTACH. */
  clsp_status_t clsp_handoff_neutralize(clsp_handoff_t *handoff);

  /**
   * @brief Atomically reserve, mark, and publish one immutable ATTACH request.
   *
   * Queue capacity is reserved while the request remains invisible. The handoff
   * then enters `CLSP_HANDOFF_PHASE_ATTACH_SUBMITTED` before the candidate runtime
   * publishes the request and wakes its worker. Any failure returns with request
   * ID zero and leaves the handoff definitely not submitted.
   */
  clsp_status_t clsp_handoff_submit_attach(
    clsp_handoff_t *handoff,
    uint16_t message_type,
    uint64_t request_id,
    clsp_const_byte_span_t payload,
    uint32_t deadline_milliseconds,
    clsp_control_submission_t *output
  );

  /** @brief Irreversibly commit authenticated ATTACH to the candidate generation. */
  clsp_status_t clsp_handoff_commit(
    clsp_handoff_t *handoff,
    uint32_t new_input_generation
  );

  /**
   * @brief Cancel an uncommitted candidate using an explicit outcome classification.
   *
   * Definite rejection before neutralization restores the old core immediately.
   * Definite rejection after neutralization keeps old producers closed until a fresh
   * baseline ACK for the same old input generation. Ambiguous outcome is forward-only
   * and terminal; it never restores the old association.
   */
  clsp_status_t clsp_handoff_cancel(
    clsp_handoff_t *handoff,
    uint32_t kind
  );

  /**
   * @brief Accept one authenticated fresh-baseline ACK for the currently gated generation.
   *
   * This operation is normally completed automatically from native LSPI processing;
   * the explicit API permits a coarse control-plane baseline proof without packet data.
   */
  clsp_status_t clsp_handoff_acknowledge_baseline(
    clsp_handoff_t *handoff,
    uint32_t input_generation,
    uint64_t baseline_id
  );

  /** @brief Stop and release the retained prior association after committed handoff. */
  clsp_status_t clsp_handoff_retire(clsp_handoff_t *handoff);

  /** @brief Copy one secret-free native handoff telemetry snapshot. */
  clsp_status_t clsp_handoff_copy_snapshot(
    const clsp_handoff_t *handoff,
    clsp_handoff_snapshot_t *output
  );

  /** @brief Copy association-local input-baseline readiness without claiming a handoff observer. */
  clsp_status_t clsp_core_copy_input_baseline(
    const clsp_core_t *core,
    clsp_input_baseline_snapshot_t *output
  );

  /** @brief Wait for one exact input generation's authenticated baseline ACK. */
  clsp_status_t clsp_core_wait_input_baseline(
    const clsp_core_t *core,
    uint32_t input_generation,
    uint32_t timeout_milliseconds,
    clsp_input_baseline_snapshot_t *output
  );

  /**
   * @brief Start a pinned DTLS association on a nonblocking UDP/kqueue worker.
   *
   * @param core Core handle.
   * @param endpoint Exact remote endpoint and required leaf-SPKI pin.
   * @return Success or a fail-closed provider/lifecycle status.
   */
  clsp_status_t clsp_core_start(clsp_core_t *core, const clsp_endpoint_t *endpoint);

  /**
   * @brief Stop native transport ownership and quiesce callbacks.
   *
   * @param core Core handle.
   * @return Typed lifecycle status.
   */
  clsp_status_t clsp_core_stop(clsp_core_t *core);

  /**
   * @brief Queue one reliable LSPC request for DTLS protection and transmission.
   *
   * The native core assigns the message ID, includes the current selective ACK
   * state, retains a byte-identical frame for bounded RTO retries, and delivers
   * the authenticated response through `clsp_control_callback_t`.
   *
   * @param core Authenticated core handle.
   * @param message_type Nonzero LSP/1 message type.
   * @param request_id Random nonzero connection-local request identifier.
   * @param payload Deterministic-CBOR payload fitting one path-safe record.
   * @param deadline_milliseconds Relative operation deadline, 20 through 30000 ms.
   * @return Typed queueing status.
   */
  clsp_status_t clsp_core_send_control(
    clsp_core_t *core,
    uint16_t message_type,
    uint64_t request_id,
    clsp_const_byte_span_t payload,
    uint32_t deadline_milliseconds
  );

  /** @brief Queue one semantic response correlated to an authenticated host request. */
  clsp_status_t clsp_core_send_control_response(
    clsp_core_t *core,
    uint16_t message_type,
    uint64_t request_id,
    clsp_const_byte_span_t payload,
    uint8_t error_response,
    uint32_t deadline_milliseconds
  );

  /** @brief Wait until one queued semantic response is submitted and cached. */
  clsp_status_t clsp_core_wait_control_response(
    clsp_core_t *core,
    uint64_t request_id,
    uint32_t timeout_milliseconds
  );

  /** @brief Install exact host-audio SSRC/PT/generation admission before AUDIO_CONFIG_ACK. */
  clsp_status_t clsp_core_configure_audio(
    clsp_core_t *core,
    const clsp_audio_configuration_t *configuration
  );

  /** @brief Install exact reverse-microphone sender mapping before semantic ACK. */
  clsp_status_t clsp_core_configure_microphone(
    clsp_core_t *core,
    const clsp_microphone_configuration_t *configuration
  );

  /** @brief Queue one complete mono Opus packet into the bounded native mic sender. */
  clsp_status_t clsp_core_submit_microphone_packet(
    clsp_core_t *core,
    clsp_const_byte_span_t opus_packet
  );

  /** @brief Mark the next microphone RTP packet as a capture discontinuity. */
  clsp_status_t clsp_core_mark_microphone_discontinuity(clsp_core_t *core);

  /** @brief Stop reverse microphone and discard all queued stale packets. */
  clsp_status_t clsp_core_stop_microphone(clsp_core_t *core);

  /** @brief Install exact native video mapping before VIDEO_CONFIG_ACK. */
  clsp_status_t clsp_core_configure_video(
    clsp_core_t *core,
    const clsp_video_configuration_t *configuration
  );

  /** @brief Publish retained completed frames only after VIDEO_CONFIG_ACK submission. */
  clsp_status_t clsp_core_activate_video(
    clsp_core_t *core,
    uint32_t video_generation
  );

  /** @brief Enable native 1,200-to-1,400-to-family-ceiling DPLPMTUD. */
  clsp_status_t clsp_core_start_path_discovery(clsp_core_t *core);

  /** @brief Queue one reliable client PATH_PROBE intent and its exact-size LSPP. */
  clsp_status_t clsp_core_send_path_probe(
    clsp_core_t *core,
    uint64_t probe_id,
    uint16_t udp_payload_size,
    uint64_t request_id,
    clsp_const_byte_span_t payload,
    uint32_t deadline_milliseconds
  );

  /** @brief Retain one authenticated host PATH_PROBE intent until matching LSPP. */
  clsp_status_t clsp_core_accept_path_probe(
    clsp_core_t *core,
    uint64_t probe_id,
    uint16_t udp_payload_size,
    uint64_t request_id
  );

  /** @brief Confirm one exact authenticated client-initiated PATH_PROBE_ACK. */
  clsp_status_t clsp_core_confirm_path_probe(
    clsp_core_t *core,
    uint64_t probe_id,
    uint16_t received_payload_size
  );

  /** @brief Report one terminal decoder result for an exact delivered frame/epoch and current hardware credit. */
  clsp_status_t clsp_core_report_video_decode(
    clsp_core_t *core,
    uint32_t video_generation,
    uint64_t frame_id,
    uint32_t recovery_epoch,
    uint8_t decoder_status,
    uint8_t decoder_credit,
    uint8_t render_mailbox_occupancy
  );

  /** @brief Report one Metal commit for LSPV state. */
  clsp_status_t clsp_core_report_video_commit(
    clsp_core_t *core,
    uint32_t video_generation,
    uint64_t frame_id,
    uint8_t render_mailbox_occupancy
  );

  /** @brief Install one exact authenticated input-only START_RESPONSE mapping. */
  clsp_status_t clsp_core_configure_input(
    clsp_core_t *core,
    const clsp_input_configuration_t *configuration
  );

  /** @brief Submit one relative-pointer sample to the native cumulative composer. */
  clsp_status_t clsp_core_submit_pointer(
    clsp_core_t *core,
    const clsp_pointer_sample_t *sample
  );

  /** @brief Submit one ordered keyboard or pointer-button transition. */
  clsp_status_t clsp_core_submit_input_edge(
    clsp_core_t *core,
    const clsp_input_edge_t *edge
  );

  /** @brief Submit one GameController lifecycle or digital-button edge. */
  clsp_status_t clsp_core_submit_controller_edge(clsp_core_t *core, const clsp_controller_edge_t *edge);

  /** @brief Submit latest GameController trigger/stick state. */
  clsp_status_t clsp_core_submit_controller_state(clsp_core_t *core, const clsp_controller_state_t *state);

  /** @brief Submit latest GameController gyro or accelerometer state. */
  clsp_status_t clsp_core_submit_controller_sensor(clsp_core_t *core, const clsp_controller_sensor_t *sensor);

  /** @brief Submit a controller touchpad begin/end/cancel edge. */
  clsp_status_t clsp_core_submit_controller_touch_edge(clsp_core_t *core, const clsp_controller_touch_edge_t *edge);

  /** @brief Submit latest controller touchpad coordinates. */
  clsp_status_t clsp_core_submit_controller_touch_state(clsp_core_t *core, const clsp_controller_touch_state_t *state);

  /** @brief Stop accepting samples and release native capture authority state. */
  clsp_status_t clsp_core_neutralize_input(clsp_core_t *core);

  /**
   * @brief Start preferred IOHID capture on a dedicated native dispatch queue.
   *
   * On failure, callbacks are quiesced before return so AppKit can safely
   * become the sole fallback owner.
   */
  clsp_status_t clsp_core_start_apple_input_capture(
    clsp_core_t *core,
    clsp_apple_input_capture_t **output
  );

  /** @brief Quiesce callbacks, neutralize authority, and release a native capture owner. */
  void clsp_apple_input_capture_stop(clsp_apple_input_capture_t *capture);

  /**
   * @brief Copy a low-rate telemetry snapshot.
   *
   * @param core Core handle.
   * @param output Caller-owned fixed-layout output.
   * @return Typed copy status.
   */
  clsp_status_t clsp_core_copy_telemetry(
    const clsp_core_t *core,
    clsp_telemetry_snapshot_t *output
  );

  /**
   * @brief Add one owning reference to a retained callback buffer.
   *
   * @param buffer Buffer handle, or null for no operation.
   */
  void clsp_buffer_retain(clsp_buffer_t *buffer);

  /**
   * @brief Release one owning reference to a retained callback buffer.
   *
   * @param buffer Buffer handle, or null for no operation.
   */
  void clsp_buffer_release(clsp_buffer_t *buffer);

  /**
   * @brief Borrow immutable bytes from a retained buffer.
   *
   * The returned span remains valid while the caller retains `buffer`.
   *
   * @param buffer Retained buffer handle.
   * @param output Receives a borrowed pointer/length span.
   * @return Typed access status.
   */
  clsp_status_t clsp_buffer_bytes(
    const clsp_buffer_t *buffer,
    clsp_const_byte_span_t *output
  );

  /**
   * @brief Return a stable English diagnostic label for one status value.
   *
   * @param status Typed status.
   * @return Static null-terminated diagnostic string.
   */
  const char *clsp_status_description(clsp_status_t status);

#ifdef __cplusplus
}
#endif

#endif
