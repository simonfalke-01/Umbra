#ifndef UMBRA_CLIENT_MICROPHONE_RTSP_EXTENSION_H
#define UMBRA_CLIENT_MICROPHONE_RTSP_EXTENSION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct _RTSP_MESSAGE;

#ifndef UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY
#define UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY 64
#endif

typedef struct UmbraClientMicrophoneRTSPSnapshot {
    uint8_t session_id[16];
    uint8_t salt[16];
    uint16_t server_port;
    uint16_t client_port;
    char remote_address[UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY];
} UmbraClientMicrophoneRTSPSnapshot;

typedef enum UmbraClientMicrophoneRTSPSetupDisposition {
    UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_DECLINED = 0,
    UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_ACCEPTED = 1,
    UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_FATAL = 2
} UmbraClientMicrophoneRTSPSetupDisposition;

void umbra_client_microphone_rtsp_configure(bool requested, uint16_t client_port);
void umbra_client_microphone_rtsp_clear(void);

bool umbra_client_microphone_rtsp_accept_describe(const char *payload, size_t payload_length);
bool umbra_client_microphone_rtsp_should_setup(void);
char *umbra_client_microphone_rtsp_setup_target(void);
bool umbra_client_microphone_rtsp_format_transport(char *buffer, size_t capacity);
UmbraClientMicrophoneRTSPSetupDisposition umbra_client_microphone_rtsp_evaluate_setup(
    const struct _RTSP_MESSAGE *response
);

/*
 * Appends the exact version-one ANNOUNCE selection after successful SETUP and
 * otherwise succeeds without modifying the normal GameStream payload.
 * After successful SETUP, allocation failure is fatal: Lumen has committed
 * microphone state and would reject a normal ANNOUNCE without this selection.
 */
bool umbra_client_microphone_rtsp_append_announce(char **payload, int *payload_length);

/* Copies and consumes the successful generation snapshot. */
bool umbra_client_microphone_rtsp_take_snapshot(UmbraClientMicrophoneRTSPSnapshot *snapshot);

#if defined(UMBRA_STREAM_TESTING)
bool umbra_client_microphone_rtsp_test_setup_succeeded(void);
#endif

#endif
