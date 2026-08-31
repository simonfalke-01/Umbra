/**
 * @file SecurityProviders.cpp
 * @brief wolfSSL 5.9.2 DTLS 1.3 and libSRTP 2.8.0 production providers.
 */

#include "SecurityProviders.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <new>
#include <optional>

#if CLSP_CORE_HAS_WOLFSSL
  #include <wolfssl/options.h>
  #include <wolfssl/error-ssl.h>
  #include <wolfssl/ssl.h>
  #include <wolfssl/wolfcrypt/sha256.h>
  #include <wolfssl/wolfio.h>

  #include <cerrno>
  #include <sys/socket.h>
#endif

#if CLSP_CORE_HAS_LIBSRTP
  #include <srtp2/srtp.h>
  #include <pthread.h>
#endif

namespace umbra::lsp {
  namespace {
    /** @brief Clear secret bytes without dead-store elimination. */
    void clear_secret(const std::span<std::uint8_t> bytes) noexcept {
      volatile std::uint8_t *cursor = bytes.data();
      for (std::size_t index = 0; index < bytes.size(); ++index) {
        cursor[index] = 0;
      }
    }

#if CLSP_CORE_HAS_WOLFSSL
    /** @brief Parsed strict-DER tag and complete/content byte ranges. */
    struct DerElement {
      std::uint8_t tag {};  ///< DER tag octet.
      std::span<const std::uint8_t> encoded;  ///< Complete tag-length-value bytes.
      std::span<const std::uint8_t> content;  ///< Value bytes only.
    };

    /** @brief Parse one canonical definite-length DER element. */
    [[nodiscard]] std::optional<DerElement> parse_der_element(
      const std::span<const std::uint8_t> input,
      std::size_t &offset
    ) noexcept {
      const auto begin = offset;
      if (offset + 2U > input.size()) {
        return std::nullopt;
      }
      const auto tag = input[offset++];
      const auto first_length = input[offset++];
      std::size_t content_size = 0;
      if ((first_length & 0x80U) == 0) {
        content_size = first_length;
      } else {
        const auto length_octets = static_cast<std::size_t>(first_length & 0x7fU);
        if (length_octets == 0 || length_octets > sizeof(std::size_t) ||
            offset + length_octets > input.size() || input[offset] == 0) {
          return std::nullopt;
        }
        for (std::size_t index = 0; index < length_octets; ++index) {
          if (content_size > (std::numeric_limits<std::size_t>::max() >> 8U)) {
            return std::nullopt;
          }
          content_size = (content_size << 8U) | input[offset++];
        }
        if (content_size < 128U) {
          return std::nullopt;
        }
      }
      if (content_size > input.size() - offset) {
        return std::nullopt;
      }
      const auto content_begin = offset;
      offset += content_size;
      return DerElement {
        .tag = tag,
        .encoded = input.subspan(begin, offset - begin),
        .content = input.subspan(content_begin, content_size),
      };
    }

    /** @brief Locate the complete DER SubjectPublicKeyInfo in an X.509 certificate. */
    [[nodiscard]] std::optional<std::span<const std::uint8_t>> extract_spki(
      const std::span<const std::uint8_t> certificate_der
    ) noexcept {
      std::size_t certificate_offset = 0;
      const auto certificate = parse_der_element(certificate_der, certificate_offset);
      if (!certificate || certificate->tag != 0x30U || certificate_offset != certificate_der.size()) {
        return std::nullopt;
      }
      std::size_t certificate_content_offset = 0;
      const auto tbs = parse_der_element(certificate->content, certificate_content_offset);
      if (!tbs || tbs->tag != 0x30U) {
        return std::nullopt;
      }
      std::size_t tbs_offset = 0;
      auto field = parse_der_element(tbs->content, tbs_offset);
      if (!field) {
        return std::nullopt;
      }
      if (field->tag == 0xa0U) {
        field = parse_der_element(tbs->content, tbs_offset);
        if (!field) {
          return std::nullopt;
        }
      }
      for (std::size_t field_index = 0; field_index < 4U; ++field_index) {
        field = parse_der_element(tbs->content, tbs_offset);
        if (!field) {
          return std::nullopt;
        }
      }
      const auto spki = parse_der_element(tbs->content, tbs_offset);
      if (!spki || spki->tag != 0x30U) {
        return std::nullopt;
      }
      return spki->encoded;
    }

