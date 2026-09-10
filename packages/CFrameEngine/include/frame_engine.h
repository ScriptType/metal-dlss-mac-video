#ifndef HDR_FRAME_ENGINE_H
#define HDR_FRAME_ENGINE_H
#include <stdint.h>
#include "hdr_cache_pixels.h"
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define FE_ABI_VERSION 1
// macOS process memory sampling; zero means unavailable.
uint64_t fe_process_resident_bytes(void);
typedef struct fe_session fe_session;
typedef struct fe_output fe_output;
typedef enum { FE_ACCEPTED = 0, FE_FULL = 1, FE_CANCELLED = 2, FE_FAILED = 3,
               FE_EMPTY = 4, FE_DUPLICATE = 5 } fe_status;
typedef enum { FE_LINEAR = 0, FE_SRGB = 1, FE_BT709 = 2, FE_PQ = 3, FE_HLG = 4 } fe_transfer;
typedef enum { FE_BT2020 = 0, FE_BT709_PRIMARIES = 1, FE_DISPLAY_P3 = 2 } fe_primaries;
typedef enum { FE_RGB = 0, FE_YUV709 = 1, FE_YUV2020 = 2, FE_YUV601 = 3 } fe_matrix;
typedef enum { FE_FULL_RANGE = 0, FE_VIDEO_RANGE = 1 } fe_range;
typedef enum { FE_CONTENT_UNKNOWN = 0, FE_CONTENT_ORIGINAL = 1, FE_CONTENT_ENHANCED = 2,
               FE_CONTENT_PREPARED_ORIGINAL = 3, FE_CONTENT_PREPARED_ENHANCED = 4 } fe_content_kind;
typedef struct { int64_t value; int32_t timescale; } fe_time;
typedef struct {
    uint32_t width, height;
    double crop_x, crop_y, crop_width, crop_height;
    double rotation_degrees;
    uint32_t pixel_aspect_num, pixel_aspect_den;
} fe_geometry;
typedef struct {
    uint32_t primaries, transfer, matrix, range, chroma_location;
    double reference_white_nits, hlg_peak_nits;
    // xy pairs for R/G/B/white; metadata is source interpretation, never guessed.
    double mastering_xy[8];
    double mastering_min_nits, mastering_max_nits, max_cll, max_fall;
} fe_colour;
typedef struct {
    uint32_t width, height, bytes_per_row;
    uint64_t offset;
} fe_plane;
typedef struct {
    uint32_t struct_size, abi_version;
    uint64_t source_id, stream_id, frame_id, generation;
    fe_time pts, duration;
    fe_geometry geometry;
    fe_colour colour;
    // Output retains source interpretation separately from transformed colour.
    fe_colour source_colour;
    uint32_t pixel_format, plane_count;
    fe_plane planes[3];
    // CVPixelBufferRef. Accepted submissions retain it; it must remain immutable.
    void *pixel_buffer;
    // Optional id<MTLSharedEvent>. Producer MUST eventually signal ready_value.
    void *ready_event;
    uint64_t ready_value;
    // Optional additional storage owner, retained synchronously on acceptance.
    void *owner;
    void (*retain_owner)(void *);
    void (*release_owner)(void *);
    // Monotonic host seconds (CACurrentMediaTime); zero means no deadline.
    double deadline_host_seconds;
} fe_frame;
typedef struct {
    uint32_t struct_size, abi_version, max_in_flight;
    uint64_t memory_limit_bytes;
    uint32_t processing_width, processing_height;
    double reference_white_nits, effect_strength, colour_strength, maximum_luminance_ratio;
    // UTF-8 strings are copied by create. NULL weights selects HDR bypass.
    const char *model_path, *model_version;
} fe_config;
typedef struct {
    uint64_t submitted, completed, cancelled, failures, duplicate_submissions;
    uint64_t retained_bytes, peak_retained_bytes;
    uint32_t occupied_slots, peak_slots;
    double last_completed_seconds;
} fe_statistics;

// Process-wide neural residency/processing/cache admission policy; configure
// before retaining neural sessions. JSON keys and measured counters are defined
// in docs/frame-engine.md. This supplements per-session frame limits and does
// not claim a hard cap on transient MLX or operating-system resident memory.
fe_status fe_runtime_configure(const char *policy_json, char *error, size_t capacity);
size_t fe_runtime_resources_json(char *json, size_t capacity);

