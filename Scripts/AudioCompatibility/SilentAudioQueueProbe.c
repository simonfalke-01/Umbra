#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    kProbeBufferCount = 3,
    kProbeFramesPerBuffer = 720,
    kProbeChannelCount = 2,
};

typedef struct {
    AudioQueueRef queue;
    _Atomic uint64_t callbackCount;
    _Atomic int32_t callbackStatus;
    uint32_t bufferByteCount;
} ProbeContext;

static void note_first_error(_Atomic int32_t *destination, OSStatus status) {
    int32_t expected = noErr;
    (void)atomic_compare_exchange_strong(destination, &expected, status);
}

static void silent_output_callback(
    void *userData,
    AudioQueueRef queue,
    AudioQueueBufferRef buffer
) {
    ProbeContext *context = userData;
    memset(buffer->mAudioData, 0, context->bufferByteCount);
    buffer->mAudioDataByteSize = context->bufferByteCount;
    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    if (status != noErr) {
        note_first_error(&context->callbackStatus, status);
    }
    atomic_fetch_add_explicit(&context->callbackCount, 1, memory_order_relaxed);
}

static OSStatus current_output_device_uid(CFStringRef *deviceUID) {
    AudioObjectPropertyAddress defaultAddress = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    AudioDeviceID device = kAudioObjectUnknown;
    uint32_t deviceSize = sizeof(device);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &defaultAddress,
        0,
        NULL,
        &deviceSize,
        &device
    );
    if (status != noErr || device == kAudioObjectUnknown) {
        return status != noErr ? status : kAudioHardwareBadDeviceError;
    }

    AudioObjectPropertyAddress uidAddress = {
        .mSelector = kAudioDevicePropertyDeviceUID,
        .mScope = kAudioDevicePropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain,
    };
    uint32_t uidSize = sizeof(*deviceUID);
    return AudioObjectGetPropertyData(
        device,
        &uidAddress,
        0,
        NULL,
        &uidSize,
        deviceUID
    );
}

static OSStatus configure_queue(AudioQueueRef queue) {
    CFStringRef deviceUID = NULL;
    OSStatus status = current_output_device_uid(&deviceUID);
    if (status != noErr || deviceUID == NULL) {
        return status != noErr ? status : kAudioHardwareBadDeviceError;
    }
    status = AudioQueueSetProperty(
        queue,
        kAudioQueueProperty_CurrentDevice,
        &deviceUID,
        sizeof(deviceUID)
    );
    CFRelease(deviceUID);
    if (status != noErr) {
        return status;
    }

    AudioChannelLayout layout = {
        .mChannelLayoutTag = kAudioChannelLayoutTag_Stereo,
        .mChannelBitmap = 0,
        .mNumberChannelDescriptions = 0,
    };
    status = AudioQueueSetProperty(
        queue,
        kAudioQueueProperty_ChannelLayout,
        &layout,
        sizeof(layout)
    );
    if (status != noErr) {
        return status;
    }

    // The probe must exercise the physical queue without producing audible output.
    return AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 0.0f);
}

static OSStatus run_cycle(double durationSeconds, uint64_t *callbackCount) {
    AudioStreamBasicDescription format = {
        .mSampleRate = 48000.0,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagsNativeEndian,
        .mBytesPerPacket = kProbeChannelCount * sizeof(float),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = kProbeChannelCount * sizeof(float),
        .mChannelsPerFrame = kProbeChannelCount,
        .mBitsPerChannel = 32,
    };
    ProbeContext context = {
        .queue = NULL,
        .callbackCount = 0,
        .callbackStatus = noErr,
        .bufferByteCount = kProbeFramesPerBuffer * kProbeChannelCount * sizeof(float),
    };
    AudioQueueBufferRef buffers[kProbeBufferCount] = {NULL, NULL, NULL};
    OSStatus status = AudioQueueNewOutput(
        &format,
        silent_output_callback,
        &context,
        CFRunLoopGetCurrent(),
        kCFRunLoopDefaultMode,
        0,
        &context.queue
    );
    if (status != noErr) {
        return status;
    }

    status = configure_queue(context.queue);
    for (int index = 0; status == noErr && index < kProbeBufferCount; index += 1) {
        status = AudioQueueAllocateBuffer(
            context.queue,
            context.bufferByteCount,
            &buffers[index]
        );
        if (status == noErr) {
            memset(buffers[index]->mAudioData, 0, context.bufferByteCount);
            buffers[index]->mAudioDataByteSize = context.bufferByteCount;
            status = AudioQueueEnqueueBuffer(context.queue, buffers[index], 0, NULL);
        }
    }

    uint32_t primedFrames = 0;
    if (status == noErr) {
        status = AudioQueuePrime(context.queue, 0, &primedFrames);
    }
    if (status == noErr) {
        status = AudioQueueStart(context.queue, NULL);
    }
    if (status == noErr) {
        (void)CFRunLoopRunInMode(kCFRunLoopDefaultMode, durationSeconds, false);
        status = atomic_load_explicit(&context.callbackStatus, memory_order_acquire);
    }

    OSStatus stopStatus = AudioQueueStop(context.queue, true);
    OSStatus disposeStatus = AudioQueueDispose(context.queue, true);
    *callbackCount += atomic_load_explicit(&context.callbackCount, memory_order_relaxed);
    if (status != noErr) {
        return status;
    }
    if (stopStatus != noErr) {
        return stopStatus;
    }
    return disposeStatus;
}

static int copy_bundle_identifier(char *destination, size_t destinationSize) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef identifier = bundle == NULL ? NULL : CFBundleGetIdentifier(bundle);
    if (identifier == NULL) {
        return 0;
    }
    return CFStringGetCString(
        identifier,
        destination,
        (CFIndex)destinationSize,
        kCFStringEncodingUTF8
    );
}

int main(int argc, char **argv) {
    int cycleCount = argc > 1 ? atoi(argv[1]) : 3;
    double durationSeconds = argc > 2 ? strtod(argv[2], NULL) : 0.35;
    if (cycleCount < 1 || cycleCount > 20 || durationSeconds < 0.05 || durationSeconds > 5.0) {
        fprintf(stderr, "invalid probe arguments\n");
        return 64;
    }

    char bundleIdentifier[256] = {0};
    if (!copy_bundle_identifier(bundleIdentifier, sizeof(bundleIdentifier))) {
        fprintf(stderr, "could not resolve the containing app bundle identifier\n");
        return 65;
    }
    if (strcmp(bundleIdentifier, "app.umbra.Umbra") != 0) {
        fprintf(stderr, "unexpected bundle identifier: %s\n", bundleIdentifier);
        return 66;
    }

    uint64_t callbackCount = 0;
    for (int cycle = 0; cycle < cycleCount; cycle += 1) {
        OSStatus status = run_cycle(durationSeconds, &callbackCount);
        if (status != noErr) {
            fprintf(
                stderr,
                "RESULT identity=%s pid=%d cycles_completed=%d callbacks=%llu status=%d\n",
                bundleIdentifier,
                getpid(),
                cycle,
                callbackCount,
                (int)status
            );
            return 1;
        }
    }

    if (callbackCount < (uint64_t)cycleCount) {
        fprintf(stderr, "AudioQueue callbacks did not run\n");
        return 2;
    }
    printf(
        "RESULT identity=%s pid=%d cycles_completed=%d callbacks=%llu status=clean\n",
        bundleIdentifier,
        getpid(),
        cycleCount,
        callbackCount
    );
    return 0;
}
