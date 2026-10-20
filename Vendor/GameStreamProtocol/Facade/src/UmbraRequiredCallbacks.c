#include "Limelight-internal.h"

bool areRequiredCallbacksPresent(
    PDECODER_RENDERER_CALLBACKS drCallbacks,
    PAUDIO_RENDERER_CALLBACKS arCallbacks,
    PCONNECTION_LISTENER_CALLBACKS clCallbacks)
{
    return drCallbacks != NULL &&
           drCallbacks->setup != NULL &&
           drCallbacks->start != NULL &&
           drCallbacks->stop != NULL &&
           drCallbacks->cleanup != NULL &&
           drCallbacks->submitDecodeUnit != NULL &&
           arCallbacks != NULL &&
           arCallbacks->init != NULL &&
           arCallbacks->start != NULL &&
           arCallbacks->stop != NULL &&
           arCallbacks->cleanup != NULL &&
           arCallbacks->decodeAndPlaySample != NULL &&
           clCallbacks != NULL &&
           clCallbacks->stageStarting != NULL &&
           clCallbacks->stageComplete != NULL &&
           clCallbacks->stageFailed != NULL &&
           clCallbacks->connectionStarted != NULL &&
           clCallbacks->connectionTerminated != NULL &&
           clCallbacks->logMessage != NULL &&
           clCallbacks->rumble != NULL &&
           clCallbacks->connectionStatusUpdate != NULL &&
           clCallbacks->setHdrMode != NULL &&
           clCallbacks->rumbleTriggers != NULL &&
           clCallbacks->setMotionEventState != NULL &&
           clCallbacks->setControllerLED != NULL &&
           clCallbacks->setAdaptiveTriggers != NULL;
}
