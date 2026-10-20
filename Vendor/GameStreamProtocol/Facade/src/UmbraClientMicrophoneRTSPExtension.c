#include "Platform.h"
#include "Rtsp.h"
#include "UmbraClientMicrophoneRTSPExtension.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern struct sockaddr_storage RemoteAddr;

static const char *const k_describe_attributes[] = {
    "a=x-lumen-mic.version:1",
    "a=x-lumen-mic.codec:opus",
    "a=x-lumen-mic.sampleRate:48000",
    "a=x-lumen-mic.channels:1",
    "a=x-lumen-mic.packetDurationMs:20",
    "a=x-lumen-mic.crypto:aes-256-gcm",
    "a=x-lumen-mic.fec:opus-inband"
};

static const char k_announce_attributes[] =
    "a=x-lumen-mic.enabled:1\r\n"
    "a=x-lumen-mic.version:1\r\n"
    "a=x-lumen-mic.codec:opus\r\n"
    "a=x-lumen-mic.sampleRate:48000\r\n"
    "a=x-lumen-mic.channels:1\r\n"
    "a=x-lumen-mic.packetDurationMs:20\r\n"
    "a=x-lumen-mic.fec:opus-inband\r\n";

static struct {
    bool requested;
    bool capability_accepted;
    bool setup_succeeded;
    uint16_t client_port;
    UmbraClientMicrophoneRTSPSnapshot snapshot;
} g_microphone_rtsp;

static bool line_equals(const char *line, size_t line_length, const char *expected) {
    size_t expected_length = strlen(expected);
    return line_length == expected_length && memcmp(line, expected, expected_length) == 0;
}

static bool line_has_microphone_prefix(const char *line, size_t line_length) {
    static const char prefix[] = "a=x-lumen-mic.";
    return line_length >= sizeof(prefix) - 1 && memcmp(line, prefix, sizeof(prefix) - 1) == 0;
}

static void clear_negotiated_state(void) {
    g_microphone_rtsp.capability_accepted = false;
    g_microphone_rtsp.setup_succeeded = false;
    memset(&g_microphone_rtsp.snapshot, 0, sizeof(g_microphone_rtsp.snapshot));
}

void umbra_client_microphone_rtsp_configure(bool requested, uint16_t client_port) {
    memset(&g_microphone_rtsp, 0, sizeof(g_microphone_rtsp));
    g_microphone_rtsp.requested = requested;
    g_microphone_rtsp.client_port = client_port;
}

void umbra_client_microphone_rtsp_clear(void) {
    memset(&g_microphone_rtsp, 0, sizeof(g_microphone_rtsp));
}

bool umbra_client_microphone_rtsp_accept_describe(const char *payload, size_t payload_length) {
    clear_negotiated_state();
    if (!g_microphone_rtsp.requested || payload == NULL || payload_length == 0) {
        return false;
    }

    size_t expected_index = 0;
    bool malformed = false;
    size_t offset = 0;
    while (offset < payload_length) {
        size_t line_start = offset;
        while (offset < payload_length && payload[offset] != '\n') {
            offset++;
        }
        size_t line_length = offset - line_start;
        if (line_length > 0 && payload[line_start + line_length - 1] == '\r') {
            line_length--;
        }
        if (offset < payload_length) {
            offset++;
        }

        const char *line = payload + line_start;
        if (line_has_microphone_prefix(line, line_length)) {
            if (expected_index >= sizeof(k_describe_attributes) / sizeof(k_describe_attributes[0]) ||
                !line_equals(line, line_length, k_describe_attributes[expected_index])) {
                malformed = true;
            }
            else {
                expected_index++;
            }
        }
        else if (expected_index > 0 &&
                 expected_index < sizeof(k_describe_attributes) / sizeof(k_describe_attributes[0])) {
            /* The version-one advertisement is one exact, contiguous block. */
            malformed = true;
        }
    }

    g_microphone_rtsp.capability_accepted = !malformed &&
        expected_index == sizeof(k_describe_attributes) / sizeof(k_describe_attributes[0]);
    return g_microphone_rtsp.capability_accepted;
}

