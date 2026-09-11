/**
 * @file SecurityProviders.h
 * @brief Exact-policy wolfSSL DTLS client and directional libSRTP context owners.
 */

#pragma once

#include "CLSPCore.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace umbra::lsp {
  /** @brief RFC 5764 exporter length for AEAD AES-128-GCM. */
  inline constexpr std::size_t dtls_srtp_exporter_size = 56;

  /** @brief Exact directional DTLS-SRTP exporter bytes. */
  using DtlsSrtpExporter = std::array<std::uint8_t, dtls_srtp_exporter_size>;

  /** @brief Dedicated TLS exporter length for PIN-pairing transcript binding. */
  inline constexpr std::size_t pairing_exporter_size = 32;

  /** @brief Dedicated `EXPORTER-Lumen-LSP-Pairing-v1` bytes. */
  using PairingExporter = std::array<std::uint8_t, pairing_exporter_size>;

  /** @brief Exact negotiated inbound video SRTP stream registry. */
  struct VideoSrtpInboundConfiguration {
    std::uint32_t primary_ssrc {};  ///< Required primary video SSRC using encrypted extensions.
    std::uint32_t flexfec_ssrc {};  ///< Optional FlexFEC SSRC without encrypted extensions.
    std::uint32_t rtx_ssrc {};  ///< Optional RFC 4588 SSRC using encrypted copied extensions.
  };

  /** @brief Authenticated DTLS application-record receiver. */
  using DtlsApplicationDataCallback = bool (*)(void *context, std::span<const std::uint8_t> plaintext) noexcept;

  /** @brief Concrete wolfSSL 5.9.2 DTLS 1.3 client bound to one connected UDP socket. */
  class WolfSSLDtlsClient final {
  public:
    /** @brief Construct an empty provider. */
    WolfSSLDtlsClient() noexcept;

    WolfSSLDtlsClient(const WolfSSLDtlsClient &) = delete;
    WolfSSLDtlsClient &operator=(const WolfSSLDtlsClient &) = delete;

    /** @brief Destroy the association and clear exported secrets. */
    ~WolfSSLDtlsClient();

    /**
     * @brief Configure the exact LSP/1 policy for one connected socket.
     *
     * @param socket Connected nonblocking UDP socket.
     * @param peer_address Complete connected peer address.
     * @param peer_address_size Encoded peer-address length.
     * @param expected_spki_sha256 Required invitation/trust SPKI digest.
     * @param callback Authenticated application-record callback.
     * @param callback_context Opaque callback context.
     * @return Provider initialization status.
     */
    [[nodiscard]] clsp_status_t initialize(
      int socket,
      const void *peer_address,
      unsigned int peer_address_size,
      std::span<const std::uint8_t, 32> expected_spki_sha256,
      DtlsApplicationDataCallback callback,
      void *callback_context
    ) noexcept;

    /** @brief Emit the initial ClientHello or advance a waiting handshake. */
    [[nodiscard]] clsp_status_t advance_handshake() noexcept;

    /**
     * @brief Process exactly one RFC 7983-classified DTLS datagram.
     *
     * @param datagram Complete UDP payload.
     * @return Exact provider status.
     */
    [[nodiscard]] clsp_status_t receive(std::span<const std::uint8_t> datagram) noexcept;

    /**
     * @brief Protect and send one LSPC application record.
     *
     * @param plaintext Complete LSPC frame.
     * @return Exact provider status.
     */
    [[nodiscard]] clsp_status_t send_application_data(std::span<const std::uint8_t> plaintext) noexcept;

    /**
     * @brief Process one expired retransmission timer without authenticating the peer.
     * @return Retransmission status; success does not mean handshake completion.
     */
    [[nodiscard]] clsp_status_t handle_timeout() noexcept;

    /** @brief Return the current whole-second DTLS timeout, or zero when unavailable. */
    [[nodiscard]] std::uint32_t timeout_seconds() const noexcept;

    /** @brief Return whether exact policy, SPKI pinning, and exporter validation succeeded. */
    [[nodiscard]] bool authenticated() const noexcept;

    /** @brief Return the validated 56-byte exporter after authentication. */
    [[nodiscard]] const DtlsSrtpExporter &exporter() const noexcept;

    /** @brief Return the dedicated validated 32-byte PIN-pairing exporter. */
    [[nodiscard]] const PairingExporter &pairing_exporter() const noexcept;

  private:
    class Impl;
    Impl *impl_ {};  ///< Nothrow-allocated provider implementation.
  };

  /** @brief Directional libSRTP 2.8.0 AEAD AES-128-GCM context pair. */
  class SrtpSession final {
  public:
    /** @brief Construct an empty SRTP owner. */
    SrtpSession() noexcept;

    SrtpSession(const SrtpSession &) = delete;
    SrtpSession &operator=(const SrtpSession &) = delete;

    /** @brief Destroy contexts and clear copied key material. */
    ~SrtpSession();

    /**
     * @brief Install client-write outbound and server-write inbound contexts.
     *
     * @param exporter Exact RFC 5764 exporter bytes.
     * @return Exact fail-closed provider status.
     */
    [[nodiscard]] clsp_status_t initialize(const DtlsSrtpExporter &exporter) noexcept;

    /**
     * @brief Authenticate and decrypt one received SRTP or SRTCP packet in place.
     *
     * @param packet Mutable packet capacity containing the protected packet.
     * @param length In/out protected/plaintext size.
     * @param rtcp Selects SRTCP instead of SRTP.
     * @param replay Set only when libSRTP rejected an authenticated-sequence replay candidate.
     * @return Exact authentication result.
     */
    [[nodiscard]] clsp_status_t unprotect(
      std::span<std::uint8_t> packet,
      std::size_t &length,
      bool rtcp,
      bool &replay
    ) noexcept;

    /**
     * @brief Encrypt and authenticate one outbound RTP or RTCP packet in place.
     *
     * @param packet Mutable packet capacity including tag headroom.
     * @param length In/out plaintext/protected size.
     * @param rtcp Selects SRTCP instead of SRTP.
     * @return Exact protection result.
     */
    [[nodiscard]] clsp_status_t protect(
      std::span<std::uint8_t> packet,
      std::size_t &length,
      bool rtcp
    ) noexcept;

    /** @brief Query exact libSRTP bytes appended by outbound SRTCP protection. */
    [[nodiscard]] clsp_status_t rtcp_protect_trailer_length(std::size_t &length) const noexcept;

    /**
     * @brief Add one exact negotiated inbound SSRC policy.
     *
     * @param ssrc Nonzero negotiated inbound synchronization source.
     * @param encrypted_extension_ids Optional RFC 6904 extension IDs.
     * @return Exact provider status.
     */
    [[nodiscard]] clsp_status_t configure_inbound_stream(
      std::uint32_t ssrc,
      std::span<const int> encrypted_extension_ids = {}
    ) noexcept;

    /**
     * @brief Install the negotiated primary, FlexFEC, and RTX inbound policies.
     *
     * RFC 6904 applies only to the primary stream and the RTX stream that copies
     * primary RTP header extensions. The FlexFEC repair stream uses the same
     * server-write master material and an independent replay database without
     * encrypted-extension processing.
     *
     * @param configuration Exact noncolliding negotiated video SSRC registry.
     * @param encrypted_extension_ids RFC 6904 extension IDs for primary and RTX.
     * @return Exact provider status.
     */
    [[nodiscard]] clsp_status_t configure_video_inbound(
      const VideoSrtpInboundConfiguration &configuration,
      std::span<const int> encrypted_extension_ids
    ) noexcept;

    /** @brief Authenticate/decrypt one packet through the video-specific context. */
    [[nodiscard]] clsp_status_t unprotect_video(
      std::span<std::uint8_t> packet,
      std::size_t &length,
      bool rtcp,
      bool &replay
    ) noexcept;

    /** @brief Return whether both directional contexts are live. */
    [[nodiscard]] bool ready() const noexcept;

  private:
    class Impl;
    Impl *impl_ {};  ///< Nothrow-allocated provider implementation.
  };
}  // namespace umbra::lsp
