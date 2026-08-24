#ifndef UMBRA_OPTIMIZATION_MODE_RTSP_EXTENSION_H
#define UMBRA_OPTIMIZATION_MODE_RTSP_EXTENSION_H

#include "UmbraStreamingBridge.h"

#include <stdbool.h>

/*
 * The pinned Moonlight transport is process-global. The facade configures this
 * extension immediately before LiStartConnection(), and clears it immediately
 * after that blocking call returns on every success, failure, or cancellation
 * path. Legacy/NVIDIA mode emits no Umbra or Lumen attributes. The dedicated
 * client-protocol marker is emitted only with an explicitly selected Lumen
 * optimization or fidelity extension.
 */
bool umbra_optimization_mode_rtsp_configure(UmbraStreamOptimizationMode mode);
bool umbra_video_fidelity_rtsp_configure(UmbraStreamFidelityMode mode);
void umbra_optimization_mode_rtsp_clear(void);
bool umbra_optimization_mode_rtsp_append_announce(char **payload, int *payload_length);

#if defined(UMBRA_STREAM_TESTING)
UmbraStreamOptimizationMode umbra_optimization_mode_rtsp_test_current(void);
#endif

#endif