bool umbra_client_microphone_rtsp_should_setup(void) {
    return g_microphone_rtsp.requested && g_microphone_rtsp.capability_accepted;
}

char *umbra_client_microphone_rtsp_setup_target(void) {
    static char target[] = "streamid=lumen-mic/1/0";
    return target;
}

bool umbra_client_microphone_rtsp_format_transport(char *buffer, size_t capacity) {
    if (!umbra_client_microphone_rtsp_should_setup() || buffer == NULL || capacity == 0 ||
        g_microphone_rtsp.client_port == 0 || g_microphone_rtsp.client_port == UINT16_MAX) {
        return false;
    }
    int written = snprintf(
        buffer,
        capacity,
        "unicast;X-GS-ClientPort=%u-%u",
        (unsigned int)g_microphone_rtsp.client_port,
        (unsigned int)g_microphone_rtsp.client_port + 1
    );
    return written > 0 && (size_t)written < capacity;
}

static bool ascii_case_insensitive_equals(const char *left, const char *right) {
    while (*left != '\0' && *right != '\0') {
        unsigned char left_character = (unsigned char)*left++;
        unsigned char right_character = (unsigned char)*right++;
        if (left_character >= 'A' && left_character <= 'Z') {
            left_character = (unsigned char)(left_character + ('a' - 'A'));
        }
        if (right_character >= 'A' && right_character <= 'Z') {
            right_character = (unsigned char)(right_character + ('a' - 'A'));
        }
        if (left_character != right_character) {
            return false;
        }
    }
    return *left == '\0' && *right == '\0';
}

static const char *single_header_value(const RTSP_MESSAGE *response, const char *name) {
    const char *value = NULL;
    size_t count = 0;
    for (POPTION_ITEM option = response->options; option != NULL; option = option->next) {
        if (ascii_case_insensitive_equals(option->option, name)) {
            value = option->content;
            count++;
        }
    }
    return count == 1 ? value : NULL;
}

static bool decode_lowercase_hex_16(const char *text, uint8_t output[16]) {
    if (text == NULL || strlen(text) != 32) {
        return false;
    }
    for (size_t index = 0; index < 16; index++) {
        unsigned int high;
        unsigned int low;
        char high_character = text[index * 2];
        char low_character = text[index * 2 + 1];
        if (high_character >= '0' && high_character <= '9') {
            high = (unsigned int)(high_character - '0');
        }
        else if (high_character >= 'a' && high_character <= 'f') {
            high = (unsigned int)(high_character - 'a' + 10);
        }
        else {
            return false;
        }
        if (low_character >= '0' && low_character <= '9') {
            low = (unsigned int)(low_character - '0');
        }
        else if (low_character >= 'a' && low_character <= 'f') {
            low = (unsigned int)(low_character - 'a' + 10);
        }
        else {
            return false;
        }
        output[index] = (uint8_t)((high << 4) | low);
    }
    return true;
}

static bool parse_server_port(const char *transport, uint16_t *server_port) {
    static const char prefix[] = "unicast;server_port=";
    if (transport == NULL || server_port == NULL) {
        return false;
    }
    if (strncmp(transport, prefix, sizeof(prefix) - 1) != 0) {
        return false;
    }
    const char *start = transport + sizeof(prefix) - 1;
    if (*start < '0' || *start > '9') {
        return false;
    }
    unsigned long value = 0;
    const char *cursor = start;
    while (*cursor >= '0' && *cursor <= '9') {
        value = value * 10 + (unsigned long)(*cursor - '0');
        if (value > UINT16_MAX) {
            return false;
        }
        cursor++;
    }
    if (value == 0 || *cursor != '\0') {
        return false;
    }
    *server_port = (uint16_t)value;
    return true;
}