    /** @brief Compare two 32-byte pins without early exit. */
    [[nodiscard]] bool equal_pin(
      const std::span<const std::uint8_t, 32> left,
      const std::span<const std::uint8_t, 32> right
    ) noexcept {
      std::uint8_t difference = 0;
      for (std::size_t index = 0; index < left.size(); ++index) {
        difference = static_cast<std::uint8_t>(difference | (left[index] ^ right[index]));
      }
      return difference == 0;
    }

    pthread_once_t wolfssl_initialization_once = PTHREAD_ONCE_INIT;  ///< Process-wide initialization guard.
    int wolfssl_initialization_result = WOLFSSL_FAILURE;  ///< Stable process-wide initialization result.

    /** @brief Initialize wolfSSL once without global-cleanup races. */
    void initialize_wolfssl_once() noexcept {
      wolfssl_initialization_result = wolfSSL_Init();
    }
#endif

#if CLSP_CORE_HAS_LIBSRTP
    pthread_once_t libsrtp_initialization_once = PTHREAD_ONCE_INIT;  ///< Process-wide initialization guard.
    srtp_err_status_t libsrtp_initialization_result = srtp_err_status_init_fail;  ///< Stable libSRTP result.

    /** @brief Initialize libSRTP once without process-global shutdown races. */
    void initialize_libsrtp_once() noexcept {
      libsrtp_initialization_result = srtp_init();
    }
#endif
  }  // namespace

  class WolfSSLDtlsClient::Impl {
  public:
#if CLSP_CORE_HAS_WOLFSSL
    /** @brief Release all wolfSSL and exporter state. */
    ~Impl() {
      if (session_ != nullptr) {
        wolfSSL_free(session_);
      }
      if (context_ != nullptr) {
        wolfSSL_CTX_free(context_);
      }
      clear_secret(exporter_);
      clear_secret(expected_spki_sha256_);
    }

    /** @brief Configure the exact LSP client profile. */
    [[nodiscard]] clsp_status_t initialize(
      const int socket,
      const void *peer_address,
      const unsigned int peer_address_size,
      const std::span<const std::uint8_t, 32> expected_spki_sha256,
      const DtlsApplicationDataCallback callback,
      void *callback_context
    ) noexcept {
      if (socket < 0 || peer_address == nullptr || peer_address_size == 0 || callback == nullptr) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      const auto *library_version = wolfSSL_lib_version();
      if (library_version == nullptr || std::strcmp(library_version, "5.9.2") != 0 ||
          pthread_once(&wolfssl_initialization_once, initialize_wolfssl_once) != 0 ||
          wolfssl_initialization_result != WOLFSSL_SUCCESS) {
        return CLSP_STATUS_MISSING_WOLFSSL;
      }

      socket_ = socket;
      callback_ = callback;
      callback_context_ = callback_context;
      std::copy(expected_spki_sha256.begin(), expected_spki_sha256.end(), expected_spki_sha256_.begin());
      context_ = wolfSSL_CTX_new(wolfDTLSv1_3_client_method());
      if (context_ == nullptr ||
          wolfSSL_CTX_set_cipher_list(context_, "TLS13-AES128-GCM-SHA256") != WOLFSSL_SUCCESS) {
        return CLSP_STATUS_DTLS_FAILURE;
      }
      (void)wolfSSL_CTX_set_session_cache_mode(context_, WOLFSSL_SESS_CACHE_OFF);
      int group = WOLFSSL_ECC_X25519;
      if (wolfSSL_CTX_set_groups(context_, &group, 1) != WOLFSSL_SUCCESS ||
          wolfSSL_CTX_set_tlsext_use_srtp(context_, "SRTP_AEAD_AES_128_GCM") != 0 ||
          wolfSSL_CTX_no_ticket_TLSv13(context_) != 0) {
        return CLSP_STATUS_DTLS_FAILURE;
      }
      wolfSSL_CTX_set_verify(context_, WOLFSSL_VERIFY_NONE, nullptr);
      wolfSSL_CTX_SetIORecv(context_, receive_callback);
      wolfSSL_CTX_SetIOSend(context_, send_callback);

      session_ = wolfSSL_new(context_);
      if (session_ == nullptr) {
        return CLSP_STATUS_DTLS_FAILURE;
      }
      char alpn[] = "lumen-stream/1";
      group = WOLFSSL_ECC_X25519;
      if (wolfSSL_set_groups(session_, &group, 1) != WOLFSSL_SUCCESS ||
          wolfSSL_UseALPN(
            session_,
            alpn,
            static_cast<unsigned int>(sizeof(alpn) - 1U),
            WOLFSSL_ALPN_FAILED_ON_MISMATCH
          ) != WOLFSSL_SUCCESS ||
          wolfSSL_set_tlsext_use_srtp(session_, "SRTP_AEAD_AES_128_GCM") != 0 ||
          wolfSSL_no_ticket_TLSv13(session_) != 0 ||
          wolfSSL_dtls_set_peer(session_, const_cast<void *>(peer_address), peer_address_size) != WOLFSSL_SUCCESS) {
        return CLSP_STATUS_DTLS_FAILURE;
      }
      wolfSSL_dtls_set_using_nonblock(session_, 1);
      wolfSSL_SetIOReadCtx(session_, this);
      wolfSSL_SetIOWriteCtx(session_, this);
      wolfSSL_KeepArrays(session_);
      return CLSP_STATUS_OK;
    }

