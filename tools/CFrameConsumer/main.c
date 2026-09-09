#include "frame_engine.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <assert.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static atomic_int retained = 0, released = 0;
static void retain_owner(void *owner) { assert(owner == &retained); ++retained; }
static void release_owner(void *owner) { assert(owner == &retained); ++released; }

int main(void) {
    CFDictionaryRef surface = CFDictionaryCreate(NULL, NULL, NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = { kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey };
    const void *values[] = { surface, kCFBooleanTrue };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CVPixelBufferRef buffer = NULL;
    assert(CVPixelBufferCreate(NULL, 4, 2, kCVPixelFormatType_64RGBAHalf, attrs, &buffer) == kCVReturnSuccess);
    CFRelease(attrs); CFRelease(surface);
    CVPixelBufferLockBaseAddress(buffer, 0);
    __fp16 *samples = CVPixelBufferGetBaseAddress(buffer);
    samples[0] = -2; samples[1] = 203; samples[2] = 4000; samples[3] = 1;
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    fe_config config = { .struct_size = sizeof(config), .abi_version = FE_ABI_VERSION,
        .max_in_flight = 3, .memory_limit_bytes = 64 * 1024 * 1024,
        .processing_width = 4, .processing_height = 2, .reference_white_nits = 203,
        .effect_strength = 0, .colour_strength = 0, .maximum_luminance_ratio = 2 };
    char error[1024];
    fe_session *session = fe_session_create(&config, error, sizeof(error));
    if (!session) { fprintf(stderr, "%s\n", error); return 1; }
    assert(fe_session_measurements_configure(session,
        "{\"adapter\":\"C-consumer\",\"source\":\"numeric\",\"sourceWidth\":4,\"sourceHeight\":2,"
        "\"processingWidth\":4,\"processingHeight\":2,\"displayWidth\":4,\"displayHeight\":2,"
        "\"sourceFPS\":24,\"modelVersion\":\"original\",\"implementationRevision\":\"C-test\","
        "\"settingsJSON\":\"{}\",\"warmupFrames\":0,\"displayConfiguration\":\"offscreen\","
        "\"powerConfiguration\":\"unrecorded\"}") == FE_ACCEPTED);
    fe_frame frame = { .struct_size = sizeof(frame), .abi_version = FE_ABI_VERSION,
        .source_id = 1, .stream_id = 2, .frame_id = 3, .generation = fe_session_generation(session),
        .pts = {1001, 24000}, .duration = {1001, 24000},
        .geometry = { .width = 4, .height = 2, .crop_width = 4, .crop_height = 2,
            .pixel_aspect_num = 1, .pixel_aspect_den = 1 },
        .colour = { .primaries = FE_BT2020, .transfer = FE_LINEAR, .matrix = FE_RGB,
            .range = FE_FULL_RANGE, .reference_white_nits = 203, .hlg_peak_nits = 1000 },
        .pixel_format = kCVPixelFormatType_64RGBAHalf, .pixel_buffer = buffer,
        .owner = &retained, .retain_owner = retain_owner, .release_owner = release_owner };
    assert(fe_session_submit(session, &frame) == FE_ACCEPTED);
    assert(retained == 1);
    CFRelease(buffer); // The engine now owns the input; caller's reference is gone.

    fe_output *output = NULL;
    const struct timespec delay = {0, 1000000};
    for (int i = 0; i < 10000 && !output; ++i) {
        fe_status status = fe_session_poll(session, &output);
        assert(status == FE_EMPTY || status == FE_ACCEPTED);
        if (!output) nanosleep(&delay, NULL);
    }
    if (!output) {
        fe_session_error(session, error, sizeof(error));
        fprintf(stderr, "GPU completion timed out: %s\n", error); return 1;
    }
    const fe_frame *result = fe_output_frame(output);
    assert(result->pts.value == 1001 && result->pts.timescale == 24000);
    assert(result->frame_id == 3 && result->ready_event == NULL);
    CVPixelBufferRef result_buffer = result->pixel_buffer;
    CVPixelBufferLockBaseAddress(result_buffer, kCVPixelBufferLock_ReadOnly);
    const __fp16 *pixels = CVPixelBufferGetBaseAddress(result_buffer);
    assert(pixels[0] == -2 && pixels[1] == 203 && pixels[2] == 4000 && pixels[3] == 1);
    CVPixelBufferUnlockBaseAddress(result_buffer, kCVPixelBufferLock_ReadOnly);
    fe_output *redraw = NULL;
    assert(fe_session_redraw(session, &redraw) == FE_ACCEPTED);
    assert(fe_output_frame(redraw)->pixel_buffer == result_buffer);
    fe_statistics stats;
    fe_session_statistics(session, &stats);
    assert(stats.submitted == 1 && stats.completed == 1);
    size_t json_size = fe_session_measurements_json(session, NULL, 0);
    char *json = malloc(json_size);
    assert(json && fe_session_measurements_json(session, json, json_size) == json_size);
    assert(strstr(json, "\"completedTotal\":1") != NULL);
    assert(strstr(json, "planar_import") == NULL); // This fixture was already linear RGB.
    assert(strstr(json, "rgba16f_pack") != NULL);
    free(json);
    assert(fe_session_reset(session) != result->generation);
    fe_session_destroy(session);
    // Both leases survive teardown, including the buffer returned by the C ABI.
    assert(CVPixelBufferGetWidth(fe_output_frame(redraw)->pixel_buffer) == 4);
    fe_output_release(output); fe_output_release(redraw);
    for (int i = 0; i < 1000 && released != 1; ++i) nanosleep(&delay, NULL);
    assert(released == 1);
    printf("{\"c_abi\":1,\"completed_frames\":1,\"hdr_samples_nits\":[-2,203,4000],"
           "\"same_frame_redraw\":true,\"owner_released\":true,\"lease_survived_destroy\":true}\n");
    return 0;
}