static bool snapshot_selected_remote_address(
    char output[UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY]
) {
    memset(output, 0, UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY);
    const struct sockaddr *address = (const struct sockaddr *)&RemoteAddr;
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)address;
        return inet_ntop(
            AF_INET,
            &ipv4->sin_addr,
            output,
            UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY
        ) != NULL;
    }
    if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *ipv6 = (const struct sockaddr_in6 *)address;
        if (inet_ntop(
                AF_INET6,
                &ipv6->sin6_addr,
                output,
                UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY
            ) == NULL) {
            return false;
        }
        if (ipv6->sin6_scope_id != 0) {
            size_t address_length = strlen(output);
            int written = snprintf(
                output + address_length,
                UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY - address_length,
                "%%%u",
                (unsigned int)ipv6->sin6_scope_id
            );
            if (written <= 0 ||
                (size_t)written >= UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY - address_length) {
                memset(output, 0, UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY);
                return false;
            }
        }
        return true;
    }
    return false;
}

static bool accept_successful_setup(const RTSP_MESSAGE *response) {
    g_microphone_rtsp.setup_succeeded = false;
    memset(&g_microphone_rtsp.snapshot, 0, sizeof(g_microphone_rtsp.snapshot));
    if (!umbra_client_microphone_rtsp_should_setup() || response == NULL ||
        response->type != TYPE_RESPONSE || response->message.response.statusCode != 200) {
        g_microphone_rtsp.capability_accepted = false;
        return false;
    }

    const char *session = single_header_value(response, "X-Lumen-Mic-Session");
    const char *salt = single_header_value(response, "X-Lumen-Mic-Salt");
    const char *transport = single_header_value(response, "Transport");
    if (!decode_lowercase_hex_16(session, g_microphone_rtsp.snapshot.session_id) ||
        !decode_lowercase_hex_16(salt, g_microphone_rtsp.snapshot.salt) ||
        !parse_server_port(transport, &g_microphone_rtsp.snapshot.server_port) ||
        !snapshot_selected_remote_address(g_microphone_rtsp.snapshot.remote_address)) {
        clear_negotiated_state();
        return false;
    }

    g_microphone_rtsp.snapshot.client_port = g_microphone_rtsp.client_port;
    g_microphone_rtsp.setup_succeeded = true;
    return true;
}

UmbraClientMicrophoneRTSPSetupDisposition umbra_client_microphone_rtsp_evaluate_setup(
    const RTSP_MESSAGE *response
) {
    if (!umbra_client_microphone_rtsp_should_setup() || response == NULL ||
        response->type != TYPE_RESPONSE) {
        clear_negotiated_state();
        return UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_FATAL;
    }
    if (response->message.response.statusCode != 200) {
        clear_negotiated_state();
        return UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_DECLINED;
    }
    return accept_successful_setup(response)
        ? UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_ACCEPTED
        : UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_FATAL;
}

bool umbra_client_microphone_rtsp_append_announce(char **payload, int *payload_length) {
    if (!g_microphone_rtsp.setup_succeeded) {
        return true;
    }
    if (payload == NULL || payload_length == NULL || *payload == NULL || *payload_length < 0 ||
        (size_t)*payload_length > SIZE_MAX - (sizeof(k_announce_attributes) - 1) ||
        (size_t)*payload_length + (sizeof(k_announce_attributes) - 1) > INT_MAX) {
        clear_negotiated_state();
        return false;
    }

    size_t original_length = (size_t)*payload_length;
    size_t selection_length = sizeof(k_announce_attributes) - 1;
    char *extended = realloc(*payload, original_length + selection_length);
    if (extended == NULL) {
        clear_negotiated_state();
        return false;
    }
    memcpy(extended + original_length, k_announce_attributes, selection_length);
    *payload = extended;
    *payload_length = (int)(original_length + selection_length);
    return true;
}

bool umbra_client_microphone_rtsp_take_snapshot(UmbraClientMicrophoneRTSPSnapshot *snapshot) {
    if (snapshot == NULL || !g_microphone_rtsp.setup_succeeded) {
        return false;
    }
    *snapshot = g_microphone_rtsp.snapshot;
    umbra_client_microphone_rtsp_clear();
    return true;
}

#if defined(UMBRA_STREAM_TESTING)
bool umbra_client_microphone_rtsp_test_setup_succeeded(void) {
    return g_microphone_rtsp.setup_succeeded;
}
#endif