    /** @brief Advance a handshake without an incoming datagram. */
    [[nodiscard]] clsp_status_t advance_handshake() noexcept {
      return complete_or_wait(wolfSSL_connect(session_));
    }

    /** @brief Process one complete DTLS datagram. */
    [[nodiscard]] clsp_status_t receive(const std::span<const std::uint8_t> datagram) noexcept {
      if (session_ == nullptr || datagram.empty() || datagram.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      pending_input_ = datagram;
      input_consumed_ = false;
      auto status = authenticated_ ? drain_application_records() : complete_or_wait(wolfSSL_connect(session_));
      pending_input_ = {};
      input_consumed_ = false;
      return status;
    }

    /** @brief Protect and emit one DTLS application record. */
    [[nodiscard]] clsp_status_t send_application_data(const std::span<const std::uint8_t> plaintext) noexcept {
      if (!authenticated_) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      if (plaintext.empty() || plaintext.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      const auto written = wolfSSL_write(session_, plaintext.data(), static_cast<int>(plaintext.size()));
      return written == static_cast<int>(plaintext.size()) ? CLSP_STATUS_OK : operation_status(written);
    }

    /** @brief Process one DTLS retransmission timeout. */
    [[nodiscard]] clsp_status_t handle_timeout() noexcept {
      if (session_ == nullptr || authenticated_) {
        return CLSP_STATUS_OK;
      }
      return complete_or_wait(wolfSSL_dtls_got_timeout(session_));
    }

    /** @brief Return wolfSSL's current timeout. */
    [[nodiscard]] std::uint32_t timeout_seconds() const noexcept {
      return session_ == nullptr || authenticated_ ? 0U : wolfSSL_dtls_get_current_timeout(session_);
    }

    /** @brief Return authentication completion. */
    [[nodiscard]] bool authenticated() const noexcept {
      return authenticated_;
    }

    /** @brief Return exporter bytes. */
    [[nodiscard]] const DtlsSrtpExporter &exporter() const noexcept {
      return exporter_;
    }

  private:
    /** @brief Supply one pending complete UDP datagram to wolfSSL. */
    static int receive_callback(WOLFSSL *session, char *buffer, const int size, void *opaque) noexcept {
      (void)session;
      auto *self = static_cast<Impl *>(opaque);
      if (self == nullptr || buffer == nullptr || size < 0) {
        return WOLFSSL_CBIO_ERR_GENERAL;
      }
      if (self->input_consumed_ || self->pending_input_.empty()) {
        return WOLFSSL_CBIO_ERR_WANT_READ;
      }
      if (self->pending_input_.size() > static_cast<std::size_t>(size)) {
        return WOLFSSL_CBIO_ERR_GENERAL;
      }
      std::memcpy(buffer, self->pending_input_.data(), self->pending_input_.size());
      self->input_consumed_ = true;
      return static_cast<int>(self->pending_input_.size());
    }

    /** @brief Submit one complete DTLS datagram on the connected UDP socket. */
    static int send_callback(WOLFSSL *session, char *buffer, const int size, void *opaque) noexcept {
      (void)session;
      auto *self = static_cast<Impl *>(opaque);
      if (self == nullptr || self->socket_ < 0 || buffer == nullptr || size <= 0) {
        return WOLFSSL_CBIO_ERR_GENERAL;
      }
      const auto sent = ::send(self->socket_, buffer, static_cast<std::size_t>(size), 0);
      if (sent == size) {
        return size;
      }
      return sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? WOLFSSL_CBIO_ERR_WANT_WRITE
                                                                   : WOLFSSL_CBIO_ERR_GENERAL;
    }

    /** @brief Convert a wolfSSL result into a fail-closed provider status. */
    [[nodiscard]] clsp_status_t operation_status(const int result) const noexcept {
      const auto error = wolfSSL_get_error(session_, result);
      return error == WOLFSSL_ERROR_WANT_READ || error == WOLFSSL_ERROR_WANT_WRITE ? CLSP_STATUS_OK
                                                                                   : CLSP_STATUS_DTLS_FAILURE;
    }

    /** @brief Complete exact-policy validation or accept a nonblocking wait. */
    [[nodiscard]] clsp_status_t complete_or_wait(const int result) noexcept {
      if (result == WOLFSSL_SUCCESS) {
        return authenticated_ ? CLSP_STATUS_OK : complete_handshake();
      }
      return operation_status(result);
    }

    /** @brief Validate negotiated policy, pin the server SPKI, and export 56 bytes. */
    [[nodiscard]] clsp_status_t complete_handshake() noexcept {
      char *selected_alpn = nullptr;
      unsigned short selected_alpn_size = 0;
      const auto *profile = wolfSSL_get_selected_srtp_profile(session_);
      const auto alpn_status = wolfSSL_ALPN_GetProtocol(session_, &selected_alpn, &selected_alpn_size);
      const auto *version = wolfSSL_get_version(session_);
      const auto *cipher = wolfSSL_get_cipher_name(session_);
      const auto *curve = wolfSSL_get_curve_name(session_);
      const auto cipher_matches = cipher != nullptr &&
                                  (std::strcmp(cipher, "TLS13-AES128-GCM-SHA256") == 0 ||
                                   std::strcmp(cipher, "TLS_AES_128_GCM_SHA256") == 0);
      if (version == nullptr || std::strcmp(version, "DTLSv1.3") != 0 || !cipher_matches ||
          curve == nullptr || std::strcmp(curve, "X25519") != 0 || profile == nullptr ||
          profile->id != SRTP_AEAD_AES_128_GCM || profile->name == nullptr ||
          std::strcmp(profile->name, "SRTP_AEAD_AES_128_GCM") != 0 ||
          alpn_status != WOLFSSL_SUCCESS || selected_alpn == nullptr || selected_alpn_size != 14U ||
          std::memcmp(selected_alpn, "lumen-stream/1", 14U) != 0) {
        return CLSP_STATUS_DTLS_FAILURE;
      }

      WOLFSSL_X509 *certificate = wolfSSL_get_peer_certificate(session_);
      if (certificate == nullptr) {
        return CLSP_STATUS_DTLS_FAILURE;
      }
      int certificate_size = 0;
      const auto *certificate_der = wolfSSL_X509_get_der(certificate, &certificate_size);
      std::array<std::uint8_t, 32> actual_pin {};
      const auto certificate_span = certificate_der != nullptr && certificate_size > 0 ?
                                      std::span<const std::uint8_t> {
                                        certificate_der,
                                        static_cast<std::size_t>(certificate_size),
                                      } :
                                      std::span<const std::uint8_t> {};
      const auto spki = extract_spki(certificate_span);
      const auto pin_status = spki && spki->size() <= std::numeric_limits<word32>::max() ?
                                wc_Sha256Hash(
                                  spki->data(),
                                  static_cast<word32>(spki->size()),
                                  actual_pin.data()
                                ) :
                                -1;
      wolfSSL_X509_free(certificate);
      if (pin_status != 0) {
        clear_secret(actual_pin);
        return CLSP_STATUS_DTLS_FAILURE;
      }
      const auto pin_matches = equal_pin(actual_pin, expected_spki_sha256_);
      clear_secret(actual_pin);
      if (!pin_matches) {
        return CLSP_STATUS_SPKI_MISMATCH;
      }

      std::size_t exporter_size = 0;
      if (wolfSSL_export_dtls_srtp_keying_material(session_, nullptr, &exporter_size) != LENGTH_ONLY_E ||
          exporter_size != exporter_.size()) {
        return CLSP_STATUS_DTLS_FAILURE;
      }
      exporter_size = exporter_.size();
      if (wolfSSL_export_dtls_srtp_keying_material(session_, exporter_.data(), &exporter_size) != WOLFSSL_SUCCESS ||
          exporter_size != exporter_.size()) {
        clear_secret(exporter_);
        return CLSP_STATUS_DTLS_FAILURE;
      }
      wolfSSL_FreeArrays(session_);
      authenticated_ = true;
      return CLSP_STATUS_OK;
    }

    /** @brief Drain authenticated application records already buffered by wolfSSL. */
    [[nodiscard]] clsp_status_t drain_application_records() noexcept {
      std::array<std::uint8_t, 16U * 1024U> plaintext {};
      for (std::size_t record = 0; record < 32U; ++record) {
        const auto size = wolfSSL_read(session_, plaintext.data(), static_cast<int>(plaintext.size()));
        if (size > 0) {
          const auto accepted = callback_(
            callback_context_,
            std::span<const std::uint8_t> {plaintext.data(), static_cast<std::size_t>(size)}
          );
          clear_secret(std::span<std::uint8_t> {plaintext.data(), static_cast<std::size_t>(size)});
          if (!accepted) {
            return CLSP_STATUS_DTLS_FAILURE;
          }
          continue;
        }
        clear_secret(plaintext);
        return operation_status(size);
      }
      clear_secret(plaintext);
      return CLSP_STATUS_DTLS_FAILURE;
    }

    WOLFSSL_CTX *context_ {};  ///< Exact DTLS 1.3 client context.
    WOLFSSL *session_ {};  ///< One peer-bound DTLS association.
    int socket_ {-1};  ///< Connected nonblocking UDP socket.
    std::span<const std::uint8_t> pending_input_ {};  ///< One complete incoming DTLS datagram.
    DtlsApplicationDataCallback callback_ {};  ///< Authenticated application-record receiver.
    void *callback_context_ {};  ///< Opaque application-record callback context.
    DtlsSrtpExporter exporter_ {};  ///< Validated RFC 5764 exporter bytes.
    std::array<std::uint8_t, 32> expected_spki_sha256_ {};  ///< Required server pin.
    bool input_consumed_ {};  ///< Whether wolfSSL consumed the pending datagram.
    bool authenticated_ {};  ///< Exact policy, pin, and exporter completion.
#else
    /** @brief No-op destructor for dependency-free builds. */
    ~Impl() = default;

    /** @brief Fail closed when wolfSSL is not linked. */
    [[nodiscard]] clsp_status_t initialize(
      int,
      const void *,
      unsigned int,
      std::span<const std::uint8_t, 32>,
      DtlsApplicationDataCallback,
      void *
    ) noexcept {
      return CLSP_STATUS_MISSING_WOLFSSL;
    }

    [[nodiscard]] clsp_status_t advance_handshake() noexcept { return CLSP_STATUS_MISSING_WOLFSSL; }
    [[nodiscard]] clsp_status_t receive(std::span<const std::uint8_t>) noexcept { return CLSP_STATUS_MISSING_WOLFSSL; }
    [[nodiscard]] clsp_status_t send_application_data(std::span<const std::uint8_t>) noexcept { return CLSP_STATUS_MISSING_WOLFSSL; }
    [[nodiscard]] clsp_status_t handle_timeout() noexcept { return CLSP_STATUS_MISSING_WOLFSSL; }
    [[nodiscard]] std::uint32_t timeout_seconds() const noexcept { return 0; }
    [[nodiscard]] bool authenticated() const noexcept { return false; }
    [[nodiscard]] const DtlsSrtpExporter &exporter() const noexcept { return exporter_; }

  private:
    DtlsSrtpExporter exporter_ {};  ///< Always-zero unavailable exporter.
#endif
  };

  WolfSSLDtlsClient::WolfSSLDtlsClient() noexcept:
      impl_ {new (std::nothrow) Impl} {
  }

  WolfSSLDtlsClient::~WolfSSLDtlsClient() {
    delete impl_;
  }

  clsp_status_t WolfSSLDtlsClient::initialize(
    const int socket,
    const void *peer_address,
    const unsigned int peer_address_size,
    const std::span<const std::uint8_t, 32> expected_spki_sha256,
    const DtlsApplicationDataCallback callback,
    void *callback_context
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->initialize(
                                socket,
                                peer_address,
                                peer_address_size,
                                expected_spki_sha256,
                                callback,
                                callback_context
                              );
  }

  clsp_status_t WolfSSLDtlsClient::advance_handshake() noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->advance_handshake();
  }

