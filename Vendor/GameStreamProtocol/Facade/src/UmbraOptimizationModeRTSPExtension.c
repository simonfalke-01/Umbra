#include "UmbraOptimizationModeRTSPExtension.h"

#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define UMBRA_OPTIMIZATION_MODE_RTSP_MAX_ANNOUNCE_LENGTH (1024 * 1024)

static const char kOptimizationModePrefix[] = "a=x-lumen-optimization-mode:";
static const char kLatencyAttribute[] = "a=x-lumen-optimization-mode:latency\r\n";
static const char kQualityAttribute[] = "a=x-lumen-optimization-mode:quality\r\n";
static const char kFidelityPrefix[] = "a=x-lumen-video-fidelity:";
static const char kVisuallyLosslessAttribute[] = "a=x-lumen-video-fidelity:visually-lossless-allowed\r\n";
static const char kCodecLosslessAttribute[] = "a=x-lumen-video-fidelity:codec-lossless-required\r\n";
static const char kUmbraClientPrefix[] = "a=x-umbra-client-protocol:";
static const char kUmbraLegacyClientAttribute[] = "a=x-umbra-client-protocol:legacy-v1\r\n";

static atomic_int g_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY;
static atomic_int g_fidelity_mode = UMBRA_STREAM_FIDELITY_UNSPECIFIED;

static bool is_known_mode(UmbraStreamOptimizationMode mode) {
    return mode >= UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY &&
        mode <= UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY;
}

static bool contains_attribute_prefix(
    const char *payload,
    size_t payload_length,
    const char *prefix,
    size_t prefix_length
) {
    if (payload_length < prefix_length) {
        return false;
    }
    for (size_t offset = 0; offset <= payload_length - prefix_length; offset++) {
        if (memcmp(payload + offset, prefix, prefix_length) == 0) {
            return true;
        }
    }
    return false;
}

static bool append_attribute(
    char **payload,
    int *payload_length,
    const char *prefix,
    size_t prefix_length,
    const char *attribute
) {
    const size_t original_length = (size_t)*payload_length;
    const size_t attribute_length = strlen(attribute);
    if (contains_attribute_prefix(*payload, original_length, prefix, prefix_length) ||
        original_length > (size_t)INT_MAX - attribute_length ||
        original_length + attribute_length > UMBRA_OPTIMIZATION_MODE_RTSP_MAX_ANNOUNCE_LENGTH) {
        return false;
    }

    char *resized = realloc(*payload, original_length + attribute_length + 1);
    if (resized == NULL) {
        return false;
    }
    memcpy(resized + original_length, attribute, attribute_length);
    resized[original_length + attribute_length] = '\0';
    *payload = resized;
    *payload_length = (int)(original_length + attribute_length);
    return true;
}

bool umbra_optimization_mode_rtsp_configure(UmbraStreamOptimizationMode mode) {
    if (!is_known_mode(mode)) {
        umbra_optimization_mode_rtsp_clear();
        return false;
    }
    atomic_store_explicit(&g_optimization_mode, mode, memory_order_release);
    return true;
}

bool umbra_video_fidelity_rtsp_configure(UmbraStreamFidelityMode mode) {
    if (mode < UMBRA_STREAM_FIDELITY_UNSPECIFIED ||
        mode > UMBRA_STREAM_FIDELITY_CODEC_LOSSLESS_REQUIRED) {
        atomic_store_explicit(&g_fidelity_mode, UMBRA_STREAM_FIDELITY_UNSPECIFIED, memory_order_release);
        return false;
    }
    atomic_store_explicit(&g_fidelity_mode, mode, memory_order_release);
    return true;
}

void umbra_optimization_mode_rtsp_clear(void) {
    atomic_store_explicit(
        &g_optimization_mode,
        UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY,
        memory_order_release
    );
    atomic_store_explicit(
        &g_fidelity_mode,
        UMBRA_STREAM_FIDELITY_UNSPECIFIED,
        memory_order_release
    );
}

bool umbra_optimization_mode_rtsp_append_announce(char **payload, int *payload_length) {
    UmbraStreamOptimizationMode mode = (UmbraStreamOptimizationMode)atomic_load_explicit(
        &g_optimization_mode,
        memory_order_acquire
    );
    UmbraStreamFidelityMode fidelity = (UmbraStreamFidelityMode)atomic_load_explicit(
        &g_fidelity_mode,
        memory_order_acquire
    );
    if (!is_known_mode(mode) || payload == NULL || payload_length == NULL || *payload == NULL ||
        *payload_length < 0 || *payload_length > UMBRA_OPTIMIZATION_MODE_RTSP_MAX_ANNOUNCE_LENGTH ||
        fidelity < UMBRA_STREAM_FIDELITY_UNSPECIFIED ||
        fidelity > UMBRA_STREAM_FIDELITY_CODEC_LOSSLESS_REQUIRED ||
        (fidelity != UMBRA_STREAM_FIDELITY_UNSPECIFIED && mode != UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY)) {
        return false;
    }

    /* Legacy/NVIDIA sessions must retain the pinned GameStream ANNOUNCE bytes.
     * Umbra's dedicated marker is emitted only alongside an explicitly gated
     * Lumen optimization or fidelity extension. */
    if (mode == UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY &&
        fidelity == UMBRA_STREAM_FIDELITY_UNSPECIFIED) {
        return true;
    }

    if (!append_attribute(
            payload,
            payload_length,
            kUmbraClientPrefix,
            sizeof(kUmbraClientPrefix) - 1,
            kUmbraLegacyClientAttribute)) {
        return false;
    }

    if (mode != UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY) {
        const char *attribute = mode == UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY
            ? kLatencyAttribute
            : kQualityAttribute;
        if (!append_attribute(
                payload,
                payload_length,
                kOptimizationModePrefix,
                sizeof(kOptimizationModePrefix) - 1,
                attribute)) {
            return false;
        }
    }
    if (fidelity != UMBRA_STREAM_FIDELITY_UNSPECIFIED) {
        const char *attribute = fidelity == UMBRA_STREAM_FIDELITY_CODEC_LOSSLESS_REQUIRED
            ? kCodecLosslessAttribute
            : kVisuallyLosslessAttribute;
        if (!append_attribute(
                payload,
                payload_length,
                kFidelityPrefix,
                sizeof(kFidelityPrefix) - 1,
                attribute)) {
            return false;
        }
    }
    return true;
}

#if defined(UMBRA_STREAM_TESTING)
UmbraStreamOptimizationMode umbra_optimization_mode_rtsp_test_current(void) {
    return (UmbraStreamOptimizationMode)atomic_load_explicit(
        &g_optimization_mode,
        memory_order_acquire
    );
}
#endif