// No function waits for inference/GPU work. Configuration is immutable per session.
fe_session *fe_session_create(const fe_config *config, char *error, size_t error_capacity);
fe_status fe_session_submit(fe_session *session, const fe_frame *frame);
// Returned lease owns the immutable pixel buffer, valid until fe_output_release.
fe_status fe_session_poll(fe_session *session, fe_output **output);
// Redraw returns the most recent completed frame; never submits temporal work.
fe_status fe_session_redraw(fe_session *session, fe_output **output);
const fe_frame *fe_output_frame(const fe_output *output);
// A polled output is already GPU-complete. Consumers retain the lease until their
// own GPU completion. Output leases survive reset and session destruction.
void fe_output_release(fe_output *output);
// Immutable provenance of this output lease; use this for the displayed state,
// not a context progress snapshot which may refer to a later queued frame.
fe_content_kind fe_output_content_kind(const fe_output *output);
// The adapter must compare this generation immediately before presentation.
uint64_t fe_session_generation(fe_session *session);
// Increments generation; drops queued/completed work and resets temporal history.
uint64_t fe_session_reset(fe_session *session);
void fe_session_statistics(fe_session *session, fe_statistics *statistics);
// Copies latest asynchronous failure; returns required UTF-8 bytes incl terminator.
size_t fe_session_error(fe_session *session, char *error, size_t capacity);
// MeasurementConfiguration JSON (docs/frame-engine.md), before first submission.
fe_status fe_session_measurements_configure(fe_session *session, const char *configuration_json);
void fe_session_record_presentation(fe_session *session, uint64_t generation, uint64_t frame_id,
                                    double host_seconds, double av_offset_seconds);
void fe_session_record_drop(fe_session *session, uint64_t generation, uint64_t frame_id);
void fe_session_record_transfers(fe_session *session, uint64_t generation, uint64_t frame_id,
                                 int32_t gpu_copies, int32_t cpu_readbacks, int32_t cpu_waits);
void fe_session_record_seek(fe_session *session, double seconds);
void fe_session_record_energy(fe_session *session, double joules);
// Returns required bytes including NUL. Retry if greater than capacity. NULL JSON
// queries size. Reports include unavailable metrics; NAN A/V offset means unknown.
size_t fe_session_measurements_json(fe_session *session, char *json, size_t capacity);
// Nonblocking shutdown. Before unloading this dylib or terminating its runtime,
// close every session, poll until idle, then destroy. Ordinary output leases may
// outlive sessions but must also be released before unloading the library.
void fe_session_close(fe_session *session);
int32_t fe_session_is_idle(fe_session *session);
void fe_session_destroy(fe_session *session);
// Prepared mode shares the persistent HDRSegmentCache with its asynchronous
// preparation job. actual_source_path must come from the opened playback core,
// never from an independently supplied cache configuration. JSON fields are
// sourcePath, cacheDirectory, capacityBytes, optional rangeStart/rangeEnd exact
// {value,timescale}, segmentFrames (default60), prerollFrames (default8).
typedef struct fe_prepared fe_prepared;
// A selected-core provider owns independent background readers. Inventory mode
// returns exact decoded/playback PTS, duration and geometry with NULL pixels.
// Pixel mode returns immutable decoded CVPixelBuffers for [start,end), including
// every frame from exact preroll. Seeking to an earlier keyframe is internal.
// Inventory scans the whole video stream; start/end timescale are zero there.
// Stream index is the zero-based video stream ordinal, not a global stream ID.
typedef enum { FE_PREPARATION_INVENTORY = 0, FE_PREPARATION_PIXELS = 1 } fe_preparation_mode;
typedef struct {
    uint32_t struct_size, abi_version;
    // Copied UTF-8 semantic version, including decoder and exact timing policy.
    const char *identifier;
    void *user;
    void (*retain_user)(void *);
    void (*release_user)(void *);
    void *(*open)(void *user, const char *source_path, uint32_t video_stream_index,
                  fe_time start, fe_time end, uint32_t mode, char *error, size_t capacity);
    // FE_ACCEPTED=one frame, FE_EMPTY=EOF, FE_FAILED/FE_CANCELLED otherwise.
    // Descriptor/pixel/owner pointers remain valid until next() or close(). The
    // engine retains accepted CVPixelBuffer/owner before asking for another frame.
    fe_status (*next)(void *reader, fe_frame *frame, char *error, size_t capacity);
    // cancel is thread-safe, nonblocking and may overlap next; it interrupts I/O.
    // open/next/close are serial per reader on a utility queue. Different readers
    // may run concurrently. close follows any in-flight next and runs exactly once.
    void (*cancel)(void *reader);
    void (*close)(void *reader);
} fe_preparation_decoder_provider;
fe_prepared *fe_prepared_create(const fe_config *config, const char *configuration_json,
                                const char *actual_source_path, char *error, size_t capacity);
// Copies the vtable and identifier; retains user if non-NULL (paired callbacks
// then required). Callback code must remain loaded until all contexts are idle
// and destroyed. No fallback to another decoder on failure or timing mismatch.
fe_prepared *fe_prepared_create_with_decoder(const fe_config *config, const char *configuration_json,
                                const char *actual_source_path, const fe_preparation_decoder_provider *decoder,
                                char *error, size_t capacity);
fe_session *fe_prepared_session_create(fe_prepared *prepared, char *error, size_t capacity);
fe_status fe_prepared_start(fe_prepared *prepared);
void fe_prepared_cancel(fe_prepared *prepared);
size_t fe_prepared_progress_json(fe_prepared *prepared, char *json, size_t capacity);
int32_t fe_prepared_is_idle(fe_prepared *prepared);
// For process teardown, cancel preparation, close/drain all playback sessions,
// wait for prepared idle, then destroy sessions and this handle. Calls do not wait.
void fe_prepared_destroy(fe_prepared *prepared);
#ifdef __cplusplus
}
#endif
#endif