  clsp_status_t WolfSSLDtlsClient::receive(const std::span<const std::uint8_t> datagram) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->receive(datagram);
  }

  clsp_status_t WolfSSLDtlsClient::send_application_data(const std::span<const std::uint8_t> plaintext) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->send_application_data(plaintext);
  }

  clsp_status_t WolfSSLDtlsClient::handle_timeout() noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->handle_timeout();
  }

  std::uint32_t WolfSSLDtlsClient::timeout_seconds() const noexcept {
    return impl_ == nullptr ? 0U : impl_->timeout_seconds();
  }

  bool WolfSSLDtlsClient::authenticated() const noexcept {
    return impl_ != nullptr && impl_->authenticated();
  }

  const DtlsSrtpExporter &WolfSSLDtlsClient::exporter() const noexcept {
    static constexpr DtlsSrtpExporter unavailable {};
    return impl_ == nullptr ? unavailable : impl_->exporter();
  }

  class SrtpSession::Impl {
  public:
#if CLSP_CORE_HAS_LIBSRTP
    /** @brief Destroy directional contexts. */
    ~Impl() {
      if (inbound_ != nullptr) {
        srtp_dealloc(inbound_);
      }
      if (outbound_ != nullptr) {
        srtp_dealloc(outbound_);
      }
      clear_secret(inbound_master_key_);
    }

    /** @brief Install exact AEAD AES-128-GCM policies. */
    [[nodiscard]] clsp_status_t initialize(const DtlsSrtpExporter &exporter) noexcept {
      const auto *version = srtp_get_version_string();
      if (version == nullptr || std::strstr(version, "2.8.0") == nullptr ||
          pthread_once(&libsrtp_initialization_once, initialize_libsrtp_once) != 0 ||
          libsrtp_initialization_result != srtp_err_status_ok) {
        return CLSP_STATUS_MISSING_LIBSRTP;
      }

      std::array<std::uint8_t, 28> outbound_key {};
      std::array<std::uint8_t, 28> inbound_key {};
      std::copy_n(exporter.data(), 16U, outbound_key.data());
      std::copy_n(exporter.data() + 32U, 12U, outbound_key.data() + 16U);
      std::copy_n(exporter.data() + 16U, 16U, inbound_key.data());
      std::copy_n(exporter.data() + 44U, 12U, inbound_key.data() + 16U);
      inbound_master_key_ = inbound_key;

      srtp_policy_t outbound_policy {};
      srtp_crypto_policy_set_aes_gcm_128_16_auth(&outbound_policy.rtp);
      srtp_crypto_policy_set_aes_gcm_128_16_auth(&outbound_policy.rtcp);
      outbound_policy.ssrc.type = ssrc_any_outbound;
      outbound_policy.key = outbound_key.data();
      outbound_policy.window_size = 128;
      outbound_policy.allow_repeat_tx = 0;
      outbound_policy.next = nullptr;

      const auto outbound_status = srtp_create(&outbound_, &outbound_policy);
      const auto inbound_status = outbound_status == srtp_err_status_ok ?
                                    srtp_create(&inbound_, nullptr) :
                                    srtp_err_status_init_fail;
      clear_secret(outbound_key);
      clear_secret(inbound_key);
      if (outbound_status != srtp_err_status_ok || inbound_status != srtp_err_status_ok) {
        if (outbound_ != nullptr) {
          srtp_dealloc(outbound_);
          outbound_ = nullptr;
        }
        if (inbound_ != nullptr) {
          srtp_dealloc(inbound_);
          inbound_ = nullptr;
        }
        return CLSP_STATUS_SRTP_FAILURE;
      }
      return CLSP_STATUS_OK;
    }

    /** @brief Deprotect one packet in place. */
    [[nodiscard]] clsp_status_t unprotect(
      const std::span<std::uint8_t> packet,
      std::size_t &length,
      const bool rtcp,
      bool &replay
    ) noexcept {
      replay = false;
      if (inbound_ == nullptr || length > packet.size() || length > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      auto encoded_length = static_cast<int>(length);
      const auto status = rtcp ? srtp_unprotect_rtcp(inbound_, packet.data(), &encoded_length) :
                                 srtp_unprotect(inbound_, packet.data(), &encoded_length);
      if (status == srtp_err_status_replay_fail || status == srtp_err_status_replay_old) {
        replay = true;
        return CLSP_STATUS_SRTP_FAILURE;
      }
      if (status != srtp_err_status_ok || encoded_length < 0) {
        return CLSP_STATUS_SRTP_FAILURE;
      }
      length = static_cast<std::size_t>(encoded_length);
      return CLSP_STATUS_OK;
    }

    /** @brief Protect one packet in place. */
    [[nodiscard]] clsp_status_t protect(
      const std::span<std::uint8_t> packet,
      std::size_t &length,
      const bool rtcp
    ) noexcept {
      if (outbound_ == nullptr || length > packet.size() || packet.size() - length < 16U ||
          length > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      auto encoded_length = static_cast<int>(length);
      const auto status = rtcp ? srtp_protect_rtcp(outbound_, packet.data(), &encoded_length) :
                                 srtp_protect(outbound_, packet.data(), &encoded_length);
      if (status != srtp_err_status_ok || encoded_length < 0 || static_cast<std::size_t>(encoded_length) > packet.size()) {
        return CLSP_STATUS_SRTP_FAILURE;
      }
      length = static_cast<std::size_t>(encoded_length);
      return CLSP_STATUS_OK;
    }

    /** @brief Query exact outbound SRTCP trailer bytes for the installed policy. */
    [[nodiscard]] clsp_status_t rtcp_protect_trailer_length(std::size_t &length) const noexcept {
      if (outbound_ == nullptr) {
        return CLSP_STATUS_INVALID_STATE;
      }
      std::uint32_t trailer = 0;
      if (srtp_get_protect_rtcp_trailer_length(outbound_, 0, 0, &trailer) != srtp_err_status_ok || trailer == 0) {
        return CLSP_STATUS_SRTP_FAILURE;
      }
      length = trailer;
      return CLSP_STATUS_OK;
    }

    /** @brief Return directional readiness. */
    [[nodiscard]] bool ready() const noexcept {
      return inbound_ != nullptr && outbound_ != nullptr;
    }

    [[nodiscard]] clsp_status_t configure_video_inbound(
      const VideoSrtpInboundConfiguration &configuration,
      const std::span<const int> encrypted_extension_ids
    ) noexcept {
      const auto duplicate_flexfec = configuration.flexfec_ssrc != 0 &&
                                     configuration.flexfec_ssrc == configuration.primary_ssrc;
      const auto duplicate_rtx = configuration.rtx_ssrc != 0 &&
                                 (configuration.rtx_ssrc == configuration.primary_ssrc ||
                                  configuration.rtx_ssrc == configuration.flexfec_ssrc);
      if (configuration.primary_ssrc == 0 || duplicate_flexfec || duplicate_rtx ||
          encrypted_extension_ids.empty() ||
          encrypted_extension_ids.size() > 3U) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      auto status = configure_inbound_stream(configuration.primary_ssrc, encrypted_extension_ids);
      if (status == CLSP_STATUS_OK && configuration.flexfec_ssrc != 0) {
        status = configure_inbound_stream(configuration.flexfec_ssrc, {});
      }
      if (status == CLSP_STATUS_OK && configuration.rtx_ssrc != 0) {
        status = configure_inbound_stream(configuration.rtx_ssrc, encrypted_extension_ids);
      }
      return status;
    }

    /** @brief Add one exact inbound SSRC to the empty-by-default libSRTP session. */
    [[nodiscard]] clsp_status_t configure_inbound_stream(
      const std::uint32_t ssrc,
      const std::span<const int> encrypted_extension_ids
    ) noexcept {
      if (inbound_ == nullptr || ssrc == 0 || encrypted_extension_ids.size() > 3U) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      for (const auto &registered : registered_inbound_) {
        if (registered.ssrc == ssrc) {
          return registered.encrypted_extension_count == encrypted_extension_ids.size() &&
                         std::ranges::equal(
                           encrypted_extension_ids,
                           std::span<const int> {registered.encrypted_extensions}.first(
                             registered.encrypted_extension_count
                           )
                         ) ?
                   CLSP_STATUS_OK :
                   CLSP_STATUS_INVALID_STATE;
        }
      }
      auto *registration = std::ranges::find_if(registered_inbound_, [](const RegisteredInbound &entry) {
        return entry.ssrc == 0;
      });
      if (registration == registered_inbound_.end()) {
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      *registration = {};
      registration->ssrc = ssrc;
      registration->encrypted_extension_count = encrypted_extension_ids.size();
      std::copy(
        encrypted_extension_ids.begin(),
        encrypted_extension_ids.end(),
        registration->encrypted_extensions.begin()
      );
      srtp_policy_t policy {};
      srtp_crypto_policy_set_aes_gcm_128_16_auth(&policy.rtp);
      srtp_crypto_policy_set_aes_gcm_128_16_auth(&policy.rtcp);
      policy.ssrc.type = ssrc_specific;
      policy.ssrc.value = ssrc;
      policy.key = inbound_master_key_.data();
      policy.window_size = 128;
      policy.allow_repeat_tx = 0;
      if (!encrypted_extension_ids.empty()) {
        policy.enc_xtn_hdr = registration->encrypted_extensions.data();
        policy.enc_xtn_hdr_count = static_cast<int>(encrypted_extension_ids.size());
      }
      const auto added = srtp_add_stream(inbound_, &policy);
      if (added != srtp_err_status_ok) {
        *registration = {};
        return CLSP_STATUS_SRTP_FAILURE;
      }
      return CLSP_STATUS_OK;
    }

    [[nodiscard]] clsp_status_t unprotect_video(
      const std::span<std::uint8_t> packet,
      std::size_t &length,
      const bool rtcp,
      bool &replay
    ) noexcept {
      replay = false;
      return unprotect(packet, length, rtcp, replay);
    }

  private:
    /** @brief Exact dynamically installed inbound stream policy identity. */
    struct RegisteredInbound {
      std::array<int, 3> encrypted_extensions {};  ///< Copied RFC 6904 extension IDs.
      std::uint32_t ssrc {};  ///< Nonzero registered SSRC.
      std::size_t encrypted_extension_count {};  ///< Populated extension count.
    };

    srtp_t inbound_ {};  ///< Server-write inbound replay/authentication context.
    srtp_t outbound_ {};  ///< Client-write outbound replay/authentication context.
    std::array<std::uint8_t, 28> inbound_master_key_ {};  ///< Retained server-write video key+salt.
    std::array<RegisteredInbound, 8> registered_inbound_ {};  ///< Exact configured inbound SSRC policies.
#else
    /** @brief No-op destructor for dependency-free builds. */
    ~Impl() = default;

    [[nodiscard]] clsp_status_t initialize(const DtlsSrtpExporter &) noexcept {
      return CLSP_STATUS_MISSING_LIBSRTP;
    }

    [[nodiscard]] clsp_status_t unprotect(
      std::span<std::uint8_t>,
      std::size_t &,
      bool,
      bool &replay
    ) noexcept {
      replay = false;
      return CLSP_STATUS_MISSING_LIBSRTP;
    }

    [[nodiscard]] clsp_status_t protect(std::span<std::uint8_t>, std::size_t &, bool) noexcept {
      return CLSP_STATUS_MISSING_LIBSRTP;
    }

    [[nodiscard]] clsp_status_t rtcp_protect_trailer_length(std::size_t &) const noexcept {
      return CLSP_STATUS_MISSING_LIBSRTP;
    }

    [[nodiscard]] bool ready() const noexcept {
      return false;
    }

    [[nodiscard]] clsp_status_t configure_video_inbound(
      const VideoSrtpInboundConfiguration &,
      std::span<const int>
    ) noexcept {
      return CLSP_STATUS_MISSING_LIBSRTP;
    }

    [[nodiscard]] clsp_status_t configure_inbound_stream(std::uint32_t, std::span<const int>) noexcept {
      return CLSP_STATUS_MISSING_LIBSRTP;
    }

    [[nodiscard]] clsp_status_t unprotect_video(std::span<std::uint8_t>, std::size_t &, bool, bool &) noexcept {
      return CLSP_STATUS_MISSING_LIBSRTP;
    }
#endif
  };

  SrtpSession::SrtpSession() noexcept:
      impl_ {new (std::nothrow) Impl} {
  }

  SrtpSession::~SrtpSession() {
    delete impl_;
  }

  clsp_status_t SrtpSession::initialize(const DtlsSrtpExporter &exporter) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->initialize(exporter);
  }

  clsp_status_t SrtpSession::unprotect(
    const std::span<std::uint8_t> packet,
    std::size_t &length,
    const bool rtcp,
    bool &replay
  ) noexcept {
    if (impl_ == nullptr) {
      replay = false;
      return CLSP_STATUS_RESOURCE_EXHAUSTED;
    }
    return impl_->unprotect(packet, length, rtcp, replay);
  }

  clsp_status_t SrtpSession::protect(
    const std::span<std::uint8_t> packet,
    std::size_t &length,
    const bool rtcp
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->protect(packet, length, rtcp);
  }

  clsp_status_t SrtpSession::rtcp_protect_trailer_length(std::size_t &length) const noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->rtcp_protect_trailer_length(length);
  }

  bool SrtpSession::ready() const noexcept {
    return impl_ != nullptr && impl_->ready();
  }

  clsp_status_t SrtpSession::configure_video_inbound(
    const VideoSrtpInboundConfiguration &configuration,
    const std::span<const int> encrypted_extension_ids
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->configure_video_inbound(configuration, encrypted_extension_ids);
  }

  clsp_status_t SrtpSession::configure_inbound_stream(
    const std::uint32_t ssrc,
    const std::span<const int> encrypted_extension_ids
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->configure_inbound_stream(ssrc, encrypted_extension_ids);
  }

  clsp_status_t SrtpSession::unprotect_video(
    const std::span<std::uint8_t> packet,
    std::size_t &length,
    const bool rtcp,
    bool &replay
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->unprotect_video(packet, length, rtcp, replay);
  }
}  // namespace umbra::lsp
